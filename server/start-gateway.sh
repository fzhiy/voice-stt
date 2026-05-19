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

# fastapi / uvicorn 装在 streamenv venv 里, 不在系统 python3 里. 用 venv 的 python.
# 用户可通过 PYTHON= 覆盖; venv 不存在则 fallback 到系统 python3 (开发机/最小镜像).
VENV_PY="${PYTHON:-$SCRIPT_DIR/streamenv/bin/python3}"
if [[ ! -x "$VENV_PY" ]]; then
    VENV_PY="python3"
fi

case "${1:-}" in
    --stop)
        killed=0
        if [[ -f "$PID_FILE" ]]; then
            pid=$(cat "$PID_FILE")
            if kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null; then
                echo "✓ 已停止 mini-gateway (pid=$pid)"
                killed=1
            fi
            rm -f "$PID_FILE"
        fi
        # 兜底: 即便有 PID 文件也再扫一遍 — pid 可能漂移过, 或别处启动的实例没写 PID
        # 文件. 用 mini-gateway.py 当锚 (regex), 转义那个点避免误匹配同前缀的别名.
        pids=$(pgrep -f "mini-gateway\.py" 2>/dev/null || true)
        if [[ -n "$pids" ]]; then
            for p in $pids; do
                if kill "$p" 2>/dev/null; then
                    echo "✓ 兜底 kill pid=$p"
                    killed=1
                fi
            done
        fi
        if (( killed == 0 )); then
            echo "未运行"
        fi
        exit 0
        ;;
    --status)
        if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            echo "✓ mini-gateway 运行中 (pid=$(cat "$PID_FILE"))"
            curl -fs --max-time 3 "http://127.0.0.1:$GATEWAY_PORT/health" | "$VENV_PY" -m json.tool 2>/dev/null \
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
    echo "→ 后台启动: $VENV_PY mini-gateway.py (port $GATEWAY_PORT)"
    nohup "$VENV_PY" mini-gateway.py >>"$LOG_FILE" 2>&1 &
    pid=$!
    echo "$pid" > "$PID_FILE"
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        echo "✓ pid=$pid，日志 $LOG_FILE"
    else
        echo "❌ 启动失败" >&2
        tail -20 "$LOG_FILE"
        exit 1
    fi
else
    exec "$VENV_PY" mini-gateway.py
fi
