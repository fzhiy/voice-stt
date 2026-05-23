#!/usr/bin/env python3
"""Dev-only scaffold: crude B-WER proxy for trie biasing A/B evaluation.

Usage (after deploy with TRIE_BIASING_ENABLED=1):
    python scripts/eval-trie-bias.py ~/voice-stack/history/2026-05.jsonl

The script reads held-out transcript pairs from a JSONL history file
(client-side format: see docs/ARCHITECTURE.md §History), keeps only rows
where `paraformer_raw` differs from `final_text`, and computes a crude
biased-word error rate (B-WER) proxy comparing `paraformer_raw` against
a reference column (`final_text` or `corrected_text` when present).

This is a scaffold — the Lead runs it post-deploy, not in CI.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def _load_pairs(jsonl_path: Path) -> list[dict]:
    """Return rows where paraformer_raw != final_text (candidate improvements)."""
    pairs = []
    with jsonl_path.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            raw = row.get("paraformer_raw", "")
            final = row.get("final_text", "")
            if raw and final and raw != final:
                pairs.append(row)
    return pairs


def _word_error_rate(hyp: str, ref: str) -> float:
    """Crude WER: Levenshtein word-level distance / len(ref.split())."""
    h = hyp.split()
    r = ref.split()
    if not r:
        return 0.0
    # Dynamic programming
    d = list(range(len(h) + 1))
    for ri, rw in enumerate(r):
        d2 = [ri + 1]
        for hi, hw in enumerate(h):
            d2.append(min(d2[-1] + 1, d[hi + 1] + 1, d[hi] + (0 if hw == rw else 1)))
        d = d2
    return d[-1] / len(r)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("jsonl", type=Path, help="Path to history JSONL file")
    parser.add_argument("--ref-col", default="corrected_text",
                        help="Reference column (fallback: final_text). Default: corrected_text")
    args = parser.parse_args()

    if not args.jsonl.exists():
        print(f"ERROR: file not found: {args.jsonl}", file=sys.stderr)
        sys.exit(1)

    pairs = _load_pairs(args.jsonl)
    if not pairs:
        print("No differing pairs found — nothing to evaluate.")
        return

    wer_raw_total = 0.0
    wer_final_total = 0.0
    n = 0

    for row in pairs:
        ref = row.get(args.ref_col) or row.get("final_text", "")
        if not ref:
            continue
        raw = row.get("paraformer_raw", "")
        final = row.get("final_text", "")
        wer_raw_total += _word_error_rate(raw, ref)
        wer_final_total += _word_error_rate(final, ref)
        n += 1

    if n == 0:
        print("No evaluable pairs (reference column empty).")
        return

    wer_raw = wer_raw_total / n
    wer_final = wer_final_total / n
    improvement = (wer_raw - wer_final) / wer_raw * 100 if wer_raw > 0 else 0.0

    print(f"Evaluated {n} differing pairs from {args.jsonl.name}")
    print(f"  paraformer_raw  B-WER: {wer_raw:.3f}")
    print(f"  final_text      B-WER: {wer_final:.3f}")
    print(f"  relative improvement: {improvement:.1f}%")
    print()
    print("NOTE: This is a dev scaffold — run manually post-deploy, not in CI.")
    print("      'B-WER' here is a proxy; it is not standard WER.")


if __name__ == "__main__":
    main()
