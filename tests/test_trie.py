"""P0 unit tests for server/biasing/trie.py.

Uses a deterministic mock tokenizer — no real model load.
Mock tokenizer: splits on spaces, hashes each token to an int in [1, 9999].
Leading-space variant gets different hash to simulate BPE context-dependence.
"""
import sys
from pathlib import Path

# Make biasing/ importable via server pythonpath
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "server"))

from biasing.trie import build_trie, count_nodes


def _mock_tokenizer(text: str, add_special_tokens: bool = False) -> list[int]:
    """Deterministic mock: splits on whitespace, returns hash-based token ids.

    Returns ids list directly (not a HuggingFace encoding object).
    Leading space changes the hash so 'iPhone' != ' iPhone' tokens.
    """
    tokens = text.split()
    return [abs(hash(t + str(i))) % 9000 + 1 for i, t in enumerate(tokens)]


def _mock_tokenizer_bpe(text: str, add_special_tokens: bool = False) -> list[int]:
    """BPE-like mock: tokenizes character-by-character, different for leading space."""
    # Simulate BPE context-dependence: leading space changes first token
    if text.startswith(" "):
        prefix_id = abs(hash("_SPACE_" + text[1:2])) % 9000 + 1
        rest_ids = [abs(hash(c + str(i))) % 9000 + 1 for i, c in enumerate(text[1:])]
        return [prefix_id] + rest_ids[1:]
    return [abs(hash(c + str(i))) % 9000 + 1 for i, c in enumerate(text)]


def test_smoke_returns_dict_with_children():
    """(a) build_trie returns dict with 'children' root key."""
    trie = build_trie(["iPhone"], _mock_tokenizer)
    assert isinstance(trie, dict)
    assert "children" in trie
    assert "terminal" in trie


def test_terminal_markers_correct_depth():
    """(b) Terminal markers placed correctly on encoded terms."""
    # "foo bar" tokenizes to 2 tokens; terminal should be at depth 2
    trie = build_trie(["foo bar"], _mock_tokenizer)
    # root → first-token → second-token (terminal=True)
    # Both 'foo bar' and ' foo bar' are inserted; check one path
    # The path for 'foo bar' (without leading space)
    ids = _mock_tokenizer("foo bar")
    assert len(ids) == 2
    node = trie
    for i, tid in enumerate(ids):
        assert tid in node["children"], f"token {tid} at depth {i} missing"
        node = node["children"][tid]
    assert node["terminal"] is True


def test_two_tokenization_entries_dont_collide():
    """(c) Both encodings (with/without leading space) reachable from root."""
    trie = build_trie(["iPhone"], _mock_tokenizer_bpe)
    ids_plain = _mock_tokenizer_bpe("iPhone")
    ids_space = _mock_tokenizer_bpe(" iPhone")
    assert ids_plain != ids_space, "Mock tokenizer must produce different ids for leading-space variant"
    # Both paths must be reachable from root
    for ids, label in [(ids_plain, "plain"), (ids_space, "with-leading-space")]:
        node = trie
        for tid in ids:
            assert tid in node["children"], f"[{label}] token {tid} missing in trie"
            node = node["children"][tid]
        assert node["terminal"] is True, f"[{label}] terminal not set"


def test_prefix_pair_claude_code():
    """(d) 'Claude' terminal node has children continuing to 'Code' tokens (F4)."""
    # We use tokens: Claude=[10], Code=[20], ' Claude'=[30], ' Code'=[40]
    # Use a custom tokenizer that maps these deterministically
    token_map = {
        "Claude": [10],
        " Claude": [30],
        "Claude Code": [10, 20],
        " Claude Code": [30, 40],
    }

    def _tokenizer(text: str, add_special_tokens: bool = False) -> list[int]:
        return token_map.get(text, [abs(hash(text)) % 9000 + 1])

    trie = build_trie(["Claude", "Claude Code"], _tokenizer)

    # Walk to the 'Claude' terminal node (via plain 'Claude' path: [10])
    node = trie
    assert 10 in node["children"], "First token of 'Claude' not in root.children"
    claude_node = node["children"][10]
    assert claude_node["terminal"] is True, "'Claude' node should be terminal"
    # And it must have children leading to 'Code' (token 20)
    assert claude_node["children"], "'Claude' terminal node must have children for 'Code'"
    assert 20 in claude_node["children"], "Token for 'Code' must be a child of 'Claude' node"
    code_node = claude_node["children"][20]
    assert code_node["terminal"] is True, "'Claude Code' endpoint must be terminal"


def test_empty_term_list():
    """(e) Empty term list → trie has empty root.children."""
    trie = build_trie([], _mock_tokenizer)
    assert trie["children"] == {}
    assert trie["terminal"] is False


def test_two_tokenization_builds_two_paths_iphone():
    """Two-tokenization entries: build_trie(['iPhone']) with mock BPE creates two root-child paths."""
    trie = build_trie(["iPhone"], _mock_tokenizer_bpe)
    ids_plain = _mock_tokenizer_bpe("iPhone")
    ids_space = _mock_tokenizer_bpe(" iPhone")
    assert ids_plain[0] != ids_space[0], "Leading-space must change first token"
    # Both first tokens must be children of root
    assert ids_plain[0] in trie["children"]
    assert ids_space[0] in trie["children"]


def test_count_nodes_nonempty():
    """count_nodes returns > 1 for a non-empty trie."""
    trie = build_trie(["hello world"], _mock_tokenizer)
    assert count_nodes(trie) > 1
