import time
from typing import Any

import numpy as np

from .base import StreamingPartialBackend


class ParaformerBackend(StreamingPartialBackend):
    """FunASR Paraformer-zh-streaming backend for chunk-level partial transcription."""

    # Numeric constants must match module-level values in funasr-stream-server.py byte-for-byte
    CHUNK_SIZE = [0, 5, 3]
    ENCODER_LOOKBACK = 4
    DECODER_LOOKBACK = 1

    def __init__(self, model_name: str = "paraformer-zh-streaming") -> None:
        self._model_name = model_name
        self.model = None

    def load(self) -> None:
        from funasr import AutoModel
        t0 = time.time()
        self.model = AutoModel(model=self._model_name, disable_update=True, log_level="WARNING")
        print(f"[{time.strftime('%H:%M:%S')}] ASR streaming model ready in {time.time()-t0:.1f}s")

    def new_session_state(self) -> Any:
        """Return a fresh per-connection Paraformer cache dict."""
        return {}

    def generate_chunk(
        self,
        pcm_float32: np.ndarray,
        session_state: Any,
        is_final: bool = False,
        hotwords: str = "",
    ) -> str:
        """Run streaming Paraformer inference on one chunk. Returns incremental text."""
        res = self.model.generate(
            input=pcm_float32,
            cache=session_state,
            is_final=is_final,
            chunk_size=self.CHUNK_SIZE,
            encoder_chunk_look_back=self.ENCODER_LOOKBACK,
            decoder_chunk_look_back=self.DECODER_LOOKBACK,
            hotword=hotwords,
        )
        if not res:
            return ""
        return res[0].get("text", "")
