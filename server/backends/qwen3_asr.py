import os
import time
from pathlib import Path

import numpy as np

from .base import FinalPassBackend

import text_postprocess


# Read env vars at import time. Defaults tuned for a 12 GB GPU shared with
# other services (the common "12-24 GB consumer card" target). On bigger
# cards or ASR-dedicated boxes, override via .env.server (see server/README.md
# "Tuning presets" section). Empirical floor on 12 GB / 0.6B is GPU_FRAC=0.5;
# below that vLLM bails with "No available memory for the cache blocks".
QWEN3_ASR_PATH = os.environ.get("QWEN3_ASR_PATH", str(Path.home() / ".cache" / "qwen3-asr-0.6b"))
QWEN3_BACKEND = os.environ.get("QWEN3_BACKEND", "vllm").lower()
QWEN3_VLLM_GPU_FRAC = float(os.environ.get("QWEN3_VLLM_GPU_FRAC", "0.5"))
QWEN3_VLLM_MAX_MODEL_LEN = int(os.environ.get("QWEN3_VLLM_MAX_MODEL_LEN", "4096"))
QWEN3_VLLM_BATCH = int(os.environ.get("QWEN3_VLLM_BATCH", "4"))
# Optional vLLM quantization. fp8 = on-the-fly W8A16 dynamic quant for Ada/Hopper GPUs,
# halves weight footprint (~3.9GB → ~2GB for 1.7B). Empty = bf16 (no quant).
QWEN3_VLLM_QUANTIZATION = os.environ.get("QWEN3_VLLM_QUANTIZATION", "").strip() or None
# Optional CPU offload (in GB). Trades latency for GPU memory by keeping N GB of
# weights on CPU and swapping to GPU on demand. Use only if quantization can't be applied.
QWEN3_VLLM_CPU_OFFLOAD_GB = float(os.environ.get("QWEN3_VLLM_CPU_OFFLOAD_GB", "0") or "0")
# Language tag passed to Qwen3-ASR per inference. Default "none" passes Python
# None — qwen_asr's self-detect mode (the model picks the language(s) itself).
# Verified 2026-05-21 as the best option for mixed Chinese-English dictation: no
# EOS truncation on a 63s utterance, ~87% English-term preservation vs near-total
# over-Sinicization ("Sonnet"->"少量的", "subagent"->"沙威酱") under a hard lock.
# Pass a specific language name to hard-lock the decoder instead — set
# QWEN3_LANGUAGE=Chinese if you hit the EOS-truncation bug some older qwen_asr
# versions showed with self-detect on long mixed audio (the 2026-05-15 reason the
# lock existed; no longer reproduces on the current vLLM/FP8 stack). Empty and
# "none" both map to None. Do NOT pass "auto" — qwen_asr rejects that literal
# string with "Unsupported language" (it is not a valid Qwen3-ASR value).
QWEN3_LANGUAGE = os.environ.get("QWEN3_LANGUAGE", "none").strip()
# Max new tokens per Qwen3-ASR inference. Bumped from the historical 512 to 4096
# (matches the qwen_asr package's own demo defaults). Higher value is safe with
# vLLM — it allocates KV cache per actual emission, not the cap.
QWEN3_MAX_NEW_TOKENS = int(os.environ.get("QWEN3_MAX_NEW_TOKENS", "4096"))
TRIE_BIASING_ENABLED = os.environ.get("TRIE_BIASING_ENABLED", "0") not in ("0", "false", "no", "")


def _log(*a):
    print(f"[{time.strftime('%H:%M:%S')}]", *a, flush=True)


class Qwen3ASRBackend(FinalPassBackend):
    """Qwen3-ASR backend for one-shot full-utterance transcription.

    Reproduces the vLLM -> transformers fallback chain from
    funasr-stream-server.py:404-429 and the qwen3_transcribe() body (548-595).
    """

    def __init__(self) -> None:
        self.is_loaded: bool = False
        self._model = None
        self._engine_actual: str | None = None
        self._context: str = ""

    def load(self) -> None:
        """Load Qwen3-ASR model. vLLM -> transformers fallback chain."""
        _log(f"loading Qwen3-ASR from {QWEN3_ASR_PATH} (requested backend={QWEN3_BACKEND}) ...")
        t0 = time.time()
        # 链: vllm → transformers → None. 显式 transformers 跳过 vllm.
        try_vllm = QWEN3_BACKEND in ("vllm", "auto")
        if try_vllm:
            try:
                self._model = self._load_vllm()
                self._engine_actual = "vllm"
                self.is_loaded = True
                _log(f"Qwen3-ASR ready in {time.time()-t0:.1f}s (backend=vllm)")
                return
            except Exception as e:
                _log(f"WARN: vLLM backend failed ({e!r}), falling back to transformers (SLOW: ~20-50x slower than vLLM).")
                _log("WARN: to use vLLM, ensure CUDA_HOME=/usr/local/cuda-13.0 PATH=/usr/local/cuda-13.0/bin:$PATH is exported.")
                t0 = time.time()
        if self._model is None:
            try:
                self._model = self._load_transformers()
                self._engine_actual = "transformers"
                self.is_loaded = True
                slow_note = " — SLOW (~20-50x slower than vLLM)" if try_vllm else ""
                _log(f"Qwen3-ASR ready in {time.time()-t0:.1f}s (backend=transformers{slow_note})")
            except Exception as e:
                _log(f"Qwen3-ASR load failed (transformers): {e} — final will fall back to paraformer + ct-punc + LLM polish")
                self._model = None
                self._engine_actual = None
                self.is_loaded = False

    def _load_vllm(self):
        import torch  # noqa: F401
        from qwen_asr import Qwen3ASRModel
        # JIT 内核首次会在 ~/.cache/flashinfer/ 编译, 需要 PATH 含 nvcc 12+ (compute_89 支持).
        # enforce_eager=True 关 CUDA graph 省 1-2GB 显存 (4070Ti 12GB 跟 Paraformer / Punc 共享).
        kwargs = dict(
            gpu_memory_utilization=QWEN3_VLLM_GPU_FRAC,
            max_model_len=QWEN3_VLLM_MAX_MODEL_LEN,
            enforce_eager=True,
            max_inference_batch_size=QWEN3_VLLM_BATCH,
            max_new_tokens=QWEN3_MAX_NEW_TOKENS,
            dtype="bfloat16",
        )
        if QWEN3_VLLM_QUANTIZATION:
            kwargs["quantization"] = QWEN3_VLLM_QUANTIZATION
            _log(f"  enabling vLLM quantization={QWEN3_VLLM_QUANTIZATION}")
        if QWEN3_VLLM_CPU_OFFLOAD_GB > 0:
            kwargs["cpu_offload_gb"] = QWEN3_VLLM_CPU_OFFLOAD_GB
            _log(f"  enabling vLLM cpu_offload_gb={QWEN3_VLLM_CPU_OFFLOAD_GB}")
        if TRIE_BIASING_ENABLED:
            from biasing.hotword_lp import HotwordTriePerReqLP  # deferred — keeps vLLM/torch off the flag-off path
            kwargs["logits_processors"] = [HotwordTriePerReqLP]
        return Qwen3ASRModel.LLM(QWEN3_ASR_PATH, **kwargs)

    def _load_transformers(self):
        import torch
        from qwen_asr import Qwen3ASRModel
        return Qwen3ASRModel.from_pretrained(
            QWEN3_ASR_PATH,
            dtype=torch.bfloat16,
            device_map="cuda:0",
            max_inference_batch_size=1,
            max_new_tokens=QWEN3_MAX_NEW_TOKENS,
        )

    @property
    def engine_actual(self) -> str | None:
        """For history metadata. Returns 'vllm' / 'transformers' / None (I7)."""
        return self._engine_actual

    @property
    def would_use_vllm(self) -> bool:
        """True if this backend will attempt to load via vLLM (checked pre-load).

        Used by funasr-stream-server.py to gate the pre-fork trie build without
        calling load() first. Reads QWEN3_BACKEND at module-import time (same
        source as the load() decision).
        """
        return QWEN3_BACKEND in ("vllm", "auto")

    @property
    def tokenizer(self):
        """Return the underlying tokenizer (Qwen2TokenizerFast-compatible).

        Raises AttributeError if the model has not been loaded yet (self._model
        is None) or if the backend fell back to transformers (which doesn't
        expose a processor.tokenizer). Only vLLM path needs this for trie build.
        """
        if self._model is None:
            raise AttributeError(
                "Qwen3ASRBackend.tokenizer accessed before load() — call load() first, "
                "or use a standalone Qwen3ASRProcessor.from_pretrained() for pre-fork trie build."
            )
        try:
            return self._model.processor.tokenizer
        except AttributeError as exc:
            raise AttributeError(
                f"Qwen3ASRBackend.tokenizer: unexpected model structure ({exc}). "
                "Check qwen_asr version or use Qwen3ASRProcessor.from_pretrained()."
            ) from exc

    def update_context(self, context: str) -> None:
        """Server calls this from reload_vocab() to keep QWEN3_CONTEXT fresh (I5)."""
        self._context = context

    def transcribe(
        self,
        pcm_int16_bytes: bytes,
        sample_rate: int = 16000,
        log_tag: str = "final",
    ) -> tuple[str, str]:
        """跑 Qwen3-ASR 在完整音频上。返回 (text, language)。失败回退 ('', '')

        `context=self._context` 把整个 hotwords.yaml + 提示作为 system message 传给模型，
        bias 它倾向于我们的术语写法（Claude Code 而非 Cloud Code 等）。再叠加一层
        deterministic string-level post-correction 兜住高频残留。

        log_tag 用于区分 final / partial 调用在日志里的标识。"""
        if self._model is None or not pcm_int16_bytes:
            return ("", "")
        try:
            arr = np.frombuffer(pcm_int16_bytes, dtype=np.int16).astype(np.float32) / 32768.0
            # 裁首尾静音：防 Qwen3 在静音段 hallucinate 出 "嗯啊好的 / 它不是好的" 之类
            orig_size = arr.size
            arr, rms_stats = text_postprocess._trim_silence(arr, sample_rate)
            if arr.size < sample_rate * 0.2:  # 裁完 < 200ms 太短不跑（含全静音情况）
                if rms_stats:
                    _log(f"  qwen3-asr skip: trimmed to {arr.size/sample_rate:.2f}s, rms min/p50/max={rms_stats[0]:.4f}/{rms_stats[1]:.4f}/{rms_stats[2]:.4f}")
                return ("", "")
            t = time.time()
            # QWEN3_LANGUAGE (module top): "none"/"" -> Python None (self-detect,
            # the default); a specific name ("Chinese", "English", …) hard-locks
            # the decoder. "auto" is intentionally NOT mapped — qwen_asr rejects
            # that literal string with "Unsupported language", so a stale config
            # that sets it will (correctly) fail loud rather than silently degrade.
            lang_arg = QWEN3_LANGUAGE if QWEN3_LANGUAGE.lower() not in ("", "none") else None
            results = self._model.transcribe(
                audio=(arr, sample_rate),
                context=self._context,
                language=lang_arg,
            )
            if not results:
                return ("", "")
            raw = (results[0].text or "").strip()
            # Context-echo guard: 短/弱音频 (尤其 PTT 启动 pre-roll 段) 偶尔触发 hallucination,
            # 模型放弃听音频, 直接回 context (system prompt) 里的 hotwords 列表片段当 transcription.
            # 实测 4 例: rms_p50 0.03~0.10, 时长 0.5~1.5s, 输出逐字逐句对应
            # hotwords.yaml 的 user_added 段 ('API, pane, fork, repo, Deck, TMUX, ...').
            # 判定: raw 前 30 字符整段在 _context 里出现 → 几乎一定是 echo (真转写不可能含 prompt 字面值).
            # < 20 字短输出放行避免误杀单词级 PTT (如 '对', 'OK', 单个 hotword).
            if raw and len(raw) >= 20 and self._context and raw[:30] in self._context:
                _log(f"  {log_tag} DROP context-echo: raw='{raw[:60]}...'")
                return ("", "")
            # post-correct (qwen3_post_correct) was moved to the server-side
            # wrapper transcribe_final_async() so every final-pass backend
            # (including future cloud-volcano / local-onnx) shares the same
            # deterministic homophone-fix layer. Backend returns raw output;
            # server wraps post-correct around it uniformly.
            lang = results[0].language or ""
            if arr.size != orig_size:
                dur_info = f"{orig_size/sample_rate:.1f}s->{arr.size/sample_rate:.1f}s"
            else:
                dur_info = f"{arr.size/sample_rate:.1f}s"
            rms_info = f" rms_p50={rms_stats[1]:.4f}" if rms_stats else ""
            _log(f"  {log_tag} {time.time()-t:.2f}s ({dur_info}){rms_info} lang={lang} -> '{raw[:50]}'")
            return (raw, lang)
        except Exception as e:
            _log(f"  {log_tag} failed: {e} (fallback)")
            return ("", "")
