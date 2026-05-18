#!/usr/bin/env bash
# 录音 + 转写，文本输出到 stdout
# 用法：
#   ./voice-input.sh              # 默认 10 秒
#   ./voice-input.sh -d 15        # 录 15 秒
#   ./voice-input.sh -i           # 交互式（回车开始/停止）
#   ./voice-input.sh --check      # 仅检查 gateway 连通性

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env

if [[ "${1:-}" == "--check" ]]; then
    if check_gateway; then
        green "Gateway $(gateway_url) 可达"
        exit 0
    else
        red "Gateway $(gateway_url) 不可达"
        exit 1
    fi
fi

# Tunnel auto-establish (v0.1 default OFF — tunnel.sh ships only if user adds it).
# v0.1 OSS release expects Tailscale or direct LAN reach to the gateway. If you've
# added a tunnel.sh helper in $SCRIPT_DIR and want auto-tunnel, set USE_TUNNEL=1.
ensure_tunnel() {
    [[ "${USE_TUNNEL:-0}" == "1" ]] || return 0
    if check_gateway 2>/dev/null; then
        return 0
    fi
    if [[ ! -f "$SCRIPT_DIR/tunnel.sh" ]]; then
        red "USE_TUNNEL=1 but $SCRIPT_DIR/tunnel.sh not found — set GPU_TAILSCALE / GPU_HOST + a directly-reachable gateway, or supply your own tunnel.sh"
        return 1
    fi
    yellow "[tunnel] Gateway 不可达，自动建立 SSH 隧道..."
    bash "$SCRIPT_DIR/tunnel.sh" >&2 || {
        red "tunnel 建立失败"
        return 1
    }
    sleep 0.5
}
ensure_tunnel || exit 3

text=$(voice_transcribe "$@")
if [[ -z "$text" ]]; then
    red "未获得转写文本"
    exit 2
fi
echo "$text"
