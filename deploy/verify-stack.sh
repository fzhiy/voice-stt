#!/usr/bin/env bash
# 远程跑 GPU 主机上的 test-pipeline.sh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

set -a
# shellcheck disable=SC1091
source .env
set +a

REMOTE_DIR="${REMOTE_DIR:-~/voice-stack}"
ssh "$GPU_HOST" "cd ${REMOTE_DIR} && bash test-pipeline.sh"
