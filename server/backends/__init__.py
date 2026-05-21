"""
Backend factory for pluggable ASR backends.

Selection semantics (resolve order):
1. If FINAL_BACKEND is set explicitly:
   - "qwen3_asr"     -> return Qwen3ASRBackend() (local vLLM)
   - "cloud-volcano" -> raise NotImplementedError; cloud providers are sibling
                        WS servers (`volcano-stream-server.py`), not final-pass
                        backends. Kept as a loud failure for legacy configs.
   - "none"          -> return None
   - other           -> raise ValueError (server exits non-zero)
2. If FINAL_BACKEND is unset:
   - USE_QWEN3_ASR=0 -> return None (preserves existing fallback)
   - else             -> return Qwen3ASRBackend()

Lazy imports: each backend is imported ONLY inside the branch that returns it,
so e.g. cloud-only deployments never import vllm / transformers / qwen-asr, and
local-only deployments never import volcengine-audio.
"""
import os


def get_final_backend():
    """Return the configured FinalPassBackend instance, or None.

    Raises ValueError for unknown FINAL_BACKEND values (P0_5).
    Raises NotImplementedError for the legacy "cloud-volcano" value;
    cloud providers run as sibling WS servers in this architecture, not
    as final-pass backends.
    """
    final_backend_env = os.environ.get("FINAL_BACKEND", "")
    if final_backend_env:
        val = final_backend_env.strip().lower()
        if val == "qwen3_asr":
            from .qwen3_asr import Qwen3ASRBackend
            return Qwen3ASRBackend()
        elif val == "cloud-volcano":
            # Cloud providers are sibling WS servers in this architecture,
            # NOT final-pass backends. Point ASR_WS_URL at e.g.
            # `python server/volcano-stream-server.py` instead of trying to
            # set FINAL_BACKEND. Fail loud to catch legacy configs.
            raise NotImplementedError(
                "FINAL_BACKEND=cloud-volcano is not a supported value: "
                "cloud providers are sibling WS servers, not final-pass "
                "backends. Run `python server/volcano-stream-server.py` "
                "and point your client (ASR_WS_URL) at its port (default "
                "ws://127.0.0.1:18093/). For local GPU final-pass keep "
                "FINAL_BACKEND=qwen3_asr (default) or use FINAL_BACKEND=none."
            )
        elif val == "none":
            return None
        else:
            raise ValueError(
                f"Unknown FINAL_BACKEND={final_backend_env!r}. "
                f"Valid values are: qwen3_asr, none."
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
