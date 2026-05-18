# voice-stt Configuration Reference

All configuration is in `.env`, created from `.env.example`. Its location:

- **Installed mode:** `%LOCALAPPDATA%\voice-stt\.env`
- **Portable mode:** at the extraction root, next to `README.md`

Variables marked **Required** must be set before the tool works.
All others have safe defaults — leave them commented out unless you need to change them.

---

## Required

| Variable | Default | Meaning |
|---|---|---|
| `ASR_WS_URL` | `ws://192.168.1.50:8082/` | WebSocket URL for the FunASR streaming server. Change to your GPU machine's LAN IP or Tailscale hostname. |
| `RECORD_DEVICE_NAME` | _(none)_ | Windows dshow microphone device name. Discover with: `record.ps1 -Diagnose` |

---

## Recording

| Variable | Default | Meaning | When to change |
|---|---|---|---|
| `RECORD_DEVICE_ID` | `-1` | waveIn device ID (`-1` = system default). Rarely needed if `RECORD_DEVICE_NAME` is set. | Only if dshow name lookup fails |
| `RECORD_RATE` | `16000` | Sample rate (Hz). FunASR expects 16000. | Do not change |
| `RECORD_CHANNELS` | `1` | Channels to request from ffmpeg. | Do not change |
| `RECORD_BITS` | `16` | Bit depth. | Do not change |
| `RECORD_MIC_CHANNEL` | `left` | Which channel to use when the mic delivers stereo: `left`, `right`, or `mix`. | If your headset only works on the right element |
| `RECORD_WARMUP_SEC` | _(internal default)_ | Ring buffer size in seconds for warm-capture pre-roll. Increase if the first syllable is still clipped. | Rarely needed |
| `USE_MCI` | `0` | Force legacy MCI audio path (debug only). | Do not change |
| `USE_WAVEIN` | `1` | Enable waveIn capture path. | Do not change |

---

## Network / ASR Server

| Variable | Default | Meaning | When to change |
|---|---|---|---|
| `GATEWAY_URL` | _(none)_ | HTTP URL of the optional batch ASR gateway (Shift+Alt+V path). Example: `http://gpu-tower:9080` | If you use batch upload mode |

Server-side knobs (`STREAM_HOST`, `STREAM_PORT`, and all FunASR / Qwen3 /
VAD / LLM / hotword variables) live on the GPU host, not in the Windows
client `.env`. See [server/README.md](../server/README.md).

---

## Whisper / Batch Gateway (optional — Shift+Alt+V)

Only needed if you use the optional batch upload path. Skip if you only use
the streaming path (Shift+Alt+S, primary).

| Variable | Default | Meaning |
|---|---|---|
| `WHISPER_MODEL` | `large-v3-turbo` | Model name sent to the gateway. |
| `WHISPER_LANG` | `zh` | Language hint. Use `en` for English-only, or leave `zh` for mixed. |

Server-side knobs (`WHISPER_HOST`, `WHISPER_PORT`, `GATEWAY_PORT`,
`WHISPER_INITIAL_PROMPT`) live on the gateway host, not in the Windows
client `.env` — see [server/README.md](../server/README.md).

---

## Server-side configuration

Streaming ASR (FunASR + Qwen3-ASR), VAD, optional LLM polish, hotword lists,
and HuggingFace mirror — all configured on the GPU host, not on the Windows
client. See [server/README.md](../server/README.md) for the full list.

LLM polish (`ENABLE_LLM`) is **OFF by default** in v0.1; you only need it if
you want LLM cleanup on the optional batch path.

---

## Debug

| Variable | Default | Meaning |
|---|---|---|
| `VERBOSE` | `0` | Set `1` to print additional diagnostic output in voice helper scripts. |

---

## File Locations

Runtime files written by voice-stt (not in `.env` — controlled by the code):

| File | Purpose |
|---|---|
| `%LOCALAPPDATA%\voice-stt\.env` | Your configuration (preserved on uninstall) |
| `%LOCALAPPDATA%\voice-stt\partial.txt` | Live partial transcript (read by caption renderer) |
| `%LOCALAPPDATA%\voice-stt\stream-debug.log` | Streaming PTT debug log |
| `%LOCALAPPDATA%\voice-stt\ptt-debug.log` | Batch PTT debug log |
| `%LOCALAPPDATA%\voice-stt\renderer.log` | Caption renderer log |
| `%LOCALAPPDATA%\voice-stt\stream-ws-trace.log` | WebSocket trace log |
| `%LOCALAPPDATA%\voice-stt\mic-daemon-<pid>.log` | Warm-capture daemon log |
| `%TEMP%\voice-stt-*.wav` | Temporary recording files (deleted after upload) |
