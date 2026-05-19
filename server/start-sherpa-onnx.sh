#!/bin/bash
# Start the sherpa-onnx ASR backend for voice-stt's "zero-GPU" mode.
#
# Single Python process: sherpa-onnx-stream-server.py uses
# sherpa_onnx.OnlineRecognizer directly (no separate C++ websocket-server
# binary needed — the pip wheel doesn't ship one anyway).
#
# Same wire protocol as funasr-stream-server.py, so the Windows client
# connects unchanged on port 8082.
#
# Model: streaming Paraformer-bilingual-zh-en int8 ONNX. RTF ~0.05-0.15 on
# modern mobile CPUs. SenseVoice is offline-only (can't deliver sub-300ms
# streaming partials), so this path uses streaming Paraformer.
#
# Env overrides:
#   SHERPA_MODEL_DIR    default: $HOME/.cache/sherpa-onnx-streaming-paraformer-bilingual-zh-en
#   SHERPA_USE_INT8     default: 1   (0 = use fp32 weights for slight accuracy gain)
#   SHERPA_NUM_THREADS  default: 4
#   LISTEN_HOST         default: 0.0.0.0
#   LISTEN_PORT         default: 8082  (same port as funasr-stream-server.py)
#   LOG_DIR             default: ./logs
#   PYTHON              default: ./.venv-sherpa/bin/python if exists, else python3

set -e
cd "$(dirname "$0")"  # voice-stt/server/

SHERPA_MODEL_DIR="${SHERPA_MODEL_DIR:-$HOME/.cache/sherpa-onnx-streaming-paraformer-bilingual-zh-en}"
LOG_DIR="${LOG_DIR:-./logs}"

if [ -z "$PYTHON" ]; then
    if [ -x "./.venv-sherpa/bin/python" ]; then
        PYTHON="./.venv-sherpa/bin/python"
    else
        PYTHON="python3"
    fi
fi

mkdir -p "$LOG_DIR"

# ----- prereq check -----
if [ ! -d "$SHERPA_MODEL_DIR" ]; then
    cat <<EOF >&2
ERROR: sherpa model dir not found:
  $SHERPA_MODEL_DIR

First-run setup:
  # 1. python deps (use a venv to avoid touching system Python on Ubuntu 24+)
  uv venv server/.venv-sherpa
  uv pip install --python server/.venv-sherpa/bin/python sherpa-onnx websockets numpy

  # 2. model (~1 GB tar -> ~830 MB fp32 + ~230 MB int8 ONNX inside)
  cd ~/.cache/
  wget https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-paraformer-bilingual-zh-en.tar.bz2
  tar xjf sherpa-onnx-streaming-paraformer-bilingual-zh-en.tar.bz2

Or set SHERPA_MODEL_DIR to a different model dir.
EOF
    exit 1
fi

if ! "$PYTHON" -c "import sherpa_onnx, websockets, numpy" 2>/dev/null; then
    echo "ERROR: missing Python deps (sherpa_onnx / websockets / numpy) in $PYTHON" >&2
    echo "Install with: uv pip install --python $PYTHON sherpa-onnx websockets numpy" >&2
    exit 1
fi

# ----- stop existing -----
if pkill -f sherpa-onnx-stream-server.py 2>/dev/null; then
    echo "stopped existing sherpa-onnx stream server"
    sleep 1
fi

# ----- launch -----
LISTEN_PORT="${LISTEN_PORT:-8082}"
echo "starting sherpa-onnx stream server (port $LISTEN_PORT, python=$PYTHON) ..."
SHERPA_MODEL_DIR="$SHERPA_MODEL_DIR" \
nohup "$PYTHON" sherpa-onnx-stream-server.py \
    > "$LOG_DIR/sherpa-onnx-stream.log" 2>&1 &
PID=$!
echo "  pid=$PID  (log: $LOG_DIR/sherpa-onnx-stream.log)"

sleep 4

if ! kill -0 "$PID" 2>/dev/null; then
    echo "ERROR: stream server died on startup; check $LOG_DIR/sherpa-onnx-stream.log" >&2
    tail -30 "$LOG_DIR/sherpa-onnx-stream.log" >&2
    exit 1
fi

cat <<EOF

voice-stt sherpa-onnx (zero-GPU) path ready.

  client connects to:   ws://localhost:$LISTEN_PORT/
  model:                $SHERPA_MODEL_DIR
  python:               $PYTHON

Tail log:
  tail -f $LOG_DIR/sherpa-onnx-stream.log

Stop:
  pkill -f sherpa-onnx-stream-server.py
EOF
