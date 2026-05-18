from abc import ABC, abstractmethod
from typing import Any
import numpy as np


class StreamingPartialBackend(ABC):
    """Chunk-level streaming partial transcription."""

    @abstractmethod
    def load(self) -> None:
        """Load model weights. Called once per process under _IS_MAIN_PROCESS."""

    @abstractmethod
    def new_session_state(self) -> Any:
        """Return a fresh opaque per-connection state object.
        For Paraformer this is the `{}` cache dict; future backends may return
        anything (None, a custom struct, etc.)."""

    @abstractmethod
    def generate_chunk(
        self,
        pcm_float32: np.ndarray,    # mono 16kHz float32 in [-1, 1]
        session_state: Any,          # opaque per-session state (see new_session_state)
        is_final: bool = False,
        hotwords: str = "",
    ) -> str:
        """Run streaming inference on one chunk. Returns incremental text
        (empty string if nothing to emit yet). May mutate session_state in place."""


class FinalPassBackend(ABC):
    """One-shot full-utterance transcription. Called once per session
    after EOF, or per VAD chunk for long audio."""

    is_loaded: bool = False

    @abstractmethod
    def load(self) -> None:
        """Load model weights. Called once per process under _IS_MAIN_PROCESS.
        MUST set self.is_loaded = True on success; leave False on failure."""

    @abstractmethod
    def transcribe(
        self,
        pcm_int16_bytes: bytes,      # raw int16 PCM, mono, 16kHz
        sample_rate: int = 16000,
        log_tag: str = "final",      # for distinguishable logging (partial / final / chunk)
    ) -> tuple[str, str]:             # (text, detected_language)
        """Transcribe full utterance PCM. Returns (text, language).
        Must return ('', '') on failure — never raise in steady state.
        Caller serializes via qwen3_inference_lock and runs under executor."""

    @property
    @abstractmethod
    def engine_actual(self) -> str | None:
        """For history metadata. Returns the underlying engine identifier
        (e.g. 'vllm' / 'transformers' / 'cloud-dashscope'), or None if not loaded.
        Mirrors the pre-refactor `qwen3_backend_actual` global var (I7)."""

    def update_context(self, context: str) -> None:
        """Server calls this from reload_vocab() to keep the backend's
        QWEN3_CONTEXT-equivalent fresh (I5). Default no-op for backends that
        don't use a server-injected context. Qwen3ASRBackend overrides."""
        pass
