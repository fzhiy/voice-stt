# voice-stt

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Real-time push-to-talk voice transcription for Windows, powered by
[FunASR](https://github.com/modelscope/FunASR) streaming ASR. Press
**Shift+Alt+S**, speak, release — your words appear as a caption and paste
into the active window.

```
Shift+Alt+S  →  hold to dictate, release to paste (streaming, caption preview)
Shift+Alt+P  →  read selected text aloud (SAPI TTS, zero-latency)
Shift+Alt+V  →  batch PTT (uploads WAV to Whisper-compatible gateway)
```

**Features:**
- Live partial-transcript caption during dictation (no waiting for release)
- Warm mic capture with ~300ms pre-roll ring buffer (no clipped first syllable)
- Left-channel-only recording for headsets with single working mic element
- Self-hosted ASR — no cloud API key, audio stays on your network

See [docs/QUICKSTART.md](docs/QUICKSTART.md) for first-run instructions.

---

## Install

**Requires:** Windows 10+, PowerShell 5.1+, and `ffmpeg` on `PATH`
(`winget install --id Gyan.FFmpeg -e`). AutoHotkey v2 is installed
automatically by `install.bat`; for portable mode you install it once
yourself.

Download the [latest release ZIP](../../releases/latest) (`voice-stt.zip`) and
extract anywhere. The ZIP serves both modes — double-click either:

| File | Mode | What happens |
|---|---|---|
| `install.bat` | **Installed** (autostart on login) | Downloads AHK v2 if absent → copies scripts to `%LOCALAPPDATA%\voice-stt\` → seeds `.env` there → registers Startup shortcut |
| `start.bat` | **Portable** (no install) | Reads `.env` from the extracted folder root (auto-seeds from `.env.example` on first run) → launches `voice-hotkey.ahk` from `windows\`. Requires AHK v2 to already be installed. |

> **SmartScreen** will warn about unsigned scripts. Click **More info** →
> **Run anyway**. The scripts are open-source — review `install.ps1` before
> running if you want.

### Portable mode prerequisite

`start.bat` does NOT auto-install AutoHotkey. Install AHK v2 manually first:
download `AutoHotkey_2.0.x.zip` from [autohotkey.com](https://www.autohotkey.com)
and extract its contents to `%LOCALAPPDATA%\Programs\AutoHotkey\v2\` (so
`AutoHotkey64.exe` lands at that path). For auto-install, use `install.bat`
instead.

### CLI alternatives

Prefer PowerShell? Both wrappers are thin — call the underlying scripts directly:

```powershell
# Installed mode
.\install.ps1 -DryRun       # preview planned actions
.\install.ps1               # apply

# Portable mode
.\windows\launch.ps1
```

### Developer install (from git)

For local development, clone the repo and run from there:

```powershell
git clone https://github.com/fzhiy/voice-stt
cd voice-stt
.\install.ps1
```

The repo layout matches the release ZIP — same `install.ps1` works in both.

---

## 5-minute setup

See **[docs/QUICKSTART.md](docs/QUICKSTART.md)** for the full walkthrough:
install → configure → first PTT → paste.

---

## Configuration

All options are set in `.env` (created from `.env.example` by the installer).
See **[docs/CONFIG.md](docs/CONFIG.md)** for every variable with defaults.

Minimum required:

```ini
ASR_WS_URL=ws://192.168.1.50:8082/    # your FunASR server
RECORD_DEVICE_NAME=Microphone Array   # discover: record.ps1 -Diagnose
```

---

## Self-hosting the ASR server

See **[server/README.md](server/README.md)** to run FunASR Paraformer +
Qwen3-ASR (0.6B default; 1.7B as quality preset on ≥16 GB cards) on a Linux
GPU host and expose it over your LAN or Tailscale.

---

## License

[MIT](LICENSE) — see [CONTRIBUTING.md](CONTRIBUTING.md) to contribute.
