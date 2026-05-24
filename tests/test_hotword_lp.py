"""P0 unit tests for server/biasing/hotword_lp.py.

Mocks vllm and tests _PerReqHotwordTrieLP (per-request callable) and
HotwordTriePerReqLP (adapter) without GPU or real model.

The AdapterLogitsProcessor mock is minimal: just enough for HotwordTriePerReqLP
to be instantiatable (no __init__ override needed, but the class must subclass it).
"""
import sys
import types
from pathlib import Path

import pytest

# Skip the entire module if torch is absent (no GPU stack in dev/CI)
torch = pytest.importorskip("torch", reason="torch not installed; LP tests need torch")

# Stub vllm BEFORE importing hotword_lp (vllm not required — only torch)
_vllm_stub = types.ModuleType("vllm")
_vllm_v1 = types.ModuleType("vllm.v1")
_vllm_v1_sample = types.ModuleType("vllm.v1.sample")
_vllm_v1_sample_lp = types.ModuleType("vllm.v1.sample.logits_processor")

class _FakeAdapterLP:
    """Minimal stub for AdapterLogitsProcessor base."""
    def __init__(self, *args, **kwargs):
        pass

_vllm_v1_sample_lp.AdapterLogitsProcessor = _FakeAdapterLP
_vllm_stub.v1 = _vllm_v1
_vllm_v1.sample = _vllm_v1_sample
_vllm_v1_sample.logits_processor = _vllm_v1_sample_lp

sys.modules["vllm"] = _vllm_stub
sys.modules["vllm.v1"] = _vllm_v1
sys.modules["vllm.v1.sample"] = _vllm_v1_sample
sys.modules["vllm.v1.sample.logits_processor"] = _vllm_v1_sample_lp

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "server"))

from biasing import state
from biasing.hotword_lp import _PerReqHotwordTrieLP, HotwordTriePerReqLP, TRIE_LAMBDA


# ─────────────────── helpers ────────────────────────────────────────────────

def _make_trie(token_map: dict) -> dict:
    """Build a trie from explicit {text: [ids]} mappings for testing."""
    from biasing.trie import build_trie

    terms = list(token_map.keys())

    def _tokenizer(text: str, add_special_tokens: bool = False) -> list[int]:
        return token_map.get(text, [])

    return build_trie(terms, _tokenizer)


def _fake_logits(vocab_size: int = 500) -> torch.Tensor:
    return torch.zeros(vocab_size, dtype=torch.float32)


# ─────────────────── tests ──────────────────────────────────────────────────

def test_biases_correct_indices_on_trie_walk():
    """(a) LP biases correct token-id indices as output_ids walks the trie."""
    # Trie: "hello"=[10], " hello"=[30]
    # Expected: root.children = {10, 30}; after advancing to 10, node.children = {}
    token_map = {"hello": [10], " hello": [30]}
    trie = _make_trie(token_map)

    lp = _PerReqHotwordTrieLP(trie, TRIE_LAMBDA)
    logits = _fake_logits()

    # Step 0: output_ids empty → bias = root.children = {10, 30}
    result = lp([], logits.clone())
    assert result[10].item() > 0.0, "Token 10 should be biased at start"
    assert result[30].item() > 0.0, "Token 30 should be biased at start"

    # Step 1: output_ids=[10] → advance from root via 10, node is now terminal leaf
    # bias = terminal leaf's children (empty) UNION root.children ({10, 30})
    logits2 = _fake_logits()
    result2 = lp([10], logits2.clone())
    # Root children still biased (allows new matches)
    assert result2[10].item() > 0.0
    assert result2[30].item() > 0.0


def test_prefix_pair_terminal_with_children():
    """(b) Terminal-with-children node keeps biasing continuation + root-children (F4)."""
    # Trie: "Claude"=[10], "Claude Code"=[10, 20]
    # → node[10] has terminal=True AND children={20}
    token_map = {
        "Claude": [10],
        " Claude": [30],
        "Claude Code": [10, 20],
        " Claude Code": [30, 40],
    }
    trie = _make_trie(token_map)

    # Verify structure: root[10] is terminal with children
    assert 10 in trie["children"]
    claude_node = trie["children"][10]
    assert claude_node["terminal"] is True
    assert 20 in claude_node["children"], "Code token must be child of Claude node"

    lp = _PerReqHotwordTrieLP(trie, TRIE_LAMBDA)
    logits = _fake_logits(vocab_size=500)

    # Advance through token 10 ("Claude")
    result = lp([10], logits.clone())
    # After advancing to claude_node (terminal-with-children), cursor stays there.
    # Bias = claude_node.children ({20}) UNION root.children ({10, 30})
    assert result[20].item() > 0.0, "Continuation token (Code) must be biased"
    assert result[10].item() > 0.0, "Root child (Claude) must be biased for new match"
    assert result[30].item() > 0.0, "Root child (' Claude') must be biased for new match"


def test_unmatched_token_resets_to_root():
    """(c) Unmatched token resets to root; if it's in root.children, descends."""
    token_map = {"foo": [1], " foo": [2], "bar": [3]}
    trie = _make_trie(token_map)

    lp = _PerReqHotwordTrieLP(trie, TRIE_LAMBDA)
    # Advance to foo node (token 1)
    lp([1], _fake_logits())
    assert lp.node is trie["children"][1]

    # Now output an unmatched token (99, not in foo's children)
    logits = _fake_logits(vocab_size=500)
    result = lp([1, 99], logits.clone())
    # 99 is not in foo-node.children → reset to root; 99 not in root.children → stay at root
    assert lp.node is trie, "Should have reset to root"
    # Bias = root.children = {1, 2, 3}
    assert result[1].item() > 0.0
    assert result[2].item() > 0.0
    assert result[3].item() > 0.0


def test_unmatched_then_root_child_descends():
    """(c-2) If unmatched token happens to be a root child, descend into it."""
    token_map = {"foo": [1], " foo": [2]}
    trie = _make_trie(token_map)

    lp = _PerReqHotwordTrieLP(trie, TRIE_LAMBDA)
    # Start from some non-root node by advancing to 1
    lp([1], _fake_logits())

    # Now output token 2 which is NOT a child of node[1] but IS a root child
    logits = _fake_logits(vocab_size=500)
    lp([1, 2], logits.clone())
    # After reset, token 2 found in root.children → cursor descended into root[2]
    assert lp.node is trie["children"][2], "Should have descended into root[2]"


def test_terminal_leaf_no_children_next_mismatch_resets():
    """(d) Terminal leaf (no children) → next step's mismatch resets to root."""
    token_map = {"foo": [1], " foo": [2]}
    trie = _make_trie(token_map)

    lp = _PerReqHotwordTrieLP(trie, TRIE_LAMBDA)

    # Advance to foo terminal leaf (token 1)
    lp([1], _fake_logits())
    foo_node = trie["children"][1]
    assert foo_node["terminal"] is True
    assert foo_node["children"] == {}, "foo node should be a terminal leaf"
    assert lp.node is foo_node

    # Next token: something not in foo_node.children (which is empty) → reset
    lp([1, 99], _fake_logits())
    assert lp.node is trie, "Should have reset to root after terminal leaf mismatch"


def test_new_req_lp_returns_none_when_trie_is_none():
    """(e) HotwordTriePerReqLP.new_req_logits_processor returns None when trie is None."""
    state.set_trie(None)
    lp = HotwordTriePerReqLP()
    result = lp.new_req_logits_processor(None)
    assert result is None


def test_new_req_lp_returns_instance_when_trie_set():
    """(e-2) Returns a _PerReqHotwordTrieLP when trie is set."""
    trie = {"children": {}, "terminal": False}
    state.set_trie(trie)
    try:
        lp = HotwordTriePerReqLP()
        result = lp.new_req_logits_processor(None)
        assert isinstance(result, _PerReqHotwordTrieLP)
    finally:
        state.set_trie(None)


def test_is_argmax_invariant_returns_false():
    """(f) is_argmax_invariant() returns False."""
    lp = HotwordTriePerReqLP()
    assert lp.is_argmax_invariant() is False


def test_empty_trie_no_op():
    """(g) Codex Step 9 Low: empty trie root → LP biases nothing, no crash.

    Empty trie ({"children": {}, "terminal": False}) should be a no-op for any
    output_ids. Regression guard: if _PerReqHotwordTrieLP ever errors on
    root.children being empty, this catches it.
    """
    empty_root = {"children": {}, "terminal": False}
    lp = _PerReqHotwordTrieLP(empty_root, 5.0)

    # Empty output_ids
    logits_a = _fake_logits()
    out_a = lp([], logits_a)
    assert torch.equal(out_a, _fake_logits()), "Empty trie + empty output should leave logits unchanged"

    # Non-empty output_ids — should also be no-op (no child to descend to)
    logits_b = _fake_logits()
    out_b = lp([123], logits_b)
    assert torch.equal(out_b, _fake_logits()), "Empty trie + any token should leave logits unchanged"
    assert lp.node is empty_root, "Cursor should stay at root (already there)"


def test_lp_applies_correct_lambda():
    """LP applies exactly TRIE_LAMBDA to biased indices."""
    token_map = {"hi": [7], " hi": [8]}
    trie = _make_trie(token_map)

    lp = _PerReqHotwordTrieLP(trie, 3.0)
    logits = _fake_logits(vocab_size=500)
    result = lp([], logits.clone())
    assert abs(result[7].item() - 3.0) < 1e-6, f"Expected +3.0 on token 7, got {result[7].item()}"
    assert abs(result[8].item() - 3.0) < 1e-6


def test_only_two_methods_overridden_in_adapter():
    """Adapter subclass defines only is_argmax_invariant and new_req_logits_processor."""
    # Only these two should be defined on the subclass itself
    defined_in_subclass = {
        name for name in vars(HotwordTriePerReqLP)
        if not name.startswith("__")
    }
    assert "is_argmax_invariant" in defined_in_subclass
    assert "new_req_logits_processor" in defined_in_subclass
    # __init__, apply, update_state must NOT be overridden
    for forbidden in ("__init__", "apply", "update_state"):
        assert forbidden not in vars(HotwordTriePerReqLP), (
            f"{forbidden} must NOT be overridden in HotwordTriePerReqLP"
        )
