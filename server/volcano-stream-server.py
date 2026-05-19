#!/usr/bin/env python3
"""Volcano Engine (火山引擎 / 豆包流式语音识别 2.0) ASRProvider.

M2 refactor: scaffolding (voice-stt protocol, hotwords/mappings, EOF
short-circuit) lives in asr_common. This file holds only the Volcano-
specific bits: binary frame codec + WS handshake + VolcanoProvider.

Credentials: ~/.config/voice-stt/secrets/volcano.env (mode 600):
    VOLCANO_APP_ID=...
    VOLCANO_ACCESS_TOKEN=...

Env vars (defaults shown):
    VOLCANO_SECRETS       ~/.config/voice-stt/secrets/volcano.env
    VOLCANO_RESOURCE_ID   volc.seedasr.sauc.duration  (ASR 2.0 hour-based)
    VOLCANO_ENDPOINT      wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async
    HOTWORDS_FILE         ./hotwords.yaml
    LISTEN_HOST           0.0.0.0
    LISTEN_PORT           8082

Reference: docs/dev/changes/2026-05-19-volcano-cloud-asr.md §5 (frame protocol)
"""

from __future__ import annotations

import asyncio
import gzip
import json
import os
import struct
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
    load_hotwords_terms,
    load_mappings,
    log,
    parse_env_file,
    serve,
)


# ────────────────────── Volcano binary frame protocol ──────────────────────
# Reference: https://www.volcengine.com/docs/6561/1354869
PROTOCOL_V1 = 0b0001
HEADER_SIZE_1 = 0b0001  # actual header = 1*4 = 4 bytes

MSG_FULL_REQ = 0b0001
MSG_AUDIO_REQ = 0b0010
MSG_FULL_RESP = 0b1001
MSG_ERROR = 0b1111

FLAG_POS_SEQ = 0b0001
FLAG_NEG_SEQ = 0b0011

SERIAL_RAW = 0b0000
SERIAL_JSON = 0b0001

COMP_NONE = 0b0000
COMP_GZIP = 0b0001


def _make_header(msg_type: int, flags: int, serial: int, comp: int) -> bytes:
    b0 = (PROTOCOL_V1 << 4) | HEADER_SIZE_1
    b1 = (msg_type << 4) | flags
    b2 = (serial << 4) | comp
    return struct.pack(">BBBB", b0, b1, b2, 0x00)


def build_full_client_request(params: dict, sequence: int = 1) -> bytes:
    payload = gzip.compress(json.dumps(params, ensure_ascii=False).encode("utf-8"))
    header = _make_header(MSG_FULL_REQ, FLAG_POS_SEQ, SERIAL_JSON, COMP_GZIP)
    seq = struct.pack(">i", sequence)
    size = struct.pack(">I", len(payload))
    return header + seq + size + payload


def build_audio_chunk(audio: bytes, sequence: int, last: bool = False) -> bytes:
    if last:
        payload = gzip.compress(audio) if audio else b""
        comp = COMP_GZIP if audio else COMP_NONE
        header = _make_header(MSG_AUDIO_REQ, FLAG_NEG_SEQ, SERIAL_RAW, comp)
        seq = struct.pack(">i", -abs(sequence))
    else:
        payload = gzip.compress(audio)
        header = _make_header(MSG_AUDIO_REQ, FLAG_POS_SEQ, SERIAL_RAW, COMP_GZIP)
        seq = struct.pack(">i", sequence)
    size = struct.pack(">I", len(payload))
    return header + seq + size + payload


def parse_server_response(data: bytes) -> dict:
    if len(data) < 4:
        return {"type": "unknown", "reason": "frame too short"}
    header_size = (data[0] & 0x0F) * 4
    msg_type = (data[1] >> 4) & 0x0F
    flags = data[1] & 0x0F
    comp = data[2] & 0x0F
    is_last = bool(flags & 0x02)
    has_seq = bool(flags & 0x01)

    pos = header_size
    seq = None
    if has_seq:
        seq = struct.unpack(">i", data[pos:pos + 4])[0]
        pos += 4

    if msg_type == MSG_FULL_RESP:
        payload_size = struct.unpack(">I", data[pos:pos + 4])[0]
        payload = data[pos + 4:pos + 4 + payload_size]
        if comp == COMP_GZIP:
            try:
                payload = gzip.decompress(payload)
            except Exception as e:
                return {"type": "unknown", "reason": f"gzip decompress fail: {e!r}"}
        try:
            data_obj = json.loads(payload)
        except Exception as e:
            return {"type": "unknown", "reason": f"json parse fail: {e!r}"}
        return {"type": "result", "is_last": is_last, "seq": seq, "data": data_obj}

    if msg_type == MSG_ERROR:
        if len(data) < pos + 8:
            return {"type": "error", "code": 0, "message": "truncated error frame"}
        error_code = struct.unpack(">I", data[pos:pos + 4])[0]
        error_size = struct.unpack(">I", data[pos + 4:pos + 8])[0]
        msg_bytes = data[pos + 8:pos + 8 + error_size]
        if comp == COMP_GZIP:
            try:
                msg_bytes = gzip.decompress(msg_bytes)
            except Exception:
                pass
        return {"type": "error", "code": error_code, "message": msg_bytes.decode("utf-8", errors="replace")}

    return {"type": "unknown", "msg_type": msg_type, "flags": flags}


def _extract_text(result_data: dict) -> str:
    """Volcano's `result` field is sometimes dict, sometimes list — handle both."""
    r = result_data.get("result", {})
    if isinstance(r, dict):
        return (r.get("text") or "").strip()
    if isinstance(r, list) and r:
        first = r[0]
        if isinstance(first, dict):
            return (first.get("text") or "").strip()
    return ""


# ────────────────────── config ──────────────────────
SECRETS_PATH = env_path("VOLCANO_SECRETS", lambda: Path.home() / ".config" / "voice-stt" / "secrets" / "volcano.env")
VOLCANO_RESOURCE_ID = env_str("VOLCANO_RESOURCE_ID", "volc.seedasr.sauc.duration")
VOLCANO_ENDPOINT = env_str("VOLCANO_ENDPOINT", "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")
HOTWORDS_FILE = env_str("HOTWORDS_FILE", str(Path(__file__).parent / "hotwords.yaml"))
LISTEN_HOST = env_str("LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = env_int("LISTEN_PORT", 8082)


# ────────────────────── VolcanoProvider ──────────────────────
class VolcanoProvider(ASRProvider):
    BACKEND_TAG = "volcano-doubao-2.0"

    def __init__(self, app_id: str, access_token: str, hotwords_terms: list[str], mappings: dict[str, str]):
        self.app_id = app_id
        self.access_token = access_token
        self.hotwords_terms = hotwords_terms
        self.mappings = mappings
        self.upstream: Optional[websockets.WebSocketClientProtocol] = None
        self._sequence = 2  # seq=1 is reserved for Full Client Request
        self._connect_id = ""
        self._last_partial = ""

    def _build_request_params(self) -> dict:
        params: dict = {
            "user": {"uid": "voice-stt-client"},
            "audio": {
                "format": "pcm", "codec": "raw",
                "rate": self.SAMPLE_RATE, "bits": 16, "channel": 1,
            },
            "request": {
                "model_name": "bigmodel",
                "enable_itn": True,
                "enable_punc": True,
                "enable_ddc": False,
                "result_type": "full",
                "show_utterances": False,
            },
        }
        if self.hotwords_terms:
            hotword_obj = {"hotwords": [{"word": w} for w in self.hotwords_terms]}
            params["request"]["corpus"] = {
                "context": json.dumps(hotword_obj, ensure_ascii=False),
            }
        return params

    async def connect(self) -> None:
        self._connect_id = str(uuid.uuid4())
        headers = [
            ("X-Api-App-Key", self.app_id),
            ("X-Api-Access-Key", self.access_token),
            ("X-Api-Resource-Id", VOLCANO_RESOURCE_ID),
            ("X-Api-Connect-Id", self._connect_id),
        ]
        self.upstream = await websockets.connect(
            VOLCANO_ENDPOINT, additional_headers=headers,
            max_size=None, open_timeout=10,
        )
        tt_logid = ""
        try:
            tt_logid = self.upstream.response.headers.get("x-tt-logid", "") if self.upstream.response else ""
        except AttributeError:
            try:
                tt_logid = self.upstream.response_headers.get("x-tt-logid", "")  # type: ignore
            except Exception:
                pass
        log(f"  upstream connect id={self._connect_id} x-tt-logid={tt_logid or '<n/a>'}")
        # send Full Client Request (seq=1) — handshake with audio config + hotwords
        params = self._build_request_params()
        await self.upstream.send(build_full_client_request(params, sequence=1))

    async def send_audio(self, pcm: bytes) -> None:
        assert self.upstream is not None
        seq = self._sequence
        self._sequence += 1
        await self.upstream.send(build_audio_chunk(pcm, seq, last=False))

    async def end_audio(self) -> None:
        assert self.upstream is not None
        seq = self._sequence
        self._sequence += 1
        await self.upstream.send(build_audio_chunk(b"", seq, last=True))

    async def events(self) -> AsyncIterator[dict]:
        assert self.upstream is not None
        async for raw in self.upstream:
            if isinstance(raw, str):
                continue  # Volcano doesn't send text frames in steady state
            result = parse_server_response(bytes(raw) if isinstance(raw, bytearray) else raw)
            if result["type"] == "error":
                code = result.get("code", 0)
                msg = result.get("message", "")
                log(f"  upstream error code={code} msg={msg[:160]!r}")
                yield {
                    "type": "final", "text": "",
                    "error_code": code, "error_message": msg,
                }
                return
            if result["type"] != "result":
                continue
            text = _extract_text(result["data"])
            if result["is_last"]:
                final_text = apply_mappings(text, self.mappings)
                log(f"  EOF final -> '{final_text[:60]}'")
                yield {
                    "type": "final", "text": final_text, "language": "",
                }
                return
            # partial: forward only on change
            if text and text != self._last_partial:
                self._last_partial = text
                yield {
                    "type": "partial", "text": text,
                    "backend": f"{self.BACKEND_TAG}-partial",
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
    creds = parse_env_file(SECRETS_PATH, ["VOLCANO_APP_ID", "VOLCANO_ACCESS_TOKEN"])
    app_id = creds["VOLCANO_APP_ID"]
    access_token = creds["VOLCANO_ACCESS_TOKEN"]
    log(f"loaded credentials from {SECRETS_PATH}")

    mappings = load_mappings(HOTWORDS_FILE)
    log(f"mappings: {len(mappings)} loaded from {HOTWORDS_FILE}")

    hotwords_terms = load_hotwords_terms(HOTWORDS_FILE, max_count=100)
    log(f"hotwords: {len(hotwords_terms)} terms (Volcano 2.0 streaming caps at ~100 tokens)")
    log(f"resource_id={VOLCANO_RESOURCE_ID}")
    log(f"upstream={VOLCANO_ENDPOINT}")

    def provider_factory() -> VolcanoProvider:
        return VolcanoProvider(app_id, access_token, hotwords_terms, mappings)

    await serve(provider_factory, LISTEN_HOST, LISTEN_PORT)


if __name__ == "__main__":
    try:
        asyncio.run(_main())
    except KeyboardInterrupt:
        pass
