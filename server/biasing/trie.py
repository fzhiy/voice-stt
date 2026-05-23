"""Token-id trie builder — vLLM-free, no I/O.

Each node: {"children": {token_id: node, ...}, "terminal": bool}
Root has terminal=False.

For each hotword term two entries are built:
  tokenize(term)        — handles "iPhone" when it starts a sentence
  tokenize(' ' + term)  — handles " iPhone" with a leading space in BPE context

Both paths are merged into the single trie. Entries that produce an empty
token list after encoding are skipped.
"""
from __future__ import annotations


def build_trie(terms: list[str], tokenizer) -> dict:
    """Build and return a token-id trie from *terms* using *tokenizer*.

    *tokenizer* must support __call__(text, add_special_tokens=False)
    and return an object with an .ids attribute (HuggingFace fast tokenizer
    convention), OR return a list[int] directly.

    Both tokenize(term) and tokenize(' '+term) are inserted.
    """
    root: dict = {"children": {}, "terminal": False}

    def _encode(text: str) -> list[int]:
        result = tokenizer(text, add_special_tokens=False)
        if isinstance(result, list):
            return result
        ids = getattr(result, "ids", None)
        if ids is not None:
            return ids
        # HuggingFace BatchEncoding / dict-like
        return list(result["input_ids"])

    def _insert(ids: list[int]) -> None:
        if not ids:
            return
        node = root
        for i, tid in enumerate(ids):
            children = node["children"]
            if tid not in children:
                children[tid] = {"children": {}, "terminal": False}
            node = children[tid]
        node["terminal"] = True

    for term in terms:
        term = term.strip()
        if not term:
            continue
        _insert(_encode(term))
        _insert(_encode(" " + term))

    return root


def count_nodes(root: dict) -> int:
    """Count total nodes in the trie (including root), BFS."""
    count = 1
    stack = list(root["children"].values())
    while stack:
        node = stack.pop()
        count += 1
        stack.extend(node["children"].values())
    return count
