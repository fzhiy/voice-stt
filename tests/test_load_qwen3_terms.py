"""P0 unit tests for load_qwen3_terms + _collect_qwen3_terms equivalence.

Spec: tests/test_load_qwen3_terms.py (R1-F7 + R2-F3 invariant)
"""
import importlib.util
import os
import sys
from pathlib import Path
from unittest.mock import MagicMock

import yaml


# ─────────────────── server module import ───────────────────────────────────

def _import_server_module():
    """Import funasr-stream-server.py with heavy ML deps stubbed out."""
    sys.modules.setdefault("numpy", MagicMock(int16=int, float32=float, zeros=lambda *a, **kw: []))
    sys.modules["funasr"] = MagicMock(AutoModel=MagicMock(return_value=MagicMock()))
    sys.modules.setdefault("websockets", MagicMock())
    sys.modules["webrtcvad"] = MagicMock()
    os.environ["USE_QWEN3_ASR"] = "0"
    os.environ["STREAM_PUNC_MODEL"] = ""
    os.environ["HISTORY_ENABLED"] = "0"

    repo_root = Path(__file__).resolve().parent.parent
    server_path = repo_root / "server" / "funasr-stream-server.py"
    spec = importlib.util.spec_from_file_location("funasr_stream_server_lqt", server_path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


srv = _import_server_module()
load_qwen3_terms = srv.load_qwen3_terms
_collect_qwen3_terms = srv._collect_qwen3_terms

_REPO_ROOT = Path(__file__).resolve().parent.parent
_LIVE_YAML = str(_REPO_ROOT / "server" / "hotwords.yaml")


# ─────────────────── fixtures ───────────────────────────────────────────────

_LEGACY_YAML = """\
ai_agent:
  - transformer
  - attention
chinese_tech:
  - 流式
  - 大模型
user_added:
  - API
  - SSH
mappings:
  "拉马": "Llama"
"""

_MIXED_YAML = """\
english_context_terms:
  - transformer
  - attention
paraformer_hotwords:
  - 流式
user_added:
  - API
  - SSH
auto_promoted:
  - worktree
mappings:
  "拉马": "Llama"
snippets:
  my-email: user@example.com
"""

_MULTIWORD_YAML = """\
english_context_terms:
  - Claude Code
  - Command A
  - F1 score
  - transformer
mappings:
  "拉马": "Llama"
"""


# ─────────────────── tests ──────────────────────────────────────────────────

def test_live_yaml_set_equivalence(tmp_path):
    """(a) On live hotwords.yaml, set(load_qwen3_terms) == set(_collect_qwen3_terms(data))."""
    terms_via_func = load_qwen3_terms(_LIVE_YAML)
    with open(_LIVE_YAML, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    terms_via_helper = _collect_qwen3_terms(data)
    assert set(terms_via_func) == set(terms_via_helper), (
        f"Set mismatch. Only in func: {set(terms_via_func) - set(terms_via_helper)}, "
        f"only in helper: {set(terms_via_helper) - set(terms_via_func)}"
    )


def test_skips_mappings_section(tmp_path):
    """(b) load_qwen3_terms SKIPS mappings: section."""
    yaml_file = tmp_path / "test.yaml"
    yaml_file.write_text(_MIXED_YAML, encoding="utf-8")
    terms = load_qwen3_terms(str(yaml_file))
    term_set = set(terms)
    # mappings RHS "Llama" and LHS "拉马" must not appear via mappings
    assert "拉马" not in term_set, "LHS of mapping must not be in terms"
    assert "Llama" not in term_set, "RHS of mapping must not be in terms (not a list)"


def test_skips_snippets_section(tmp_path):
    """(c) load_qwen3_terms SKIPS snippets: section."""
    yaml_file = tmp_path / "test.yaml"
    yaml_file.write_text(_MIXED_YAML, encoding="utf-8")
    terms = load_qwen3_terms(str(yaml_file))
    term_set = set(terms)
    assert "my-email" not in term_set, "snippets key must not appear in terms"
    assert "user@example.com" not in term_set, "snippets value must not appear in terms"


def test_multiword_terms_preserved_as_single_entry(tmp_path):
    """(d) Multi-word hotwords appear as single entries (not split on whitespace)."""
    yaml_file = tmp_path / "test.yaml"
    yaml_file.write_text(_MULTIWORD_YAML, encoding="utf-8")
    terms = load_qwen3_terms(str(yaml_file))
    term_set = set(terms)
    assert "Claude Code" in term_set, "'Claude Code' must appear as a single entry"
    assert "Command A" in term_set, "'Command A' must appear as a single entry"
    assert "F1 score" in term_set, "'F1 score' must appear as a single entry"
    # Substrings must NOT be added separately
    assert "Code" not in term_set, "'Code' must not be a split-off entry"
    assert "Command" not in term_set, "'Command' must not be a split-off entry"


def test_order_preserved(tmp_path):
    """(e) Order is preserved within iteration (insertion order, no sort)."""
    yaml_content = "group_a:\n  - aaa\n  - bbb\ngroup_b:\n  - ccc\n"
    yaml_file = tmp_path / "test.yaml"
    yaml_file.write_text(yaml_content, encoding="utf-8")
    terms = load_qwen3_terms(str(yaml_file))
    assert terms == ["aaa", "bbb", "ccc"], f"Expected ['aaa','bbb','ccc'], got {terms}"


def test_legacy_flat_fixture(tmp_path):
    """(f) On LEGACY-flat fixture, set match holds."""
    yaml_file = tmp_path / "legacy.yaml"
    yaml_file.write_text(_LEGACY_YAML, encoding="utf-8")
    terms_via_func = load_qwen3_terms(str(yaml_file))
    data = yaml.safe_load(_LEGACY_YAML)
    terms_via_helper = _collect_qwen3_terms(data)
    assert set(terms_via_func) == set(terms_via_helper)
    # Should contain terms from all list sections
    term_set = set(terms_via_func)
    assert "transformer" in term_set
    assert "流式" in term_set
    assert "API" in term_set


def test_mixed_schema_all_three_sections(tmp_path):
    """(g) Mixed fixture: qwen3_context_terms + legacy user_added + auto_promoted all included."""
    yaml_file = tmp_path / "mixed.yaml"
    yaml_file.write_text(_MIXED_YAML, encoding="utf-8")
    terms_via_func = load_qwen3_terms(str(yaml_file))
    data = yaml.safe_load(_MIXED_YAML)
    terms_via_helper = _collect_qwen3_terms(data)
    assert set(terms_via_func) == set(terms_via_helper)
    term_set = set(terms_via_func)
    assert "transformer" in term_set
    assert "流式" in term_set
    assert "API" in term_set
    assert "SSH" in term_set
    assert "worktree" in term_set
