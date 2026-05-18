#!/usr/bin/env bash
# 在远端 GPU 主机上跑：下载 ggml-large-v3-turbo 到 ~/voice-stack/models/
# 不动宿主机已有的 ~/whisper.cpp/models/
#
# 用法：bash download-model.sh
#       MODEL=large-v3 bash download-model.sh    # 切换其他模型

set -euo pipefail

MODEL="${MODEL:-large-v3-turbo}"
MODELS_DIR="$HOME/voice-stack/models"
FILE="ggml-${MODEL}.bin"
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${FILE}"

# 候选下载源（首选官方，失败回退镜像）
URLS=(
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${FILE}"
    "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/${FILE}"
)

mkdir -p "$MODELS_DIR"

if [[ -f "$MODELS_DIR/$FILE" ]]; then
    size=$(stat -c%s "$MODELS_DIR/$FILE")
    echo "✓ 模型已存在: $MODELS_DIR/$FILE ($(numfmt --to=iec $size))"
    exit 0
fi

echo "→ 下载 $FILE 到 $MODELS_DIR ..."
echo "  （large-v3-turbo 约 1.5 GB）"

for url in "${URLS[@]}"; do
    echo "尝试: $url"
    if curl -fL --progress-bar -o "$MODELS_DIR/$FILE.tmp" "$url"; then
        mv "$MODELS_DIR/$FILE.tmp" "$MODELS_DIR/$FILE"
        echo "✓ 完成: $MODELS_DIR/$FILE ($(stat -c%s "$MODELS_DIR/$FILE" | numfmt --to=iec))"
        exit 0
    else
        echo "  失败，尝试下一个源..."
        rm -f "$MODELS_DIR/$FILE.tmp"
    fi
done

echo "❌ 所有下载源都失败" >&2
exit 1
