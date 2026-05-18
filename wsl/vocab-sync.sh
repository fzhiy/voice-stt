#!/usr/bin/env bash
# vocab-sync.sh — atomically SCP server/hotwords.yaml to remote voice-stack
# then trigger funasr-stream-server to reload via mini-gateway's
# POST /v1/vocab/reload (which sends SIGUSR1 to the streaming server).
#
# Usage: vocab-sync.sh         (no args)
#
# Exit codes:
#   0 = yaml deployed AND server signaled reload
#   1 = yaml deployment failed (server NOT touched)
#   2 = yaml deployed but reload curl failed (manual restart may be needed
#       — or just wait <=30s for the mtime watcher to pick it up)
#
# Atomicity: scp writes .tmp first, then ssh mv -> avoids server reading a
# half-written yaml while SCP is mid-transfer. reload failure does NOT block
# the yaml deploy: the mtime watcher will eventually catch it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
YAML="${REPO_ROOT}/server/hotwords.yaml"
if [[ -z "${REMOTE_HOST:-}" ]]; then
    if [[ -n "${GPU_USER:-}" && -n "${GPU_HOST:-}" ]]; then
        REMOTE_HOST="${GPU_USER}@${GPU_HOST}"
    else
        echo "ERROR: set REMOTE_HOST or both GPU_USER and GPU_HOST in .env / shell env" >&2
        exit 1
    fi
fi
REMOTE_DIR="${REMOTE_DIR:-voice-stack}"  # relative to remote $HOME
RELOAD_URL="${RELOAD_URL:-http://localhost:9080/v1/vocab/reload}"

if [[ ! -f "$YAML" ]]; then
    echo "ERROR: $YAML not found" >&2
    exit 1
fi

# Local yaml-safe validation (cheap pre-flight)
if ! python3 -c "import yaml,sys; yaml.safe_load(open('$YAML'))" 2>/dev/null; then
    echo "ERROR: local yaml validation failed; refusing to deploy" >&2
    exit 1
fi

# Atomic deploy: .tmp + mv on remote
if ! scp -q "$YAML" "${REMOTE_HOST}:${REMOTE_DIR}/hotwords.yaml.tmp"; then
    echo "ERROR: scp failed" >&2
    exit 1
fi
if ! ssh "$REMOTE_HOST" "mv ${REMOTE_DIR}/hotwords.yaml.tmp ${REMOTE_DIR}/hotwords.yaml"; then
    echo "ERROR: remote mv failed (server still on old yaml)" >&2
    ssh "$REMOTE_HOST" "rm -f ${REMOTE_DIR}/hotwords.yaml.tmp" 2>/dev/null || true
    exit 1
fi
echo "deployed: ${REMOTE_HOST}:${REMOTE_DIR}/hotwords.yaml"

# Trigger reload via mini-gateway -> SIGUSR1 to funasr-stream-server
if curl -fsS -X POST "$RELOAD_URL" -o /dev/null; then
    echo "reload signaled via $RELOAD_URL"
    exit 0
fi
echo "WARN: reload curl to $RELOAD_URL failed; yaml deployed but server未重载" >&2
echo "      mtime watcher will pick up within 30s; or pkill -USR1 -f funasr-stream-server.py on remote" >&2
exit 2
