# Architecture

voice-stt is a **two-process system**: a Windows client that captures audio
and renders the caption, and a Linux GPU host that runs the ASR models. They
talk over WebSocket (streaming path) or HTTP (batch path).

---

## Roles

| Node | Role | What runs |
|---|---|---|
| **Windows host** | Capture + UI | AutoHotkey hotkey daemon, ffmpeg mic capture, PowerShell WebSocket client, caption renderer |
| **Linux GPU host** | ASR backend | `funasr-stream-server.py` (streaming) and/or Docker Compose stack (batch); FunASR Paraformer + Qwen3-ASR (0.6B default, 1.7B optional) |

A single GPU host can serve many Windows clients on the same Tailscale or LAN
network.

---

## Streaming path (Shift+Alt+S, primary)

The low-latency dictation flow. WebSocket carries PCM upstream and partial /
final transcripts downstream.

```
[Windows]                                          [GPU host]

  Shift+Alt+S held
      │
      ├─ voice-mic-daemon.ps1 keeps a warm           
      │  500 ms ring buffer of 16 kHz mono PCM
      │                                              
      ├─ voice-ptt-stream-ws.ps1 opens
      │  ws://<GPU_HOST>:8082/ ────────────────▶  funasr-stream-server.py
      │  · streams PCM in 100 ms chunks                accepts WS connection
      │                                                FunASR Paraformer
      │                                                emits partial captions
      │  ◀───────────────────────────────────────  every ~300 ms
      │
      ├─ voice-preview-renderer-fallback.ahk
      │  shows partial text near the cursor
      │
  Shift+Alt+S released
      │
      ├─ client sends end-of-audio signal ─────▶  Qwen3-ASR-1.7B
      │                                              runs on the full PCM
      │  ◀────  final transcript ───────────────  ~1 s after release
      │
      └─ voice-hotkey.ahk pastes final text
         into the active window
```

**Latency budget** (typical):
- Partial captions: ~300 ms after speech onset.
- Final transcript: ~1 s after Shift+Alt+S release.

---

## Batch path (Shift+Alt+V, optional)

Used when the streaming path isn't available, or when you want to swap in a
cloud Whisper-compatible API. Records the whole utterance to a WAV file,
uploads it, gets a single response.

```
[Windows]                                          [GPU host]

  Shift+Alt+V pressed
      │
      ├─ record.ps1 captures the whole utterance
      │  to %TEMP%\voice-stt-input-<pid>.wav
      │
      ├─ voice-input.ps1 POSTs the WAV to
      │  http://<GPU_HOST>:9080/v1/audio/transcriptions
      │                                       ───▶  mini-gateway.py (port 9080)
      │                                                proxies to whisper-server (8081)
      │                                                Whisper Large-v3-turbo transcribes
      │                                                (optionally) Ollama Qwen2.5 7B polishes
      │  ◀──────────────────────────────────────   single JSON response
      │
      └─ voice-hotkey.ahk pastes the text
```

**Latency budget**: 3-10 s for a ~10 s utterance, depending on Whisper config
and whether LLM polish is enabled.

---

## Why this design

### Capture on the Windows client, not on the GPU host

Audio capture is path-shortest where the user is. Sending PCM over the
network adds 5-50 ms; routing the user's audio device through the GPU host
adds rewriteable layers and breaks when the user is on a different network.

### WebSocket for streaming, HTTP for batch

WebSocket keeps a hot connection so partial transcripts can stream back
without re-handshaking. HTTP is what every Whisper-compatible API speaks, so
the batch path doubles as the future cloud-ASR bridge (planned for v0.2).

### Qwen3-ASR-1.7B for final, Paraformer for partials

Paraformer is fast (~50 ms inference) but lower accuracy; great for the
live caption while you're still speaking. Qwen3-ASR-1.7B is heavier (~500 ms
inference) but much more accurate; runs once on the full audio after release
to produce the final paste-able text.

### Tailscale or LAN, not a public endpoint

Easier to secure (mesh + ACL), no certificate management, no public IP
required, and zero per-month cost for personal use. The server binds to
`127.0.0.1:8082` by default (loopback only); set `STREAM_HOST=0.0.0.0` to
expose over LAN / Tailscale and gate with a firewall + Tailscale ACL.

---

## Security boundary

- **Transport**: Tailscale provides WireGuard end-to-end encryption by
  default; LAN deployments inherit your local network's trust model.
- **Server binding**: `funasr-stream-server.py` listens on `127.0.0.1`
  (loopback) by default — no network exposure out of the box. Override
  with `STREAM_HOST=0.0.0.0` to bind to all interfaces, then gate with a
  firewall + Tailscale ACL (or LAN-only routing).
- **Local artifacts**: WAV captures land at `%TEMP%\voice-stt-*.wav` and are
  deleted by the client after upload. Partial caption state at
  `%LOCALAPPDATA%\voice-stt\partial.txt` is plain text and overwritten each
  utterance.
- **Logs**: trace logs at `%LOCALAPPDATA%\voice-stt\*.log` may contain
  transcript fragments. They are local-only; rotate or delete if you share
  the machine.

---

## What's NOT in v0.1

For honesty's sake, voice-stt's architecture history includes paths that are
NOT shipping in v0.1:

- **iPhone / mobile capture** — Tailscale-based iPhone dictation flow exists
  in the project's history but isn't tuned or tested enough for OSS release.
  Deferred to v0.2 or later.
- **PWA + VPS reverse proxy** — Caddy + autossh + Tailscale TLS termination
  on a separate VPS for a PWA front-end. Same status: deferred.
- **Cloud ASR (OpenAI, Groq, Deepgram)** — `OPENAI_BASE_URL` + Bearer auth.
  Planned for v0.2; v0.1 supports OpenAI-compatible URLs but not Bearer auth.

The codebase still contains placeholders or partial implementations for some
of these. They're inert at runtime under v0.1 defaults.
