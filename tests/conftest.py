"""Shared pytest setup.

test_mappings.py imports funasr-stream-server.py with heavy deps stubbed via
`sys.modules.setdefault(...)` so models never load. Importing the real numpy
here first makes that setdefault a no-op for numpy specifically, so
test_text_postprocess.py's silence-trim tests get the real ndarray
implementation instead of a MagicMock. numpy is a declared dependency, so it
is always present in CI.
"""
import numpy  # noqa: F401  (imported for its side effect: populate sys.modules first)
