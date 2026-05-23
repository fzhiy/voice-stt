"""Trie state container — vLLM-free.

Holds the module-global hotword trie reference. No vLLM / torch imports.
The trie is a fork-time snapshot: set_trie() MUST be called BEFORE
final_backend.load() so vLLM's EngineCore subprocess (forked during
vllm.LLM() construction) inherits the populated trie.
"""

_HOTWORD_TRIE: dict | None = None


def set_trie(t: dict | None) -> None:
    """Atomically replace the trie reference (no in-place mutation)."""
    global _HOTWORD_TRIE
    _HOTWORD_TRIE = t


def get_trie() -> dict | None:
    """Return the current trie root, or None if not set."""
    return _HOTWORD_TRIE
