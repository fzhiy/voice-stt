"""
Text post-processing helpers for ASR output.

Moved from funasr-stream-server.py so Qwen3ASRBackend can import them
(the hyphenated server filename precludes a clean import path back into it).

Reload hook: call set_snippets(d) from reload_vocab() every time snippets
are reloaded so runtime hotword changes continue to affect Qwen3 final text (I5).
"""
import re

import numpy as np


# 最后一道兜底：Qwen3-ASR 仍然容易把 "Claude" 听成 "Cloud"，单条 string-level 修正
# 比让 LLM 再跑一次划算。键越长越优先（按词长降序）。case-insensitive 匹配，所以
# 只列 canonical 写法即可，"cloud code" / "Cloud Code" / "CLOUD CODE" 都会被替换。
QWEN3_POST_CORRECT = {
    "Cloud Cloud Client": "Claude Code CLI",
    "Cloud Code Client": "Claude Code CLI",
    "Cloud Code CLI": "Claude Code CLI",
    "Cloud Cloud CLI": "Claude Code CLI",
    "Cloud Cloud Code": "Claude Code",
    "Cloud Cloud": "Claude Code",
    "Cloud Code": "Claude Code",
    "Cloud Max": "Claude Max",
    "Cloud Opus": "Claude Opus",
    "Cloud Sonnet": "Claude Sonnet",
    "Cloud Haiku": "Claude Haiku",
    "Cloud Session": "Claude Session",
    "Code X": "Codex",
    # Brand: voice-stt — ASR often mishears the letter-by-letter spelling
    "Voice S T T": "voice-stt",
    "Voice SSTT": "voice-stt",
    "Voice SST": "voice-stt",
    "Voice STT": "voice-stt",
    "Voice的S T T": "voice-stt",   # ASR 在 Voice 跟字母间塞 的
    "Voice SDK": "voice-stt",      # 2026-05-18 起加,实测高频错听形 (Voice STT/voice-stt 都被听成 Voice SDK)
    # Brand: voice-claude (archive) — still referenced when discussing OSS prep history
    "Voice Cloud": "voice-claude",
    # Brand: Qwen3 (Tongyi 官方英文写法) — Chinese homophones + English-pronunciation variants
    # 统一 normalize 到官方 "Qwen3",不保留 "千问三" 这个中文译名 (用户要求 2026-05-18)
    "千问三": "Qwen3",
    "千万三": "Qwen3",
    "queen 三": "Qwen3",
    "queen three": "Qwen3",
    "queen 3": "Qwen3",
    "Quin Three": "Qwen3",
    "Quin 三": "Qwen3",
    "Quin 3": "Qwen3",
    "Quinn Three": "Qwen3",        # 实测变体,双 n
    "Quinn 三": "Qwen3",
    "Quinn 3": "Qwen3",
    # Brand: Claude Opus — Ops 是 Opus 截短/弱化形, Mac 是 Max
    "Cloud Ops Mac": "Claude Opus Max",   # 复合,优先于单独 Cloud Ops
    "Cloud Ops": "Claude Opus",
    "CloudOps": "Claude Opus",            # 无空格连写形
    # Reasoning level: Effort 被听成 Fert
    "Max Fert": "Max Effort",
    # Brand: Tailscale — 被空格拆成 Tail Scale, 或听成 Tesscale
    "Tail Scale": "Tailscale",
    "Tesscale": "Tailscale",
}

# 编译一次，按 key 长度降序避免短键先吃掉长键的覆盖
_QWEN3_POST_CORRECT_PATTERNS = [
    (re.compile(re.escape(k), re.IGNORECASE), v)
    for k, v in sorted(QWEN3_POST_CORRECT.items(), key=lambda kv: -len(kv[0]))
]


# 语气词清洗 (用户要求把"嗯/啊/呃 um uh"等 filler 在送给 agent 之前去掉, 又不想加
# LLM polish 那 1-2s 延迟). 用保守的 regex: 只清楚明显的语气词, 不动可能是内容的词
# (例 "like" / "这个" 因常做内容词跳过). 词边界 + 跨标点不残留.
_FILLER_RE = re.compile(
    r"""(?xi)                              # verbose + case-insensitive
    (?:^|(?<=[\s，。、！？,!?.\;:]))         # 前面是 BOS / 空白 / 标点 (lookbehind 长度都=1, 安全)
    (?:                                    # ----- patterns -----
        嗯+ | 啊+ | 呃+ | 哦+ |              # CN 单字语气词 (连续多个一起删)
        额额* |                              # "额" 网络口语化
        就是说\s*(?=[，。、！？,!?.])?      | # 仅当后面跟标点才删 (内容里 "就是说" 留)
        那个那个 |                           # 双重 "那个" 一定是 filler
        \bum+\b | \buh+\b | \bah+\b | \ber+\b | # EN 语气词
        \bhmm+\b
    )
    \s*                                    # 顺便吃后面空格
    """,
    re.VERBOSE | re.IGNORECASE,
)


def remove_fillers(text: str) -> str:
    if not text:
        return text
    out = _FILLER_RE.sub("", text)
    # 连续空格 / 空格前的标点收一下
    out = re.sub(r"\s+", " ", out).strip()
    out = re.sub(r"\s+([，。、！？,!?.])", r"\1", out)
    out = re.sub(r"^[，。、！？,!?.\s]+", "", out)  # 句首残留标点
    return out


def qwen3_post_correct(text: str) -> str:
    """对 Qwen3-ASR 输出做 deterministic 字符串替换，修正高频同音误识。"""
    if not text:
        return text
    out = text
    for pat, repl in _QWEN3_POST_CORRECT_PATTERNS:
        out = pat.sub(repl, out)
    out = remove_fillers(out)
    out = expand_snippets(out)
    return out


# Snippet replacement (type4me parity P2): hotwords.yaml 里 snippets: 区段定义
# `key: value` 对, 文本里出现 key (case-insensitive, 词边界 \b 保护) 就替换为 value.
# 例: snippets.my-email = "<MAINTAINER_EMAIL>" → 语音"my email"转 "my-email"被它扩展.
SNIPPETS: dict = {}


def set_snippets(d: dict) -> None:
    """Reload hook: server calls this from reload_vocab() to keep SNIPPETS live (I5)."""
    global SNIPPETS
    SNIPPETS = d


def expand_snippets(text: str) -> str:
    """文本里出现 snippet key (word-boundary, case-insensitive) 替换为 value.
    短 key 先长后短按 len 降序排, 防止短 key 吞长 key."""
    if not text or not SNIPPETS:
        return text
    out = text
    for key in sorted(SNIPPETS, key=len, reverse=True):
        # 用 regex 词边界, 避免 my-email 吃掉 my-email-2
        pattern = r"\b" + re.escape(key) + r"\b"
        out = re.sub(pattern, SNIPPETS[key], out, flags=re.IGNORECASE)
    return out


def _trim_silence(arr: np.ndarray, sample_rate: int,
                  threshold: float = 0.015,
                  pad_ms: int = 100,
                  win_ms: int = 50):
    """裁掉首尾低于阈值的窗口；只裁首尾，不动中间停顿（保留 prosody）。
    全段低于阈值返回空数组，让调用方跳过 Qwen3 走 fallback。
    threshold=0.015（float32 [-1,1] 标度约 -36dB）。0.005 实测穿不透环境噪声
    （笔记本风扇/键盘），所有窗口 RMS 都顶上去导致根本不裁。pad=100ms 防爆破音
    （P/T/K 等）起音被吞。返回 (裁后数组, rms_stats_for_log)。"""
    if arr.size == 0:
        return arr, None
    win = max(1, int(sample_rate * win_ms / 1000))
    n_full = arr.size // win
    if n_full == 0:
        return arr, None  # 太短分不出一个完整窗口；交给上层 200ms 早返回兜底
    rms = np.sqrt(np.mean(arr[: n_full * win].reshape(n_full, win) ** 2, axis=1))
    stats = (float(rms.min()), float(np.percentile(rms, 50)), float(rms.max()))
    above = np.where(rms > threshold)[0]
    if above.size == 0:
        return arr[:0], stats
    pad = int(sample_rate * pad_ms / 1000)
    start = max(0, above[0] * win - pad)
    end = min(arr.size, (above[-1] + 1) * win + pad)
    return arr[start:end], stats
