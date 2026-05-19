#!/usr/bin/env python3
"""
FunASR streaming ASR server (Paraformer-zh-streaming).

WebSocket protocol:
  - Client connects to ws://HOST:PORT/
  - Sends binary frames: raw PCM int16 mono 16kHz (any chunk size).
  - Server runs streaming inference and sends JSON text frames back:
      {"type":"partial","text":"<累积部分转写>"}
  - When client wants to finalize, sends text frame "EOF". Server returns:
      {"type":"final","text":"<最终结果>"}
    then closes the connection.

设计：
  - 一连接 = 一会话 = 一份 FunASR cache（recurrent state）。连接关时清。
  - 模型只 load 一次（全局）。第一次推理有 warmup 开销，之后 chunk 级别推理 <100ms。
  - chunk_size=[0,10,5] → ~600ms 端到端，是 FunASR 官方推荐配置。

启动：
  ./streamenv/bin/python funasr-stream-server.py
  STREAM_PORT=8082 ./streamenv/bin/python funasr-stream-server.py
"""
import asyncio
import json
import multiprocessing
import os
import re
import signal
import sys
import time
import urllib.request
from pathlib import Path

# vLLM spawn-method 子进程 (EngineCore worker) 会 re-import 本脚本作为
# multiprocessing.spawn 的 unpickle 步骤。如果 module-level 跑 qwen3 load,
# 子进程会重新跑 → 浪费时间 + 触发 freeze_support 噪音 log。
# 这个 flag 让 model loading 只在 main 跑。
_IS_MAIN_PROCESS = multiprocessing.current_process().name == "MainProcess"
import numpy as np
import websockets
import yaml
from funasr import AutoModel
try:
    import webrtcvad
    _WEBRTCVAD_AVAILABLE = True
except ImportError:
    _WEBRTCVAD_AVAILABLE = False
import text_postprocess
from backends import get_streaming_backend, get_final_backend

HOST = os.environ.get("STREAM_HOST", "127.0.0.1")
PORT = int(os.environ.get("STREAM_PORT", "8082"))
PUNC_MODEL_NAME = os.environ.get("STREAM_PUNC_MODEL", "ct-punc-c")  # 空串=不加标点模型
# History records: server-side append-only JSONL, 月滚动. HISTORY_ENABLED=0 关掉.
HISTORY_ENABLED = os.environ.get("HISTORY_ENABLED", "1") not in ("0", "false", "no", "")
HISTORY_DIR = Path(os.environ.get(
    "HISTORY_DIR",
    str(Path.home() / "voice-stack" / "history")
))


def _history_append(rec: dict) -> None:
    """Append one transcription record to monthly JSONL. 静默失败 (不破坏 server)."""
    if not HISTORY_ENABLED:
        return
    try:
        HISTORY_DIR.mkdir(parents=True, exist_ok=True)
        month_file = HISTORY_DIR / f"{time.strftime('%Y-%m')}.jsonl"
        with open(month_file, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception as e:
        log(f"  history append failed: {e}")
# 最终结果送 mini-gateway polish（拿标点+术语+自纠错+简体）。
# 设为空串关闭这步。
POLISH_URL = os.environ.get("POLISH_URL", "http://127.0.0.1:9080/v1/text/polish")
POLISH_TIMEOUT = int(os.environ.get("POLISH_TIMEOUT", "15"))
# 热词学习：Qwen3 final 出结果后把 paraformer raw + qwen3 final 丢给 gateway，
# 让 LLM 抽同音术语对学习，append 进 hotwords-learned.jsonl 等用户审核。
# 设为空串关掉这步。
LEARN_URL = os.environ.get("LEARN_URL", "http://127.0.0.1:9080/v1/text/learn")
LEARN_TIMEOUT = int(os.environ.get("LEARN_TIMEOUT", "30"))
# 热词词典：boost Paraformer 对这些词的概率
HOTWORDS_FILE = os.environ.get("HOTWORDS_FILE", str(Path(__file__).parent / "hotwords.yaml"))

def log(*a):
    print(f"[{time.strftime('%H:%M:%S')}]", *a, flush=True)


def load_hotwords(path: str) -> str:
    """从 YAML 拉所有分类的词扁平化成空格分隔字符串。Paraformer hotword 用。"""
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}
        words = []
        for cat, items in data.items():
            if isinstance(items, list):
                words.extend(items)
        # Paraformer hotword 期望空格分隔；多词术语用下划线连接更稳
        # 但其实 hotword 支持多 token 词组直接传，保留原样
        return " ".join(words)
    except Exception as e:
        log(f"failed to load hotwords from {path}: {e} (fallback empty)")
        return ""


def load_qwen3_context(path: str) -> str:
    """构造给 Qwen3-ASR transcribe(context=...) 的 system prompt.

    设计依据 QwenLM/Qwen3-ASR 官方 examples + Toolkit README:
        context="Qwen-ASR, DashScope, FFmpeg"   # 裸 term list
        context=["", "交易 停滞", ""]            # per-sample phrase
    官方明确说 context 效果 "subtle - probability nudging, not enforcement",
    所以不塞 persona / language / 复杂 instruction (语言走 language="Chinese"
    参数, 见 backends/qwen3_asr.py:150). 跟之前的多段式 prompt 相比:
      - 删除角色 preamble ("你正在转写...") — 官方 example 从无
      - 删除 category labels ("- ai agent:") — 官方 flatten 全部 terms
      - 删除语言指令 ("输出使用简体中文") — 跟 language 参数重复
      - 保留 "英文原样大小写" — voice-stt 独有但解决真实痛点
    """
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}
        seen = set()
        terms = []
        for _cat, items in data.items():
            if not isinstance(items, list):
                continue
            for item in items:
                t = str(item).strip()
                if t and t not in seen:
                    seen.add(t)
                    terms.append(t)
        if not terms:
            return ""
        glossary = ", ".join(terms)
        return glossary + "\n\n英文专有名词保持原样大小写。"
    except Exception as e:
        log(f"failed to build qwen3 context from {path}: {e} (fallback empty)")
        return ""



# Snippet replacement (type4me parity P2): hotwords.yaml 里 snippets: 区段定义
# `key: value` 对, 文本里出现 key (case-insensitive, 词边界 \b 保护) 就替换为 value.
# 例: snippets.my-email = "<MAINTAINER_EMAIL>" → 语音"my email"转 "my-email"被它扩展.
SNIPPETS = {}

def load_snippets(path: str) -> dict:
    """读 hotwords.yaml 的 snippets: 区段. 失败返 {}."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}
        sn = data.get("snippets") or {}
        if not isinstance(sn, dict):
            log(f"  snippets: section in {path} is not a dict, skipping")
            return {}
        # 过滤空值 + 非 str
        return {k: str(v) for k, v in sn.items() if k and v}
    except Exception as e:
        log(f"failed to load snippets from {path}: {e} (fallback empty)")
        return {}


# Mappings: final-text post-correct table. hotwords.yaml `mappings:` 区段定义 LHS->RHS,
# final 文本 send 给 client 前过一遍. partial 不过, 避免一闪一变.
# 跟 SNIPPETS 区别: snippets 给已识别出的"短 key"做扩展 (my-email->真邮箱),
# mappings 修正 Qwen3 同音误识 (ghosty->Ghostty) 这种 ASR 错.
MAPPINGS = {}


def load_mappings(path: str) -> dict:
    """读 hotwords.yaml 的 mappings: 区段, 返回 dict[LHS_str, RHS_str].
    缺段 / 解析失败 -> {} (server 不崩, 走原文)."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}
        mp = data.get("mappings") or {}
        if not isinstance(mp, dict):
            log(f"  mappings: section in {path} is not a dict, skipping")
            return {}
        return {str(k): str(v) for k, v in mp.items() if k and v is not None}
    except Exception as e:
        log(f"failed to load mappings from {path}: {e} (fallback empty)")
        return {}


def apply_mappings(text: str) -> str:
    """final 文本上做 LHS->RHS 替换. 规则:
      - 长 LHS 优先 (按 len 降序) 避免短 LHS 吞掉长 LHS 的子串
      - LHS 大小写不敏感 (re.IGNORECASE), RHS 原样输出
      - 纯 ASCII LHS 加 \\b 词边界保护; 含 CJK 的 LHS 直接子串替换 (CJK 之间无 \\b)
      - 每次成功替换打一条 log 方便用户排查
    """
    if not text or not MAPPINGS:
        return text
    out = text
    for lhs in sorted(MAPPINGS, key=len, reverse=True):
        rhs = MAPPINGS[lhs]
        has_cjk = any("\u4e00" <= c <= "\u9fff" for c in lhs)
        if has_cjk:
            pattern = re.escape(lhs)
        else:
            pattern = r"\b" + re.escape(lhs) + r"\b"
        new_out, n = re.subn(pattern, rhs, out, flags=re.IGNORECASE)
        if n > 0:
            prev = out if len(out) <= 80 else out[:80] + "..."
            after = new_out if len(new_out) <= 80 else new_out[:80] + "..."
            log(f"  [mapping] '{lhs}' -> '{rhs}' (in: '{prev}' -> '{after}')")
            out = new_out
    return out


HOTWORDS = load_hotwords(HOTWORDS_FILE)
log(f"hotwords: {len(HOTWORDS.split())} terms loaded")

QWEN3_CONTEXT = load_qwen3_context(HOTWORDS_FILE)
log(f"qwen3 context: {len(QWEN3_CONTEXT)} chars built")

SNIPPETS = load_snippets(HOTWORDS_FILE)
if SNIPPETS:
    log(f"snippets: {len(SNIPPETS)} entries loaded ({', '.join(list(SNIPPETS)[:3])}{'...' if len(SNIPPETS) > 3 else ''})")

MAPPINGS = load_mappings(HOTWORDS_FILE)
log(f"mappings: {len(MAPPINGS)} loaded")


def reload_vocab() -> None:
    """Atomically re-read HOTWORDS / QWEN3_CONTEXT / SNIPPETS / MAPPINGS from
    HOTWORDS_FILE. Called by mtime watcher + SIGUSR1 handler + /v1/vocab/reload.
    Per-load 失败保持旧表 (load_* 内部 try/except), 整体 try/except 兜底防 server 崩."""
    global HOTWORDS, QWEN3_CONTEXT, SNIPPETS, MAPPINGS
    try:
        new_hw = load_hotwords(HOTWORDS_FILE)
        new_ctx = load_qwen3_context(HOTWORDS_FILE)
        new_sn = load_snippets(HOTWORDS_FILE)
        new_mp = load_mappings(HOTWORDS_FILE)
        HOTWORDS = new_hw
        QWEN3_CONTEXT = new_ctx
        SNIPPETS = new_sn
        MAPPINGS = new_mp
        _seed_backend_state()
        log(f"vocab reloaded: {len(HOTWORDS.split())} hotwords, "
            f"{len(SNIPPETS)} snippets, {len(MAPPINGS)} mappings, "
            f"{len(QWEN3_CONTEXT)} ctx chars")
    except Exception as e:
        log(f"reload_vocab failed: {e} (keeping current tables)")


async def vocab_mtime_watcher(interval: float = 30.0) -> None:
    """Poll HOTWORDS_FILE mtime; on change call reload_vocab. interval 默认 30s
    跟 brief 一致. 异常不阻断循环 (单次 reload 失败下次再试)."""
    try:
        last_mtime = os.path.getmtime(HOTWORDS_FILE)
    except OSError:
        last_mtime = 0.0
    while True:
        try:
            await asyncio.sleep(interval)
            try:
                cur = os.path.getmtime(HOTWORDS_FILE)
            except OSError:
                continue
            if cur != last_mtime:
                log(f"hotwords.yaml mtime changed ({last_mtime:.0f} -> {cur:.0f}), reloading vocab")
                reload_vocab()
                last_mtime = cur
        except asyncio.CancelledError:
            break
        except Exception as e:
            log(f"vocab_mtime_watcher iter err: {e} (continuing)")

streaming_backend = get_streaming_backend()
if _IS_MAIN_PROCESS:
    streaming_backend.load()

# Speculative partial：每 PARTIAL_INTERVAL_SEC 在最后 MAX_PARTIAL_AUDIO_SEC 秒
# PCM 上跑一次 Qwen3-ASR 出 partial。type4me 同款"重跑全量+cooperative skip"。
# QWEN3_PARTIAL_ENABLED=0 临时禁用 partial task（GPU contention 应急开关）。
QWEN3_PARTIAL_ENABLED = os.environ.get("QWEN3_PARTIAL_ENABLED", "1") not in ("0", "false", "no", "")
PARTIAL_INTERVAL_SEC = float(os.environ.get("QWEN3_PARTIAL_INTERVAL_SEC", "1.5"))
# Partial 看全量 PCM（默认）vs tail 45s（老链路）。全量保证 partial 不丢录音开头，
# 配合 PARTIAL_AS_FINAL_MIN_COVERAGE 让长录音 EOF 时 last partial 直接当 final。
QWEN3_PARTIAL_USE_FULL_BUFFER = os.environ.get("QWEN3_PARTIAL_USE_FULL_BUFFER", "1") not in ("0", "false", "no", "")
# Hard safety cap：极端长录音（>300s）才生效，防止 partial 跑无限长音频
MAX_PARTIAL_AUDIO_SEC = float(os.environ.get("QWEN3_PARTIAL_MAX_AUDIO_SEC", "300"))
# 用 last partial 当 final，跳过 EOF 时的完整 final 推理。
# 条件：last partial 内容 >= 5 字 + 覆盖率 >= 0.85 (partial 看到的音频长 / 总音频长)。
# 收益：长录音 latency 46s -> <1s（partial 录音结束前已跑完）。
# 防御开关：USE_LAST_PARTIAL_AS_FINAL=0 回退老链全量 final 推理。
USE_LAST_PARTIAL_AS_FINAL = os.environ.get("USE_LAST_PARTIAL_AS_FINAL", "1") not in ("0", "false", "no", "")
PARTIAL_AS_FINAL_MIN_COVERAGE = float(os.environ.get("PARTIAL_AS_FINAL_MIN_COVERAGE", "0.65"))
# VAD-based chunking for long audio (业界主流：whisper-streaming / faster-whisper + pyannote VAD)。
# 长音频 (≥THRESHOLD_SEC) EOF 时按静音边界切成 MIN-MAX 秒短段，每段独立 Qwen3 推理后拼接。
# 解决 Qwen3 在 ≥30s 音频上的 EOS 提前截断 + 推理 0.5× 实时的固有问题。
VAD_CHUNKING_ENABLED = os.environ.get("VAD_CHUNKING_ENABLED", "1") not in ("0", "false", "no", "")
VAD_CHUNK_THRESHOLD_SEC = float(os.environ.get("VAD_CHUNK_THRESHOLD_SEC", "25"))
VAD_CHUNK_MIN_SEC = float(os.environ.get("VAD_CHUNK_MIN_SEC", "5"))
VAD_CHUNK_MAX_SEC = float(os.environ.get("VAD_CHUNK_MAX_SEC", "15"))
VAD_AGGRESSIVENESS = int(os.environ.get("VAD_AGGRESSIVENESS", "1"))  # 0-3, 越高越激进切
VAD_PADDING_MS = int(os.environ.get("VAD_PADDING_MS", "200"))

try:
    final_backend = get_final_backend()
except ValueError as e:
    log(f"FATAL: {e}")
    sys.exit(1)
if final_backend is not None and _IS_MAIN_PROCESS:
    final_backend.load()


def _seed_backend_state() -> None:
    """Propagate SNIPPETS + QWEN3_CONTEXT into stateful helpers (I5).
    Called once after initial vocab load and from reload_vocab()."""
    text_postprocess.set_snippets(SNIPPETS)
    if final_backend is not None:
        final_backend.update_context(QWEN3_CONTEXT)


_seed_backend_state()


def _vad_chunk_pcm(pcm_int16_bytes: bytes, sample_rate: int = 16000) -> list:
    """VAD-based chunking：按静音边界把长 PCM 切成 MIN-MAX 秒短段。
    每段 [start_byte, end_byte) 加 VAD_PADDING_MS overlap。
    返回 list[bytes] PCM 段，每段独立喂 Qwen3 推理。
    失败 (webrtcvad 不可用 / 全静音) 返回 [pcm_int16_bytes] 单元素 list 让外层走单次推理。"""
    if not _WEBRTCVAD_AVAILABLE:
        return [pcm_int16_bytes]
    frame_ms = 30  # webrtcvad 支持 10/20/30 ms
    bytes_per_sec = sample_rate * 2  # int16 mono
    frame_bytes = int(sample_rate * frame_ms / 1000) * 2
    total_frames = len(pcm_int16_bytes) // frame_bytes
    if total_frames == 0:
        return [pcm_int16_bytes]

    vad = webrtcvad.Vad(VAD_AGGRESSIVENESS)
    # 每帧标记 voice/silence
    voice_flags = []
    for i in range(total_frames):
        frame = pcm_int16_bytes[i * frame_bytes:(i + 1) * frame_bytes]
        try:
            voice_flags.append(vad.is_speech(frame, sample_rate))
        except Exception:
            voice_flags.append(True)  # 出错算 voice，宁多勿少

    # 累积 voice frames 成 segment；遇到 ≥10 连续 silence frames (300ms) → close segment
    # 段长 < MIN_SEC 继续累积；> MAX_SEC hard split
    min_frames = int(VAD_CHUNK_MIN_SEC * 1000 / frame_ms)
    max_frames = int(VAD_CHUNK_MAX_SEC * 1000 / frame_ms)
    silence_close_frames = int(300 / frame_ms)  # 300ms 静音算 segment 边界
    pad_frames = int(VAD_PADDING_MS / frame_ms)

    segments = []  # list of (start_frame, end_frame) 索引
    cur_start = None
    silence_run = 0
    for i, is_voice in enumerate(voice_flags):
        if is_voice:
            if cur_start is None:
                cur_start = i
            silence_run = 0
            if (i - cur_start + 1) >= max_frames:
                segments.append((cur_start, i + 1))
                cur_start = None
                silence_run = 0
        else:
            silence_run += 1
            if cur_start is not None and silence_run >= silence_close_frames:
                seg_len = (i - silence_run + 1) - cur_start
                if seg_len >= min_frames:
                    segments.append((cur_start, i - silence_run + 1))
                    cur_start = None
                    silence_run = 0
    # 收尾
    if cur_start is not None:
        seg_len = total_frames - cur_start
        if seg_len >= min_frames or not segments:
            segments.append((cur_start, total_frames))

    if not segments:
        return [pcm_int16_bytes]
    if len(segments) == 1:
        return [pcm_int16_bytes]  # 切不开就交给单次推理

    # 转回 bytes，加 padding overlap
    chunks = []
    for start_f, end_f in segments:
        s = max(0, start_f - pad_frames) * frame_bytes
        e = min(total_frames, end_f + pad_frames) * frame_bytes
        chunks.append(pcm_int16_bytes[s:e])
    return chunks


def _stitch_chunks(texts: list) -> str:
    """拼接 chunk 转写。相邻段 padding overlap 可能产生 ≥3 字开头重复，trim 掉。"""
    if not texts:
        return ""
    out = texts[0]
    for nxt in texts[1:]:
        if not nxt:
            continue
        # 找 out 末尾 vs nxt 开头的最长重叠 (3-20 字)
        overlap = 0
        max_check = min(20, len(out), len(nxt))
        for k in range(max_check, 2, -1):  # 从长到短找
            if out[-k:] == nxt[:k]:
                overlap = k
                break
        out += nxt[overlap:]
    return out


# qwen3_inference_lock 序列化 partial + final，防同模型并发 generate（batch=1 行为未定义）。
qwen3_inference_lock = asyncio.Lock()
# FunASR AutoModel.generate 大概率非线程安全 (内部缓存 + decoder state). 多连接同时
# 跑 paraformer.generate 会 race. 加锁串行化 (FunASR partial 单次 50ms, 串行不痛).
paraformer_inference_lock = asyncio.Lock()


async def transcribe_final_async(pcm_bytes: bytes, sample_rate: int = 16000,
                                 log_tag: str = "final") -> tuple:
    """Async wrapper around final_backend.transcribe(). lock 序列化推理，executor 跑同步推理。"""
    if final_backend is None or not final_backend.is_loaded:
        return ("", "")
    loop = asyncio.get_event_loop()
    async with qwen3_inference_lock:
        return await loop.run_in_executor(
            None, final_backend.transcribe, pcm_bytes, sample_rate, log_tag
        )

# 独立标点模型：在 paraformer 出最终 raw 文本后跑一遍，加 。，？！
# 比 LLM polish 快 50x（CPU 上 50ms vs GPU 上 LLM 2s），且保证一定有标点
punc_model = None
if PUNC_MODEL_NAME and _IS_MAIN_PROCESS:
    log(f"loading punctuation model {PUNC_MODEL_NAME} ...")
    t0 = time.time()
    try:
        punc_model = AutoModel(model=PUNC_MODEL_NAME, disable_update=True, log_level="WARNING")
        log(f"punc model ready in {time.time()-t0:.1f}s")
    except Exception as e:
        log(f"punc model load failed: {e} (continuing without punctuation)")
        punc_model = None


def add_punctuation(text: str) -> str:
    if not text or punc_model is None:
        return text
    try:
        t = time.time()
        res = punc_model.generate(input=text)
        if res and isinstance(res, list) and res[0].get("text"):
            out = res[0]["text"]
            log(f"  punc {time.time()-t:.2f}s '{text[:30]}' -> '{out[:30]}'")
            return out
    except Exception as e:
        log(f"  punc failed: {e}")
    return text


def post_learn_hotwords(streaming: str, final: str) -> None:
    """Fire-and-forget：把 paraformer raw + Qwen3 final 送给 gateway 学习。失败静默。"""
    if not LEARN_URL or not streaming or not final or streaming.strip() == final.strip():
        return
    try:
        body = json.dumps({"streaming": streaming, "final": final}, ensure_ascii=False).encode("utf-8")
        req = urllib.request.Request(
            LEARN_URL, data=body,
            headers={"Content-Type": "application/json; charset=utf-8"},
        )
        with urllib.request.urlopen(req, timeout=LEARN_TIMEOUT) as resp:
            data = json.load(resp)
        n = len(data.get("candidates") or [])
        if n:
            log(f"  learn posted -> {n} candidates")
    except Exception as e:
        log(f"  learn post failed: {e}")


def polish_text(raw: str) -> str:
    """送 mini-gateway /v1/text/polish 拿 LLM 清洗后结果。失败时退原文。"""
    if not raw or not POLISH_URL:
        return raw
    try:
        body = json.dumps({"text": raw}, ensure_ascii=False).encode("utf-8")
        req = urllib.request.Request(
            POLISH_URL, data=body,
            headers={"Content-Type": "application/json; charset=utf-8"},
        )
        t = time.time()
        with urllib.request.urlopen(req, timeout=POLISH_TIMEOUT) as resp:
            data = json.load(resp)
        cleaned = (data.get("text") or "").strip()
        log(f"  polish {time.time()-t:.2f}s '{raw[:30]}' -> '{cleaned[:30]}'")
        return cleaned or raw
    except Exception as e:
        log(f"  polish failed: {e} (fallback to raw)")
        return raw


async def handle(websocket):
    """
    架构：producer/consumer 解耦 Paraformer 跟 Qwen3。
    - 主协程读 WS 消息：binary → 推 PCM 进 pcm_queue + pcm_buffer
    - 后台 paraformer_consumer task：从 queue 取 PCM 跑流式推理 + 发 partial
    - EOF 到达主协程时，**立即** 在 pcm_buffer 上跑 Qwen3，不等 consumer drain
    - Qwen3 成功：发 final，sentinel 让 consumer 退（处理掉的 partial 已经发了，
      没处理掉的不要紧——final 把它覆盖）
    - Qwen3 失败：await consumer drain，跑 is_final + ct-punc + polish 老链
    并发安全：paraformer 跟 Qwen3 send 都走 send_lock，避免 JSON 帧交叉
    """
    addr = websocket.remote_address
    log(f"+ client {addr}")
    cache = streaming_backend.new_session_state()
    accumulated = ""         # paraformer 流式累积的 raw 文本
    pcm_buffer = bytearray() # 全程 PCM 缓冲，给 Qwen3-ASR 跑 final
    chunk_count = 0
    t_first_chunk = None

    pcm_queue: asyncio.Queue = asyncio.Queue()
    send_lock = asyncio.Lock()
    loop = asyncio.get_event_loop()

    async def paraformer_consumer():
        """后台跑 paraformer 流式推理。每次 generate 套 run_in_executor
        避免阻塞 event loop（修原本同步 generate 的 anti-pattern）。"""
        nonlocal accumulated
        while True:
            try:
                item = await pcm_queue.get()
            except asyncio.CancelledError:
                break
            if item is None:  # sentinel = stop
                break
            pcm = item
            try:
                async with paraformer_inference_lock:
                    txt = await loop.run_in_executor(
                        None,
                        lambda p=pcm: streaming_backend.generate_chunk(
                            p, cache, is_final=False, hotwords=HOTWORDS
                        )
                    )
            except Exception as e:
                log(f"  paraformer task err: {e}")
                continue
            if not txt:
                continue
            accumulated += txt
            try:
                async with send_lock:
                    await websocket.send(json.dumps(
                        {"type": "partial", "text": accumulated},
                        ensure_ascii=False
                    ))
            except websockets.exceptions.ConnectionClosed:
                # client 已收到 final 或断开，consumer 自然退
                break
            except Exception as e:
                log(f"  partial send err: {e}")
                break

    consumer_task = asyncio.create_task(paraformer_consumer())

    # ─────────────────────────────────────────────────────────
    # Speculative Qwen3 partial (type4me 模式):
    # 每 PARTIAL_INTERVAL_SEC 检查 pcm_buffer 是否新增足够样本，在最后
    # MAX_PARTIAL_AUDIO_SEC 秒上跑一次 Qwen3 partial。inflight check =
    # cooperative skip (不强行中断 GPU kernel)。
    # ─────────────────────────────────────────────────────────
    samples_per_sec_bytes = 16000 * 2  # mono int16
    partial_threshold_bytes = int(PARTIAL_INTERVAL_SEC * samples_per_sec_bytes)
    max_partial_bytes = int(MAX_PARTIAL_AUDIO_SEC * samples_per_sec_bytes)
    last_partial_at_bytes = 0
    inflight_partial: asyncio.Task | None = None
    partial_seq = 0
    # last partial 结果缓存：EOF 时如果覆盖率够，直接当 final 用免去全量推理
    last_partial_text = ""
    last_partial_lang = ""
    last_partial_audio_sec = 0.0
    # History (Phase 1 of type4me parity). 各 final 路径填好这些字段, finally 块写 jsonl.
    history_rec = {
        "ts_start": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "client_addr": f"{addr[0]}:{addr[1]}",
        "partial_count_qwen3": 0,
        "partial_inference_total_s": 0.0,
        "final_text": "",
        "final_backend": "",
        "final_derived_from": "",
        "language": "",
        "partial_as_final_used": False,
        "partial_as_final_coverage": None,
        "vad_chunks_used": 0,
    }

    async def _do_qwen3_partial(snapshot: bytes, seq: int):
        nonlocal last_partial_text, last_partial_lang, last_partial_audio_sec
        t_inf = time.time()
        text, lang = await transcribe_final_async(snapshot, 16000, log_tag="qwen3-asr-partial")
        history_rec["partial_count_qwen3"] += 1
        history_rec["partial_inference_total_s"] += time.time() - t_inf
        if not text:
            return
        # 缓存结果给 EOF 路径用（用 partial 当 final 时复用）
        last_partial_text = text
        last_partial_lang = lang
        last_partial_audio_sec = len(snapshot) / samples_per_sec_bytes
        try:
            async with send_lock:
                await websocket.send(json.dumps(
                    {"type": "partial", "text": text,
                     "language": lang,
                     "backend": "qwen3-asr-partial",
                     "seq": seq},
                    ensure_ascii=False
                ))
        except websockets.exceptions.ConnectionClosed:
            pass
        except Exception as e:
            log(f"  qwen3-partial send err: {e}")

    async def qwen3_partial_loop():
        nonlocal last_partial_at_bytes, inflight_partial, partial_seq
        try:
            while True:
                await asyncio.sleep(0.3)  # 检查频率，比 INTERVAL 更密以减少最坏延迟
                new_bytes = len(pcm_buffer) - last_partial_at_bytes
                if new_bytes < partial_threshold_bytes:
                    continue
                if inflight_partial is not None and not inflight_partial.done():
                    continue  # cooperative skip：上一轮还在跑，跳过本轮
                last_partial_at_bytes = len(pcm_buffer)
                # 全量 PCM（默认） vs tail-only（fallback）。全量让 partial 不丢开头，
                # 长录音 EOF 时 last partial 直接当 final 用，免去 EOF 后再跑全量推理。
                if QWEN3_PARTIAL_USE_FULL_BUFFER:
                    snapshot = bytes(pcm_buffer[-max_partial_bytes:]) if len(pcm_buffer) > max_partial_bytes else bytes(pcm_buffer)
                else:
                    snapshot = bytes(pcm_buffer[-max_partial_bytes:])
                partial_seq += 1
                inflight_partial = asyncio.create_task(
                    _do_qwen3_partial(snapshot, partial_seq)
                )
        except asyncio.CancelledError:
            pass

    qwen3_partial_task = None
    if QWEN3_PARTIAL_ENABLED and final_backend is not None and final_backend.is_loaded:
        qwen3_partial_task = asyncio.create_task(qwen3_partial_loop())

    # 上传速率诊断：每 1s 报告 chunks/s + 最大 chunk gap，
    # 用来定位 PS client / SSH tunnel 是否真的丢帧。
    rate_window_start = None
    rate_window_chunks = 0
    last_chunk_t = None
    max_chunk_gap_ms = 0.0

    try:
        async for msg in websocket:
            if isinstance(msg, (bytes, bytearray)):
                now = time.time()
                if t_first_chunk is None:
                    t_first_chunk = now
                    rate_window_start = now
                if last_chunk_t is not None:
                    gap_ms = (now - last_chunk_t) * 1000
                    if gap_ms > max_chunk_gap_ms:
                        max_chunk_gap_ms = gap_ms
                last_chunk_t = now
                rate_window_chunks += 1
                if now - rate_window_start >= 1.0:
                    elapsed = now - rate_window_start
                    log(f"  rx {rate_window_chunks} chunks in {elapsed:.2f}s = {rate_window_chunks/elapsed:.1f}/s (max gap {max_chunk_gap_ms:.0f}ms)")
                    rate_window_start = now
                    rate_window_chunks = 0
                    max_chunk_gap_ms = 0.0
                pcm_buffer.extend(msg)
                pcm = np.frombuffer(msg, dtype=np.int16).astype(np.float32) / 32768.0
                if pcm.size == 0:
                    continue
                chunk_count += 1
                await pcm_queue.put(pcm)
            else:
                # text message
                if isinstance(msg, str) and msg.strip().upper() == "EOF":
                    log(f"  EOF after {chunk_count} chunks ({len(pcm_buffer)} bytes pcm)")
                    # sentinel：consumer 处理完当前正在跑的那个 chunk 就退；
                    # 我们**不等**它（关键：跳过队列里剩下的 chunk）
                    await pcm_queue.put(None)
                    # 停掉 partial 调度循环（不再 spawn 新 partial），
                    # 但 **不 cancel** 正在跑的 inflight partial——它的结果可能能当 final 用
                    if qwen3_partial_task is not None and not qwen3_partial_task.done():
                        qwen3_partial_task.cancel()
                    if inflight_partial is not None and not inflight_partial.done():
                        try:
                            await asyncio.wait_for(inflight_partial, timeout=30)
                        except asyncio.TimeoutError:
                            log("  inflight partial timeout (30s); fallback to full final")
                        except Exception as e:
                            log(f"  inflight partial err while waiting: {e}")

                    # 决策：last partial 覆盖率够就当 final 用，否则跑全量
                    total_audio_sec = len(pcm_buffer) / samples_per_sec_bytes
                    coverage = (last_partial_audio_sec / total_audio_sec) if total_audio_sec > 0 else 0
                    use_partial_as_final = (
                        USE_LAST_PARTIAL_AS_FINAL
                        and final_backend is not None and final_backend.is_loaded
                        and last_partial_text
                        and len(last_partial_text) >= 5
                        and coverage >= PARTIAL_AS_FINAL_MIN_COVERAGE
                    )

                    qwen3_text = ""
                    qwen3_lang = ""
                    derived_from = ""
                    history_rec["partial_as_final_coverage"] = round(coverage, 3)
                    if use_partial_as_final:
                        log(f"  using last partial as final (coverage {coverage:.2f}, {len(last_partial_text)} chars, saved ~{total_audio_sec/2:.1f}s inference)")
                        qwen3_text = last_partial_text
                        qwen3_lang = last_partial_lang
                        derived_from = "last_partial"
                        history_rec["partial_as_final_used"] = True
                    elif final_backend is not None and final_backend.is_loaded:
                        if last_partial_text:
                            log(f"  last partial coverage {coverage:.2f} < {PARTIAL_AS_FINAL_MIN_COVERAGE}, running full final")
                        # 长音频走 VAD chunking：按静音边界切短段，每段独立推理后拼接，
                        # 解决 Qwen3 在 ≥30s 上 EOS 提前截断 + 推理 0.5× 实时的问题
                        if (VAD_CHUNKING_ENABLED and _WEBRTCVAD_AVAILABLE
                                and total_audio_sec >= VAD_CHUNK_THRESHOLD_SEC):
                            chunks = _vad_chunk_pcm(bytes(pcm_buffer), 16000)
                            if len(chunks) > 1:
                                log(f"  VAD chunked {total_audio_sec:.1f}s into {len(chunks)} segments")
                                history_rec["vad_chunks_used"] = len(chunks)
                                texts = []
                                for i, chunk_bytes in enumerate(chunks):
                                    t, l = await transcribe_final_async(
                                        chunk_bytes, 16000,
                                        log_tag=f"qwen3-asr-chunk-{i+1}/{len(chunks)}"
                                    )
                                    if t:
                                        texts.append(t)
                                        if not qwen3_lang:
                                            qwen3_lang = l
                                qwen3_text = _stitch_chunks(texts)
                                derived_from = f"vad-chunked-{len(chunks)}"
                            else:
                                # VAD 切不开（无明显静音边界）退到单次全量推理
                                qwen3_text, qwen3_lang = await transcribe_final_async(
                                    bytes(pcm_buffer), 16000
                                )
                                derived_from = "single"
                        else:
                            qwen3_text, qwen3_lang = await transcribe_final_async(
                                bytes(pcm_buffer), 16000
                            )
                            derived_from = "single"

                    if qwen3_text:
                        qwen3_text = apply_mappings(qwen3_text)
                        final_payload = {
                            "type": "final", "text": qwen3_text,
                            "language": qwen3_lang,
                            "raw_streaming": accumulated,
                            "backend": "qwen3-asr",
                        }
                        if derived_from:
                            final_payload["derived_from"] = derived_from
                        async with send_lock:
                            await websocket.send(json.dumps(final_payload, ensure_ascii=False))
                        history_rec["final_text"] = qwen3_text
                        history_rec["final_backend"] = "qwen3-asr"
                        history_rec["final_derived_from"] = derived_from
                        history_rec["language"] = qwen3_lang or ""
                        # fire-and-forget：paraformer raw vs qwen3 final 学新热词
                        loop.run_in_executor(
                            None, post_learn_hotwords, accumulated, qwen3_text
                        )
                    else:
                        # Fallback 老链：等 paraformer 真正 drain 完才 is_final
                        try:
                            await asyncio.wait_for(consumer_task, timeout=30)
                        except asyncio.TimeoutError:
                            log("  fallback: consumer drain timeout (30s)")
                        try:
                            async with paraformer_inference_lock:
                                tail = await loop.run_in_executor(
                                    None,
                                    lambda: streaming_backend.generate_chunk(
                                        np.zeros(1, dtype=np.float32),
                                        cache, is_final=True, hotwords=HOTWORDS
                                    )
                                )
                        except Exception as e:
                            log(f"  final inference err: {e}")
                            tail = ""
                        if tail:
                            accumulated += tail
                        punctuated = await loop.run_in_executor(
                            None, add_punctuation, accumulated
                        )
                        polished = await loop.run_in_executor(
                            None, polish_text, punctuated
                        )
                        polished = apply_mappings(polished)
                        async with send_lock:
                            await websocket.send(json.dumps(
                                {"type": "final", "text": polished,
                                 "punctuated": punctuated, "raw": accumulated,
                                 "backend": "paraformer+ctpunc+polish"},
                                ensure_ascii=False
                            ))
                        history_rec["final_text"] = polished
                        history_rec["final_backend"] = "paraformer+ctpunc+polish"
                    break
    except websockets.exceptions.ConnectionClosed:
        pass
    except Exception as e:
        log(f"  handler err: {e}")
    finally:
        # consumer 清理：sentinel 已发过；若它还卡着就 cancel
        if not consumer_task.done():
            consumer_task.cancel()
            try:
                await asyncio.gather(consumer_task, return_exceptions=True)
            except Exception:
                pass
        # qwen3 partial 调度 + inflight 推理 cancel
        if qwen3_partial_task is not None and not qwen3_partial_task.done():
            qwen3_partial_task.cancel()
        if inflight_partial is not None and not inflight_partial.done():
            inflight_partial.cancel()
        try:
            tasks_to_clean = [t for t in (qwen3_partial_task, inflight_partial) if t is not None]
            if tasks_to_clean:
                await asyncio.gather(*tasks_to_clean, return_exceptions=True)
        except Exception:
            pass
        dur = (time.time() - t_first_chunk) if t_first_chunk else 0
        log(f"- client {addr} closed; chunks={chunk_count} dur={dur:.1f}s final='{accumulated[:60]}'")
        # Phase 1 history: append finalized rec to monthly JSONL.
        history_rec["ts_end"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        history_rec["audio_dur_s"] = round(dur, 2)
        history_rec["chunks_received"] = chunk_count
        history_rec["paraformer_raw"] = accumulated
        history_rec["qwen3_backend"] = final_backend.engine_actual if final_backend else None
        history_rec["partial_inference_total_s"] = round(history_rec["partial_inference_total_s"], 2)
        _history_append(history_rec)


async def main():
    # SIGUSR1 -> reload_vocab. Used by mini-gateway /v1/vocab/reload endpoint
    # to skip the 30s mtime poll. Sync (file I/O ~ms) so safe in signal callback.
    loop = asyncio.get_running_loop()
    try:
        loop.add_signal_handler(signal.SIGUSR1, _on_sigusr1_reload)
        log("registered SIGUSR1 handler for vocab reload")
    except NotImplementedError:
        log("SIGUSR1 handler unsupported on this platform; mtime watcher only")
    watcher_task = asyncio.create_task(vocab_mtime_watcher())
    try:
        async with websockets.serve(handle, HOST, PORT, max_size=4 * 1024 * 1024):
            log(f"streaming server listening on ws://{HOST}:{PORT}")
            await asyncio.Future()
    finally:
        watcher_task.cancel()


def _on_sigusr1_reload() -> None:
    log("SIGUSR1 received: triggering vocab reload")
    reload_vocab()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
