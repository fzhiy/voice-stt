#!/bin/bash
# Start the Volcano Engine (火山引擎 / 豆包流式语音识别 2.0) cloud ASR proxy.
#
# Same wire protocol as funasr-stream-server.py and sherpa-onnx-stream-server.py:
# Windows AHK client connects unchanged on the configured port. Internally this
# proxy opens an upstream WSS to Volcano per PTT session, translates frames.
#
# Credentials: ~/.config/voice-stt/secrets/volcano.env (mode 600).
#   VOLCANO_APP_ID=...
#   VOLCANO_ACCESS_TOKEN=...
# Get these from https://console.volcengine.com/iam/keymanage/  +  豆包语音控制台.
# Free tier: 20 hours of audio over 6 months (ASR 2.0 hour-based).
#
# Env overrides:
#   VOLCANO_SECRETS       default: ~/.config/voice-stt/secrets/volcano.env
#   VOLCANO_RESOURCE_ID   default: volc.seedasr.sauc.duration (ASR 2.0)
#                                  fallback to volc.bigasr.sauc.duration for 1.0
#   VOLCANO_ENDPOINT      default: wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async
#   HOTWORDS_FILE         default: ./hotwords.yaml
#   LISTEN_HOST           default: 0.0.0.0
#   LISTEN_PORT           default: 8082
#   LOG_DIR               default: ./logs
#   PYTHON                default: ./.venv-volcano/bin/python if exists, else python3

set -e
cd "$(dirname "$0")"  # voice-stt/server/

VOLCANO_SECRETS="${VOLCANO_SECRETS:-$HOME/.config/voice-stt/secrets/volcano.env}"
LOG_DIR="${LOG_DIR:-./logs}"

if [ -z "$PYTHON" ]; then
    if [ -x "./.venv-volcano/bin/python" ]; then
        PYTHON="./.venv-volcano/bin/python"
    else
        PYTHON="python3"
    fi
fi

mkdir -p "$LOG_DIR"

# ----- prereq: secrets file -----
if [ ! -f "$VOLCANO_SECRETS" ]; then
    cat <<EOF >&2
ERROR: Volcano secrets not found at:
  $VOLCANO_SECRETS

First-run setup:
  mkdir -p ~/.config/voice-stt/secrets
  chmod 700 ~/.config/voice-stt/secrets
  cat > $VOLCANO_SECRETS <<KEYS
VOLCANO_APP_ID=<your app id from console.volcengine.com>
VOLCANO_ACCESS_TOKEN=<your access token from 豆包语音控制台>
KEYS
  chmod 600 $VOLCANO_SECRETS

Free tier: 20 hours audio over 6 months (ASR 2.0 hour-based).
EOF
    exit 1
fi

if [ "$(stat -c '%a' "$VOLCANO_SECRETS")" != "600" ]; then
    echo "WARN: $VOLCANO_SECRETS permissions are $(stat -c '%a' "$VOLCANO_SECRETS"), should be 600" >&2
    echo "  fix with: chmod 600 $VOLCANO_SECRETS" >&2
fi

# ----- prereq: python deps -----
if ! "$PYTHON" -c "import websockets, numpy" 2>/dev/null; then
    echo "ERROR: missing Python deps (websockets / numpy) in $PYTHON" >&2
    echo "Install with: uv pip install --python $PYTHON websockets numpy" >&2
    exit 1
fi

# ----- stop existing -----
if pkill -f volcano-stream-server.py 2>/dev/null; then
    echo "stopped existing volcano-stream-server"
    sleep 1
fi

# ----- launch -----
LISTEN_PORT="${LISTEN_PORT:-8082}"
echo "starting volcano-stream-server (port $LISTEN_PORT, python=$PYTHON) ..."
VOLCANO_SECRETS="$VOLCANO_SECRETS" \
nohup "$PYTHON" volcano-stream-server.py \
    > "$LOG_DIR/volcano-stream.log" 2>&1 &
PID=$!
echo "  pid=$PID  (log: $LOG_DIR/volcano-stream.log)"

sleep 3

if ! kill -0 "$PID" 2>/dev/null; then
    echo "ERROR: volcano-stream-server died on startup; check $LOG_DIR/volcano-stream.log" >&2
    tail -30 "$LOG_DIR/volcano-stream.log" >&2
    exit 1
fi

cat <<EOF

voice-stt Volcano (cloud-ASR) path ready.

  client connects to:   ws://localhost:$LISTEN_PORT/
  upstream:             $VOLCANO_ENDPOINT
  resource_id:          ${VOLCANO_RESOURCE_ID:-volc.seedasr.sauc.duration}
  secrets:              $VOLCANO_SECRETS
  python:               $PYTHON

Tail log:
  tail -f $LOG_DIR/volcano-stream.log

Stop:
  pkill -f volcano-stream-server.py
EOF
