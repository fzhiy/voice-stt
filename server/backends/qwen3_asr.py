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
                _log(f"WARN: to use vLLM, ensure CUDA_HOME=/usr/local/cuda-13.0 PATH=/usr/local/cuda-13.0/bin:$PATH is exported.")
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
        return Qwen3ASRModel.LLM(
            QWEN3_ASR_PATH,
            gpu_memory_utilization=QWEN3_VLLM_GPU_FRAC,
            max_model_len=QWEN3_VLLM_MAX_MODEL_LEN,
            enforce_eager=True,
            max_inference_batch_size=QWEN3_VLLM_BATCH,
            max_new_tokens=512,
            dtype="bfloat16",
        )

    def _load_transformers(self):
        import torch
        from qwen_asr import Qwen3ASRModel
        return Qwen3ASRModel.from_pretrained(
            QWEN3_ASR_PATH,
            dtype=torch.bfloat16,
            device_map="cuda:0",
            max_inference_batch_size=1,
            max_new_tokens=512,
        )

    @property
    def engine_actual(self) -> str | None:
        """For history metadata. Returns 'vllm' / 'transformers' / None (I7)."""
        return self._engine_actual

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
            # language="Chinese" 强锁语种 tag。原本 None 让模型自检，但长中英混音频上
            # 模型偶尔返回空 lang 导致 EOS 触发偏早、输出被截断（见
            # docs/dev/changes/2026-05-15-verify-qwen3-context.md）。
            # context 里已有"保留英文原样不翻译"规则保护品牌词。
            results = self._model.transcribe(
                audio=(arr, sample_rate),
                context=self._context,
                language="Chinese",
            )
            if not results:
                return ("", "")
            raw = (results[0].text or "").strip()
            text = text_postprocess.qwen3_post_correct(raw)
            lang = results[0].language or ""
            if arr.size != orig_size:
                dur_info = f"{orig_size/sample_rate:.1f}s->{arr.size/sample_rate:.1f}s"
            else:
                dur_info = f"{arr.size/sample_rate:.1f}s"
            rms_info = f" rms_p50={rms_stats[1]:.4f}" if rms_stats else ""
            if text != raw:
                _log(f"  {log_tag} {time.time()-t:.2f}s ({dur_info}){rms_info} lang={lang} -> '{text[:50]}' (post-correct fixed from '{raw[:50]}')")
            else:
                _log(f"  {log_tag} {time.time()-t:.2f}s ({dur_info}){rms_info} lang={lang} -> '{text[:50]}'")
            return (text, lang)
        except Exception as e:
            _log(f"  {log_tag} failed: {e} (fallback)")
            return ("", "")
