"""Vocab mapping unit tests.

Imports `server/funasr-stream-server.py` directly so the test exercises the
real mapping path. Heavy ML deps are stubbed *before* import so model loading
doesn't fire on the test process.

Coverage:
  Positives:
    1. Single LHS->RHS with case-insensitive LHS, preserved RHS case
    2. Longest LHS first wins over shorter overlap
    3. Multiple distinct mappings in one input
    4. Word-boundary lets standalone short LHS work (but only at boundary)
    5. CJK LHS via substring (no \\b between CJK chars)

  Negatives (whitelist-filter-adjacent — pin apply_mappings boundary behavior
  so the upstream whitelist filter's job is well-defined):
    6. Empty MAPPINGS -> text unchanged
    7. Empty text -> empty output
    8. LHS not present -> unchanged
    9. Word boundary protects substring inside longer ASCII word
   10. Identity-mapping (LHS==RHS, mixed case) is a no-op after collapse
"""
import importlib.util
import os
import sys
from pathlib import Path
from unittest.mock import MagicMock


def _import_server_module():
    """Load funasr-stream-server.py without triggering heavy model loads.
    Stubs ML / network deps (numpy / funasr / websockets / webrtcvad / yaml fallback)
    so local dev box without the streamenv venv can still run the tests."""
    # numpy: only need np.frombuffer etc. for inference paths — never called here
    # numpy stays real (tests/conftest.py imports it first, making this setdefault
    # a no-op) — text_postprocess needs the genuine ndarray. funasr/webrtcvad are
    # force-stubbed (assignment, not setdefault) and the safety env vars are forced,
    # so the import never touches real models even when pytest runs from the actual
    # ASR venv where those packages exist.
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
apply_mappings = srv.apply_mappings
load_mappings = srv.load_mappings


def _set(mappings):
    srv.MAPPINGS = mappings


# ----- positives (decision-tree §3) -----

def test_basic_lhs_rhs_case_insensitive_lhs_preserved_rhs():
    _set({"cloud code": "Claude Code"})
    assert apply_mappings("this cloud code rocks") == "this Claude Code rocks"
    assert apply_mappings("THIS CLOUD CODE rocks") == "THIS Claude Code rocks"


def test_longest_lhs_first_wins():
    _set({
        "cloud code cli": "Claude Code CLI",
        "cloud code": "Claude Code",
    })
    assert apply_mappings("run cloud code cli now") == "run Claude Code CLI now"
    assert apply_mappings("run cloud code now") == "run Claude Code now"


def test_multiple_distinct_lhs_in_one_input():
    _set({
        "should also S": "Shift+Alt+S",
        "ghosty": "Ghostty",
    })
    out = apply_mappings("press should also S then open ghosty")
    assert out == "press Shift+Alt+S then open Ghostty"


def test_short_lhs_with_spaces_at_boundary_works():
    """LHS containing internal spaces still gets \\b-anchored at outer edges."""
    _set({"m c p": "MCP"})
    assert apply_mappings("use m c p server") == "use MCP server"


def test_cjk_lhs_substring_replace():
    """CJK LHS doesn't get \\b; relies on whitelist preventing common-word LHS."""
    _set({"福川": "浮窗"})
    assert apply_mappings("我说福川对吗") == "我说浮窗对吗"


# ----- negatives (whitelist-filter-adjacent) -----

def test_empty_mappings_passthrough():
    _set({})
    assert apply_mappings("anything cloud code here") == "anything cloud code here"


def test_empty_text_passthrough():
    _set({"cloud code": "Claude Code"})
    assert apply_mappings("") == ""
    assert apply_mappings(None) is None  # falsy guard


def test_no_match_unchanged():
    _set({"qwen": "Qwen"})
    assert apply_mappings("nothing related here") == "nothing related here"


def test_word_boundary_protects_substring():
    """`ai`->`AI` must NOT match inside `rain`/`said`/`fair`."""
    _set({"ai": "AI"})
    assert apply_mappings("the rain in spain stays mainly") == "the rain in spain stays mainly"
    assert apply_mappings("i said fair") == "i said fair"
    # standalone still works
    assert apply_mappings("an ai tool") == "an AI tool"


def test_identity_mapping_after_case_fold_is_noop():
    """LHS==RHS (case-insensitive) is a no-op; same string returned even though
    re.subn fires. Demonstrates that the upstream whitelist filter should
    drop such mappings before they reach apply_mappings."""
    _set({"Claude": "Claude"})
    assert apply_mappings("Claude is ready") == "Claude is ready"
    _set({"claude": "Claude"})  # case-only "fix" — still works
    assert apply_mappings("claude is ready") == "Claude is ready"


# ----- load_mappings I/O smoke test -----

def test_load_mappings_from_real_yaml(tmp_path):
    """Sanity-check the YAML loader: empty mappings: yields {}, dict yaml yields dict."""
    p = tmp_path / "hw.yaml"
    p.write_text("mappings:\n", encoding="utf-8")
    assert load_mappings(str(p)) == {}

    p.write_text(
        'mappings:\n'
        '  "cloud code": "Claude Code"\n'
        '  "ghosty": "Ghostty"\n',
        encoding="utf-8",
    )
    out = load_mappings(str(p))
    assert out == {"cloud code": "Claude Code", "ghosty": "Ghostty"}


def test_load_mappings_missing_section_returns_empty(tmp_path):
    p = tmp_path / "hw.yaml"
    p.write_text("user_added:\n  - foo\n", encoding="utf-8")
    assert load_mappings(str(p)) == {}
