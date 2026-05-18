# Third-Party Notices

voice-stt is distributed under the [MIT License](LICENSE) but depends on,
or interoperates with, several third-party components — software libraries,
ML model checkpoints, container images, and system tools. Each component
remains under its own license; this file is a non-exhaustive pointer to
those licenses so downstream packagers and users can comply with them.

If you redistribute voice-stt with any of these components bundled, consult
the upstream license texts (linked below) for the exact obligations.

---

## ML model checkpoints

These are **downloaded at runtime** from public registries (HuggingFace,
Ollama, ModelScope). voice-stt does **not** redistribute the weights.

| Model | License | Upstream |
|---|---|---|
| Qwen3-ASR-0.6B / Qwen3-ASR-1.7B (final-pass) | Apache-2.0 (Qwen License) | [huggingface.co/Qwen/Qwen3-ASR-0.6B](https://huggingface.co/Qwen/Qwen3-ASR-0.6B) |
| FunASR Paraformer-zh-streaming (live partial captions) | per ModelScope model card | [modelscope.cn/models/iic/speech_paraformer-large_asr_nat-zh-cn-16k-common-vocab8404-pytorch](https://modelscope.cn/models/iic/speech_paraformer-large_asr_nat-zh-cn-16k-common-vocab8404-pytorch) |
| FunASR CT-Transformer punctuation (`ct-punc-c`) | per ModelScope model card | [modelscope.cn/models/iic/punc_ct-transformer_zh-cn-common-vocab272727-pytorch](https://modelscope.cn/models/iic/punc_ct-transformer_zh-cn-common-vocab272727-pytorch) |
| OpenAI Whisper (large-v3-turbo, batch path) | MIT | [github.com/openai/whisper](https://github.com/openai/whisper) — checkpoints repackaged by ggerganov/whisper.cpp |
| Qwen2.5:7B (Ollama LLM polish, batch path) | Apache-2.0 (Qwen License) | [ollama.com/library/qwen2.5](https://ollama.com/library/qwen2.5) |

---

## Container images

Pulled by `server/docker-compose.yml` from public registries.

| Image | License | Upstream |
|---|---|---|
| `ghcr.io/omachala/diction-gateway:latest` | MIT (per upstream) | [github.com/omachala/diction-gateway](https://github.com/omachala/diction-gateway) |

---

## Python runtime dependencies (server)

Installed by the user into `streamenv` or via Docker; not vendored. License
metadata is whatever each package publishes on PyPI.

| Package | Typical license | Used for |
|---|---|---|
| `funasr` | MIT | streaming Paraformer + CT-Punc |
| `vllm` | Apache-2.0 | Qwen3-ASR inference engine (default) |
| `torch`, `torchaudio` | BSD-3-Clause | tensor runtime |
| `transformers` | Apache-2.0 | Qwen3-ASR transformers fallback engine |
| `huggingface_hub` | Apache-2.0 | model download |
| `websockets` | BSD-3-Clause | WebSocket server |
| `webrtcvad` | MIT (Python binding) / BSD (Google WebRTC) | voice activity detection |
| `numpy` | BSD-3-Clause | array ops |
| `pyyaml` | MIT | hotwords config |
| `qwen-asr` (Tongyi SDK, package name may evolve) | per Tongyi license | provides `Qwen3ASRModel` |

For a complete tree run `pip list --format=freeze` inside `streamenv` after
installation.

---

## Windows runtime tools

Installed by the user (or by `install.ps1`); not vendored in this repository.

| Tool | License | Upstream |
|---|---|---|
| AutoHotkey v2 (hotkey daemon runtime) | GPL-2.0 | [autohotkey.com](https://www.autohotkey.com) |
| ffmpeg (mic capture via DirectShow) | LGPL-2.1-or-later / GPL-2.0-or-later (build-dependent) | [ffmpeg.org](https://ffmpeg.org) |
| Microsoft Edge WebView2 Runtime (caption renderer, optional) | Microsoft Software License Terms | [developer.microsoft.com/microsoft-edge/webview2](https://developer.microsoft.com/microsoft-edge/webview2) |
| PowerShell 5.1+ | MIT (PowerShell 7) / Microsoft EULA (5.1 built-in) | Windows ships PS 5.1; PS 7 from [github.com/PowerShell/PowerShell](https://github.com/PowerShell/PowerShell) |

The previous `windows/lib/` AHK wrappers (WebView2.ahk, etc.) were dropped
for v0.1; the Edit-control fallback renderer ships as the primary caption
renderer. WebView2 caption renderer support is a v0.2 candidate (the
fallback Edit-control renderer is good enough for v0.1).

---

## Server-side / deploy-side system tools

Used by `deploy/` and `infra/wsl/` helper scripts. Not bundled.

| Tool | License | Used for |
|---|---|---|
| Docker / Docker Compose | Apache-2.0 | container runtime for `mini-gateway` |
| nvidia-container-toolkit | Apache-2.0 | GPU access inside containers |
| whisper.cpp (`whisper-server` binary) | MIT | Whisper batch ASR backend |
| Ollama | MIT | LLM polish backend (qwen2.5:7b) |
| Tailscale | BSD-3-Clause | mesh networking for cross-host access |
| Caddy (optional WSL reverse proxy) | Apache-2.0 | TLS termination for Tailscale-exposed endpoints |
| ttyd (optional WSL terminal) | MIT | web terminal over Tailscale |
| rsync, OpenSSH, autossh | BSD / public-domain mix | rsync deploy + persistent tunnels |
| systemd (Linux service supervision) | LGPL-2.1-or-later | service lifecycle on the GPU host |

---

## Karpathy LLM-coding guidelines (vendored as CLAUDE.md)

The repo-root `CLAUDE.md` is vendored from
[multica-ai/andrej-karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills)
(MIT). It is used as a behavioral guideline for LLM-assisted contributions
and is not executed at runtime.

---

## Reporting issues with this notices file

If you spot a missing component, a wrong license, or an inaccurate upstream
link, please open an issue or PR at
[github.com/fzhiy/voice-stt](https://github.com/fzhiy/voice-stt).
