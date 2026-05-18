# voice-stt Quick Start (5 minutes)

This guide takes you from nothing to your first successful push-to-talk dictation.

---

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| Windows | 10 or 11 | 64-bit |
| PowerShell | 5.1+ | Comes with Windows; `pwsh` 7 also works |
| AutoHotkey | v2 | Installed by `install.ps1` automatically |
| ffmpeg | any recent | `winget install --id Gyan.FFmpeg -e` |
| FunASR server | — | See [server/README.md](../server/README.md) |

---

## Step 1 — Install

Download the [latest release ZIP](../../releases/latest) (`voice-stt.zip` —
link resolves to GitHub Releases; available after the first release is published)
and extract anywhere on your machine. Two entry points sit at the extraction root:

**Installed mode** (autostart on login):

1. Double-click `install.bat`
2. SmartScreen warns — click **More info** → **Run anyway**
3. Wait for "Installation complete."

What `install.bat` does (via `install.ps1`):
- Downloads AutoHotkey v2 from autohotkey.com (pinned version) if absent
- Copies scripts to `%LOCALAPPDATA%\voice-stt\`
- Seeds `.env` from `.env.example`
- Registers a Startup shortcut that runs `launch.ps1` at login (which loads
  `.env` and starts `voice-hotkey.ahk`)

**Portable mode** (no install, runs in place):

1. First install AHK v2: download `AutoHotkey_2.0.x.zip` from
   [autohotkey.com](https://www.autohotkey.com) and extract to
   `%LOCALAPPDATA%\Programs\AutoHotkey\v2\`. (Portable mode does NOT
   auto-install AHK.)
2. Double-click `start.bat` in the extracted voice-stt folder. First run
   creates `voice-stt\.env` (next to README.md) from `.env.example` and
   prompts you to edit it.

> **Portable note:** `start.bat` (and `windows\launch.ps1`) still writes to
> `%LOCALAPPDATA%\voice-stt\` for the caption preview state file and
> diagnostic logs. "Portable" means the scripts are self-contained, not that
> nothing is written outside the extraction folder.

> **SmartScreen warning:** Click **More info** → **Run anyway**. This is
> expected for unsigned scripts. See [SECURITY.md](../SECURITY.md).

### CLI alternative

Prefer running the .ps1 scripts directly?

```powershell
.\install.ps1 -DryRun        # preview, no changes
.\install.ps1                # install
.\windows\launch.ps1         # portable mode
```

---

## Step 2 — Configure

Open your `.env` in any text editor. Its location depends on the mode:

- **Installed mode:** `%LOCALAPPDATA%\voice-stt\.env`
- **Portable mode:** `<extracted-folder>\.env` (next to `README.md`)

Set the two required values:

```ini
# Required: WebSocket URL of your FunASR server
ASR_WS_URL=ws://192.168.1.50:8082/

# Required: your microphone dshow device name
# Discover device names:
#   powershell -File "%LOCALAPPDATA%\voice-stt\record.ps1" -Diagnose
RECORD_DEVICE_NAME=Headset Microphone (USB Audio Device)
```

Save the file. Full option reference: [CONFIG.md](CONFIG.md).

---

## Step 3 — Start voice-stt

Either:
- **Reboot** — the Startup shortcut launches `voice-hotkey.ahk` automatically, or
- **Double-click** `%LOCALAPPDATA%\voice-stt\voice-hotkey.ahk`

You will see an AutoHotkey tray icon appear in the system tray. A tooltip
"mic daemon 启动" confirms the warm-capture daemon is running.

---

## Step 4 — First PTT

1. Open any text editor, browser text box, chat app, etc.
2. Hold **Shift+Alt+S**
3. Speak clearly: _"hello world this is a test"_
4. A dark caption window appears near the bottom of the screen showing partial transcription
5. Release **Shift+Alt+S**
6. Wait ~1-2 seconds for final transcription
7. The text pastes into your active window automatically

---

## Troubleshooting

**No caption appears:**
- Check `%LOCALAPPDATA%\voice-stt\stream-debug.log` for errors
- Verify `ASR_WS_URL` in `.env` is reachable: `Test-NetConnection <host> -Port 8082`

**"DeviceName not set" error:**
- Run `record.ps1 -Diagnose` and copy the exact device name string into `.env`

**Transcription is empty or garbled:**
- Check the FunASR port is reachable from Windows:
  `Test-NetConnection <host> -Port 8082` (TcpTestSucceeded should be True).
  Note: 8082 is a WebSocket endpoint, so `curl` will not return HTML — port
  reachability is the right signal.
- Try a shorter phrase first

**SmartScreen blocks install.ps1:**
- Right-click install.ps1 → Properties → Unblock, then re-run
- Or: Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned

---

More help: [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | [CONFIG.md](CONFIG.md)
