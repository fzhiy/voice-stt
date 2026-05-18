#!/usr/bin/env bash
# 在 A1 ~/voice-stack/ 下跑：验证整条复用链路
# 链路：Gateway (9080) → Whisper Large-v3-turbo (8081) + Ollama (11434, qwen2.5:7b)

set -euo pipefail

GATEWAY_PORT="${GATEWAY_PORT:-9080}"
WHISPER_PORT="${WHISPER_PORT:-8081}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
info() { echo -e "${YELLOW}[..]${NC} $*"; }

info "1. 宿主机 Ollama (:11434)"
curl -fs --max-time 5 http://127.0.0.1:11434/api/version >/dev/null \
    && ok "Ollama API 可达" || fail "Ollama 不通"

info "2. Ollama 是否有 qwen2.5:7b"
if curl -fs http://127.0.0.1:11434/api/tags | grep -q '"qwen2.5:7b"'; then
    ok "qwen2.5:7b 已就绪"
else
    fail "qwen2.5:7b 未下载，运行 ollama pull qwen2.5:7b"
fi

info "3. 宿主机 Whisper-large (:$WHISPER_PORT)"
if curl -fs --max-time 5 "http://127.0.0.1:$WHISPER_PORT/" >/dev/null; then
    ok "whisper-large :$WHISPER_PORT 可达"
else
    fail "whisper-large 不通，启动：bash start-whisper-large.sh --daemon"
fi

info "4. Gateway 容器 (:$GATEWAY_PORT)"
if curl -fs --max-time 5 "http://127.0.0.1:$GATEWAY_PORT/" >/dev/null 2>&1; then
    ok "Gateway :$GATEWAY_PORT 可达"
else
    fail "Gateway 不通，运行：docker compose up -d"
fi

info "5. 端到端：生成 3 秒静音 WAV 测 Gateway → Whisper"
TEST_WAV=/tmp/voice-test-$$.wav
if command -v ffmpeg >/dev/null; then
    ffmpeg -f lavfi -i anullsrc=r=16000:cl=mono -t 3 -y "$TEST_WAV" 2>/dev/null
    RESP=$(curl -sS --max-time 30 -X POST "http://127.0.0.1:$GATEWAY_PORT/v1/audio/transcriptions" \
        -F "file=@$TEST_WAV" -F "language=zh" -F "model=large-v3-turbo" -F "response_format=json")
    rm -f "$TEST_WAV"
    if echo "$RESP" | grep -q '"text"'; then
        ok "Gateway → Whisper 端到端通：$(echo "$RESP" | head -c 200)"
    else
        fail "返回不是预期格式：$(echo "$RESP" | head -c 300)"
    fi
else
    info "(跳过：无 ffmpeg)"
fi

info "6. Ollama 中文清洗冒烟"
RESP=$(curl -sS --max-time 30 http://127.0.0.1:11434/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"qwen2.5:7b","messages":[{"role":"user","content":"嗯那个test"}],"stream":false}')
if echo "$RESP" | grep -q '"content"'; then
    ok "Ollama chat 正常"
else
    fail "Ollama chat 异常：$(echo "$RESP" | head -c 200)"
fi

info "7. GPU 占用"
nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu --format=csv,noheader 2>/dev/null | head -1

echo
ok "自检完成"
