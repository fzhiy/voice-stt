"""Tests for should_persist_for().

Uses the same importlib/MagicMock stub pattern as test_mappings.py so the
server module can be imported without heavy ML deps installed.

Coverage (≥7 assertions as required by spec):
  1. ?persist_history=1  → True
  2. ?persist_history=true → True  (case-insensitive)
  3. ?persist_history=yes  → True
  4. ?persist_history=0  → False
  5. ?persist_history=false → False
  6. ?persist_history=no → False
  7. ?persist_history= (empty value) → False
  8. Key absent + HISTORY_ENABLED env True  → True  (env fallback)
  9. Key absent + HISTORY_ENABLED env False → False (env fallback)
 10. AttributeError (no request attr) → HISTORY_ENABLED env fallback
 11. Multiple query params — persist_history last value wins
"""
import importlib.util
import os
import sys
from pathlib import Path
from unittest.mock import MagicMock


def _import_server_module():
    """Load funasr-stream-server.py without triggering heavy model loads.
    Matches the stub setup in test_mappings.py exactly."""
    sys.modules.setdefault("numpy", MagicMock(int16=int, float32=float, zeros=lambda *a, **kw: []))
    sys.modules["funasr"] = MagicMock(AutoModel=MagicMock(return_value=MagicMock()))
    sys.modules.setdefault("websockets", MagicMock())
    sys.modules["webrtcvad"] = MagicMock()
    os.environ["USE_QWEN3_ASR"] = "0"
    os.environ["STREAM_PUNC_MODEL"] = ""
    os.environ["HISTORY_ENABLED"] = "0"

    repo_root = Path(__file__).resolve().parent.parent
    server_path = repo_root / "server" / "funasr-stream-server.py"
    spec = importlib.util.spec_from_file_location("funasr_stream_server", server_path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


srv = _import_server_module()
should_persist_for = srv.should_persist_for


def _ws(path: str):
    """Build a minimal websocket mock with request.path set."""
    ws = MagicMock()
    ws.request.path = path
    return ws


def _set_env(enabled: bool):
    """Override the module-level HISTORY_ENABLED for env-fallback tests."""
    srv.HISTORY_ENABLED = enabled


# ----- explicit ?persist_history= values -----

def test_persist_1_is_true():
    assert should_persist_for(_ws("/?persist_history=1")) is True


def test_persist_true_is_true():
    assert should_persist_for(_ws("/?persist_history=true")) is True


def test_persist_yes_is_true():
    assert should_persist_for(_ws("/?persist_history=yes")) is True


def test_persist_TRUE_case_insensitive():
    assert should_persist_for(_ws("/?persist_history=TRUE")) is True


def test_persist_0_is_false():
    assert should_persist_for(_ws("/?persist_history=0")) is False


def test_persist_false_is_false():
    assert should_persist_for(_ws("/?persist_history=false")) is False


def test_persist_no_is_false():
    assert should_persist_for(_ws("/?persist_history=no")) is False


def test_persist_empty_value_is_false():
    """Empty value (?persist_history=) is not in ('1','true','yes') → False."""
    assert should_persist_for(_ws("/?persist_history=")) is False


# ----- env fallback when key absent -----

def test_no_key_falls_back_to_env_true():
    _set_env(True)
    assert should_persist_for(_ws("/")) is True


def test_no_key_falls_back_to_env_false():
    _set_env(False)
    assert should_persist_for(_ws("/")) is False


# ----- AttributeError / TypeError fallback -----

def test_attribute_error_falls_back_to_env():
    """If websocket.request raises AttributeError, return HISTORY_ENABLED."""
    ws = MagicMock()
    del ws.request  # force AttributeError on ws.request.path
    _set_env(True)
    assert should_persist_for(ws) is True
    _set_env(False)
    assert should_persist_for(ws) is False


# ----- last value wins for repeated key -----

def test_last_value_wins():
    """parse_qs returns a list; we take [-1] — last occurrence wins."""
    assert should_persist_for(_ws("/?persist_history=0&persist_history=1")) is True
    assert should_persist_for(_ws("/?persist_history=1&persist_history=0")) is False
