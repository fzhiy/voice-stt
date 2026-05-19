# server/tools — diagnostic scripts

Stand-alone helpers for troubleshooting cloud ASR provider setup. None of
these are imported by the streaming servers; they exist for human use.

## `provider_smoke.py`

End-to-end test for any voice-stt-protocol WS server. Streams a known 16 kHz
mono int16 WAV at real-time pace, sends `"EOF"`, prints partial + final events.

```bash
# default: ws://127.0.0.1:18094/ (Tencent), using sherpa-onnx test WAV
python server/tools/provider_smoke.py

# point at any other backend
URL=ws://127.0.0.1:18093/ python server/tools/provider_smoke.py   # Volcano
URL=ws://127.0.0.1:18095/ python server/tools/provider_smoke.py   # Xfyun
URL=ws://127.0.0.1:8082/  python server/tools/provider_smoke.py   # FunASR

# override the test audio
WAV=/path/to/your-16khz-mono.wav python server/tools/provider_smoke.py
```

Expected output on success:

```
loaded 0.wav: 16000Hz 1ch 16bit 10.05s (321700 bytes)
  partial: 昨天
  partial: 昨天是
  ...
  final:   昨天是。Monday.Today is礼拜二，The day after tomorrow是星期三。
partials: 16  finals: 1
OK
```

## `tencent_get_appid.py`

Calls Tencent Cloud `cam:GetUserAppId` with TC3-HMAC-SHA256 signing to
discover the AppID for the credentials in `~/.config/voice-stt/secrets/tencent.env`.

Use case: you registered a Tencent Cloud sub-user and have a SecretId/Key
pair but don't know which AppID to put in the URL path. UIN and AppID look
similar (both are ~10 digit numbers) but are different fields; the wrong
one causes `code=4002 '鉴权失败'`.

```bash
python server/tools/tencent_get_appid.py
# Response: {"Uin": "100...", "OwnerUin": "100...", "AppId": 1301574382, ...}
```

Use `AppId` (not `Uin` or `OwnerUin`) as `TENCENT_APP_ID` in tencent.env.

## `tencent_sentence_probe.py`

Calls Tencent's HTTP `SentenceRecognition` API (一句话识别) with a real
5-second WAV. Useful diagnostic: if the WS streaming endpoint
(`tencent-stream-server.py`) returns `code=4004 '资源包耗尽'` but this script
succeeds, the issue is **「实时语音识别」 sub-product specifically** isn't
activated — not an account-wide billing problem. See
[docs/TROUBLESHOOTING.md § Cloud ASR providers](../../docs/TROUBLESHOOTING.md#cloud-asr-providers).

```bash
python server/tools/tencent_sentence_probe.py
# Success: {"Response": {"Result": "...transcribed text...", "AudioDuration": 5000, ...}}
# 4004:    {"Response": {"Error": {"Code": "FailedOperation.UserResourceNotEnough", ...}}}
```
