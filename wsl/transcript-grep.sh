#!/usr/bin/env bash
# 检索 voice-stt 本地转写恢复日志.
# 数据源: %LOCALAPPDATA%\voice-stt\transcripts\YYYY-MM.jsonl (AHK 写)
# 在 WSL 里通过 /mnt/c/Users/<USER>/AppData/Local/voice-stt/transcripts/ 访问.
#
# 用法:
#   transcript-grep.sh                       # 最近 20 条, 倒序
#   transcript-grep.sh --last 50             # 最近 50 条
#   transcript-grep.sh --grep "qwen3"        # 全文搜
#   transcript-grep.sh --since "1h"          # 1 小时内 (支持 1h / 30m / 2d)
#   transcript-grep.sh --status no_out       # 只看转写失败的
#   transcript-grep.sh --raw                 # 不 pretty-print, 输出原始 JSONL

set -euo pipefail

WIN_USER="${VOICE_STT_WIN_USER:-$(cmd.exe /c echo %USERNAME% 2>/dev/null | tr -d '\r')}"
TRANSCRIPT_DIR="/mnt/c/Users/${WIN_USER}/AppData/Local/voice-stt/transcripts"

if [[ ! -d "$TRANSCRIPT_DIR" ]]; then
    echo "recovery log dir not found: $TRANSCRIPT_DIR" >&2
    echo "set VOICE_STT_WIN_USER if Windows username detection failed" >&2
    exit 2
fi

last=20
grep_pat=""
since=""
status_filter=""
raw=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --last)   last="$2"; shift 2 ;;
        --grep)   grep_pat="$2"; shift 2 ;;
        --since)  since="$2"; shift 2 ;;
        --status) status_filter="$2"; shift 2 ;;
        --raw)    raw=1; shift ;;
        -h|--help)
            sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Build jq filter. Records are time-sorted within each month file (append-only).
# Concat in descending filename order so newest month comes first.
files=$(ls -1 "$TRANSCRIPT_DIR"/*.jsonl 2>/dev/null | sort -r)
if [[ -z "$files" ]]; then
    echo "(empty)"; exit 0
fi

# since cutoff -> ISO ts string for jq comparison
cutoff_ts=""
if [[ -n "$since" ]]; then
    case "$since" in
        *h) secs=$(( ${since%h} * 3600 )) ;;
        *m) secs=$(( ${since%m} * 60 )) ;;
        *d) secs=$(( ${since%d} * 86400 )) ;;
        *)  echo "bad --since format: $since (try 1h / 30m / 2d)" >&2; exit 2 ;;
    esac
    cutoff_ts=$(date -u -d "@$(($(date +%s) - secs))" +"%Y-%m-%dT%H:%M:%S")
fi

# jq filter pipeline: optional since / status / grep, reverse, head.
filter='.'
[[ -n "$cutoff_ts" ]]      && filter="$filter | select(.ts >= \"$cutoff_ts\")"
[[ -n "$status_filter" ]]  && filter="$filter | select(.paste_status == \"$status_filter\")"
[[ -n "$grep_pat" ]]       && filter="$filter | select((.text // \"\") | test(\"$grep_pat\"; \"i\"))"

# tac to invert in-file order (newest last in file -> first in output), then jq filter, then head.
tac $files | jq -c "$filter" 2>/dev/null | head -n "$last" | (
    if (( raw )); then
        cat
    else
        # Pretty short form: ts | duration | status | title | text(50)
        jq -r '"\(.ts)  \(.duration_sec)s  [\(.paste_status)]  → \(.target_title_used // .target_title_release)\n  \((.text // "") | .[0:160])\n"'
    fi
)
