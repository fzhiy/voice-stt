"""Test Tencent ASR SentenceRecognition (HTTP, NOT WebSocket) with real audio.

Goal: determine whether the account's ASR billing is broken (4004 on every
ASR call) OR specific to the WebSocket streaming endpoint.

Uses a 5-second slice of the test WAV (well under SentenceRecognition's
60s/1MB limits).
"""
import base64
import hashlib
import hmac
import json
import time
import urllib.request
import wave
from pathlib import Path

SECRETS = Path.home() / ".config" / "voice-stt" / "secrets" / "tencent.env"
WAV = Path.home() / ".cache" / "sherpa-onnx-streaming-paraformer-bilingual-zh-en" / "test_wavs" / "0.wav"


def _parse_env(p):
    out = {}
    for line in p.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def _tc3_call(host, service, action, version, payload, sid, skey):
    ts = int(time.time())
    date = time.strftime("%Y-%m-%d", time.gmtime(ts))
    canonical_headers = (
        f"content-type:application/json; charset=utf-8\n"
        f"host:{host}\n"
        f"x-tc-action:{action.lower()}\n"
    )
    signed = "content-type;host;x-tc-action"
    body = json.dumps(payload)
    body_hash = hashlib.sha256(body.encode()).hexdigest()
    canon = f"POST\n/\n\n{canonical_headers}\n{signed}\n{body_hash}"
    scope = f"{date}/{service}/tc3_request"
    canon_hash = hashlib.sha256(canon.encode()).hexdigest()
    to_sign = f"TC3-HMAC-SHA256\n{ts}\n{scope}\n{canon_hash}"

    def h(k, m): return hmac.new(k, m.encode(), hashlib.sha256).digest()
    sk1 = h(("TC3" + skey).encode(), date)
    sk2 = h(sk1, service)
    sk3 = h(sk2, "tc3_request")
    sig = hmac.new(sk3, to_sign.encode(), hashlib.sha256).hexdigest()
    auth = (f"TC3-HMAC-SHA256 Credential={sid}/{scope}, "
            f"SignedHeaders={signed}, Signature={sig}")
    req = urllib.request.Request(
        f"https://{host}", data=body.encode(), method="POST",
        headers={
            "Authorization": auth, "Content-Type": "application/json; charset=utf-8",
            "Host": host, "X-TC-Action": action, "X-TC-Timestamp": str(ts),
            "X-TC-Version": version,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode())
        except Exception:
            return {"error": str(e)}


def make_short_wav(src: Path, duration_sec: float = 5.0) -> bytes:
    """Read WAV, keep first N seconds, re-encode as full WAV bytes."""
    with wave.open(str(src), "rb") as w:
        sr = w.getframerate()
        nch = w.getnchannels()
        sw = w.getsampwidth()
        n_frames = int(duration_sec * sr)
        pcm = w.readframes(n_frames)
    # Build a fresh WAV file (PCM in-memory)
    import io
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(nch)
        w.setsampwidth(sw)
        w.setframerate(sr)
        w.writeframes(pcm)
    return buf.getvalue()


def main():
    c = _parse_env(SECRETS)
    sid, skey = c["TENCENT_SECRET_ID"], c["TENCENT_SECRET_KEY"]
    wav_bytes = make_short_wav(WAV, 5.0)
    print(f"audio: {len(wav_bytes)} bytes (5s WAV)")

    payload = {
        "ProjectId": 0,
        "SubServiceType": 2,                  # 2 = 一句话识别
        "EngSerViceType": "16k_zh",
        "SourceType": 1,                       # 1 = inline data (Data field)
        "VoiceFormat": "wav",
        "UsrAudioKey": f"voice-stt-probe-{int(time.time())}",
        "Data": base64.b64encode(wav_bytes).decode(),
        "DataLen": len(wav_bytes),
    }
    r = _tc3_call("asr.tencentcloudapi.com", "asr", "SentenceRecognition",
                  "2019-06-14", payload, sid, skey)
    print(json.dumps(r, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
