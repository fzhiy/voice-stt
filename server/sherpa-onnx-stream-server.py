#!/usr/bin/env python3
"""sherpa-onnx streaming WebSocket server for voice-stt.

Zero-GPU path: same wire protocol as funasr-stream-server.py
(int16 LE PCM frames + "EOF" text frame; emits {"type":"partial"|"final"}),
so the Windows AHK / PowerShell client connects unchanged via ASR_WS_URL.

Pure Python — uses sherpa_onnx.OnlineRecognizer directly. No spawning of the
C++ sherpa-onnx-online-websocket-server binary; pip install sherpa-onnx is
enough (wheel ships only the Python bindings, not the C++ WS server).

Model: streaming Paraformer-bilingual-zh-en int8 ONNX (~226 MB extracted,
~1 GB tar). RTF ~0.05-0.15 on modern mobile CPUs.

Env vars:
    SHERPA_MODEL_DIR    default: $HOME/.cache/sherpa-onnx-streaming-paraformer-bilingual-zh-en
    SHERPA_USE_INT8     default: 1   (set 0 to use float32 encoder/decoder for slightly better accuracy)
    SHERPA_NUM_THREADS  default: 4
    LISTEN_HOST         default: 0.0.0.0
    LISTEN_PORT         default: 8082  (same as funasr-stream-server.py so client config unchanged)
"""

import asyncio
import json
import os
import time
from pathlib import Path

import numpy as np
import websockets
import sherpa_onnx


SHERPA_MODEL_DIR = os.environ.get(
    "SHERPA_MODEL_DIR",
    str(Path.home() / ".cache" / "sherpa-onnx-streaming-paraformer-bilingual-zh-en"),
)
SHERPA_USE_INT8 = os.environ.get("SHERPA_USE_INT8", "1") not in ("0", "false", "no", "")
SHERPA_NUM_THREADS = int(os.environ.get("SHERPA_NUM_THREADS", "4"))
LISTEN_HOST = os.environ.get("LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8082"))

SAMPLE_RATE = 16000
BACKEND_TAG = "sherpa-onnx-paraformer"


def _log(*args):
    print(f"[{time.strftime('%H:%M:%S')}]", *args, flush=True)


def build_recognizer() -> sherpa_onnx.OnlineRecognizer:
    suffix = ".int8.onnx" if SHERPA_USE_INT8 else ".onnx"
    encoder = Path(SHERPA_MODEL_DIR) / f"encoder{suffix}"
    decoder = Path(SHERPA_MODEL_DIR) / f"decoder{suffix}"
    tokens = Path(SHERPA_MODEL_DIR) / "tokens.txt"
    for p in (encoder, decoder, tokens):
        if not p.exists():
            raise FileNotFoundError(
                f"missing model file: {p}\n"
                f"See README 'Zero-GPU CPU path' for SHERPA_MODEL_DIR setup."
            )
    _log(f"loading sherpa-onnx Paraformer ({'int8' if SHERPA_USE_INT8 else 'fp32'}) from {SHERPA_MODEL_DIR} ...")
    t0 = time.time()
    rec = sherpa_onnx.OnlineRecognizer.from_paraformer(
        tokens=str(tokens),
        encoder=str(encoder),
        decoder=str(decoder),
        num_threads=SHERPA_NUM_THREADS,
        sample_rate=SAMPLE_RATE,
        feature_dim=80,
        enable_endpoint_detection=True,
        rule1_min_trailing_silence=2.4,
        rule2_min_trailing_silence=1.2,
        rule3_min_utterance_length=20.0,
        decoding_method="greedy_search",
        provider="cpu",
    )
    _log(f"recognizer ready in {time.time()-t0:.1f}s")
    return rec


# Single recognizer instance, shared across connections. sherpa-onnx supports
# concurrent decode_stream() calls on independent OnlineStream objects.
RECOGNIZER: sherpa_onnx.OnlineRecognizer | None = None


async def decode_in_executor(stream):
    """Run blocking decode in default executor so WS event loop stays responsive."""
    loop = asyncio.get_event_loop()

    def _decode():
        while RECOGNIZER.is_ready(stream):
            RECOGNIZER.decode_stream(stream)

    await loop.run_in_executor(None, _decode)


async def handle_client(ws):
    peer = ws.remote_address
    _log(f"client connected: {peer}")
    stream = RECOGNIZER.create_stream()
    last_partial = ""
    try:
        async for msg in ws:
            if isinstance(msg, (bytes, bytearray)):
                if not msg:
                    continue
                arr_i16 = np.frombuffer(msg, dtype=np.int16)
                arr_f32 = arr_i16.astype(np.float32) / 32768.0
                stream.accept_waveform(SAMPLE_RATE, arr_f32)
                await decode_in_executor(stream)
                text = RECOGNIZER.get_result(stream).strip()
                if text and text != last_partial:
                    last_partial = text
                    out = {
                        "type": "partial",
                        "text": text,
                        "backend": f"{BACKEND_TAG}-partial",
                    }
                    await ws.send(json.dumps(out, ensure_ascii=False))
                if RECOGNIZER.is_endpoint(stream):
                    # mid-utterance endpoint: emit final-style segment, reset.
                    if text:
                        out = {
                            "type": "final",
                            "text": text,
                            "language": "",
                            "backend": BACKEND_TAG,
                        }
                        await ws.send(json.dumps(out, ensure_ascii=False))
                        _log(f"  {peer} segment final -> '{text[:60]}'")
                    RECOGNIZER.reset(stream)
                    last_partial = ""
            elif isinstance(msg, str):
                if msg.strip().upper() == "EOF":
                    # Flush remaining audio + tail-pad to force decoder to emit
                    # the last frame before we read the final result.
                    stream.input_finished()
                    tail = np.zeros(int(SAMPLE_RATE * 0.3), dtype=np.float32)
                    stream.accept_waveform(SAMPLE_RATE, tail)
                    await decode_in_executor(stream)
                    text = RECOGNIZER.get_result(stream).strip()
                    out = {
                        "type": "final",
                        "text": text,
                        "language": "",
                        "backend": BACKEND_TAG,
                    }
                    await ws.send(json.dumps(out, ensure_ascii=False))
                    _log(f"  {peer} EOF final -> '{text[:60]}'")
                    return
                else:
                    _log(f"  {peer} unknown text frame: {msg[:40]!r}")
    except websockets.ConnectionClosed:
        pass
    except Exception as e:
        _log(f"client {peer} error: {e!r}")
    finally:
        _log(f"client disconnected: {peer}")


async def main():
    global RECOGNIZER
    RECOGNIZER = build_recognizer()
    _log(f"listening on ws://{LISTEN_HOST}:{LISTEN_PORT}/")
    async with websockets.serve(handle_client, LISTEN_HOST, LISTEN_PORT, max_size=None):
        await asyncio.Future()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
