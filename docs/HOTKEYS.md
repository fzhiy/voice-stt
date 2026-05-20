# Hotkeys & customization

voice-stt ships with four push-to-talk hotkeys, all defined in
`windows/voice-hotkey.ahk` (AutoHotkey v2). For most users the defaults are
enough — you don't need to change anything.

## Default bindings

| Hotkey | Action |
|---|---|
| `Shift+Alt+S` | Hold to dictate, release to paste (streaming + live preview) |
| `Shift+Alt+E` | Cycle ASR backend (local Qwen3 ↔ cloud providers) |
| `Shift+Alt+V` | Batch push-to-talk (WAV → Whisper-compatible gateway) |
| `Shift+Alt+P` | Read selected text aloud (SAPI TTS) |

## Remapping a hotkey

Bindings are AutoHotkey v2 hotkey labels near the top of
`windows/voice-hotkey.ahk`. AHK modifier symbols:

| Symbol | Modifier |
|---|---|
| `+` | Shift |
| `!` | Alt |
| `^` | Ctrl |
| `#` | Win |

So `Shift+Alt+S` is written `+!s::`. To move dictation to, say,
`Ctrl+Alt+D`, change the `+!s` label prefix to `^!d`. Save, then reload the
script (tray icon → Reload, or restart it).

> **Installed vs. repo copy:** if you used `install.bat` / `install.ps1`, the
> *running* copy lives at `%LOCALAPPDATA%\voice-stt\`. Edit the copy there, or
> edit the repo copy and re-run `install.ps1`. Portable mode (`start.bat`)
> runs the extracted folder directly.

## Post-process modes (gateway)

The batch gateway (`server/mini-gateway.py`) can transform a transcript
before it is pasted:

- **polish** — remove fillers + fix punctuation without changing meaning
- **translate** — translate the transcript
- **prompt-optimize** — rewrite into a cleaner prompt
- **custom** — your own server-side prompt

These are selected on the server side (see `docs/CONFIG.md` for the gateway
options). Binding each mode to its own hotkey (e.g. `Shift+Alt+1/2/3`) is
**not** wired into the default client — it's a documented customization
point: add a hotkey label in `voice-hotkey.ahk` that triggers the batch flow
with the desired mode. (A first-class per-mode-hotkey feature may land in a
future release.)
