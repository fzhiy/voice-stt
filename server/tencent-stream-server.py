#!/usr/bin/env python3
"""Tencent Cloud 实时语音识别 (asr.cloud.tencent.com) ASRProvider.

Recurring monthly free tier: 5h/月 (issued on the 1st, no rollover) — used
as a permanent fallback when 火山 free hours exhaust.

Credentials: ~/.config/voice-stt/secrets/tencent.env (mode 600):
    TENCENT_APP_ID=...           # from https://console.cloud.tencent.com/asr
    TENCENT_SECRET_ID=...        # API key (AKIDxxxxx)
    TENCENT_SECRET_KEY=...       # API secret (paired with secret_id)

Env vars (defaults shown):
    TENCENT_SECRETS    ~/.config/voice-stt/secrets/tencent.env
    TENCENT_ENGINE     16k_zh   (16kHz Mandarin; see tencent docs for other models)
    HOTWORDS_FILE      ./hotwords.yaml   (mappings: applied post-correct; hotword_id TODO)
    LISTEN_HOST        0.0.0.0
    LISTEN_PORT        18094

Auth (from cloud.tencent.com/document/product/1093/48982):
    sign_str = host + path + "?" + alphabetical_query
    signature = base64(hmac_sha1(sign_str, secret_key))
    final URL = wss://host/path?<all_params>&signature=<urlencoded_sig>

Response mapping (from official docs):
    slice_type=1 → utterance-in-progress (forward as voice-stt partial)
    slice_type=2 → utterance ended (treat as stable text segment)
    top-level final=1 → session ended (emit voice-stt final)
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import json
import random
import time
import urllib.parse
import uuid
from pathlib import Path
from typing import AsyncIterator, Optional

import websockets

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
SECRETS_PATH = env_path("TENCENT_SECRETS", lambda: Path.home() / ".config" / "voice-stt" / "secrets" / "tencent.env")
TENCENT_HOST = "asr.cloud.tencent.com"
TENCENT_ENGINE = env_str("TENCENT_ENGINE", "16k_zh")
HOTWORDS_FILE = env_str("HOTWORDS_FILE", str(Path(__file__).parent / "hotwords.yaml"))
LISTEN_HOST = env_str("LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = env_int("LISTEN_PORT", 18094)


# ────────────────────── auth ──────────────────────
def _build_ws_url(app_id: str, secret_id: str, secret_key: str) -> str:
    """Construct signed Tencent ASR WS URL.

    Params are alphabetically sorted for signing; signature is appended after.
    See cloud.tencent.com/document/product/1093/48982#signature for the canonical
    signing algorithm.
    """
    timestamp = int(time.time())
    params: dict[str, str] = {
        "secretid": secret_id,
        "timestamp": str(timestamp),
        "expired": str(timestamp + 86400),
        "nonce": str(random.randint(1, 999_999_999)),
        "engine_model_type": TENCENT_ENGINE,
        "voice_id": str(uuid.uuid4()),
        "voice_format": "1",          # 1 = PCM
        "needvad": "1",               # server-side VAD for utterance segmentation
        "filter_modal": "0",          # keep modal particles like 嗯/啊
        "filter_punc": "0",           # keep punctuation
        "convert_num_mode": "1",      # 数字 ITN
    }
    path = f"/asr/v2/{app_id}"

    # Signing string: host + path + "?" + alphabetical "k=v&k=v" (no URL-encoding here)
    sorted_query = "&".join(f"{k}={params[k]}" for k in sorted(params))
    sign_str = f"{TENCENT_HOST}{path}?{sorted_query}"
    sig_raw = hmac.new(secret_key.encode("utf-8"), sign_str.encode("utf-8"), hashlib.sha1).digest()
    signature = base64.b64encode(sig_raw).decode("utf-8")

    # Final URL: same params + URL-encoded signature appended
    params["signature"] = signature
    final_query = "&".join(
        f"{k}={urllib.parse.quote(params[k], safe='')}" for k in sorted(params)
    )
    return f"wss://{TENCENT_HOST}{path}?{final_query}"


# ────────────────────── TencentProvider ──────────────────────
class TencentProvider(ASRProvider):
    BACKEND_TAG = "tencent-asr-realtime"

    def __init__(self, app_id: str, secret_id: str, secret_key: str, mappings: dict[str, str]):
        self.app_id = app_id
        self.secret_id = secret_id
        self.secret_key = secret_key
        self.mappings = mappings
        self.upstream: Optional[websockets.WebSocketClientProtocol] = None
        # Tencent sends each utterance separately. We accumulate stable
        # (slice_type=2) segments into `_stable_text` and overlay the current
        # in-progress (slice_type=1) text as `_partial_text` for the live
        # preview. The voice-stt final = _stable_text + _partial_text on flush.
        self._stable_text = ""
        self._partial_text = ""

    async def connect(self) -> None:
        url = _build_ws_url(self.app_id, self.secret_id, self.secret_key)
        self.upstream = await websockets.connect(url, max_size=None, open_timeout=10)
        log(f"  upstream connect (tencent {TENCENT_ENGINE})")
        # Tencent's initial "ready" message arrives shortly after open; we
        # don't need to send a handshake.

    async def send_audio(self, pcm: bytes) -> None:
        assert self.upstream is not None
        # Tencent accepts raw int16 LE PCM as binary frames.
        await self.upstream.send(pcm)

    async def end_audio(self) -> None:
        assert self.upstream is not None
        # End-of-utterance is a text JSON frame.
        await self.upstream.send(json.dumps({"type": "end"}))

    async def events(self) -> AsyncIterator[dict]:
        assert self.upstream is not None
        async for raw in self.upstream:
            if isinstance(raw, (bytes, bytearray)):
                continue  # Tencent doesn't send binary in steady state
            try:
                m = json.loads(raw)
            except Exception as e:
                log(f"  json parse fail: {e!r}; raw={raw[:120]!r}")
                continue

            code = m.get("code", 0)
            if code != 0:
                err_msg = m.get("message", "")
                log(f"  upstream error code={code} msg={err_msg[:160]!r}")
                yield {
                    "type": "final", "text": "",
                    "error_code": code, "error_message": err_msg,
                }
                return

            result = m.get("result") or {}
            text = (result.get("voice_text_str") or "").strip()
            slice_type = result.get("slice_type", -1)
            is_final_session = m.get("final") == 1

            if slice_type == 0:
                # utterance start — no text to emit
                continue

            if slice_type == 1:
                # utterance in progress: live partial overlay
                self._partial_text = text
                combined = self._stable_text + self._partial_text
                if combined:
                    yield {
                        "type": "partial", "text": combined,
                        "backend": f"{self.BACKEND_TAG}-partial",
                    }

            elif slice_type == 2:
                # utterance ended — text becomes stable; drop the now-redundant partial
                self._stable_text += text
                self._partial_text = ""
                # Forward an updated partial (the stable join) so the renderer
                # smoothly reflects the merged text without flashing.
                if self._stable_text:
                    yield {
                        "type": "partial", "text": self._stable_text,
                        "backend": f"{self.BACKEND_TAG}-partial",
                    }

            if is_final_session:
                final_text = apply_mappings(self._stable_text + self._partial_text, self.mappings)
                log(f"  EOF final -> '{final_text[:60]}'")
                yield {
                    "type": "final", "text": final_text, "language": "",
                }
                return

    async def close(self) -> None:
        if self.upstream is not None:
            try:
                await self.upstream.close()
            except Exception:
                pass
            self.upstream = None


# ────────────────────── entrypoint ──────────────────────
async def _main():
    creds = parse_env_file(SECRETS_PATH, ["TENCENT_APP_ID", "TENCENT_SECRET_ID", "TENCENT_SECRET_KEY"])
    app_id = creds["TENCENT_APP_ID"]
    secret_id = creds["TENCENT_SECRET_ID"]
    secret_key = creds["TENCENT_SECRET_KEY"]
    log(f"loaded credentials from {SECRETS_PATH}")

    mappings = load_mappings(HOTWORDS_FILE)
    log(f"mappings: {len(mappings)} loaded from {HOTWORDS_FILE}")
    log(f"engine={TENCENT_ENGINE}  upstream=wss://{TENCENT_HOST}/asr/v2/<app_id>?...")

    def provider_factory() -> TencentProvider:
        return TencentProvider(app_id, secret_id, secret_key, mappings)

    await serve(provider_factory, LISTEN_HOST, LISTEN_PORT)


if __name__ == "__main__":
    try:
        asyncio.run(_main())
    except KeyboardInterrupt:
        pass
