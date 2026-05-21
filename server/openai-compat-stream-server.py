#!/usr/bin/env python3
"""OpenAI-compatible Whisper HTTP (Bearer auth) ASRProvider.

Buffers voice-stt PCM frames (int16 LE @ 16kHz mono) until EOF, then sends
one multipart/form-data POST to a Whisper-compatible HTTP endpoint and emits
exactly one final event.

Credentials: ~/.config/voice-stt/secrets/openai-compat.env (mode 600):
    OPENAI_COMPAT_API_KEY=...

Env vars (defaults shown):
    OPENAI_COMPAT_SECRETS     ~/.config/voice-stt/secrets/openai-compat.env
    OPENAI_COMPAT_BASE_URL    https://api.openai.com/v1
    OPENAI_COMPAT_MODEL       whisper-1
    OPENAI_COMPAT_LANGUAGE    ""   ("" = let server auto-detect)
    OPENAI_COMPAT_TIMEOUT_S   30
    HOTWORDS_FILE             ./hotwords.yaml   (mappings applied post-correct)
    LISTEN_HOST               0.0.0.0
    LISTEN_PORT               18096
"""

import asyncio
import io
import json
import os
import urllib.error
import urllib.request
import wave
from pathlib import Path

from asr_common import (
    ASRProvider,
    apply_mappings,
    env_int,
    env_path,
    env_str,
    load_mappings,
    log,
    parse_env_file,
    serve,
)


# ────────────────────── config ──────────────────────
SECRETS_PATH = env_path("OPENAI_COMPAT_SECRETS", lambda: Path.home() / ".config" / "voice-stt" / "secrets" / "openai-compat.env")
OPENAI_COMPAT_BASE_URL = env_str("OPENAI_COMPAT_BASE_URL", "https://api.openai.com/v1")
OPENAI_COMPAT_MODEL = env_str("OPENAI_COMPAT_MODEL", "whisper-1")
OPENAI_COMPAT_LANGUAGE = env_str("OPENAI_COMPAT_LANGUAGE", "")  # "" = let server auto-detect
OPENAI_COMPAT_TIMEOUT_S = env_int("OPENAI_COMPAT_TIMEOUT_S", 30)
HOTWORDS_FILE = env_str("HOTWORDS_FILE", str(Path(__file__).parent / "hotwords.yaml"))
LISTEN_HOST = env_str("LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = env_int("LISTEN_PORT", 18096)


def _pcm_to_wav(pcm_bytes: bytes, sample_rate: int) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)  # int16
        wav.setframerate(sample_rate)
        wav.writeframes(pcm_bytes)
    return buf.getvalue()


class OpenAICompatProvider(ASRProvider):
    BACKEND_TAG = "openai-compat-whisper"
    SAMPLE_RATE = 16000

    def __init__(self, api_key: str, base_url: str, model: str, language: str, timeout_s: int, mappings: dict[str, str]):
        self._api_key = api_key
        self._base_url = base_url.rstrip("/")
        self._model = model
        self._language = language
        self._timeout_s = timeout_s
        self._mappings = mappings
        self._buf = bytearray()
        self._done = asyncio.Event()
        self._final_event: dict | None = None

    async def connect(self) -> None:
        return

    async def send_audio(self, pcm: bytes) -> None:
        self._buf.extend(pcm)

    def _post_audio_sync(self, pcm: bytes) -> dict:
        wav_bytes = _pcm_to_wav(pcm, self.SAMPLE_RATE)

        boundary = f"----vstt-{os.urandom(8).hex()}"
        parts: list[bytes] = []

        def _add_field(name: str, value: str) -> None:
            parts.append(
                f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="{name}"\r\n\r\n'
                f"{value}\r\n".encode("utf-8")
            )

        def _add_file(name: str, filename: str, content_type: str, data: bytes) -> None:
            parts.append(
                f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'
                f"Content-Type: {content_type}\r\n\r\n".encode("utf-8")
            )
            parts.append(data)
            parts.append(b"\r\n")

        _add_field("model", self._model)
        if self._language:
            _add_field("language", self._language)
        _add_file("file", "audio.wav", "audio/wav", wav_bytes)
        parts.append(f"--{boundary}--\r\n".encode("utf-8"))
        body = b"".join(parts)

        req = urllib.request.Request(
            url=f"{self._base_url}/audio/transcriptions",
            data=body,
            method="POST",
            headers={
                "Authorization": f"Bearer {self._api_key}",
                "Content-Type": f"multipart/form-data; boundary={boundary}",
                "Accept": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=self._timeout_s) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
            return {"type": "final", "text": payload.get("text") or ""}
        except urllib.error.HTTPError as e:
            body_text = ""
            try:
                body_text = e.read().decode("utf-8", errors="replace")[:500]
            except Exception:
                pass
            return {
                "type": "final",
                "text": "",
                "error_code": e.code,
                "error_message": f"HTTP {e.code}: {body_text}",
            }
        except json.JSONDecodeError as e:
            return {
                "type": "final",
                "text": "",
                "error_code": "invalid_json",
                "error_message": f"upstream returned non-JSON: {e}",
            }
        except Exception as e:
            return {
                "type": "final",
                "text": "",
                "error_code": "network_error",
                "error_message": f"{type(e).__name__}: {e}",
            }

    async def end_audio(self) -> None:
        if self._done.is_set():
            return
        # Snapshot buffer on the event-loop thread BEFORE scheduling the
        # executor: close() can race-clear self._buf from the same loop
        # while _post_audio_sync runs in a worker thread, and we'd then
        # POST an empty WAV (burning API quota for nothing).
        pcm = bytes(self._buf)
        if not pcm:
            if not self._done.is_set():  # defensive against future awaits
                self._final_event = {
                    "type": "final",
                    "text": "",
                    "error_code": "no_audio",
                    "error_message": "no audio buffered for transcription",
                }
                self._done.set()
            return
        loop = asyncio.get_running_loop()
        result = await loop.run_in_executor(None, self._post_audio_sync, pcm)
        if not self._done.is_set():
            self._final_event = result
            self._done.set()

    async def events(self):
        await self._done.wait()
        assert self._final_event is not None
        text = self._final_event.get("text", "")
        if text and self._mappings:
            text = apply_mappings(text, self._mappings)
            self._final_event = {**self._final_event, "text": text}
        yield self._final_event

    async def close(self) -> None:
        self._buf = bytearray()
        if not self._done.is_set():
            self._final_event = {
                "type": "final",
                "text": "",
                "error_code": "closed",
                "error_message": "session closed before transcription completed",
            }
            self._done.set()


# ────────────────────── entrypoint ──────────────────────
async def _main():
    creds = parse_env_file(SECRETS_PATH, ["OPENAI_COMPAT_API_KEY"])
    api_key = creds["OPENAI_COMPAT_API_KEY"]
    log(f"loaded credentials from {SECRETS_PATH}")

    mappings = load_mappings(HOTWORDS_FILE)
    log(f"mappings: {len(mappings)} loaded from {HOTWORDS_FILE}")
    log(
        f"upstream={OPENAI_COMPAT_BASE_URL} model={OPENAI_COMPAT_MODEL} "
        f"lang={OPENAI_COMPAT_LANGUAGE or '(auto)'}"
    )

    def provider_factory() -> OpenAICompatProvider:
        return OpenAICompatProvider(
            api_key=api_key,
            base_url=OPENAI_COMPAT_BASE_URL,
            model=OPENAI_COMPAT_MODEL,
            language=OPENAI_COMPAT_LANGUAGE,
            timeout_s=OPENAI_COMPAT_TIMEOUT_S,
            mappings=mappings,
        )

    await serve(provider_factory, LISTEN_HOST, LISTEN_PORT)


if __name__ == "__main__":
    try:
        asyncio.run(_main())
    except KeyboardInterrupt:
        pass
