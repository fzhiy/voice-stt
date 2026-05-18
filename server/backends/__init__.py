"""
Backend factory for pluggable ASR backends.

Selection semantics (resolve order):
1. If FINAL_BACKEND is set explicitly:
   - "qwen3_asr" -> return Qwen3ASRBackend()
   - "none"      -> return None
   - other       -> raise ValueError (server exits non-zero)
2. If FINAL_BACKEND is unset:
   - USE_QWEN3_ASR=0 -> return None (preserves existing fallback)
   - else             -> return Qwen3ASRBackend()

Lazy imports: Qwen3ASRBackend is imported ONLY inside the branch that returns it,
so USE_QWEN3_ASR=0 paths never import vllm / transformers / qwen-asr.
"""
import os


def get_final_backend():
    """Return the configured FinalPassBackend instance, or None.

    Raises ValueError for unknown FINAL_BACKEND values (P0_5).
    """
    final_backend_env = os.environ.get("FINAL_BACKEND", "")
    if final_backend_env:
        val = final_backend_env.strip().lower()
        if val == "qwen3_asr":
            from .qwen3_asr import Qwen3ASRBackend
            return Qwen3ASRBackend()
        elif val == "none":
            return None
        else:
            raise ValueError(
                f"Unknown FINAL_BACKEND={final_backend_env!r}. "
                f"Valid values are: qwen3_asr, none"
            )
    # FINAL_BACKEND unset — use legacy USE_QWEN3_ASR flag
    use_qwen3 = os.environ.get("USE_QWEN3_ASR", "1") not in ("0", "false", "no", "")
    if not use_qwen3:
        return None
    from .qwen3_asr import Qwen3ASRBackend
    return Qwen3ASRBackend()


def get_streaming_backend():
    """Return the configured StreamingPartialBackend instance.

    Returns ParaformerBackend unconditionally for v0.1.
    """
    from .paraformer import ParaformerBackend
    import os
    model_name = os.environ.get("STREAM_MODEL", "paraformer-zh-streaming")
    return ParaformerBackend(model_name=model_name)
