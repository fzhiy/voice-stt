"""P0 import-isolation test (Codex R1-F2 + R2-F2).

Spawns a subprocess with sys.modules['vllm'] = None; sys.modules['torch'] = None
and TRIE_BIASING_ENABLED=0, then imports:
  (a) funasr-stream-server.py (top-level path)
  (b) server.backends.qwen3_asr (module path)

Both must succeed without ModuleNotFoundError. After both imports:
  assert 'biasing.hotword_lp' not in sys.modules
  assert 'vllm' not in sys.modules  (None sentinel counts as not-imported)
"""
import os
import subprocess
import sys
import textwrap
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent
_SERVER_PATH = _REPO_ROOT / "server"


def _run_isolation_check() -> subprocess.CompletedProcess:
    """Run the isolation check in a fresh subprocess."""
    script = textwrap.dedent("""
        import sys, os
        from pathlib import Path
        from unittest.mock import MagicMock

        # Block vllm and torch — simulates a dev machine with no GPU stack
        sys.modules['vllm'] = None
        sys.modules['torch'] = None

        # Stub heavy deps so the server module loads without errors
        sys.modules.setdefault('numpy', MagicMock(int16=int, float32=float, zeros=lambda *a, **kw: []))
        sys.modules['funasr'] = MagicMock(AutoModel=MagicMock(return_value=MagicMock()))
        sys.modules.setdefault('websockets', MagicMock())
        sys.modules['webrtcvad'] = MagicMock()

        os.environ['TRIE_BIASING_ENABLED'] = '0'
        os.environ['USE_QWEN3_ASR'] = '0'
        os.environ['STREAM_PUNC_MODEL'] = ''
        os.environ['HISTORY_ENABLED'] = '0'

        repo_root = Path(sys.argv[1])
        server_dir = repo_root / 'server'
        sys.path.insert(0, str(server_dir))

        # (a) Import funasr-stream-server.py
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            'funasr_stream_server_flagoff',
            server_dir / 'funasr-stream-server.py',
        )
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)

        # (b) Import qwen3_asr backend module
        import backends.qwen3_asr  # noqa: F401

        # Assertions
        assert 'biasing.hotword_lp' not in sys.modules, (
            f"biasing.hotword_lp was imported with flag=0! modules: "
            f"{[k for k in sys.modules if 'biasing' in k]}"
        )
        # vllm=None sentinel: key present but value is None → was not truly imported
        # The contract: biasing.hotword_lp (which imports vllm) was never imported.
        assert sys.modules.get('vllm') is None, (
            "vllm module slot should remain None (sentinel) — no real import happened"
        )
        print("ISOLATION_OK")
    """)

    env = os.environ.copy()
    env["TRIE_BIASING_ENABLED"] = "0"

    result = subprocess.run(
        [sys.executable, "-c", script, str(_REPO_ROOT)],
        capture_output=True,
        text=True,
        env=env,
        timeout=60,
    )
    return result


def test_flag_off_no_vllm_import():
    """With TRIE_BIASING_ENABLED=0 and vLLM/torch blocked, both modules import cleanly."""
    result = _run_isolation_check()
    if result.returncode != 0:
        print("STDOUT:", result.stdout)
        print("STDERR:", result.stderr)
    assert result.returncode == 0, (
        f"Isolation check subprocess failed (returncode={result.returncode}).\n"
        f"STDOUT: {result.stdout[:2000]}\n"
        f"STDERR: {result.stderr[:2000]}"
    )
    assert "ISOLATION_OK" in result.stdout, (
        f"Expected ISOLATION_OK in stdout. Got: {result.stdout[:500]}"
    )
