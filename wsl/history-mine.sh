#!/usr/bin/env bash
# history-mine.sh — mine tech-term candidates from ground-truth history.jsonl files.
# Unlike learn-review.sh (LLM-guess pipeline, ~40% noise), history is user-verified
# final transcripts, so candidates here are significantly more reliable.
#
# Usage:
#   history-mine.sh                       — top 20 candidates table
#   history-mine.sh list [N]              — top N candidates (default 20)
#   history-mine.sh promote "T1" "T2" ... — bulk add via hotword.sh add
#   history-mine.sh raw [N]               — last N raw history JSON lines (default 20)
#   history-mine.sh [--auto-promote-confident]  — experimental: auto-add freq>=10 days>=5
#
# Candidate extraction rules:
#   - ASCII token with >=2 consecutive ASCII letters embedded in Chinese/mixed text
#   - CamelCase, hyphenated, ALL_CAPS (>=2 letters), or standalone ASCII words
#   - Length 2-30 characters
#   - NOT already in server/hotwords.yaml (any category)
#   - Ranked by frequency + multi-day coverage (>=2 distinct dates preferred)
#
# Data source (local-first):
#   1. LOCAL_HISTORY_DIR — defaults to Windows AppData path via WIN_USER discovery
#   2. Remote SSH fallback (REMOTE_HOST / GPU_USER+GPU_HOST) if local is empty
#   Only `promote` requires REMOTE_HOST (for hotword.sh deploy).
#
# REMOTE_HOST / REMOTE_DIR can be overridden via env vars (same as hotword.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
YAML="${REPO_ROOT}/server/hotwords.yaml"
REMOTE_DIR="${REMOTE_DIR:-voice-stack}"  # relative to remote $HOME
HISTORY_DIR="${REMOTE_DIR}/history"

# Local history dir: Windows AppData\Local\voice-stt\transcripts (accessed via /mnt/c)
if [[ -z "${LOCAL_HISTORY_DIR:-}" ]]; then
    WIN_USER="${WIN_USER:-$(cmd.exe /c echo %USERNAME% 2>/dev/null | tr -d '\r\n' || echo "")}"
    LOCAL_HISTORY_DIR="/mnt/c/Users/${WIN_USER}/AppData/Local/voice-stt/transcripts"
fi

# _fetch_history: cat all history jsonl files; local + remote (both, not either-or)
_fetch_history() {
    local out="" remote=""
    # Local path
    if [[ -d "$LOCAL_HISTORY_DIR" ]] && ls "${LOCAL_HISTORY_DIR}"/*.jsonl &>/dev/null 2>&1; then
        out="$(cat "${LOCAL_HISTORY_DIR}"/*.jsonl 2>/dev/null || true)"
    fi
    # SSH (optional; silent if REMOTE_HOST not set)
    if [[ -n "${REMOTE_HOST:-}" ]]; then
        remote="$(ssh "$REMOTE_HOST" \
            "ls ${HISTORY_DIR}/*.jsonl 2>/dev/null | xargs cat 2>/dev/null" \
            2>/dev/null || true)"
    elif [[ -n "${GPU_USER:-}" && -n "${GPU_HOST:-}" ]]; then
        REMOTE_HOST="${GPU_USER}@${GPU_HOST}"
        remote="$(ssh "$REMOTE_HOST" \
            "ls ${HISTORY_DIR}/*.jsonl 2>/dev/null | xargs cat 2>/dev/null" \
            2>/dev/null || true)"
    fi
    printf '%s\n%s' "$out" "$remote"
}

# Parse flags before subcommand
AUTO_PROMOTE_CONFIDENT=0
ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--auto-promote-confident" ]]; then
        AUTO_PROMOTE_CONFIDENT=1
    else
        ARGS+=("$arg")
    fi
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

SUB="${1:-list}"

case "$SUB" in
    raw)
        N="${2:-20}"
        # Fetch and print last N lines across all history jsonl files, newest first
        _fetch_history | tail -n "$N"
        exit 0
        ;;
    promote)
        shift
        if [[ $# -eq 0 ]]; then
            echo "Usage: $0 promote TERM [TERM ...]" >&2
            exit 1
        fi
        # promote requires REMOTE_HOST for hotword.sh deploy
        if [[ -z "${REMOTE_HOST:-}" ]]; then
            if [[ -n "${GPU_USER:-}" && -n "${GPU_HOST:-}" ]]; then
                REMOTE_HOST="${GPU_USER}@${GPU_HOST}"
            else
                echo "ERROR: promote requires REMOTE_HOST or both GPU_USER and GPU_HOST" >&2
                exit 1
            fi
        fi
        bash "${REPO_ROOT}/wsl/hotword.sh" add "$@"
        exit $?
        ;;
    list|"")
        N="${2:-20}"
        ;;
    *)
        echo "Unknown subcommand: $SUB" >&2
        echo "Usage: $0 [list [N] | raw [N] | promote TERM ...] [--auto-promote-confident]" >&2
        exit 1
        ;;
esac

# ----- list path -------------------------------------------------------------

# 1) Pull all history/*.jsonl (local-first, SSH fallback)
RAW=$(_fetch_history || true)

if [[ -z "$RAW" ]]; then
    echo "no history jsonl found (checked: ${LOCAL_HISTORY_DIR} and remote)" >&2
    echo "  Set LOCAL_HISTORY_DIR or REMOTE_HOST to point at *.jsonl files" >&2
    exit 0
fi

# 2) Extract candidate tokens from text fields, count freq + days
#    Field priority: final_text > text > final (client jsonl uses 'text')
CANDIDATES=$(printf '%s\n' "$RAW" | python3 -c "
import sys, json, re
from collections import defaultdict

# Regex: ASCII tokens that look like tech terms
# Matches: CamelCase, hyphenated, ALL-CAPS (>=2), plain ASCII words >=2 letters
# Also catches mixed tokens like 'v1.2', 'GPT-4', 'useState'
TECH_RE = re.compile(
    r'(?<![A-Za-z])'      # not preceded by ASCII letter (avoid mid-word slices)
    r'(?:'
        r'[A-Z][a-z]+(?:[A-Z][a-z]*)+'   # CamelCase: useState, LlamaIndex
        r'|[A-Z]{2,}(?:-[A-Z0-9]+)*'     # ALL-CAPS with optional hyphen: MCP, GPT-4
        r'|[a-zA-Z]{2,}(?:-[a-zA-Z0-9]+)+'  # hyphenated: funasr-stream, pre-trained
        r'|[A-Z][A-Za-z0-9]*[0-9]+'      # version tokens: GPT4, Qwen3, CUDA12
        r'|[a-zA-Z]{2,30}'               # plain ASCII word >=2 letters
    r')'
    r'(?![A-Za-z])',                      # not followed by ASCII letter
    re.UNICODE
)

# freq[term] = total occurrence count
# days[term] = set of date strings (YYYY-MM prefix from source filename or ts field)
freq = defaultdict(int)
days = defaultdict(set)
samples = {}   # term -> one sample transcript

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except Exception:
        continue
    # Field compat: server uses 'final_text'; client jsonl uses 'text'; legacy 'final'
    text = rec.get('final_text', '') or rec.get('text', '') or rec.get('final', '')
    if not text:
        continue
    # Date: try ts_start/ts_end (server schema), ts, timestamp, else fallback
    ts = (rec.get('ts_start', '') or rec.get('ts_end', '') or
          rec.get('ts', '') or rec.get('timestamp', '') or '')
    date_key = ts[:10] if len(ts) >= 10 else 'unknown'

    tokens = TECH_RE.findall(text)
    seen_in_line = set()
    for tok in tokens:
        # Length filter 2-30
        if len(tok) < 2 or len(tok) > 30:
            continue
        # Exclude pure lowercase common English stopwords (<=4 chars)
        if tok.lower() in {'the','a','an','and','or','in','is','it','to','of',
                           'for','on','at','by','as','be','do','if','my','we',
                           'so','but','not','has','had','was','are','all','can',
                           'did','its','via','per','the','how','why','what'}:
            continue
        freq[tok] += 1
        days[tok].add(date_key)
        if tok not in seen_in_line:
            # Store shortest sample that contains the token
            if tok not in samples or len(samples[tok]) > len(text):
                samples[tok] = text
            seen_in_line.add(tok)

# Output: FREQ<tab>DAYS<tab>TERM<tab>SAMPLE
for term, count in sorted(freq.items(), key=lambda x: (-len(days[x[0]]), -x[1])):
    day_count = len(days[term])
    sample = samples.get(term, '')
    # Truncate sample to 80 chars
    if len(sample) > 80:
        sample = sample[:77] + '...'
    print(f'{count}\t{day_count}\t{term}\t{sample}')
")

if [[ -z "$CANDIDATES" ]]; then
    echo "no tech-term candidates extracted (history jsonl may have no text field)" >&2
    exit 0
fi

# 3) Read existing hotwords into a set for fast lookup (python does this inline below)
EXISTING=$(grep -E "^  - " "$YAML" 2>/dev/null | sed 's/^  - //' | sed 's/^"//' | sed 's/"$//' || true)

# 4) Filter out already-in-yaml terms + render table
printf "%-5s  %-4s  %-30s  %s\n" "FREQ" "DAYS" "TERM" "SAMPLE_TRANSCRIPT"
printf "%-5s  %-4s  %-30s  %s\n" "-----" "----" "------------------------------" "----------------"

SHOWN=0
AUTO_PROMOTED=()

while IFS=$'\t' read -r count day_count term sample; do
    [[ -z "${term:-}" ]] && continue

    # Check if already in yaml
    if printf '%s\n' "$EXISTING" | grep -qxF "$term" 2>/dev/null; then
        continue
    fi

    # --auto-promote-confident: freq>=10 AND days>=5 → auto add (experimental, default OFF)
    if [[ $AUTO_PROMOTE_CONFIDENT -eq 1 ]] && \
       [[ "$count" -ge 10 ]] && [[ "$day_count" -ge 5 ]]; then
        AUTO_PROMOTED+=("$term")
        continue
    fi

    printf "%-5s  %-4s  %-30s  %s\n" "$count" "$day_count" "${term:0:30}" "${sample:0:60}"
    SHOWN=$((SHOWN + 1))
    if [[ $SHOWN -ge $N ]]; then break; fi
done <<< "$CANDIDATES"

echo
echo "showing ${SHOWN} candidates (excluded already-in-yaml, capped at ${N})"
echo "To promote: bash wsl/history-mine.sh promote \"Term1\" \"Term2\" ..."

# Handle auto-promote results (experimental)
if [[ $AUTO_PROMOTE_CONFIDENT -eq 1 ]]; then
    echo
    echo "[experimental --auto-promote-confident] freq>=10 + days>=5 candidates:"
    if [[ ${#AUTO_PROMOTED[@]} -eq 0 ]]; then
        echo "  (none qualified)"
    else
        printf '  + %s\n' "${AUTO_PROMOTED[@]}"
        echo "  Auto-promoting ${#AUTO_PROMOTED[@]} term(s)..."
        bash "${REPO_ROOT}/wsl/hotword.sh" add "${AUTO_PROMOTED[@]}"
    fi
fi
