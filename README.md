# voice-stt

**([简体中文](./README.zh.md) | English)**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-v0.1.1-green.svg)](CHANGELOG.md)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%2B-blue.svg)](#install)

> **Sub-second voice-to-paste for Windows + WSL.** Push-to-talk dictation
> with a pluggable ASR backend — run it fully self-hosted (FunASR Paraformer
> streaming + Qwen3-ASR-1.7B) on a 12 GB consumer GPU, or point it at a
> cloud provider (火山豆包 / Tencent / 讯飞). Live partial-transcript
> preview, zero cloud dependency by default.

```
Shift+Alt+S  →  hold to dictate, release to paste  (streaming + live preview)
Shift+Alt+E  →  cycle ASR backend (local Qwen3 / cloud providers)
Shift+Alt+V  →  batch PTT (WAV → Whisper-compatible HTTP gateway)
Shift+Alt+P  →  read selected text aloud (SAPI TTS, zero-latency)
```

---

## ✨ Features

- **Dual-pass ASR** — Paraformer streaming for `~300ms` partial captions while
  you're still speaking, Qwen3-ASR-1.7B final pass for `~1s` accurate paste-able text
- **Pluggable backend** — one `ASRProvider` ABC, swap between self-hosted
  (FunASR + Qwen3-ASR, sherpa-onnx CPU) and cloud (火山豆包 / Tencent / 讯飞)
  with `Shift+Alt+E`; all speak the same WS protocol. See [docs/PROVIDERS.md](docs/PROVIDERS.md)
- **Warm mic capture** with `~300ms` pre-roll ring buffer (no clipped first syllable)
- **Hotword auto-learning** — terms appearing ≥ 3× in 30 days get promoted into
  `hotwords.yaml` automatically; works with deterministic post-correct mappings
- **Local recovery log** — every dictation event in monthly JSONL with a
  `transcript-grep.sh` helper; transcribed text also stays on the clipboard for
  manual re-paste if focus drifts mid-recording
- **Self-hosted by default** — local path has zero cloud dependency; audio never
  leaves your network. Tailscale / LAN access only

---

## 🎬 Demo

> Demo GIF and screencast — TODO ([tracked in CHANGELOG](CHANGELOG.md))

---

## 🏗 Architecture

```mermaid
%%{init: {'theme':'neutral'}}%%
sequenceDiagram
    actor User
    participant Windows as Windows (AHK + PS)
    participant GPU as GPU host (FunASR + Qwen3-ASR)

    User->>Windows: Shift+Alt+S press
    Windows->>GPU: WS: 16 kHz PCM (100 ms chunks)
    GPU-->>Windows: Paraformer partials (~300 ms)
    Note over Windows: live preview overlay
    User->>Windows: release
    Windows->>GPU: end-of-audio
    GPU-->>Windows: Qwen3-ASR final (~1 s)
    Windows->>Windows: paste to release_hwnd
```

Two-process design: Windows client (capture + UI) talks to a Linux GPU host
(ASR backend) over WebSocket. Full diagram + roles + security boundary in
**[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

---

## 🚀 Install

**Requires:** Windows 10+, PowerShell 5.1+, `ffmpeg` on PATH
(`winget install --id Gyan.FFmpeg -e`). AutoHotkey v2 is installed
automatically by `install.bat`; for portable mode you install it once
yourself.

Download the [latest release ZIP](../../releases/latest) (`voice-stt.zip`),
extract anywhere, then double-click one of:

| Mode | File | What happens |
|---|---|---|
| **Installed** (autostart on login) | `install.bat` | Downloads AHK v2 if absent → copies scripts to `%LOCALAPPDATA%\voice-stt\` → seeds `.env` → registers Startup shortcut |
| **Portable** (no install) | `start.bat` | Reads `.env` from the extracted folder → launches `voice-hotkey.ahk`. Requires AHK v2 pre-installed |
| **Developer** (from git) | `git clone … && .\install.ps1` | Same as Installed, but from a working copy |

> **SmartScreen** will warn about unsigned scripts. Click **More info → Run
> anyway**. Review `install.ps1` yourself if you want — it's plain
> PowerShell.

**Portable mode prerequisite:** install AHK v2 from
[autohotkey.com](https://www.autohotkey.com) so `AutoHotkey64.exe` lands at
`%LOCALAPPDATA%\Programs\AutoHotkey\v2\`. For auto-install, use
`install.bat` instead.

---

## ⚡ Quick start

The full first-run walkthrough is at **[docs/QUICKSTART.md](docs/QUICKSTART.md)**.
Minimum required `.env` after install:

```ini
ASR_WS_URL=ws://192.168.1.50:8082/    # your FunASR server
RECORD_DEVICE_NAME=Microphone Array   # discover: record.ps1 -Diagnose
```

---

## 📝 Vocabulary management

voice-stt has three layers of vocabulary control, all driven by
`server/hotwords.yaml` on the GPU host:

| Layer | Where | What it does |
|---|---|---|
| **Hotwords** (term list) | `hotwords.yaml` category sections (`ai_agent:`, `cs_research:`, etc.) | Biases Qwen3-ASR's system context + Paraformer hotword boost. Bare term lists, deduped at server startup |
| **Mappings** (post-correct) | `hotwords.yaml` `mappings:` section | Deterministic LHS → RHS replacement on the final text (e.g., `"queen 3": "Qwen3"`) — runs after ASR, fixes common homophones the model misses |
| **Snippets** | `hotwords.yaml` `snippets:` section | Spoken-shorthand expansion (e.g., `my-email: "<your-email>"`) — `my email` in transcript becomes the full email |

**Auto-promotion:** the gateway's `/v1/text/learn` endpoint mines (wrong,
right) pairs from session history. Pairs occurring ≥ 3× in the last 30 days
are auto-appended to `hotwords.yaml` under an `auto_promoted:` section (daily
cap of 5 to prevent runaway). Audit log at `hotwords-auto-promoted.jsonl`.

WSL helpers under `wsl/`:
- `add-hotword.sh` — interactive promotion with atomic SCP + server reload
- `learn-review.sh` — review accumulated (wrong, right) pairs from the learn log
- `vocab-sync.sh` — manual atomic deploy of `hotwords.yaml`

Reload is hot — server watches mtime and supports `SIGUSR1` /
`POST /v1/vocab/reload` for explicit triggers.

---

## 🗂 History & recovery

Every dictation event (`ok` / `empty` / `no_out` / etc.) appends a JSONL
record to:

```
%LOCALAPPDATA%\voice-stt\transcripts\YYYY-MM.jsonl
```

Local-only, never uploaded. Month-rotating. Use `wsl/transcript-grep.sh` to
search:

```bash
./wsl/transcript-grep.sh --since 1h --grep "embedding"
./wsl/transcript-grep.sh --last 20 --status ok
```

Supports `--last N`, `--since 1h|30m|2d`, `--grep <pattern>`,
`--status <ok|empty|no_out|...>`, and `--raw` for full JSON.

If paste lands in the wrong window (e.g., focus drifted during a long
recording), the text is never lost — pull it from the JSONL with `--grep`
and re-paste manually.

---

## ⚙️ Configuration

All options live in `.env` (created from `.env.example` by the installer).
See **[docs/CONFIG.md](docs/CONFIG.md)** for every variable, default, and
"when to change" guidance.

---

## 🖥 ASR backends

**Self-hosted (default).** See **[server/README.md](server/README.md)** for
GPU server setup: vLLM loading Qwen3-ASR (0.6B default; 1.7B preset on ≥ 12 GB
FP8-capable cards like RTX 4070 Ti) + FunASR Paraformer + optional Whisper
batch path. A sherpa-onnx CPU path runs with zero GPU. Includes VRAM tuning
matrix per consumer GPU and CUDA path troubleshooting.

**Cloud.** See **[docs/PROVIDERS.md](docs/PROVIDERS.md)** for the provider
matrix and per-provider setup recipes (Volcano 火山豆包, Tencent, 讯飞), plus
cross-border billing caveats. Each provider is one standalone
`*-stream-server.py` implementing the `ASRProvider` ABC in `server/asr_common.py`
— adding your own is one file. Switch the active backend at runtime with
`Shift+Alt+E` (selection persists across restarts).

---

## 🤖 For AI Agents

If you're an LLM-driven coding agent picking up this repo, the fastest path
to productive edits:

- **Read first:** `README.md` (this), `docs/ARCHITECTURE.md` (two-process
  design, sequence diagrams), `CHANGELOG.md` (v0.1.0 scope + v0.2 plans).
- **Repo layout:**
  - `server/` — Python ASR backend (FastAPI WS + ASR backends + post-process).
    Entry points: `funasr-stream-server.py` (streaming), `mini-gateway.py` (batch HTTP).
  - `windows/` — AutoHotkey v2 client (`voice-hotkey.ahk`) + PowerShell helpers.
  - `wsl/` — Bash helpers for hotword management, transcript search, deploy.
  - `deploy/`, `infra/` — server bootstrap scripts.
  - `docs/` — user + dev documentation.
- **Architecture invariants:**
  - Streaming path (Shift+Alt+S) is the primary user flow — don't break partial
    preview latency or final paste mechanics.
  - Recovery JSONL must capture every dictation event for the
    `transcript-grep.sh` audit trail to remain useful.
  - Hotwords are case-sensitive for English brand terms; `hotwords.yaml`
    drives both Paraformer boost and Qwen3-ASR system context.
- **Common edits:**
  - Add a hotword: edit `server/hotwords.yaml` `user_added:` + run
    `wsl/vocab-sync.sh` (or let the server's mtime watcher reload).
  - Adjust ASR system prompt: `server/funasr-stream-server.py:106` `load_qwen3_context()`.
  - Add a paste mode hotkey: `windows/voice-hotkey.ahk` register at the top.
- **Deployment:** Windows client = `.\install.ps1`. GPU server =
  `bash start-stream-vllm.sh` from `voice-stack/` on the GPU host.

---

## 🤔 Why we built it

Most desktop dictation tools are either macOS-only (Wispr Flow, Aqua Voice),
cloud-only with monthly subscriptions, or IME-mode (讯飞) rather than
paste-anywhere. voice-stt fills a specific gap: **Windows + WSL push-to-talk
with self-hosted GPU ASR**, dual-pass for both `~300ms` partial preview and
`~1s` final accuracy, full ownership of hotwords / history / recovery logs,
and zero cloud dependency by default.

It's optimized for one user (the maintainer) who dictates daily into Claude
Code / Codex / Cursor terminal sessions, with technical terms (Tailscale,
Qwen3-ASR, embeddings, …) that generic ASR mispronounces. If that's your
scenario too, it should fit cleanly.

---

## 🗺 Roadmap

**Shipped since v0.1** (now in the codebase): pluggable `ASRProvider` ABC;
cloud providers Volcano 火山豆包 / Tencent / 讯飞; zero-GPU sherpa-onnx CPU
path; `Shift+Alt+E` backend toggle; OpenAI-compatible Bearer ASR provider
(`openai-compat` slot in the backend cycle); gateway post-process mode
`strict_correction` (homophone/term fix without rewriting tone); custom-mode
prompt variables `{text}` / `{selected}` / `{clipboard}`.

**Next, not yet implemented** (inspired by [joewongjc/type4me](https://github.com/joewongjc/type4me)'s
feature set):

- **Vocab management via an AI agent** — say "Qwen3.5 was misheard as
  Queen 3.5" and a coding agent (e.g. a Claude Code skill, not bundled in
  this repo) infers 3-8 phonetic variants and writes them into
  `hotwords.yaml` `mappings:`, then deploys via the existing
  `add-hotword.sh`. Wraps the manual YAML edit in natural language.
- **Per-mode hotkeys** — the gateway already implements polish / translate /
  prompt-optimize / custom post-process modes server-side; expose them as
  `Shift+Alt+1/2/3` instead of requiring a `.env` edit.
- **History CSV export** — recovery JSONL exists; add an export path for
  spreadsheet review.
- **Windows-side selection capture for `{selected}`** — the server-side
  substitution shipped in v0.1.1, but wiring AHK to snapshot the active
  selection via Ctrl+C and pass it through is still pending.
- **Voice commands** (`undo` / `new paragraph`) — exploring vs. in-model
  self-correction.
- **Demo GIF / screencast** — long-pending.

See [docs/ARCHITECTURE.md § What's NOT in v0.1](docs/ARCHITECTURE.md#whats-not-in-v01-and-v02-plans)
for the full discussion.

---

## 🙏 Acknowledgments

Built on top of:
- [FunASR](https://github.com/modelscope/FunASR) — Paraformer streaming ASR
- [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) — final-pass ASR (Qwen team)
- [vLLM](https://github.com/vllm-project/vllm) — GPU inference runtime
- [OpenAI Whisper](https://github.com/openai/whisper) — batch backend
- [AutoHotkey v2](https://www.autohotkey.com) — Windows hotkey + UI layer

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for licenses.

---

## 📜 License

[MIT](LICENSE). Contributions welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

---

## ⭐ Star History

<a href="https://star-history.com/#fzhiy/voice-stt&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=fzhiy/voice-stt&type=Date&theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=fzhiy/voice-stt&type=Date" />
    <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=fzhiy/voice-stt&type=Date" />
  </picture>
</a>
