#!/usr/bin/env python3
"""讯飞 RTASR (rtasr.xfyun.cn) ASRProvider.

Free tier: 50h trial valid 1 year from account creation (NOT永久免费; expires
to paid after a year). Used as the highest-quality Mandarin backup for the
duration of the trial — Agent A's report rates 讯飞 top tier for pure Chinese
ASR.

Credentials: ~/.config/voice-stt/secrets/xfyun.env (mode 600):
    XFYUN_APP_ID=...       # from https://console.xfyun.cn → create app
    XFYUN_API_KEY=...      # paired with app_id; used as HMAC key
    # XFYUN_API_SECRET is NOT used by RTASR (only the LLM endpoint uses it).

Env vars (defaults shown):
    XFYUN_SECRETS    ~/.config/voice-stt/secrets/xfyun.env
    XFYUN_ENDPOINT   wss://rtasr.xfyun.cn/v1/ws
    HOTWORDS_FILE    ./hotwords.yaml   (mappings: applied post-correct; hotwords via REST TODO)
    LISTEN_HOST      0.0.0.0
    LISTEN_PORT      18095

Auth (from xfyun.cn/doc/asr/rtasr/API.html):
    ts = str(int(time.time()))
    base_string = md5(app_id + ts)         # hex
    signa = base64(hmac_sha1(base_string, api_key))
    URL = wss://rtasr.xfyun.cn/v1/ws?appid=<app_id>&ts=<ts>&signa=<urlencoded_signa>

Frame format:
    Audio: binary frames, 1280 bytes per 40ms (16kHz mono int16 LE PCM).
           Re-chunked from voice-stt's 200ms client frames so each upstream
           send matches the documented size.
    End:   text frame {"end": true}

Response (nested):
    {"action":"result", "data":"<inner-json-string>"}
    inner.cn.st.type = "0" (final-of-segment) | "1" (intermediate)
    inner.cn.st.rt[*].ws[*].cw[*].w joined = text content
    Errors arrive as {"action":"error", "code":..., "desc":...}
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import json
import time
import urllib.parse
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
SECRETS_PATH = env_path("XFYUN_SECRETS", lambda: Path.home() / ".config" / "voice-stt" / "secrets" / "xfyun.env")
XFYUN_ENDPOINT = env_str("XFYUN_ENDPOINT", "wss://rtasr.xfyun.cn/v1/ws")
HOTWORDS_FILE = env_str("HOTWORDS_FILE", str(Path(__file__).parent / "hotwords.yaml"))
LISTEN_HOST = env_str("LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = env_int("LISTEN_PORT", 18095)

# Xfyun official recommendation: 1280 bytes per 40ms chunk.
XFYUN_CHUNK_BYTES = 1280


# ────────────────────── auth ──────────────────────
def _build_ws_url(app_id: str, api_key: str) -> str:
    ts = str(int(time.time()))
    base_string = hashlib.md5((app_id + ts).encode("utf-8")).hexdigest()
    sig_raw = hmac.new(api_key.encode("utf-8"), base_string.encode("utf-8"), hashlib.sha1).digest()
    signa = base64.b64encode(sig_raw).decode("utf-8")
    params = {
        "appid": app_id,
        "ts": ts,
        "signa": signa,
    }
    query = "&".join(f"{k}={urllib.parse.quote(v, safe='')}" for k, v in params.items())
    return f"{XFYUN_ENDPOINT}?{query}"


# ────────────────────── response parser ──────────────────────
def _extract_text_from_inner(inner: dict) -> str:
    """Walk the nested cn.st.rt[*].ws[*].cw[*].w structure → joined text."""
    try:
        rt = inner["cn"]["st"].get("rt", [])
    except (KeyError, TypeError, AttributeError):
        return ""
    parts: list[str] = []
    for sentence in rt:
        for ws_group in sentence.get("ws", []):
            for cw in ws_group.get("cw", []):
                w = cw.get("w", "")
                if w:
                    parts.append(w)
    return "".join(parts)


# ────────────────────── XfyunProvider ──────────────────────
class XfyunProvider(ASRProvider):
    BACKEND_TAG = "xfyun-rtasr"

    def __init__(self, app_id: str, api_key: str, mappings: dict[str, str]):
        self.app_id = app_id
        self.api_key = api_key
        self.mappings = mappings
        self.upstream: Optional[websockets.WebSocketClientProtocol] = None
        # Like Tencent, Xfyun emits segment-level finals (type=0) interleaved
        # with intermediate updates (type=1). Accumulate stable, overlay
        # in-progress.
        self._stable_text = ""
        self._partial_text = ""
        # Chunker buffer: re-frame client's 200ms blobs into 40ms (1280B) frames.
        self._send_buf = bytearray()

    async def connect(self) -> None:
        url = _build_ws_url(self.app_id, self.api_key)
        self.upstream = await websockets.connect(url, max_size=None, open_timeout=10)
        log(f"  upstream connect (xfyun rtasr)")
        # The first message from xfyun is {"action":"started"} — we let events()
        # see/ignore it rather than blocking here.

    async def _flush_buffer(self, force: bool = False) -> None:
        """Send buffered audio in 1280B chunks. If force, send any remainder too."""
        assert self.upstream is not None
        while len(self._send_buf) >= XFYUN_CHUNK_BYTES:
            chunk = bytes(self._send_buf[:XFYUN_CHUNK_BYTES])
            del self._send_buf[:XFYUN_CHUNK_BYTES]
            await self.upstream.send(chunk)
        if force and self._send_buf:
            # Pad last partial frame with silence so size matches recommendation.
            tail = bytes(self._send_buf)
            pad = XFYUN_CHUNK_BYTES - len(tail)
            await self.upstream.send(tail + (b"\x00" * pad))
            self._send_buf.clear()

    async def send_audio(self, pcm: bytes) -> None:
        self._send_buf.extend(pcm)
        await self._flush_buffer(force=False)

    async def end_audio(self) -> None:
        assert self.upstream is not None
        await self._flush_buffer(force=True)
        # End-of-data signal per xfyun RTASR docs.
        await self.upstream.send('{"end": true}')

    async def events(self) -> AsyncIterator[dict]:
        assert self.upstream is not None
        async for raw in self.upstream:
            if isinstance(raw, (bytes, bytearray)):
                continue
            try:
                m = json.loads(raw)
            except Exception as e:
                log(f"  json parse fail: {e!r}; raw={raw[:120]!r}")
                continue

            action = m.get("action", "")
            if action == "started":
                continue
            if action == "error":
                code = m.get("code", 0)
                desc = m.get("desc", "")
                log(f"  upstream error code={code} desc={desc[:160]!r}")
                yield {
                    "type": "final", "text": "",
                    "error_code": int(code) if str(code).isdigit() else 0,
                    "error_message": desc,
                }
                return
            if action != "result":
                continue

            try:
                inner = json.loads(m.get("data", "{}"))
            except Exception:
                continue

            seg_type = inner.get("cn", {}).get("st", {}).get("type", "")
            text = _extract_text_from_inner(inner)
            # is_last for the whole session: xfyun sends an empty result with
            # action=result + data containing a special marker, but in practice
            # we treat the WS close after {"end":true} as the final boundary.
            # Per-segment type "0" means "this segment's final", type "1" =
            # intermediate. The session-final arrives as a close handshake or
            # an explicit "end" marker; we emit voice-stt final when the WS
            # closes cleanly (handled in close()).
            if seg_type == "1":
                self._partial_text = text
                combined = self._stable_text + self._partial_text
                if combined:
                    yield {
                        "type": "partial", "text": combined,
                        "backend": f"{self.BACKEND_TAG}-partial",
                    }
            elif seg_type == "0":
                self._stable_text += text
                self._partial_text = ""
                if self._stable_text:
                    yield {
                        "type": "partial", "text": self._stable_text,
                        "backend": f"{self.BACKEND_TAG}-partial",
                    }

        # WS closed by upstream — emit the accumulated text as voice-stt final.
        final_text = apply_mappings(self._stable_text + self._partial_text, self.mappings)
        log(f"  EOF final -> '{final_text[:60]}'")
        yield {
            "type": "final", "text": final_text, "language": "",
        }

    async def close(self) -> None:
        if self.upstream is not None:
            try:
                await self.upstream.close()
            except Exception:
                pass
            self.upstream = None


# ────────────────────── entrypoint ──────────────────────
async def _main():
    creds = parse_env_file(SECRETS_PATH, ["XFYUN_APP_ID", "XFYUN_API_KEY"])
    app_id = creds["XFYUN_APP_ID"]
    api_key = creds["XFYUN_API_KEY"]
    log(f"loaded credentials from {SECRETS_PATH}")

    mappings = load_mappings(HOTWORDS_FILE)
    log(f"mappings: {len(mappings)} loaded from {HOTWORDS_FILE}")
    log(f"upstream={XFYUN_ENDPOINT}")

    def provider_factory() -> XfyunProvider:
        return XfyunProvider(app_id, api_key, mappings)

    await serve(provider_factory, LISTEN_HOST, LISTEN_PORT)


if __name__ == "__main__":
    try:
        asyncio.run(_main())
    except KeyboardInterrupt:
        pass
