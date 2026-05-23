"""Phase B P0 tests for Round 2 Codex F2 (3 missing items) + F1 (tokenizer property).

These cover acceptance_criteria.P0_worker_verifiable items that the Round 1
worker either skipped or covered only implicitly:

  - kwargs-no-logits_processors-on-flag-off
  - set_trie atomic reference replacement (pure Python, no torch)
  - tokenizer property pre-load (lazy resolve) AND post-load (live)

Tokenizer + kwargs tests run in subprocesses with `qwen_asr` stubbed via
sys.modules — the real package only exists on the GPU host streamenv.
"""
import subprocess
import sys
import textwrap
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent


# ---------- 1. set_trie atomic reference replacement (pure Python) ----------

def test_set_trie_replaces_reference():
    """state.set_trie(A) → get returns A; set_trie(B) → get returns B (not A)."""
    sys.path.insert(0, str(_REPO_ROOT / "server"))
    try:
        from biasing import state  # noqa: PLC0415  (import lives in test for sys.path)
    finally:
        pass

    a = {"children": {1: {"children": {}, "terminal": True}}, "terminal": False, "tag": "A"}
    b = {"children": {2: {"children": {}, "terminal": True}}, "terminal": False, "tag": "B"}

    state.set_trie(a)
    assert state.get_trie() is a

    state.set_trie(b)
    assert state.get_trie() is b
    assert state.get_trie() is not a

    state.set_trie(None)
    assert state.get_trie() is None


# ---------- 2. kwargs no `logits_processors` when flag is off ----------

def _run_kwargs_check(flag_value: str) -> subprocess.CompletedProcess:
    """Spawn a subprocess that imports qwen3_asr with the flag set, patches
    Qwen3ASRModel.LLM to capture kwargs, calls load(), inspects kwargs."""
    script = textwrap.dedent("""
        import os, sys
        from pathlib import Path
        from unittest.mock import MagicMock

        os.environ['TRIE_BIASING_ENABLED'] = sys.argv[2]

        # Stub heavy deps so the backend module loads without GPU/torch.
        sys.modules.setdefault('numpy', MagicMock(int16=int, float32=float, zeros=lambda *a, **kw: []))
        sys.modules.setdefault('torch', MagicMock())
        sys.modules.setdefault('websockets', MagicMock())
        sys.modules.setdefault('webrtcvad', MagicMock())

        # Stub vllm chain (the flag-on path will trigger `from biasing.hotword_lp ...`
        # which imports vllm.v1.sample.logits_processor.AdapterLogitsProcessor).
        sys.modules.setdefault('vllm', MagicMock())
        sys.modules.setdefault('vllm.v1', MagicMock())
        sys.modules.setdefault('vllm.v1.sample', MagicMock())
        sys.modules.setdefault('vllm.v1.sample.logits_processor', MagicMock(AdapterLogitsProcessor=type('AdapterLogitsProcessor', (), {})))

        # Capture-able stub for Qwen3ASRModel.LLM
        captured = {}
        def _fake_llm_classmethod(model, **kwargs):
            captured['kwargs'] = kwargs
            return MagicMock(processor=MagicMock(tokenizer=MagicMock()))
        fake_Qwen3ASRModel = MagicMock()
        fake_Qwen3ASRModel.LLM = _fake_llm_classmethod
        fake_Qwen3ASRModel.from_pretrained = MagicMock(return_value=MagicMock())
        sys.modules['qwen_asr'] = MagicMock(Qwen3ASRModel=fake_Qwen3ASRModel)

        repo_root = Path(sys.argv[1])
        sys.path.insert(0, str(repo_root / 'server'))
        from backends.qwen3_asr import Qwen3ASRBackend

        b = Qwen3ASRBackend()
        # Force the vllm path
        import backends.qwen3_asr as mod
        mod.QWEN3_BACKEND = 'vllm'
        b._load_vllm()

        flag = os.environ['TRIE_BIASING_ENABLED']
        kwargs = captured.get('kwargs', {})
        has_lp = 'logits_processors' in kwargs
        print(f"FLAG={flag} HAS_LP={has_lp}")
    """)

    result = subprocess.run(
        [sys.executable, "-c", script, str(_REPO_ROOT), flag_value],
        capture_output=True,
        text=True,
        timeout=60,
    )
    return result


def test_kwargs_no_logits_processors_when_flag_off():
    """TRIE_BIASING_ENABLED=0 → kwargs has NO logits_processors key (back-compat)."""
    result = _run_kwargs_check("0")
    assert result.returncode == 0, (
        f"subprocess failed.\nSTDOUT: {result.stdout}\nSTDERR: {result.stderr}"
    )
    assert "FLAG=0 HAS_LP=False" in result.stdout, (
        f"Expected no logits_processors with flag=0, got: {result.stdout[:500]}\n"
        f"STDERR: {result.stderr[:500]}"
    )


def test_kwargs_has_logits_processors_when_flag_on():
    """TRIE_BIASING_ENABLED=1 → kwargs DOES include logits_processors (LP registered)."""
    result = _run_kwargs_check("1")
    assert result.returncode == 0, (
        f"subprocess failed.\nSTDOUT: {result.stdout}\nSTDERR: {result.stderr}"
    )
    assert "FLAG=1 HAS_LP=True" in result.stdout, (
        f"Expected logits_processors present with flag=1, got: {result.stdout[:500]}\n"
        f"STDERR: {result.stderr[:500]}"
    )


# ---------- 3. tokenizer property pre-load AND post-load ----------

def _run_tokenizer_check(mode: str) -> subprocess.CompletedProcess:
    """mode ∈ {'pre_load', 'post_load', 'transformers_fallback'}."""
    script = textwrap.dedent("""
        import os, sys
        from pathlib import Path
        from unittest.mock import MagicMock

        sys.modules.setdefault('numpy', MagicMock(int16=int, float32=float, zeros=lambda *a, **kw: []))
        sys.modules.setdefault('torch', MagicMock())
        sys.modules.setdefault('websockets', MagicMock())
        sys.modules.setdefault('webrtcvad', MagicMock())

        # Stub qwen_asr — top-level + the deep submodule the lazy path imports.
        SENTINEL_TOKENIZER = MagicMock(name='lazy_loaded_tokenizer')
        fake_processor = MagicMock()
        fake_processor.tokenizer = SENTINEL_TOKENIZER
        fake_Qwen3ASRProcessor = MagicMock()
        fake_Qwen3ASRProcessor.from_pretrained = MagicMock(return_value=fake_processor)
        sys.modules['qwen_asr'] = MagicMock(Qwen3ASRModel=MagicMock())
        # Deep submodule path the lazy resolve uses
        fake_core = MagicMock()
        fake_transformers_backend = MagicMock(Qwen3ASRProcessor=fake_Qwen3ASRProcessor)
        sys.modules['qwen_asr.core'] = fake_core
        sys.modules['qwen_asr.core.transformers_backend'] = fake_transformers_backend

        mode = sys.argv[2]
        repo_root = Path(sys.argv[1])
        sys.path.insert(0, str(repo_root / 'server'))

        import backends.qwen3_asr as mod
        from backends.qwen3_asr import Qwen3ASRBackend

        b = Qwen3ASRBackend()

        if mode == 'pre_load':
            mod.QWEN3_BACKEND = 'vllm'
            assert b._model is None
            tok = b.tokenizer
            assert tok is SENTINEL_TOKENIZER, f"expected lazy tokenizer, got {tok!r}"
            # Second access returns cached value (no second from_pretrained call)
            tok2 = b.tokenizer
            assert tok2 is tok
            assert fake_Qwen3ASRProcessor.from_pretrained.call_count == 1
            print('PRE_LOAD_OK')
        elif mode == 'post_load':
            POST_TOK = MagicMock(name='post_load_tokenizer')
            b._model = MagicMock(processor=MagicMock(tokenizer=POST_TOK))
            tok = b.tokenizer
            assert tok is POST_TOK, f"expected live tokenizer, got {tok!r}"
            print('POST_LOAD_OK')
        elif mode == 'transformers_fallback':
            mod.QWEN3_BACKEND = 'transformers'
            assert b._model is None
            try:
                _ = b.tokenizer
                print('FAIL_should_have_raised')
            except AttributeError as e:
                msg = str(e)
                assert 'vLLM' in msg or 'vllm' in msg, f'wrong error message: {msg!r}'
                print('TRANSFORMERS_RAISE_OK')
        else:
            print(f'UNKNOWN_MODE={mode}')
    """)

    result = subprocess.run(
        [sys.executable, "-c", script, str(_REPO_ROOT), mode],
        capture_output=True,
        text=True,
        timeout=60,
    )
    return result


def test_tokenizer_property_pre_load_lazy_resolves():
    """When _model is None and would_use_vllm is True, .tokenizer lazy-loads via
    Qwen3ASRProcessor.from_pretrained and caches the result."""
    result = _run_tokenizer_check("pre_load")
    assert result.returncode == 0, (
        f"subprocess failed.\nSTDOUT: {result.stdout}\nSTDERR: {result.stderr}"
    )
    assert "PRE_LOAD_OK" in result.stdout, (
        f"Pre-load tokenizer assertion failed.\n"
        f"STDOUT: {result.stdout[:1000]}\nSTDERR: {result.stderr[:1000]}"
    )


def test_tokenizer_property_post_load_returns_live():
    """When _model is set, .tokenizer returns self._model.processor.tokenizer."""
    result = _run_tokenizer_check("post_load")
    assert result.returncode == 0, (
        f"subprocess failed.\nSTDOUT: {result.stdout}\nSTDERR: {result.stderr}"
    )
    assert "POST_LOAD_OK" in result.stdout, (
        f"Post-load tokenizer assertion failed.\n"
        f"STDOUT: {result.stdout[:1000]}\nSTDERR: {result.stderr[:1000]}"
    )


def test_tokenizer_property_transformers_path_raises():
    """When backend would NOT use vllm (transformers fallback), pre-load .tokenizer
    raises AttributeError with a clear message mentioning vllm."""
    result = _run_tokenizer_check("transformers_fallback")
    assert result.returncode == 0, (
        f"subprocess failed.\nSTDOUT: {result.stdout}\nSTDERR: {result.stderr}"
    )
    assert "TRANSFORMERS_RAISE_OK" in result.stdout, (
        f"transformers fallback assertion failed.\n"
        f"STDOUT: {result.stdout[:1000]}\nSTDERR: {result.stderr[:1000]}"
    )
