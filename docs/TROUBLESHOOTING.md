# Troubleshooting

Organized by user-visible symptom. Each entry: what you see, likely cause, fix.

> Also see [QUICKSTART.md](QUICKSTART.md) "Troubleshooting" section for
> install-time issues; this doc covers runtime + server-side problems.

---

## Install

### `install.ps1` opens in Notepad on double-click

Windows associates `.ps1` with Notepad by default. Use one of:

- Double-click `install.bat` instead (the wrapper that calls install.ps1 with
  the right ExecutionPolicy).
- Right-click `install.ps1` → **Run with PowerShell**.
- From PowerShell: `.\install.ps1` directly.

### SmartScreen blocks `install.ps1` / `install.bat`

Expected for unsigned scripts. Click **More info** → **Run anyway**.

If you want to bypass at the file level (e.g., the file came through email or
USB), right-click the file → **Properties** → **Unblock** at the bottom.

### `install.ps1 -DryRun` says "windows\ directory not found"

You're running `install.ps1` from somewhere that doesn't have `windows/` as a
sibling. From a cloned repo, run from repo root. From the release ZIP,
extract first, then run from the extracted folder.

### Installation succeeded but Shift+Alt+S does nothing

Check that `voice-hotkey.ahk` is actually running:

1. Look for the AutoHotkey green-H tray icon in the system tray.
2. If absent, double-click `%LOCALAPPDATA%\voice-stt\launch.ps1` to start it
   (or reboot — the Startup shortcut launches it on login).
3. If AHK loaded but the hotkey doesn't trigger, another app may have
   reserved Shift+Alt+S. Test by closing other apps with global hotkeys
   (e.g., Snipping Tool variations, screen recorders).

---

## Caption / streaming PTT (Shift+Alt+S)

### No caption window appears while holding Shift+Alt+S

Check the streaming-WS trace log:

```powershell
Get-Content $env:LOCALAPPDATA\voice-stt\stream-ws-trace.log -Tail 50
```

Common patterns:

- **"WebSocket connection failed"** — `ASR_WS_URL` is unreachable. Verify the
  GPU server is running (`ss -tlnp | grep 8082` on the server) and that
  Tailscale / LAN routing is working (`Test-NetConnection <server> -Port 8082`
  from Windows).
- **"ffmpeg not found"** — install ffmpeg (`winget install Gyan.FFmpeg`),
  reopen PowerShell so PATH refreshes.
- **"Mic device not found"** — set `RECORD_DEVICE_NAME` in
  `%LOCALAPPDATA%\voice-stt\.env`. Discover the right name with
  `record.ps1 -Diagnose`.

### Caption shows but transcript is wrong / garbled

- Mic level too low — wear a headset or sit closer to the laptop mic.
- Wrong channel — laptops with a 2-channel array but one broken element
  produce noise on one side. Set `RECORD_MIC_CHANNEL=left` (or `right`) in
  `.env`.
- Wrong language — the streaming server auto-detects but you can force it via
  `STREAM_MODEL` if you know the model has a language variant.

### Final transcript appears but isn't pasted

`ClipWait` timed out — the target app didn't accept the paste. Try:

- Click into the target text field first, then hold Shift+Alt+S.
- Wait an extra second after release before switching windows.
- Some apps (terminal, certain games) intercept paste; try a regular text
  field (Notepad, browser address bar) to confirm voice-stt is working.

### Caption appears at the wrong screen position

The renderer (`voice-preview-renderer-fallback.ahk`) positions the caption
relative to the cursor at hotkey-press time. If you're on a multi-monitor
setup with mismatched DPI, position may drift. Known v0.1 limitation.

---

## Batch PTT (Shift+Alt+V)

### No response after release

Check the gateway is up:

```bash
curl http://<gateway-host>:9080/health   # batch-path gateway
```

If down: on the server, `docker compose ps` should show whisper + ollama +
mini-gateway as `Up`. If any are exiting, `docker compose logs <name>` will
show why.

### Slow (>10 s for a 5 s clip)

Whisper running on CPU instead of GPU. Check `docker compose logs whisper`
for `device: cpu` vs `device: cuda:0`. CPU fallback usually means the
NVIDIA Container Toolkit isn't installed correctly on the host.

---

## GPU server side

### `funasr-stream-server.py` crashes on startup

Tail `stream-server.log` (in `$VOICE_STACK_DIR` or `~/voice-stack`):

- **"CUDA out of memory"** — another process is using VRAM. `nvidia-smi`
  shows who. Kill it, or use the `transformers` backend instead of `vllm`
  (set `QWEN3_BACKEND=transformers`).
- **"CUDA driver mismatch"** — your installed PyTorch wheel doesn't match
  your CUDA toolkit version. Reinstall torch with the right `--extra-index-url`
  (e.g., `https://download.pytorch.org/whl/cu121` for CUDA 12.1).
- **"Could not load Qwen3-ASR-1.7B"** — `QWEN3_ASR_PATH` doesn't exist or
  the download failed. Manually `huggingface-cli download` the model, or
  set `HF_ENDPOINT=https://hf-mirror.com` and let the server retry.

### `docker compose up` reports `could not select device driver "" with capabilities: [[gpu]]`

NVIDIA Container Toolkit missing. On Ubuntu:

```bash
distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt update && sudo apt install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

### Server is up but client can't reach it

```bash
# On the server
ss -tlnp | grep -E '8082|9080'
# Expect: 0.0.0.0:8082 LISTEN ...   (NOT 127.0.0.1:8082)
```

If bound to localhost only: a firewall is restricting the bind, or the
service was started with a `--host 127.0.0.1` flag override. Check the start
script.

```bash
# From the client (Windows PowerShell)
Test-NetConnection <server-host> -Port 8082
# Expect: TcpTestSucceeded : True
```

If TCP fails: firewall (Windows Defender, ufw on the server, or Tailscale
ACL) is blocking the port.

---

## VRAM and performance

### Out-of-VRAM running both streaming and batch on the same card

Two options:

- Run only one path at a time. Don't `docker compose up` the batch stack if
  you're going to use the streaming WebSocket.
- Downgrade the batch LLM: in `server/.env.server`, set
  `LLM_MODEL=qwen2.5:3b` and `docker compose exec ollama ollama pull qwen2.5:3b`.

### Streaming latency feels high (>500 ms partial captions)

- The first inference after server startup is slow (model warmup); ~300 ms
  is steady-state once warmed.
- Check `nvidia-smi` while dictating — if utilization is at 100% with
  another workload, contention is the issue.

---

## Logs to share when asking for help

When opening an issue, attach the relevant log slice (redact any PII first):

| Symptom | Log file |
|---|---|
| Install / install.ps1 error | Output from `.\install.ps1 -DryRun` |
| Streaming WS fails | `%LOCALAPPDATA%\voice-stt\stream-ws-trace.log` |
| Caption renderer issues | `%LOCALAPPDATA%\voice-stt\renderer.log` |
| Batch PTT issues | `%LOCALAPPDATA%\voice-stt\ptt-debug.log` |
| GPU server crashes | `~/voice-stack/stream-server.log` (or `docker compose logs <service>` for batch path) |
