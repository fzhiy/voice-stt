# ASR Anywhere GPU server setup

This guide sets up the GPU server side of ASR Anywhere (formerly `voice-stt`):
a Linux machine with an NVIDIA GPU that runs the speech recognition models
that any client (Windows AHK, iOS HappyCoder, future Mac/Android) connects to
over WebSocket.

> **v0.1 status**: this guide captures a known-good combination — **Ubuntu
> 22.04, Python 3.10, CUDA 13.0, NVIDIA driver ≥ 545, torch 2.4+**. Other
> CUDA versions (12.x) probably work — override `CUDA_HOME` before running
> `start-stream-vllm.sh` (the script honors the env var). A pinned
> `requirements.txt` / `pyproject.toml` is on the v0.2 roadmap; for now you
> install Python packages by hand following the inline commands below.
> File issues if specific package versions break.

---

## Prerequisites

- **Linux** — Ubuntu 22.04+ tested; other distros likely fine.
- **NVIDIA GPU**, ≥8 GB VRAM. CUDA toolkit installed; `nvidia-smi` working.
- **Python 3.10+**, with `venv` available.
- **ffmpeg** (only needed for the optional batch path, not for streaming).
- **Network reachability** from your Windows client to this machine — LAN IP
  or Tailscale hostname both work.

---

## Two transcription paths

voice-stt ships two paths. Pick whichever fits your hardware and workflow.

### 1. Streaming path (primary, low latency)

What runs: `funasr-stream-server.py` exposes a WebSocket on port `8082`
(loopback only by default; see `STREAM_HOST` below). Combines FunASR
Paraformer-zh-streaming for live partial captions during dictation with
**Qwen3-ASR** for the final high-quality transcript. Default is the 0.6B
checkpoint for 12 GB-card friendliness; switch to 1.7B for higher quality
on ≥16 GB cards via `QWEN3_ASR_PATH`.

**VRAM**: ~5 GB total with 0.6B (Paraformer ~0.5 GB + Qwen3-ASR-0.6B ~1.5 GB
+ vLLM runtime overhead ~3 GB) or ~7-8 GB with 1.7B.

**Quick install**:

```bash
# 1. Pick a working directory (default is ~/voice-stack; override with
#    VOICE_STACK_DIR env var if you want it elsewhere).
mkdir -p ~/voice-stack && cd ~/voice-stack

# 2. Create the streaming-side venv.
python -m venv streamenv

# 3. Install runtime packages. (PyTorch's cu121 wheels are forward-compatible
#    with CUDA 12.1+ toolkits including 13.0 — adjust `cu121` to a newer tag
#    only if you have a specific reason; cu121 is the most widely tested.)
./streamenv/bin/pip install \
    --extra-index-url https://download.pytorch.org/whl/cu121 \
    funasr vllm torch torchaudio transformers \
    websockets numpy huggingface_hub

# 4. Place the server code. The streaming server imports sibling modules
#    (`text_postprocess`, `backends/`), so copy the WHOLE server/ directory
#    contents (not just individual files):
cp -r /path/to/voice-stt/server/* .
# or, if you prefer a live symlink to the cloned repo:
ln -s /path/to/voice-stt/server/funasr-stream-server.py .
ln -s /path/to/voice-stt/server/start-stream-vllm.sh    .
ln -s /path/to/voice-stt/server/hotwords.yaml           .
ln -s /path/to/voice-stt/server/text_postprocess.py     .
ln -s /path/to/voice-stt/server/backends                .

# 4b. Install the Qwen3-ASR SDK (not on PyPI as `qwen-asr`; provided by
#     Tongyi/Alibaba per the model card on HuggingFace). Check the latest
#     install command at https://huggingface.co/Qwen/Qwen3-ASR-0.6B
#     (typically: `pip install qwen3-asr-toolkit` or similar — the exact
#     package name may evolve, defer to the model card).

# 5. If your CUDA install is NOT at /usr/local/cuda-13.0, export CUDA_HOME
#    to point at it before running start-stream-vllm.sh (the script honors
#    the env var). Example: export CUDA_HOME=/usr/local/cuda-12.4

# 6. Start the streaming server. First launch downloads Qwen3-ASR-0.6B from
#    HuggingFace into ~/.cache/qwen3-asr-0.6b (~1.2 GB), so allow time.
bash start-stream-vllm.sh

# 7. Watch the log; "Qwen3-ASR ready in X.Xs" means it's serving.
tail -f stream-server.log
```

**Exposing to the client**: the Windows client connects to
`ASR_WS_URL=ws://<server>:8082/`. Use the GPU machine's LAN IP, or its
Tailscale hostname (`<hostname>.<tailnet>.ts.net`) for cross-network access.

### 2. Batch path (optional, OpenAI-compatible HTTP)

What runs: Docker Compose stack with **Whisper Large-v3-turbo** + **Ollama
Qwen2.5 7B** (optional polish). Exposes a Whisper-compatible HTTP API on
port `9080`.

Used by Shift+Alt+V on the Windows client. Also the future bridge for cloud
ASR providers (`OPENAI_BASE_URL`, planned for v0.2).

**VRAM**: ~3 GB Whisper + ~5 GB Ollama Qwen2.5 7B = ~8 GB. Can coexist with
the streaming path on a ≥16 GB card; on a 12 GB card you'll need to pick one
or downgrade the LLM (`LLM_MODEL=qwen2.5:3b`).

**Quick install**:

```bash
cd /path/to/voice-stt/server
cp .env.server.example .env.server     # edit if you need non-default ports
docker compose up -d
docker compose logs -f                  # wait for "Model loaded" lines

# Verify health
curl http://localhost:9080/health
```

---

## Configuration

Server-side runtime is configured via environment variables. The Windows
client's `.env` (see [`docs/CONFIG.md`](../docs/CONFIG.md)) only carries
client knobs — set the server-side ones here on the GPU host (e.g. via the
shell that launches `start-stream-vllm.sh`, or a `.env.server` if you keep
one). The most common ones:

| Variable | Default | Purpose |
|---|---|---|
| `STREAM_HOST` | `127.0.0.1` | WebSocket bind host (the server's `funasr-stream-server.py` defaults to localhost). **Set `STREAM_HOST=0.0.0.0` before launching to accept LAN / Tailscale connections.** Loopback-only by default protects the model endpoint until the user opts in. |
| `STREAM_PORT` | `8082` | WebSocket listen port for the streaming server. |
| `QWEN3_ASR_PATH` | `~/.cache/qwen3-asr-0.6b` | Local model dir. First launch downloads here from HuggingFace. Default is 0.6B for 12 GB-card friendliness; bump to 1.7B for higher quality on ≥16 GB cards. |
| `QWEN3_BACKEND` | `vllm` | `vllm` (fast, more VRAM) or `transformers` (slower, less VRAM, no KV pool). |
| `QWEN3_VLLM_GPU_FRAC` | `0.5` | Fraction of GPU VRAM vLLM reserves for the final-pass model + KV cache. Default 0.5 on 12 GB leaves ~5 GB free for other GPU services. See "Tuning presets" below. |
| `QWEN3_VLLM_MAX_MODEL_LEN` | `4096` | Max tokens per Qwen3 inference call. 4096 ≈ 80 s of audio (Qwen3 audio encoder ~50 tok/s). funasr-stream-server's VAD chunks long monologues at silence boundaries, so a single call rarely needs >4096. Raise to 8192 for "native long-form" (~160 s) at the cost of more VRAM. |
| `USE_QWEN3_ASR` | `1` | Set `0` to disable Qwen3 speculative partial / final and fall back to Paraformer only. |
| `HF_ENDPOINT` | _(huggingface.co)_ | Set to `https://hf-mirror.com` for mainland-China users. |
| `LLM_MODEL` | `qwen2.5:7b` | Ollama model name for the optional batch-path polish. |
| `ENABLE_LLM` | `0` | Set `1` to enable LLM post-edit on transcripts (extra ~1-2 s latency). |
| `VOICE_STACK_DIR` | `$HOME/voice-stack` | Working directory for venv + logs. |
| `WHISPER_INITIAL_PROMPT` | _(built-in domain vocab — see `mini-gateway.py`)_ | Optional prompt that biases Whisper output (e.g. domain vocabulary). Default is a built-in Chinese-tech vocab string in `mini-gateway.py`. Override via env var; read by `mini-gateway.py` and forwarded to the underlying whisper-server as the multipart `prompt` field. Set on the gateway host only — the Windows client does not forward this. |

Less common knobs (`QWEN3_PARTIAL_*`, `QWEN3_VLLM_*`, `VAD_*`,
`USE_LAST_PARTIAL_AS_FINAL`, `STREAM_MODEL`, `STREAM_PUNC_MODEL`,
`HISTORY_*`, `HOTWORDS_FILE`, `LEARN_*`) read by `funasr-stream-server.py`
are documented inline in the script's top-of-file comments.

### Final-pass ASR backend selection (`FINAL_BACKEND`)

| Value | Behavior |
|---|---|
| `qwen3_asr` | Qwen3-ASR (default, GPU recommended) |
| `none` | Disable final pass; fall back to paraformer+ctpunc+polish |
| _(unset)_ | Honor legacy `USE_QWEN3_ASR` (default 1 = qwen3_asr) |

Example (`.env.server`):
```
FINAL_BACKEND=qwen3_asr
```

### Qwen3-ASR model variants

Default is **0.6B** (model weights ~1.2 GB bf16) for 12 GB-card friendliness.
The 1.7B variant (~3.4 GB bf16) has higher accuracy and is recommended on
≥16 GB cards.

Download whichever you want:

```bash
# 0.6B (default — works on 12 GB cards with default tuning)
huggingface-cli download Qwen/Qwen3-ASR-0.6B --local-dir ~/.cache/qwen3-asr-0.6b

# 1.7B (higher quality — needs ~7-9 GB VRAM total with vLLM)
huggingface-cli download Qwen/Qwen3-ASR-1.7B --local-dir ~/.cache/qwen3-asr-1.7b
```

If you put 1.7B, point at it via `.env.server` (and bump GPU_FRAC so it fits):
```
QWEN3_ASR_PATH=$HOME/.cache/qwen3-asr-1.7b
QWEN3_VLLM_GPU_FRAC=0.75
```

### Tuning presets (`QWEN3_VLLM_GPU_FRAC` × `QWEN3_VLLM_MAX_MODEL_LEN`)

`QWEN3_VLLM_GPU_FRAC` is the fraction of total GPU VRAM that vLLM reserves
for the final-pass model. Setting it too low → vLLM bails with
"No available memory for the cache blocks" and the server falls back to a
slower (20-50×) transformers backend or to `paraformer+ctpunc+polish` chain.
Setting it too high → wastes VRAM that could host other GPU services.

Empirically calibrated on RTX 4070 Ti (12 GB) with 0.6B model, 4096 max
context, 3-concurrent peak workload (2026-05-17):

| Preset | Model | GPU_FRAC | MAX_MODEL_LEN | vLLM | ASR total | Frees | Notes |
|---|---|---|---|---|---|---|---|
| **Headroom** (default) | 0.6B | 0.5 | 4096 | ~5 GB | ~6.5 GB | ~5 GB | Recommended for 12 GB cards shared with other GPU services |
| Native long-form | 0.6B | 0.5 | 8192 | ~6 GB | ~7.5 GB | ~4 GB | Single Qwen3 call covers ~160 s (raise GPU_FRAC if 3+ concurrent) |
| Quality | 1.7B | 0.75 | 4096 | ~7.7 GB | ~9 GB | ~3 GB | Higher accuracy; needs 16+ GB cards or dedicated 12 GB box |
| Low-resource | 0.6B | — | 4096 | ~1.2 GB | ~3 GB | ~9 GB | Set `QWEN3_BACKEND=transformers` to disable vLLM KV pool; serial inference is 2-3× slower per call |
| ASR-off | — | — | — | 0 | ~1.6 GB | ~10 GB | Set `FINAL_BACKEND=none` to skip Qwen3 entirely; uses paraformer+ctpunc+polish chain; lower quality but 0 vLLM overhead |

**Empirical floor on 12 GB:** GPU_FRAC=0.5 is the minimum that allows vLLM to
allocate cache blocks for 0.6B + 4096. Below 0.5 (0.45, 0.4, 0.35 all tested
and failed), vLLM init fails. The overhead per vLLM process is ~3 GB even for
a 0.6B model (CUDA paging + scratch buffers + compile cache), much larger than
the model itself.

---

## Common issues

**`nvidia-smi` works but Qwen3-ASR fails to load** — `start-stream-vllm.sh`
uses `${CUDA_HOME:-/usr/local/cuda-13.0}` for its CUDA exports. Set
`CUDA_HOME` explicitly in the shell that launches the script if your CUDA
install is elsewhere (e.g. `export CUDA_HOME=/usr/local/cuda-12.4`).

**HuggingFace download stalls or returns 0 bytes** — set
`HF_ENDPOINT=https://hf-mirror.com` in your shell before starting the
server.

**Port 8082 not reachable from the client** — confirm the server is
listening on all interfaces:

```bash
ss -tlnp | grep 8082
# expect: LISTEN 0 N 0.0.0.0:8082 ...   (not just 127.0.0.1)
```

By default the server binds `127.0.0.1` (loopback only — protects the model
endpoint until you opt in). For LAN / Tailscale access, launch with
`STREAM_HOST=0.0.0.0 bash start-stream-vllm.sh` (or export the var in your
shell / `.env.server` before running). If you've set it and `ss -tlnp` still
shows loopback, double-check the var actually reached the server process
(check the process listing's environment, or restart the server cleanly).

**Both streaming and batch paths trying to share the GPU** — VRAM total
exceeds your card. Run only one, or use `qwen2.5:3b` for the batch LLM.

---

## v0.2 roadmap for this guide

- `requirements.txt` / `pyproject.toml` for reproducible install.
- Tested install procedures for Ubuntu 22.04, Debian 12, Fedora.
- Tailscale exposure guide (replacing what was in the deprecated
  `docs/SETUP-WSL.md`).
- Cloud ASR backend (OpenAI Whisper API, Groq, Deepgram) so users without a
  local GPU can run voice-stt too.
