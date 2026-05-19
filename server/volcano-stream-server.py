#!/usr/bin/env python3
"""Volcano Engine (火山引擎 / 豆包流式语音识别 2.0) WebSocket server for voice-stt.

Cloud-ASR path: same wire protocol as funasr-stream-server.py and
sherpa-onnx-stream-server.py — Windows AHK client connects unchanged.
Per-PTT-session this server opens an upstream WS to Volcano's
`bigmodel_async` endpoint, translates voice-stt frames (int16 PCM +
"EOF") into Volcano's binary frame protocol (gzip + sequence + Full
Client Request/Audio Only Request), forwards partial/final back as
voice-stt JSON envelopes.

Why a translation proxy and not a Provider class yet:
- Phase 3 M1 ships in a risk-isolated worktree before touching the
  ~889-line funasr-stream-server.py. M2 will extract the ASRProvider
  ABC and absorb this server into a unified asr-server.py.
- Wire-protocol-compatible deployment means Windows PS1 only needs to
  change WsUrl port to switch between local-Qwen3 / sherpa / Volcano.

Credentials: read from ~/.config/voice-stt/secrets/volcano.env, format:
    VOLCANO_APP_ID=...
    VOLCANO_ACCESS_TOKEN=...
This file MUST be mode 600 and live outside the repo (the path itself
is documented in docs/dev/changes/2026-05-19-volcano-cloud-asr.md).

Env vars:
    VOLCANO_SECRETS         default: ~/.config/voice-stt/secrets/volcano.env
    VOLCANO_RESOURCE_ID     default: volc.seedasr.sauc.duration  (ASR 2.0 hour-based)
    VOLCANO_ENDPOINT        default: wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async
    HOTWORDS_FILE           default: ./hotwords.yaml             (read mappings: + hotwords)
    LISTEN_HOST             default: 0.0.0.0
    LISTEN_PORT             default: 8082                        (same port family as funasr/sherpa)

Reference: docs/dev/changes/2026-05-19-volcano-cloud-asr.md §5 (frame protocol)
"""

import asyncio
import gzip
import json
import os
import re
import struct
import time
import uuid
from pathlib import Path

import numpy as np
import websockets


# ────────────────────── frame protocol constants ──────────────────────
# Reference: https://www.volcengine.com/docs/6561/1354869 (Agent 2 report §5)
PROTOCOL_V1 = 0b0001
HEADER_SIZE_1 = 0b0001  # actual header = 1*4 = 4 bytes

MSG_FULL_REQ = 0b0001   # client -> server: initial request (params + audio meta)
MSG_AUDIO_REQ = 0b0010  # client -> server: audio chunk
MSG_FULL_RESP = 0b1001  # server -> client: result frame
MSG_ERROR = 0b1111      # server -> client: error frame

FLAG_NONE = 0b0000
FLAG_POS_SEQ = 0b0001   # has positive sequence
FLAG_NEG = 0b0010       # last packet, no sequence
FLAG_NEG_SEQ = 0b0011   # last packet, negative sequence

SERIAL_RAW = 0b0000
SERIAL_JSON = 0b0001

COMP_NONE = 0b0000
COMP_GZIP = 0b0001


# ────────────────────── config ──────────────────────
SECRETS_PATH = Path(os.environ.get(
    "VOLCANO_SECRETS",
    str(Path.home() / ".config" / "voice-stt" / "secrets" / "volcano.env"),
))
VOLCANO_RESOURCE_ID = os.environ.get("VOLCANO_RESOURCE_ID", "volc.seedasr.sauc.duration")
VOLCANO_ENDPOINT = os.environ.get("VOLCANO_ENDPOINT", "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")
HOTWORDS_FILE = os.environ.get("HOTWORDS_FILE", str(Path(__file__).parent / "hotwords.yaml"))
LISTEN_HOST = os.environ.get("LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8082"))

BACKEND_TAG = "volcano-doubao-2.0"
SAMPLE_RATE = 16000


def _log(*args):
    print(f"[{time.strftime('%H:%M:%S')}]", *args, flush=True)


# ────────────────────── credentials ──────────────────────
def load_secrets(path: Path) -> tuple[str, str]:
    """Parse KEY=VALUE lines from ~/.config/voice-stt/secrets/volcano.env.
    Returns (app_id, access_token). Raises on missing file or missing keys."""
    if not path.exists():
        raise FileNotFoundError(
            f"Volcano secrets not found: {path}\n"
            f"Create with VOLCANO_APP_ID + VOLCANO_ACCESS_TOKEN, chmod 600."
        )
    app_id = access_token = ""
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        k = k.strip()
        v = v.strip().strip('"').strip("'")
        if k == "VOLCANO_APP_ID":
            app_id = v
        elif k == "VOLCANO_ACCESS_TOKEN":
            access_token = v
    if not app_id or not access_token:
        raise ValueError(f"VOLCANO_APP_ID or VOLCANO_ACCESS_TOKEN missing in {path}")
    return app_id, access_token


# ────────────────────── hotwords + mappings ──────────────────────
def _load_yaml_safely(path: str) -> dict:
    """Avoid pyyaml dep — only need hotwords + mappings, regex-parse."""
    if not Path(path).exists():
        return {}
    text = Path(path).read_text(encoding="utf-8")
    return text  # raw text; parsers below pick what they need


def load_hotwords_terms(yaml_path: str, max_count: int = 100) -> list[str]:
    """Flatten yaml category lists into Volcano hotword terms.
    Volcano双向流式上限 ~100 tokens — we keep brand/term-shaped entries first.
    Filters: drop terms with special chars Volcano's tokenizer dislikes minimally.
    """
    if not Path(yaml_path).exists():
        return []
    text = Path(yaml_path).read_text(encoding="utf-8")
    terms: list[str] = []
    seen: set[str] = set()
    in_category = False
    in_mappings = False
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        # crude section tracker: top-level "name:" lines
        if re.match(r"^[a-z_]+:\s*$", line):
            in_mappings = (stripped == "mappings:")
            in_category = not in_mappings
            continue
        if in_mappings:
            continue
        if in_category:
            # list item like `  - foo` or `  - "foo bar"`
            m = re.match(r"^\s*-\s+(.+?)\s*$", line)
            if m:
                term = m.group(1).strip().strip('"').strip("'")
                if term and term.lower() not in seen:
                    seen.add(term.lower())
                    terms.append(term)
                    if len(terms) >= max_count:
                        break
    return terms


MAPPINGS: dict = {}


def load_mappings(yaml_path: str) -> dict:
    """Read mappings: section. Tolerant regex parse so pyyaml stays optional."""
    if not Path(yaml_path).exists():
        return {}
    text = Path(yaml_path).read_text(encoding="utf-8")
    mp: dict = {}
    in_mappings = False
    for line in text.splitlines():
        if re.match(r"^[a-z_]+:\s*$", line):
            in_mappings = line.strip().startswith("mappings:")
            continue
        if not in_mappings:
            continue
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        # `"foo": "bar"` or `foo: bar`
        m = re.match(r'^"?([^"]+?)"?\s*:\s*"?([^"]+?)"?\s*$', stripped)
        if m:
            mp[m.group(1)] = m.group(2)
    return mp


def apply_mappings(text: str) -> str:
    """Final-text post-correct. Long LHS first; CJK substring, ASCII \\b boundary."""
    if not text or not MAPPINGS:
        return text
    out = text
    for lhs in sorted(MAPPINGS, key=len, reverse=True):
        rhs = MAPPINGS[lhs]
        has_cjk = any("一" <= c <= "鿿" for c in lhs)
        pattern = re.escape(lhs) if has_cjk else r"\b" + re.escape(lhs) + r"\b"
        new_out, n = re.subn(pattern, rhs, out, flags=re.IGNORECASE)
        if n > 0:
            _log(f"  [mapping] '{lhs}' -> '{rhs}'")
            out = new_out
    return out


# ────────────────────── frame construction ──────────────────────
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
        # Negative sequence + last-packet flag. Empty audio is fine.
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
    """Parse a single binary frame from Volcano. Returns:
        {"type": "result", "is_last": bool, "seq": int, "data": dict}
        {"type": "error", "code": int, "message": str}
        {"type": "unknown", ...}
    """
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
        error_msg = msg_bytes.decode("utf-8", errors="replace")
        return {"type": "error", "code": error_code, "message": error_msg}

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


# ────────────────────── proxy session ──────────────────────
def _build_request_params(hotwords_terms: list[str]) -> dict:
    """Volcano Full Client Request params. Hotwords go through corpus.context
    as nested JSON string per docs §9.1."""
    params: dict = {
        "user": {"uid": "voice-stt-client"},
        "audio": {
            "format": "pcm",
            "codec": "raw",
            "rate": SAMPLE_RATE,
            "bits": 16,
            "channel": 1,
        },
        "request": {
            "model_name": "bigmodel",
            "enable_itn": True,        # 数字/单位 → 阿拉伯
            "enable_punc": True,       # 自动标点
            "enable_ddc": False,       # 不删填充词 (保留"嗯/啊" 让 paste 体验自然)
            "result_type": "full",
            "show_utterances": False,
        },
    }
    if hotwords_terms:
        # nested JSON-in-string per docs (corpus.context expects escaped JSON)
        hotword_obj = {"hotwords": [{"word": w} for w in hotwords_terms]}
        params["request"]["corpus"] = {
            "context": json.dumps(hotword_obj, ensure_ascii=False),
        }
    return params


async def _proxy_one_session(client_ws, app_id: str, access_token: str, hotwords_terms: list[str]):
    """Bridge one voice-stt PTT session ↔ one Volcano upstream WS connection.

    voice-stt protocol (incoming):
        binary frame  = int16 LE PCM @ 16kHz mono
        text "EOF"    = end-of-utterance signal
    voice-stt protocol (outgoing):
        {"type":"partial","text":"...","backend":"..."}
        {"type":"final","text":"...","language":"...","backend":"..."}

    Volcano protocol (this proxy↔Volcano):
        out: Full Client Request (seq=1) -> Audio Chunks (seq=2..N) -> Last chunk (seq=-N)
        in:  Full Server Response stream until is_last=True
    """
    peer = client_ws.remote_address
    _log(f"client connected: {peer}")
    connect_id = str(uuid.uuid4())

    headers = [
        ("X-Api-App-Key", app_id),
        ("X-Api-Access-Key", access_token),
        ("X-Api-Resource-Id", VOLCANO_RESOURCE_ID),
        ("X-Api-Connect-Id", connect_id),
    ]
    last_partial = ""

    try:
        upstream = await websockets.connect(
            VOLCANO_ENDPOINT,
            additional_headers=headers,
            max_size=None,
            open_timeout=10,
        )
        # x-tt-logid header on the 101 response is the troubleshooting key.
        # websockets >= 12 exposes response.headers; older expose handshake.response_headers.
        tt_logid = ""
        try:
            tt_logid = upstream.response.headers.get("x-tt-logid", "") if upstream.response else ""
        except AttributeError:
            try:
                tt_logid = upstream.response_headers.get("x-tt-logid", "")  # type: ignore
            except Exception:
                pass
        _log(f"  {peer} upstream connect id={connect_id} x-tt-logid={tt_logid or '<n/a>'}")
    except Exception as e:
        _log(f"  {peer} upstream connect FAILED: {e!r}")
        await client_ws.send(json.dumps({
            "type": "final",
            "text": "",
            "backend": BACKEND_TAG,
            "error": f"upstream connect failed: {e!r}",
        }, ensure_ascii=False))
        return

    try:
        # ──── 1. send Full Client Request (seq=1) ────
        params = _build_request_params(hotwords_terms)
        await upstream.send(build_full_client_request(params, sequence=1))

        sequence = [2]   # mutable for nested closures
        eof_received = asyncio.Event()
        upstream_done = asyncio.Event()

        # ──── 2. client_to_upstream task ────
        async def pump_client_to_upstream():
            audio_bytes = 0
            async for msg in client_ws:
                if isinstance(msg, (bytes, bytearray)):
                    if not msg:
                        continue
                    seq = sequence[0]
                    sequence[0] = seq + 1
                    await upstream.send(build_audio_chunk(bytes(msg), seq, last=False))
                    audio_bytes += len(msg)
                elif isinstance(msg, str):
                    if msg.strip().upper() == "EOF":
                        if audio_bytes == 0:
                            # Test-Connection probe (or VAD false-start): client
                            # sent EOF with no audio. Volcano won't emit a final
                            # in this case and the session would hang, billing
                            # against the free-tier quota. Short-circuit with an
                            # empty final and drop the upstream WS.
                            await client_ws.send(json.dumps({
                                "type": "final",
                                "text": "",
                                "backend": BACKEND_TAG,
                            }, ensure_ascii=False))
                            await upstream.close()
                            _log(f"  {peer} EOF (no audio) -> empty final")
                            eof_received.set()
                            return
                        seq = sequence[0]
                        sequence[0] = seq + 1
                        await upstream.send(build_audio_chunk(b"", seq, last=True))
                        eof_received.set()
                        return
                    else:
                        _log(f"  {peer} unknown text frame: {msg[:40]!r}")
            # client closed without EOF: still tell Volcano we're done
            if audio_bytes == 0:
                await upstream.close()
                eof_received.set()
                return
            seq = sequence[0]
            await upstream.send(build_audio_chunk(b"", seq, last=True))
            eof_received.set()

        # ──── 3. upstream_to_client task ────
        async def pump_upstream_to_client():
            nonlocal last_partial
            try:
                async for raw in upstream:
                    if isinstance(raw, str):
                        continue   # Volcano doesn't send text frames in steady state
                    result = parse_server_response(bytes(raw) if isinstance(raw, bytearray) else raw)
                    if result["type"] == "error":
                        code = result.get("code", 0)
                        msg = result.get("message", "")
                        _log(f"  {peer} upstream error code={code} msg={msg[:160]!r}")
                        await client_ws.send(json.dumps({
                            "type": "final",
                            "text": "",
                            "backend": BACKEND_TAG,
                            "error_code": code,
                            "error_message": msg,
                        }, ensure_ascii=False))
                        return
                    if result["type"] != "result":
                        continue
                    is_last = result["is_last"]
                    text = _extract_text(result["data"])
                    if is_last:
                        # final segment
                        final_text = apply_mappings(text)
                        await client_ws.send(json.dumps({
                            "type": "final",
                            "text": final_text,
                            "language": "",
                            "backend": BACKEND_TAG,
                        }, ensure_ascii=False))
                        _log(f"  {peer} EOF final -> '{final_text[:60]}'")
                        return
                    # partial: only forward when text actually changes — Volcano's
                    # bigmodel_async sends fewer dupes than bigmodel but de-dupe is cheap
                    # insurance against future protocol shifts and against same-token noise.
                    if text and text != last_partial:
                        last_partial = text
                        await client_ws.send(json.dumps({
                            "type": "partial",
                            "text": text,
                            "backend": f"{BACKEND_TAG}-partial",
                        }, ensure_ascii=False))
            finally:
                upstream_done.set()

        await asyncio.gather(pump_client_to_upstream(), pump_upstream_to_client())
    except websockets.ConnectionClosed:
        pass
    except Exception as e:
        _log(f"  {peer} session error: {e!r}")
    finally:
        try:
            await upstream.close()
        except Exception:
            pass
        _log(f"client disconnected: {peer}")


# ────────────────────── server entrypoint ──────────────────────
APP_ID = ""
ACCESS_TOKEN = ""
HOTWORDS_TERMS: list[str] = []


async def handle_client(ws):
    await _proxy_one_session(ws, APP_ID, ACCESS_TOKEN, HOTWORDS_TERMS)


async def main():
    global APP_ID, ACCESS_TOKEN, MAPPINGS, HOTWORDS_TERMS
    APP_ID, ACCESS_TOKEN = load_secrets(SECRETS_PATH)
    _log(f"loaded credentials from {SECRETS_PATH}")
    MAPPINGS = load_mappings(HOTWORDS_FILE)
    _log(f"mappings: {len(MAPPINGS)} loaded from {HOTWORDS_FILE}")
    HOTWORDS_TERMS = load_hotwords_terms(HOTWORDS_FILE, max_count=100)
    _log(f"hotwords: {len(HOTWORDS_TERMS)} terms (Volcano 2.0 streaming caps at ~100 tokens)")
    _log(f"resource_id={VOLCANO_RESOURCE_ID}")
    _log(f"upstream={VOLCANO_ENDPOINT}")
    _log(f"listening on ws://{LISTEN_HOST}:{LISTEN_PORT}/")
    async with websockets.serve(handle_client, LISTEN_HOST, LISTEN_PORT, max_size=None):
        await asyncio.Future()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
