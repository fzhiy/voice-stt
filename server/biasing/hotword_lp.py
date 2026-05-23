"""Hotword trie logits processor — vLLM-coupled.

Imports vllm.v1.sample.logits_processor.AdapterLogitsProcessor and torch.
This module MUST only be imported inside the `if TRIE_BIASING_ENABLED:` branch
in server/backends/qwen3_asr.py:_load_vllm — never at module top level.

TRIE_LAMBDA env var (default 5.0) is read at module import time.
"""
from __future__ import annotations

import os

import torch
from vllm.v1.sample.logits_processor import AdapterLogitsProcessor

from biasing.state import get_trie

TRIE_LAMBDA: float = float(os.environ.get("TRIE_LAMBDA", "5.0"))


class _PerReqHotwordTrieLP:
    """Per-request prefix-safe trie logits processor (single-cursor design).

    Bias strategy (Codex R1-F4 + R2-F1):
      - Maintain one cursor (self.node) in the trie.
      - Each decode step, advance by output_ids[-1]:
          * token in current node's children → descend
          * token NOT in current node's children → reset to root;
            if token is also in root.children, descend into that root-child
      - Terminal-with-children: stay (don't reset) so longer hotwords keep biasing
      - Terminal-leaf (no children): cursor stays at terminal leaf; next step's
        mismatch will reset to root via the normal "NOT in children" branch
      - Bias = current_node.children.keys() UNION root.children.keys()
        (union seeds fresh matches at every step)
    """

    def __init__(self, trie_root: dict, lambda_: float) -> None:
        self.root = trie_root
        self.node = trie_root
        self.lambda_ = lambda_

    def __call__(self, output_ids: list[int], logits: torch.Tensor) -> torch.Tensor:
        if output_ids:
            last = output_ids[-1]
            children = self.node["children"]
            if last in children:
                self.node = children[last]
                # Terminal-with-children: stay so longer phrases keep biasing.
                # Terminal-leaf: stay too; next mismatch resets via else branch.
            else:
                # No match in current node — reset to root.
                self.node = self.root
                # If last token starts a new match from root, descend.
                root_children = self.root["children"]
                if last in root_children:
                    self.node = root_children[last]

        # Bias indices = current node's children + root's children (union)
        bias_ids: set[int] = set(self.node["children"])
        bias_ids.update(self.root["children"])
        if bias_ids:
            idx = torch.tensor(sorted(bias_ids), dtype=torch.long, device=logits.device)
            logits[idx] += self.lambda_
        return logits


class HotwordTriePerReqLP(AdapterLogitsProcessor):
    """Engine-level adapter — registered once at vLLM engine startup.

    Overrides ONLY is_argmax_invariant() and new_req_logits_processor().
    __init__, apply, and update_state are handled by AdapterLogitsProcessor base.
    """

    def is_argmax_invariant(self) -> bool:
        return False

    def new_req_logits_processor(self, params):  # type: ignore[override]
        trie = get_trie()
        if trie is None:
            return None
        return _PerReqHotwordTrieLP(trie, TRIE_LAMBDA)
