#!/bin/bash
# Voice-stack is expected at ~/voice-stack by default; override with VOICE_STACK_DIR env var.
cd "${VOICE_STACK_DIR:-$HOME/voice-stack}"
# Source .env.server (if present) so config like QWEN3_ASR_PATH persists
# across restarts. `set -a` auto-exports every assignment. The script's
# explicit exports below (QWEN3_BACKEND, QWEN3_VLLM_BATCH) still win on
# conflicts because they run after this block.
set -a
[ -f .env.server ] && . ./.env.server
set +a
# 完整清理: main + vLLM EngineCore 子进程
pkill -f funasr-stream-server 2>/dev/null
pkill -f "VLLM::EngineCore" 2>/dev/null
pkill -f "vllm.*EngineCore" 2>/dev/null
sleep 3
GPU_USED=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits)
if [ "$GPU_USED" -gt 1000 ]; then
    echo "GPU still has ${GPU_USED}MiB used after cleanup, force kill..."
    pkill -9 -f funasr-stream-server 2>/dev/null
    pkill -9 -f EngineCore 2>/dev/null
    sleep 2
fi
# Override CUDA_HOME before invoking this script if your CUDA install is elsewhere
# (e.g. `export CUDA_HOME=/usr/local/cuda-12.4`). Default tested against 13.0.
CUDA_BASE="${CUDA_HOME:-/usr/local/cuda-13.0}"
export CUDA_HOME="$CUDA_BASE"
export PATH="$CUDA_BASE/bin:${VOICE_STACK_DIR:-$HOME/voice-stack}/streamenv/bin:$PATH"
export LD_LIBRARY_PATH="$CUDA_BASE/lib64:${LD_LIBRARY_PATH:-}"
export QWEN3_BACKEND=vllm
export QWEN3_VLLM_BATCH=8   # P5: 多并发 partial 用大点 batch (默认 4)
setsid nohup ./streamenv/bin/python funasr-stream-server.py >> stream-server.log 2>&1 < /dev/null &
disown $!
echo "started pid=$!"
