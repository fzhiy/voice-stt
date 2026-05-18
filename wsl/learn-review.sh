#!/usr/bin/env bash
# learn-review.sh — aggregate mini-gateway LEARN candidates from remote jsonl,
# filter noise (already in yaml / too short / common stopwords), present sorted
# by frequency. Pairs `wsl/hotword.sh add` for batch promote.
#
# Usage:
#   learn-review.sh                       — top 20 candidates table
#   learn-review.sh list 50               — top 50
#   learn-review.sh promote "T1" "T2" ... — bulk add via hotword.sh add
#   learn-review.sh raw 100               — last 100 raw lines for debugging
#
# Reads remote ~/voice-stack/hotwords-learned.jsonl over ssh; pure-read for
# list/raw, mutates yaml only via hotword.sh in promote.

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
LEARN_LOG="${REMOTE_DIR}/hotwords-learned.jsonl"
PULL_LINES="${LEARN_REVIEW_PULL_LINES:-500}"  # last N lines of jsonl to scan

# 噪音过滤: 这些 "right" 不该 promote 进 hotwords
NOISE_RIGHT='^(VPs|skill|page|sars|brief|the|a|an|and|or|的|了|在|是|这个|那个|然后|因为|所以|但是|可以|应该|这里|那里|什么|怎么|为什么|进行|做|看|说)$'
# "right" 跟 "wrong" 长度差距太大 = LLM 把整句当一对, 跳过
MAX_RIGHT_LEN=20

SUB="${1:-list}"

case "$SUB" in
    raw)
        N="${2:-50}"
        ssh "$REMOTE_HOST" "tail -n ${N} ${LEARN_LOG}" 2>/dev/null
        exit 0
        ;;
    promote)
        shift
        if [[ $# -eq 0 ]]; then
            echo "Usage: $0 promote TERM [TERM ...]" >&2
            exit 1
        fi
        # 转发给 hotword.sh add (它处理 yaml + scp + restart)
        bash "${REPO_ROOT}/wsl/hotword.sh" add "$@"
        exit $?
        ;;
    list|"")
        N="${2:-20}"
        ;;
    *)
        echo "Unknown subcommand: $SUB" >&2
        echo "Usage: $0 [list [N] | raw [N] | promote TERM ...]" >&2
        exit 1
        ;;
esac

# ----- list path ---------------------------------------------------------

# 1) 拉远端 jsonl 最近 PULL_LINES 行
RAW=$(ssh "$REMOTE_HOST" "tail -n ${PULL_LINES} ${LEARN_LOG} 2>/dev/null" || true)
if [[ -z "$RAW" ]]; then
    echo "no LEARN candidates found on ${REMOTE_HOST}:${LEARN_LOG}" >&2
    exit 0
fi

# 2) 提取所有 (wrong, right) 对, 聚合频次 (python3 替代 jq 因为 jq 不一定装)
PAIRS=$(printf '%s\n' "$RAW" | python3 -c "
import sys, json
from collections import Counter
c = Counter()
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        rec = json.loads(line)
        for cand in rec.get('candidates') or []:
            w = (cand.get('wrong') or '').strip()
            r = (cand.get('right') or '').strip()
            if w and r:
                c[(w, r)] += 1
    except Exception: pass
for (w, r), n in c.most_common():
    print(f'{n}\t{w}\t{r}')
")

if [[ -z "$PAIRS" ]]; then
    echo "no candidate pairs extracted (jsonl may be malformed)" >&2
    exit 0
fi

# 3) 过滤 + 渲染表格
printf "%-4s  %-30s  %-30s  %s\n" "FREQ" "WRONG (ASR 听成)" "RIGHT (建议加)" "STATUS"
printf "%-4s  %-30s  %-30s  %s\n" "----" "------------------------------" "------------------------------" "------"

# tab-separated 输入: "COUNT\tWRONG\tRIGHT"
SHOWN=0
while IFS=$'\t' read -r count wrong right; do
    [[ -z "${count:-}" ]] && continue

    # Skip if right looks like noise
    if printf '%s' "$right" | grep -qE "$NOISE_RIGHT"; then
        continue
    fi
    # Skip if right too long (LLM 把整句当一对)
    if [[ ${#right} -gt $MAX_RIGHT_LEN ]]; then
        continue
    fi
    # Skip if right < 2 chars
    if [[ ${#right} -lt 2 ]]; then
        continue
    fi

    # Check if right already in yaml (any category, quoted or unquoted)
    if grep -qE "^  - \"?${right}\"?$" "$YAML" 2>/dev/null; then
        status="[in yaml]"
    else
        status=""
    fi

    printf "%-4s  %-30s  %-30s  %s\n" "$count" "${wrong:0:30}" "${right:0:30}" "$status"
    SHOWN=$((SHOWN + 1))
    if [[ $SHOWN -ge $N ]]; then break; fi
done <<< "$PAIRS"

echo
echo "showing ${SHOWN} candidates (filtered noise, capped at ${N}). Total raw pairs: $(printf '%s\n' "$PAIRS" | wc -l)"
echo "To promote: bash wsl/learn-review.sh promote \"Term1\" \"Term2\" ..."
