# Changelog

All notable changes to voice-stt are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/) (pre-1.0; breaking changes allowed).

---

## [Unreleased]

_No changes since v0.1.1._

---

## [v0.1.1] - 2026-05-21

### Added
- **Cloud ASR providers** via pluggable `ASRProvider` ABC in `server/asr_common.py`:
  - Volcano 火山豆包 ASR 2.0 — binary frame protocol, generous free tier (20 h / 6 mo + 注册送 40 h)
  - Tencent Cloud Real-Time ASR — HMAC-SHA1 signed URL, 5 h / month free in mainland CN
  - 讯飞 RTASR — HMAC-SHA1 signed URL, 50 h / 1 yr trial
- **`Shift+Alt+E`** Windows hotkey — cycle ASR backend in-place without editing
  config. Selection persisted to `%LOCALAPPDATA%\voice-stt\backend.txt`,
  shown in AHK tray tooltip
- `docs/PROVIDERS.md` — provider availability matrix, setup recipes,
  cross-border billing caveats (e.g. Tencent 5 h / month does NOT cover
  overseas traffic — overseas users should prefer Volcano)
- `server/tools/` — diagnostic helpers:
  - `provider_smoke.py` — generic E2E test for any voice-stt-protocol WS
  - `tencent_get_appid.py` — resolve UIN/AppID confusion via `cam:GetUserAppId`
  - `tencent_sentence_probe.py` — A/B probe (HTTP works ≠ WS works)
- Gateway post-process mode `strict_correction` — fixes ASR errors
  (homophones, technical terms) without removing fillers or rewriting tone.
- Custom-mode prompt variables: `system_prompt` templates may now
  reference `{text}`, `{selected}`, `{clipboard}` placeholders, which
  the gateway substitutes (single-pass regex, no re-expansion) from
  the corresponding JSON body fields. Empty/missing fields fall through
  as empty strings; placeholders are always expanded when present (no
  escape syntax); built-in modes are unaffected.
- OpenAI-compatible Bearer ASR backend (`server/openai-compat-stream-server.py`)
  — a new ASRProvider for any Whisper-compatible HTTP endpoint
  (openai.com, Groq, self-hosted). Configured via
  `~/.config/voice-stt/secrets/openai-compat.env` and selected via
  the new "openai-compat" entry in the AHK Shift+Alt+E backend cycle.

### Changed
- Paste flow no longer restores previous clipboard — transcribed text stays
  in clipboard so the user can `Ctrl+V` manually if auto-paste lands in the
  wrong window. Previous clipboard recoverable via `Win+V` system history
- `volcano-stream-server.py` refactored onto `ASRProvider` ABC, ~200 LOC of
  scaffolding moved to shared `asr_common.py`

### Fixed
- Volcano: EOF-with-no-audio now short-circuits to `{type:final,text:""}`
  instead of hanging the upstream session. Saved free-tier session quota
  during Test-Connection probes from the iPhone Happy fork client
- `MIC_DEVICE_NAME` now works as an alias for `RECORD_DEVICE_NAME` in both
  `windows/voice-mic-daemon.ps1` and `windows/voice-ptt-stream-ws.ps1`.
  Resolves the v0.1.0 "not yet wired" admission; either env var name
  starts the mic. `RECORD_DEVICE_NAME` still takes precedence if both set.
- `FINAL_BACKEND=cloud-volcano` no longer claims to be a "reserved v0.2
  placeholder". The error message now points users at the actual
  architecture pattern (cloud providers run as sibling WS servers, e.g.
  `python server/volcano-stream-server.py`, not as final-pass backends).
  Reduces confusion when a stale config references the legacy value.

---

## [v0.1.0] - 2026-05-18

First public release. See [docs/releases/v0.1.md](docs/releases/v0.1.md)
for the published release announcement.

### Known limitations (v0.1)

- **Hotkey bindings are hardcoded** (Shift+Alt+S / Shift+Alt+P / Shift+Alt+V).
  User-tunable hotkeys via `.env` (`HOTKEY_STREAM`, `HOTKEY_TTS`, `HOTKEY_VOCAB`)
  are planned for v0.2.
- **`MIC_DEVICE_NAME` alias not yet wired**: v0.1 reads only `RECORD_DEVICE_NAME`.
- **Direct OpenAI Whisper API auth is out of scope.** `OPENAI_BASE_URL` may
  point at an OpenAI-compatible gateway (e.g., a self-hosted Whisper service),
  but native `OPENAI_API_KEY` Bearer auth is deferred to v0.2.
- **Streaming ASR transport is WebSocket-only** in v0.1. HTTP transport (for
  cloud Whisper-compatible providers like Groq, OpenRouter) is a v0.2 task.
- **Demo GIF / screencast pending**: a short usage GIF will be recorded and
  committed before the public v0.1.0 release.
- **Installer is unsigned**, so Windows SmartScreen warns on first run. A
  signed `.msi` is a v0.2 candidate (cost: ~$200/yr code-signing cert).

### v0.2 roadmap (post-v0.1 directions, not yet planned dates)

- **Cloud ASR backend**: wire `OPENAI_BASE_URL` + `OPENAI_API_KEY` Bearer auth
  so users without a GPU can point at hosted Whisper APIs (OpenAI, Groq,
  DeepInfra, etc.). Adds HTTP transport to `voice-ptt-stream-ws.ps1`.
- **User-tunable hotkeys**: implement `.env` reading for `HOTKEY_STREAM`,
  `HOTKEY_TTS`, `HOTKEY_VOCAB` (replacing the hardcoded Shift+Alt+S/P/V).
- **First-run wizard**: optional GUI prompt for ASR endpoint choice (local
  GPU / cloud / OpenAI-compatible) on first launch.
- **Single-file installer**: self-extracting EXE (IExpress / 7-zip SFX) or
  signed `.msi`. Cuts the install path to a single double-click without the
  current "extract zip then double-click `install.bat`" two-step.
- **winget submission**: `winget install voice-stt` once a stable release exists.

### Added
- `install.ps1` — installer for cloned repo: installs AutoHotkey v2, copies
  scripts to `%LOCALAPPDATA%\voice-stt\`, creates Startup shortcut that runs
  `launch.ps1`. Idempotent; supports `-DryRun`.
- `windows/launch.ps1` — canonical launcher used by both installed mode (via
  the Startup shortcut) and the portable ZIP. Loads `.env` into process env
  vars before spawning AutoHotkey, so user-tunable values (`ASR_WS_URL`,
  `RECORD_DEVICE_NAME`, etc.) take effect in both modes.
- `scripts/uninstall.ps1` — reverses install.ps1 (removes scripts and Startup shortcut;
  preserves `.env` and logs).
- `scripts/build-portable.ps1` — produces `dist/voice-stt-portable.zip` for no-install use.
- Warm mic capture with ~300ms pre-roll ring buffer (no clipped first syllable on Shift+Alt+S).
- SAPI TTS hotkey (Shift+Alt+P) for pronunciation lookup.
- Caption preview window (WebView2 / Edit-control fallback) showing partial transcription
  during dictation.
- `docs/QUICKSTART.md`, `docs/CONFIG.md` — user-facing documentation.
  GPU server setup lives in `server/README.md`.
- `CONTRIBUTING.md`, `SECURITY.md` — project health files.
- `.github/workflows/secret-scan.yml` — gitleaks secret scanning on pull requests.

### Changed
- **Path refactor (migration required):** All runtime files moved from `%TEMP%` and
  ad-hoc locations to `%LOCALAPPDATA%\voice-stt\`:
  - `voice-ptt-partial.txt` → `%LOCALAPPDATA%\voice-stt\partial.txt`
  - `stream-debug.log` → `%LOCALAPPDATA%\voice-stt\stream-debug.log`
  - `ptt-debug.log` → `%LOCALAPPDATA%\voice-stt\ptt-debug.log`
  - `renderer.log` → `%LOCALAPPDATA%\voice-stt\renderer.log`
  - `stream-ws-trace.log` → `%LOCALAPPDATA%\voice-stt\stream-ws-trace.log`
  - `mic-daemon-<pid>.log` → `%LOCALAPPDATA%\voice-stt\mic-daemon-<pid>.log`

  **If you are upgrading from a pre-refactor install:** your `.env` file and hotkey
  bindings are unchanged. The `%LOCALAPPDATA%\voice-stt\` directory is created
  automatically on first run. No manual action needed.

---

## Migration notes

### Pre-refactor installs (before this release)

If you had a working setup before this open-source release:

1. **Re-run `install.ps1`** to copy updated scripts and create the new directory.
2. **Your `.env` is preserved** — the installer never overwrites an existing `.env`.
3. **Verify `ASR_WS_URL`** in `.env` still points to your FunASR server.
4. Old log files in `%TEMP%` can be deleted manually — they are no longer written there.

---

[Unreleased]: https://github.com/fzhiy/voice-stt/compare/v0.1.1...HEAD
[v0.1.1]: https://github.com/fzhiy/voice-stt/releases/tag/v0.1.1
[v0.1.0]: https://github.com/fzhiy/voice-stt/releases/tag/v0.1.0
