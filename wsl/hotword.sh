#!/usr/bin/env bash
# hotword.sh — CRUD for server/hotwords.yaml + hot-redeploy to remote funasr-stream-server.
# Supersedes add-hotword.sh (which only supported `add`). Subcommands:
#   add [--dry-run] TERM [TERM ...]   — append term(s) under user_added: (default if first arg looks like a term)
#   list [CATEGORY]                    — list all terms (optionally filtered by category)
#   search PATTERN                     — grep across all terms (case-insensitive)
#   remove TERM                        — remove first matching - "TERM" line (any category)
#   export                             — print full yaml to stdout
#
# Backward-compat: `bash hotword.sh "Web Agent"` works (no subcommand → infer `add`).
#
# Idempotent / transactional / flock-locked (same as add-hotword.sh).
#
# Exit codes:
#   0 = success
#   1 = invalid args
#   2 = yaml validation failed (after mutation)
#   3 = scp / ssh remote step failed (local yaml rolled back)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
YAML="${REPO_ROOT}/server/hotwords.yaml"
LOCK="${REPO_ROOT}/.hotword.lock"
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

# ----- subcommand routing -------------------------------------------------
SUB="${1:-}"
case "$SUB" in
    list|search|remove|export|add)
        shift
        ;;
    "")
        echo "ERROR: no subcommand or term given." >&2
        echo "Usage: $0 add TERM [TERM ...] | list [CATEGORY] | search PATTERN | remove TERM | export" >&2
        exit 1
        ;;
    *)
        # Back-compat: bare terms = add. The first arg is a term, not a subcommand.
        SUB="add"
        ;;
esac

# ----- list ----------------------------------------------------------------
if [[ "$SUB" == "list" ]]; then
    filter_cat="${1:-}"
    if [[ -n "$filter_cat" ]]; then
        awk -v cat="$filter_cat" '
            /^[a-z_]+:$/ { current = substr($0, 1, length($0)-1); next }
            /^  - / && current == cat { print $0 }
        ' "$YAML"
    else
        awk '
            /^[a-z_]+:$/ { print "[" substr($0, 1, length($0)-1) "]"; next }
            /^  - / { print "  " $0 }
        ' "$YAML"
    fi
    exit 0
fi

# ----- search --------------------------------------------------------------
if [[ "$SUB" == "search" ]]; then
    pat="${1:-}"
    if [[ -z "$pat" ]]; then
        echo "ERROR: search requires PATTERN" >&2; exit 1
    fi
    awk -v pat="$pat" '
        /^[a-z_]+:$/ { current = substr($0, 1, length($0)-1); next }
        /^  - / && tolower($0) ~ tolower(pat) { print "[" current "] " $0 }
    ' "$YAML"
    exit 0
fi

# ----- export --------------------------------------------------------------
if [[ "$SUB" == "export" ]]; then
    cat "$YAML"
    exit 0
fi

# ----- below are mutating ops; need lock + remote redeploy -----------------
exec 200>"$LOCK"
flock -x -w 30 200 || { echo "ERROR: could not acquire lock within 30s" >&2; exit 1; }

restart_remote_server() {
    # Use start-vllm.sh — has CUDA_HOME / PATH / EngineCore cleanup.
    if ! ssh "$REMOTE_HOST" "bash ${REMOTE_DIR}/start-vllm.sh" 2>/dev/null; then
        echo "ERROR: ssh restart failed" >&2
        return 1
    fi
    return 0
}

# ----- remove --------------------------------------------------------------
if [[ "$SUB" == "remove" ]]; then
    term="${1:-}"
    if [[ -z "$term" ]]; then
        echo "ERROR: remove requires TERM" >&2; exit 1
    fi
    yaml_term=$(printf '%s' "$term" | sed 's/"/\\"/g')
    if ! grep -qE "^  - \"?${yaml_term}\"?$" "$YAML"; then
        echo "term '$term' not found in yaml (nothing to remove)"
        exit 0
    fi
    BACKUP="${YAML}.bak.$$"
    cp "$YAML" "$BACKUP"
    # Remove the first matching - "term" or - term line
    awk -v term="$term" -v yterm="$yaml_term" '
        $0 == "  - \"" yterm "\"" || $0 == "  - " term { if (!removed) { removed=1; next } }
        { print }
    ' "$YAML" > "${YAML}.tmp" && mv "${YAML}.tmp" "$YAML"

    if ! python3 -c "import yaml; yaml.safe_load(open('$YAML'))" 2>/dev/null; then
        echo "ERROR: yaml validation failed; rolling back" >&2
        mv "$BACKUP" "$YAML"; exit 2
    fi
    if ! scp -q "$YAML" "${REMOTE_HOST}:${REMOTE_DIR}/hotwords.yaml"; then
        echo "ERROR: scp failed; rolling back" >&2
        mv "$BACKUP" "$YAML"; exit 3
    fi
    if ! restart_remote_server; then
        echo "  scp succeeded but restart failed; remote yaml updated but server may be down" >&2
        rm -f "$BACKUP"; exit 3
    fi
    rm -f "$BACKUP"
    echo "removed term: $term"
    echo "funasr-stream-server restarting — wait ~20s before next recording"
    exit 0
fi

# ----- add (default + explicit) --------------------------------------------
DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
    shift
fi

if [[ $# -eq 0 ]]; then
    echo "ERROR: add requires at least one TERM" >&2
    exit 1
fi

for term in "$@"; do
    if [[ -z "$term" ]] || [[ ${#term} -lt 2 ]]; then
        echo "ERROR: term '$term' empty or <2 chars" >&2
        exit 1
    fi
done

# Ensure user_added: category exists
if ! grep -qE "^${USER_ADDED_TAG}$" "$YAML"; then
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] would append '${USER_ADDED_TAG}' category to $YAML"
    else
        printf '\n%s\n  # 用户通过 /hotword add 添加，比 LLM 候选学习路径更高精度\n' "$USER_ADDED_TAG" >> "$YAML"
    fi
fi

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

ADDED=()
SKIPPED=()
for term in "$@"; do
    yaml_term=$(printf '%s' "$term" | sed 's/"/\\"/g')
    line_pattern="^  - \"${yaml_term}\"$"
    if grep -qE "$line_pattern" "$YAML" || grep -qF "  - $term" "$YAML"; then
        SKIPPED+=("$term")
        continue
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] would append: - \"$term\" under user_added:"
        ADDED+=("$term")
        continue
    fi
    awk -v marker="${USER_ADDED_TAG}" -v new_line="  - \"${yaml_term}\"" '
        $0 == marker { print; print new_line; inserted=1; next }
        { print }
        END { if (!inserted) { print marker; print new_line } }
    ' "$YAML" > "${YAML}.tmp" && mv "${YAML}.tmp" "$YAML"
    ADDED+=("$term")
done

if [[ $DRY_RUN -eq 0 ]]; then
    if ! python3 -c "import yaml; yaml.safe_load(open('$YAML'))" 2>/dev/null; then
        echo "ERROR: yaml validation failed; rolling back" >&2
        rollback_and_exit 2
    fi
fi

if [[ ${#ADDED[@]} -eq 0 ]]; then
    echo "all ${#SKIPPED[@]} term(s) already present, nothing to deploy:"
    printf '  - %s (already in yaml)\n' "${SKIPPED[@]}"
    if [[ $DRY_RUN -eq 0 ]]; then rm -f "$BACKUP"; fi
    exit 0
fi

if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] would scp $YAML to $REMOTE_HOST:$REMOTE_DIR/"
    echo "[dry-run] would restart funasr-stream-server"
else
    if ! scp -q "$YAML" "${REMOTE_HOST}:${REMOTE_DIR}/hotwords.yaml"; then
        echo "ERROR: scp failed" >&2
        rollback_and_exit 3
    fi
    if ! restart_remote_server; then
        echo "ERROR: ssh restart failed; rolling back local yaml" >&2
        rollback_and_exit 3
    fi
    rm -f "$BACKUP"
fi

echo "added ${#ADDED[@]} term(s):"
printf '  + %s\n' "${ADDED[@]}"
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    echo "skipped ${#SKIPPED[@]} (already present):"
    printf '  = %s\n' "${SKIPPED[@]}"
fi
if [[ $DRY_RUN -eq 0 ]]; then
    echo "funasr-stream-server restarting — wait ~20s before next recording"
fi
