#!/usr/bin/env bash
# add-hotword.sh — append term(s) to server/hotwords.yaml user_added category,
# deploy to remote server, restart funasr-stream-server.
#
# Usage: add-hotword.sh [--dry-run] TERM [TERM ...]
#   --dry-run    print actions without modifying / deploying anything
#
# Idempotent: existing term grep matches (case-sensitive, exact line) are skipped.
# Transactional: scp/ssh failure rolls back the local yaml append.
# Concurrency: flock prevents two skills writing yaml at once.
#
# Exit codes:
#   0 = success (>=1 term added or all already present)
#   1 = invalid args / no terms
#   2 = yaml validation failed after append (logic bug)
#   3 = scp / ssh remote step failed (yaml rolled back)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
YAML="${REPO_ROOT}/server/hotwords.yaml"
LOCK="${REPO_ROOT}/.add-hotword.lock"
if [[ -z "${REMOTE_HOST:-}" ]]; then
    if [[ -n "${GPU_USER:-}" && -n "${GPU_HOST:-}" ]]; then
        REMOTE_HOST="${GPU_USER}@${GPU_HOST}"
    else
        echo "ERROR: set REMOTE_HOST or both GPU_USER and GPU_HOST in .env / shell env" >&2
        exit 1
    fi
fi
REMOTE_DIR="${REMOTE_DIR:-voice-stack}"  # relative to remote $HOME
USER_ADDED_TAG="user_added:"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
    shift
fi

if [[ $# -eq 0 ]]; then
    echo "ERROR: no terms given. Usage: $0 [--dry-run] TERM [TERM ...]" >&2
    exit 1
fi

# Validate every term: non-empty, >=2 chars (matches LEARN_REJECT rules)
for term in "$@"; do
    if [[ -z "$term" ]] || [[ ${#term} -lt 2 ]]; then
        echo "ERROR: term '$term' empty or <2 chars" >&2
        exit 1
    fi
done

# Take exclusive lock so two parallel skill invocations don't tangle yaml writes
exec 200>"$LOCK"
flock -x -w 30 200 || { echo "ERROR: could not acquire lock within 30s"; exit 1; }

# Ensure user_added: category exists in yaml (append if missing)
if ! grep -qE "^${USER_ADDED_TAG}$" "$YAML"; then
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] would append '${USER_ADDED_TAG}' category to $YAML"
    else
        # End of file: add blank line + category header + comment
        printf '\n%s\n  # 用户通过 /add-hotword 添加，比 LLM 候选学习路径更高精度\n' "$USER_ADDED_TAG" >> "$YAML"
    fi
fi

# Backup yaml for transactional rollback on remote failure
BACKUP="${YAML}.bak.$$"
if [[ $DRY_RUN -eq 0 ]]; then
    cp "$YAML" "$BACKUP"
fi
rollback_and_exit() {
    local code=$1
    if [[ $DRY_RUN -eq 0 ]] && [[ -f "$BACKUP" ]]; then
        mv "$BACKUP" "$YAML"
        echo "  rolled back local $YAML"
    fi
    exit "$code"
}

# Per-term: skip if already present, else append under user_added:
ADDED=()
SKIPPED=()
for term in "$@"; do
    # Search the user_added section for exact "- $term" match.
    # Quote term in yaml output (handles colons, quotes, hash). Use double quotes
    # with embedded double-quote -> escape \" YAML style.
    yaml_term=$(printf '%s' "$term" | sed 's/"/\\"/g')
    line_pattern="^  - \"${yaml_term}\"$"
    # Also check unquoted legacy form (other categories may have - foo without quotes)
    legacy_pattern="^  - ${yaml_term}$"
    if grep -qE "$line_pattern" "$YAML" || grep -qF "  - $term" "$YAML"; then
        SKIPPED+=("$term")
        continue
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] would append: - \"$term\" under user_added:"
        ADDED+=("$term")
        continue
    fi
    # Insert after the user_added: line. Use awk to do it safely.
    awk -v marker="${USER_ADDED_TAG}" -v new_line="  - \"${yaml_term}\"" '
        $0 == marker { print; print new_line; inserted=1; next }
        { print }
        END { if (!inserted) { print marker; print new_line } }
    ' "$YAML" > "${YAML}.tmp" && mv "${YAML}.tmp" "$YAML"
    ADDED+=("$term")
done

# YAML validate
if [[ $DRY_RUN -eq 0 ]]; then
    if ! python3 -c "import yaml,sys; yaml.safe_load(open('$YAML'))" 2>/dev/null; then
        echo "ERROR: yaml validation failed after append; rolling back" >&2
        rollback_and_exit 2
    fi
fi

# Nothing to deploy if all skipped
if [[ ${#ADDED[@]} -eq 0 ]]; then
    echo "all ${#SKIPPED[@]} term(s) already present, nothing to deploy:"
    printf '  - %s (already in yaml)\n' "${SKIPPED[@]}"
    if [[ $DRY_RUN -eq 0 ]]; then rm -f "$BACKUP"; fi
    exit 0
fi

# Deploy: scp yaml + restart funasr-stream-server
if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] would scp $YAML to $REMOTE_HOST:$REMOTE_DIR/"
    echo "[dry-run] would restart funasr-stream-server"
else
    if ! scp -q "$YAML" "${REMOTE_HOST}:${REMOTE_DIR}/hotwords.yaml"; then
        echo "ERROR: scp failed" >&2
        rollback_and_exit 3
    fi
    # 用 start-vllm.sh 重启 (含 CUDA_HOME + EngineCore cleanup; 老的 nohup 直跑会丢
    # CUDA env 导致 vLLM 加载失败, 见 2026-05-15-vllm-default-backend.md).
    if ! ssh "$REMOTE_HOST" "bash ${REMOTE_DIR}/start-vllm.sh" 2>/dev/null; then
        echo "ERROR: ssh restart command failed; rolling back local yaml" >&2
        rollback_and_exit 3
    fi
    rm -f "$BACKUP"
fi

# Summary
echo "added ${#ADDED[@]} term(s):"
printf '  + %s\n' "${ADDED[@]}"
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    echo "skipped ${#SKIPPED[@]} (already present):"
    printf '  = %s\n' "${SKIPPED[@]}"
fi
if [[ $DRY_RUN -eq 0 ]]; then
    echo "funasr-stream-server restarting — wait ~30s before next Shift+Alt+S recording"
fi
