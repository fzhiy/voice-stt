#!/usr/bin/env bash
# 在 A1 上跑：启动第二个 whisper-server（用 large-v3-turbo）监听 :8081
# 不动用户原有 ~/whisper.cpp/build/bin/whisper-server (small @ 8080)
#
# 用法：
#   bash start-whisper-large.sh         # 前台运行（调试用）
#   bash start-whisper-large.sh --daemon # 后台运行 + 写日志
#   bash start-whisper-large.sh --stop   # 停止后台进程

set -euo pipefail

PORT="${WHISPER_PORT:-8081}"
MODEL_NAME="${MODEL:-large-v3-turbo}"
MODEL_FILE="$HOME/voice-stack/models/ggml-${MODEL_NAME}.bin"
WHISPER_BIN="$HOME/whisper.cpp/build/bin/whisper-server"
PID_FILE="$HOME/voice-stack/whisper-large.pid"
LOG_FILE="$HOME/voice-stack/whisper-large.log"
THREADS="${THREADS:-6}"
WHISPER_LANG="${WHISPER_LANG:-zh}"

# 复用用户已有的 whisper.cpp 二进制（不重新编译）
if [[ ! -x "$WHISPER_BIN" ]]; then
    echo "❌ 找不到 whisper-server 二进制: $WHISPER_BIN" >&2
    echo "   （应该在用户的 ~/whisper.cpp/build/bin/ 下）" >&2
    exit 1
fi

if [[ ! -f "$MODEL_FILE" ]]; then
    echo "❌ 模型文件不存在: $MODEL_FILE" >&2
    echo "   先跑：bash download-model.sh" >&2
    exit 1
fi

case "${1:-}" in
    --stop)
        if [[ -f "$PID_FILE" ]]; then
            pid=$(cat "$PID_FILE")
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid"
                echo "✓ 已停止 whisper-large (pid=$pid)"
            else
                echo "进程已死"
            fi
            rm -f "$PID_FILE"
        else
            echo "未运行（无 PID 文件）"
        fi
        exit 0
        ;;
    --status)
        if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            echo "✓ whisper-large 运行中 (pid=$(cat "$PID_FILE"))"
            curl -sS --max-time 3 "http://127.0.0.1:$PORT/" >/dev/null && echo "  HTTP :$PORT OK" || echo "  HTTP :$PORT 不通"
        else
            echo "✗ 未运行"
        fi
        exit 0
        ;;
esac

# 检查端口
if ss -ltn 2>/dev/null | grep -q ":${PORT} "; then
    echo "⚠ 端口 :$PORT 已被占用" >&2
    ss -ltnp 2>/dev/null | grep ":${PORT} " || true
    exit 1
fi

CMD=(
    "$WHISPER_BIN"
    -m "$MODEL_FILE"
    --host 127.0.0.1
    --port "$PORT"
    --convert
    -t "$THREADS"
    -l "$WHISPER_LANG"
    --inference-path /audio/transcriptions
)

mkdir -p "$HOME/voice-stack"

if [[ "${1:-}" == "--daemon" ]]; then
    echo "→ 后台启动: ${CMD[*]}"
    nohup "${CMD[@]}" >"$LOG_FILE" 2>&1 &
    pid=$!
    echo "$pid" > "$PID_FILE"
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        echo "✓ pid=$pid，日志 $LOG_FILE"
    else
        echo "❌ 启动失败，看日志：tail -30 $LOG_FILE" >&2
        exit 1
    fi
else
    echo "→ 前台启动（Ctrl+C 退出）: ${CMD[*]}"
    exec "${CMD[@]}"
fi
