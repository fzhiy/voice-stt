#!/usr/bin/env bash
# 检查本机/4070Ti/VPS 的 Tailscale 状态与 Gateway 连通
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

[[ -f .env ]] && { set -a; source .env; set +a; }

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo -e "${YELLOW}== 本机 Tailscale ==${NC}"
if ! command -v tailscale >/dev/null; then
    echo -e "${RED}缺 tailscale 命令${NC}"
    exit 1
fi
tailscale status || true

echo
echo -e "${YELLOW}== Gateway 连通性 ==${NC}"
HOST="${GPU_TAILSCALE:-${GPU_HOST:-localhost}}"
HOST="${HOST#*@}"  # 去掉 user@ 前缀
PORT="${GATEWAY_PORT:-8080}"
URL="http://${HOST}:${PORT}"

if curl -fs --max-time 5 "${URL}/health" >/dev/null 2>&1; then
    echo -e "${GREEN}✓ ${URL}/health 200${NC}"
elif curl -fs --max-time 5 "${URL}/" >/dev/null 2>&1; then
    echo -e "${GREEN}✓ ${URL}/ 可达${NC}"
else
    echo -e "${RED}✗ ${URL} 不通${NC}"
    echo "  检查项："
    echo "  1. tailscale ping ${HOST}"
    echo "  2. GPU 主机上 docker compose ps"
    echo "  3. GPU 主机防火墙是否放行 ${PORT}（Tailnet 内）"
    exit 2
fi

echo
echo -e "${YELLOW}== Whisper /v1/models ==${NC}"
curl -fs --max-time 5 "${URL}/v1/models" | head -50 || echo "（gateway 可能未代理 /v1/models）"
