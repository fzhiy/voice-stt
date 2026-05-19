"""Streaming smoke test for any voice-stt-protocol ASR proxy.
Reads a known 16kHz mono int16 WAV, streams it at ~real-time pace,
sends EOF, then prints partial + final events.

URL env var picks the target (defaults to local Tencent on 18094).
"""
import asyncio
import json
import os
import sys
import wave
from pathlib import Path

import websockets

WAV = Path(os.environ.get(
    "WAV",
    str(Path.home() / ".cache" / "sherpa-onnx-streaming-paraformer-bilingual-zh-en" / "test_wavs" / "0.wav"),
))
URL = os.environ.get("URL", "ws://127.0.0.1:18094/")


async def main():
    if not WAV.exists():
        print(f"missing wav: {WAV}", file=sys.stderr)
        sys.exit(2)
    with wave.open(str(WAV), "rb") as w:
        sr, nch, sw = w.getframerate(), w.getnchannels(), w.getsampwidth()
        pcm = w.readframes(w.getnframes())
    print(f"loaded {WAV.name}: {sr}Hz {nch}ch {sw*8}bit {len(pcm)/sr/nch/sw:.2f}s ({len(pcm)} bytes)")

    partials, finals = [], []
    async with websockets.connect(URL, max_size=None) as ws:
        chunk = 6400  # 200ms @ 16kHz mono s16le
        for i in range(0, len(pcm), chunk):
            await ws.send(pcm[i:i + chunk])
            try:
                while True:
                    msg = await asyncio.wait_for(ws.recv(), timeout=0.05)
                    j = json.loads(msg)
                    if j.get("type") == "partial":
                        partials.append(j["text"])
                        print(f"  partial: {j['text'][:80]}")
                    elif j.get("type") == "final":
                        finals.append(j["text"])
                        print(f"  final:   {j['text'][:80]}")
                        if j.get("error_code") or j.get("error_message"):
                            print(f"  ERROR code={j.get('error_code')} msg={j.get('error_message')!r}")
            except asyncio.TimeoutError:
                pass
            await asyncio.sleep(0.18)
        await ws.send("EOF")
        try:
            while True:
                msg = await asyncio.wait_for(ws.recv(), timeout=10.0)
                j = json.loads(msg)
                if j.get("type") == "partial":
                    partials.append(j["text"])
                    print(f"  partial: {j['text'][:80]}")
                elif j.get("type") == "final":
                    finals.append(j["text"])
                    print(f"  final:   {j['text'][:80]}")
                    if j.get("error_code") or j.get("error_message"):
                        print(f"  ERROR code={j.get('error_code')} msg={j.get('error_message')!r}")
                    break
        except asyncio.TimeoutError:
            print("WARN: timed out waiting for final after EOF", file=sys.stderr)

    print(f"\npartials: {len(partials)}  finals: {len(finals)}")
    print("OK" if finals and finals[-1] else "FAIL: no final or empty")


if __name__ == "__main__":
    asyncio.run(main())
