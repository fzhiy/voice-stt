#!/usr/bin/env bash
# AHK entry point for the WSL-side voice-input bridge.
# Avoids the `wsl.exe -e bash -lc` nested-quoting trap.
#
# Usage (from AHK / Windows):
#   wsl.exe -e bash <path-to>/voice-stt/wsl/voice-input-for-ahk.sh <duration> <wsl_out_path>
# Example:
#   wsl.exe -e bash ~/voice-stt/wsl/voice-input-for-ahk.sh 6 /mnt/c/Users/<USER>/AppData/Local/Temp/voice-ahk-out.txt
#
# The repo location is not hardcoded here — `wsl.exe -e bash <script>` runs
# the script wherever it lives. The AHK side picks the path via the
# VOICE_STT_WSL_HELPER env var.
set -euo pipefail

DURATION="${1:-6}"
OUT="${2:-/tmp/voice-ahk-out.txt}"
ERR="${OUT}.err"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 跑录音 + 转写。stdout 写到 OUT，stderr 写到 OUT.err 备用
bash "$SCRIPT_DIR/voice-input.sh" -d "$DURATION" > "$OUT" 2> "$ERR" || rc=$?

# 把 OUT 行尾的 \r 去掉（cross-platform 写文件可能带）
if [[ -f "$OUT" ]]; then
    tr -d '\r' < "$OUT" > "${OUT}.clean" && mv "${OUT}.clean" "$OUT"
fi

exit "${rc:-0}"
