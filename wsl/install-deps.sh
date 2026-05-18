#!/usr/bin/env bash
# 装 WSL 端依赖（最小集）
# 已检测：claude/codex/happy/tailscale/curl/rsync 都在
# 缺：jq（解析 Whisper JSON 返回时偶尔需要，目前 PowerShell 端已处理 JSON，可选）

set -euo pipefail

NEED=()
for t in jq; do
    command -v "$t" >/dev/null 2>&1 || NEED+=("$t")
done

if (( ${#NEED[@]} == 0 )); then
    echo "✓ 所有依赖已就绪"
    exit 0
fi

echo "需要安装: ${NEED[*]}"
if command -v apt-get >/dev/null; then
    sudo apt-get update
    sudo apt-get install -y "${NEED[@]}"
elif command -v dnf >/dev/null; then
    sudo dnf install -y "${NEED[@]}"
else
    echo "不识别的包管理器，请手动安装: ${NEED[*]}"
    exit 1
fi

echo "✓ 完成"
