"""Tests for hotwords.yaml split: paraformer_hotwords (Chinese) vs english_context_terms (all).

P0 acceptance criteria from spec hotwords-yaml-split v2:
  1. Paraformer loader on split yaml: '流式' present, 'subagent' absent.
  2. qwen3-set-identical: deduped term SET from new load_qwen3_context on split yaml ==
     deduped term SET from loader on pre-split (legacy) yaml. Baseline sourced from
     `git show HEAD:server/hotwords.yaml` (the pre-split commit), NOT the post-split file.
  3. Qwen3 loader suffix '英文专有名词保持原样大小写。' intact.
  4. Backward-compat: both loaders non-empty on a LEGACY flat fixture (old category keys).
  5. Mixed-schema: load_qwen3_context on fixture with english_context_terms + legacy
     user_added + auto_promoted returns the union of all three.
  6. Volcano order: asr_common.load_hotwords_terms(split_yaml)[:100] is English-first.
"""
import importlib.util
import os
import subprocess
import sys
from pathlib import Path
from unittest.mock import MagicMock


import asr_common


# ──────────────────────────── module import ────────────────────────────────

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
    spec = importlib.util.spec_from_file_location("funasr_stream_server", server_path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


srv = _import_server_module()
load_hotwords = srv.load_hotwords
load_qwen3_context = srv.load_qwen3_context

# Path to the live split yaml in the repo
_REPO_ROOT = Path(__file__).resolve().parent.parent
_SPLIT_YAML = str(_REPO_ROOT / "server" / "hotwords.yaml")


# ──────────────────────────── helpers ──────────────────────────────────────

def _qwen3_term_set(context_str: str) -> set:
    """Extract the deduped term set from load_qwen3_context output (suffix excluded)."""
    suffix = "\n\n英文专有名词保持原样大小写。"
    body = context_str
    if body.endswith(suffix):
        body = body[: -len(suffix)]
    return set(t.strip() for t in body.split(",") if t.strip())


_PRE_SPLIT_COMMIT = "08986fa902b4b8de097a9069415a40c1045ae9cd"


def _legacy_yaml_content() -> str:
    """Return the pre-split hotwords.yaml content from the explicit pre-split commit.

    Pinned to the SHA, NOT `HEAD`: once the split is committed, HEAD moves to the
    post-split commit and `git show HEAD:` would return the restructured file —
    making the set-equality test a vacuous self-comparison. The explicit SHA keeps
    the baseline anchored to the genuine pre-restructuring state.
    """
    result = subprocess.run(
        [
            "git", "-C", str(_REPO_ROOT),
            "show", f"{_PRE_SPLIT_COMMIT}:server/hotwords.yaml",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout


# ──────────────────────────── P0 tests ─────────────────────────────────────

def test_paraformer_chinese_only(tmp_path):
    """P0-1: Paraformer loader on split yaml has '流式', no 'subagent'."""
    result = load_hotwords(_SPLIT_YAML)
    words = result.split()
    assert "流式" in words, "'流式' missing from paraformer output"
    assert "subagent" not in words, "'subagent' must NOT be in paraformer output (English excluded)"


def test_qwen3_set_identical_to_legacy(tmp_path):
    """P0-2: qwen3-set-identical — deduped SET from split yaml == set from pre-split yaml.

    Baseline sourced from the pinned pre-split commit (see _legacy_yaml_content).
    This is NOT a self-comparison: the baseline is the pre-restructuring state,
    compared against the post-restructuring file on disk.
    """
    # Compute the legacy set from the pre-split yaml (git HEAD)
    legacy_content = _legacy_yaml_content()
    legacy_yaml_path = tmp_path / "legacy_hotwords.yaml"
    legacy_yaml_path.write_text(legacy_content, encoding="utf-8")
    legacy_ctx = load_qwen3_context(str(legacy_yaml_path))
    legacy_set = _qwen3_term_set(legacy_ctx)

    # Compute the new set from the split yaml on disk
    new_ctx = load_qwen3_context(_SPLIT_YAML)
    new_set = _qwen3_term_set(new_ctx)

    missing = legacy_set - new_set
    extra = new_set - legacy_set
    assert missing == set(), f"Terms DROPPED from Qwen3 context after split: {sorted(missing)}"
    assert extra == set(), f"Terms ADDED to Qwen3 context after split (unexpected): {sorted(extra)}"


def test_qwen3_suffix_intact():
    """P0-3: Qwen3 loader output ends with the required suffix verbatim."""
    result = load_qwen3_context(_SPLIT_YAML)
    assert result.endswith("\n\n英文专有名词保持原样大小写。"), (
        f"Suffix missing. Output tail: {result[-60:]!r}"
    )


def test_backward_compat_legacy_flat_fixture(tmp_path):
    """P0-4: Both loaders non-empty on a LEGACY flat fixture (old category keys, no new keys)."""
    legacy_yaml = tmp_path / "legacy.yaml"
    legacy_yaml.write_text(
        "ai_agent:\n"
        "  - transformer\n"
        "  - attention\n"
        "chinese_tech:\n"
        "  - 流式\n"
        "  - 大模型\n"
        "user_added:\n"
        "  - API\n"
        "mappings:\n"
        '  "拉马": "Llama"\n',
        encoding="utf-8",
    )
    hw = load_hotwords(str(legacy_yaml))
    qw = load_qwen3_context(str(legacy_yaml))
    assert hw.strip() != "", "load_hotwords must be non-empty on legacy flat fixture"
    assert qw.strip() != "", "load_qwen3_context must be non-empty on legacy flat fixture"
    # Paraformer falls back to chinese_tech on legacy yaml
    assert "流式" in hw.split(), "legacy fallback: '流式' expected from chinese_tech"
    # Qwen3 should include all list sections
    term_set = _qwen3_term_set(qw)
    assert "transformer" in term_set
    assert "流式" in term_set
    assert "API" in term_set


def test_mixed_schema_qwen3_union(tmp_path):
    """P0-5: Mixed-schema — english_context_terms + legacy user_added + auto_promoted all unioned."""
    mixed_yaml = tmp_path / "mixed.yaml"
    mixed_yaml.write_text(
        "english_context_terms:\n"
        "  - transformer\n"
        "  - attention\n"
        "paraformer_hotwords:\n"
        "  - 流式\n"
        "user_added:\n"
        "  - API\n"
        "  - SSH\n"
        "auto_promoted:\n"
        "  - worktree\n"
        "mappings:\n"
        '  "拉马": "Llama"\n',
        encoding="utf-8",
    )
    result = load_qwen3_context(str(mixed_yaml))
    term_set = _qwen3_term_set(result)
    # Must include terms from all three list sections
    assert "transformer" in term_set, "english_context_terms term missing"
    assert "流式" in term_set, "paraformer_hotwords term missing from Qwen3 context"
    assert "API" in term_set, "user_added term missing"
    assert "SSH" in term_set, "user_added term missing"
    assert "worktree" in term_set, "auto_promoted term missing"


def test_volcano_order_english_first():
    """P0-6: asr_common.load_hotwords_terms first 100 on split yaml is English-first.

    english_context_terms (English) must be the first key in the yaml so the
    first-100 cap from Volcano/cloud providers stays English-dominant.
    asr_common.py is NOT edited — this test pins its behavior against the split yaml.
    """
    terms = asr_common.load_hotwords_terms(_SPLIT_YAML, max_count=100)
    assert len(terms) == 100, f"Expected 100 terms, got {len(terms)}"

    def _is_english(term: str) -> bool:
        return all(not ("一" <= c <= "鿿") for c in term)

    english_count = sum(1 for t in terms if _is_english(t))
    # english_context_terms (English) comes first; paraformer_hotwords (Chinese) is after.
    # With 595 total terms and only ~69 Chinese terms, the first 100 should be all English.
    assert english_count == 100, (
        f"Expected all 100 terms to be English (English-first ordering), "
        f"but got {100 - english_count} Chinese terms in the first 100. "
        f"Check that english_context_terms is the FIRST key in hotwords.yaml."
    )
