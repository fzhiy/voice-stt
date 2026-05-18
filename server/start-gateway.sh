#!/usr/bin/env bash
# 启动 mini-gateway 在宿主机（不用 docker）
# 用法：
#   bash start-gateway.sh           # 前台
#   bash start-gateway.sh --daemon
#   bash start-gateway.sh --stop
#   bash start-gateway.sh --status

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 读取 .env.server（如有）
if [[ -f .env.server ]]; then
    set -a
    # shellcheck disable=SC1091
    source .env.server
    set +a
fi

export GATEWAY_PORT="${GATEWAY_PORT:-9080}"
export WHISPER_PORT="${WHISPER_PORT:-8080}"
export LLM_MODEL="${LLM_MODEL:-qwen2.5:7b}"
export WHISPER_LANG="${WHISPER_LANG:-zh}"

PID_FILE="$SCRIPT_DIR/gateway.pid"
LOG_FILE="$SCRIPT_DIR/gateway.log"

case "${1:-}" in
    --stop)
        if [[ -f "$PID_FILE" ]]; then
            pid=$(cat "$PID_FILE")
            if kill "$pid" 2>/dev/null; then
                echo "✓ 已停止 mini-gateway (pid=$pid)"
            fi
            rm -f "$PID_FILE"
        else
            # 兜底：grep python 进程
            pkill -f "python3 .*mini-gateway.py" 2>/dev/null && echo "✓ kill python mini-gateway" || echo "未运行"
        fi
        exit 0
        ;;
    --status)
        if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            echo "✓ mini-gateway 运行中 (pid=$(cat "$PID_FILE"))"
            curl -fs --max-time 3 "http://127.0.0.1:$GATEWAY_PORT/health" | python3 -m json.tool 2>/dev/null \
                || echo "  HTTP 不可达"
        else
            echo "✗ 未运行"
        fi
        exit 0
        ;;
esac

if ss -ltn 2>/dev/null | grep -q ":$GATEWAY_PORT "; then
    echo "⚠ :$GATEWAY_PORT 已被占用" >&2
    exit 1
fi

if [[ "${1:-}" == "--daemon" ]]; then
    echo "→ 后台启动: python3 mini-gateway.py (port $GATEWAY_PORT)"
    nohup python3 mini-gateway.py >"$LOG_FILE" 2>&1 &
    pid=$!
    echo "$pid" > "$PID_FILE"
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        echo "✓ pid=$pid，日志 $LOG_FILE"
    else
        echo "❌ 启动失败" >&2
        cat "$LOG_FILE"
        exit 1
    fi
else
    exec python3 mini-gateway.py
fi
