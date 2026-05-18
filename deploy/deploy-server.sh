#!/usr/bin/env bash
# 部署 server/ 到远端 GPU 主机的 ~/voice-stack/（复用模式）
#
# 关键约束：
#   - 只新建 ~/voice-stack/ 一个目录
#   - 不动远端其他文件（特别是宿主机已装的 whisper.cpp 和 Ollama service）
#   - 复用宿主机已有的 Ollama (默认 11434) 和 whisper.cpp binary
#   - 不装系统包

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# === 加载 .env ===
if [[ ! -f .env ]]; then
    echo "❌ 没有 .env，先 cp .env.example .env 并填 GPU_HOST" >&2
    exit 1
fi
set -a
# shellcheck disable=SC1091
source .env
set +a

if [[ -z "${GPU_HOST:-}" ]]; then
    echo "❌ .env 里 GPU_HOST 没填" >&2
    exit 1
fi

REMOTE_DIR="${REMOTE_DIR:-~/voice-stack}"

echo "==> 目标: ${GPU_HOST}:${REMOTE_DIR}"
echo "==> 模式: 复用宿主机 Ollama + 新建 large-v3-turbo whisper-server"
echo

# === 1. 远端预检（只读）===
echo "[1/6] 远端预检..."
ssh -o BatchMode=yes "$GPU_HOST" bash <<'EOF'
set -e
echo "  · 主机: $(hostname) ($(whoami))"
command -v docker >/dev/null && echo "  ✓ docker $(docker --version)" || { echo "  ✗ 缺 docker"; exit 10; }
docker compose version >/dev/null 2>&1 && echo "  ✓ docker compose" || { echo "  ✗ 缺 docker compose"; exit 11; }
command -v nvidia-smi >/dev/null && echo "  ✓ GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)" || echo "  ⚠ 缺 nvidia-smi"
[ -x ~/whisper.cpp/build/bin/whisper-server ] && echo "  ✓ whisper.cpp binary 存在" || { echo "  ✗ ~/whisper.cpp/build/bin/whisper-server 不存在"; exit 12; }
curl -fs --max-time 3 http://127.0.0.1:11434/api/version >/dev/null && echo "  ✓ Ollama 11434 已就绪" || { echo "  ✗ Ollama 不通"; exit 13; }
curl -fs http://127.0.0.1:11434/api/tags | grep -q '"qwen2.5:7b"' && echo "  ✓ qwen2.5:7b 已下载" || echo "  ⚠ qwen2.5:7b 未下载（脚本最后会拉）"
EOF
ec=$?
if (( ec != 0 )); then
    echo "❌ 远端预检失败 (exit=$ec)" >&2
    exit $ec
fi

# === 2. 创建目录 ===
echo
echo "[2/6] 在 ${GPU_HOST} 上创建 ${REMOTE_DIR}..."
ssh -o BatchMode=yes "$GPU_HOST" "mkdir -p ${REMOTE_DIR}/models"

# === 3. rsync server/ ===
echo
echo "[3/6] rsync 推送 server/ → ${GPU_HOST}:${REMOTE_DIR}/ ..."
rsync -av --exclude='.env.server' --exclude='models/' \
    "$PROJECT_DIR/server/" "${GPU_HOST}:${REMOTE_DIR}/"

# === 4. 远端 .env.server 处理 ===
echo
echo "[4/6] 远端 .env.server 处理..."
ssh -o BatchMode=yes "$GPU_HOST" bash -s -- "$REMOTE_DIR" <<'EOF'
set -e
cd "$1"
if [[ ! -f .env.server ]]; then
    cp .env.server.example .env.server
    echo "  · 已用默认值创建 .env.server"
fi
EOF

# === 5. 下载模型 + 启动 whisper-large + 启动 Gateway ===
echo
read -r -p "[5/6] 现在执行：下载 large-v3-turbo 模型 + 启动 whisper:8081 + 启动 Gateway:9080？[y/N] " ans
case "$ans" in
    [yY]*)
        echo
        echo "==> 下载模型（首次约 1.5GB）..."
        ssh -t "$GPU_HOST" "cd ${REMOTE_DIR} && bash download-model.sh"

        echo
        echo "==> 启动 whisper-large (后台 :8081)..."
        ssh "$GPU_HOST" "cd ${REMOTE_DIR} && bash start-whisper-large.sh --daemon"

        echo
        echo "==> 启动 Diction Gateway 容器..."
        ssh "$GPU_HOST" "cd ${REMOTE_DIR} && docker compose --env-file .env.server up -d"

        echo
        echo "==> 等待服务就绪..."
        sleep 5

        echo
        echo "[6/6] 自检"
        ssh "$GPU_HOST" "cd ${REMOTE_DIR} && bash test-pipeline.sh" || true
        ;;
    *)
        echo
        echo "跳过启动。手动启动："
        echo "  ssh ${GPU_HOST}"
        echo "  cd ${REMOTE_DIR}"
        echo "  bash download-model.sh"
        echo "  bash start-whisper-large.sh --daemon"
        echo "  docker compose --env-file .env.server up -d"
        ;;
esac

echo
echo "✅ 完成。"
