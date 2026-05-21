"""Tests for the custom-mode {var} substitution helper + gate."""
import importlib.util
import os
import sys
from pathlib import Path
from unittest.mock import MagicMock


def _import_gateway():
    class _FakeApp:
        def get(self, *a, **kw):
            return lambda f: f

        def post(self, *a, **kw):
            return lambda f: f

        def add_middleware(self, *a, **kw):
            pass

    def _fake_fastapi_ctor(*a, **kw):
        return _FakeApp()

    fake_fastapi = MagicMock()
    fake_fastapi.FastAPI = _fake_fastapi_ctor
    fake_fastapi.Request = type("Request", (), {})
    fake_fastapi.HTTPException = type("HTTPException", (Exception,), {})

    sys.modules["fastapi"] = fake_fastapi
    sys.modules["fastapi.responses"] = MagicMock()
    sys.modules["fastapi.middleware.cors"] = MagicMock()

    os.environ.pop("GATEWAY_PORT", None)

    repo_root = Path(__file__).resolve().parent.parent
    server_dir = repo_root / "server"
    if str(server_dir) not in sys.path:
        sys.path.insert(0, str(server_dir))

    gw_path = server_dir / "mini-gateway.py"
    spec = importlib.util.spec_from_file_location("mini_gateway", gw_path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


gw = _import_gateway()
sub = gw._substitute_template
gate = gw._maybe_substitute


def test_helper_is_exposed_at_module_top_level():
    assert callable(sub)
    assert callable(gate)


def test_all_three_placeholders_substituted():
    out = sub(
        "T:{text} S:{selected} C:{clipboard}",
        text="hello",
        selected="world",
        clipboard="foo",
    )
    assert out == "T:hello S:world C:foo"


def test_missing_value_falls_through_as_empty_string():
    out = sub("a {selected} b", text="", selected="", clipboard="")
    assert out == "a  b"


def test_template_without_placeholders_unchanged():
    template = "Plain template, no variables."
    out = sub(template, text="x", selected="y", clipboard="z")
    assert out == template


def test_multi_occurrence_all_replaced():
    out = sub(
        "{selected} and {selected} again",
        text="",
        selected="HI",
        clipboard="",
    )
    assert out == "HI and HI again"


def test_special_chars_inserted_verbatim():
    """Newlines, quotes, CJK, braces in values must not break or escape."""
    nasty = 'line1\nline2 "quoted" 中文 {not-a-placeholder}'
    out = sub("X={selected}=Y", text="", selected=nasty, clipboard="")
    assert out == f"X={nasty}=Y"


def test_value_containing_placeholder_is_not_re_expanded():
    """Single-pass regex: a value that contains '{clipboard}' must NOT
    have that placeholder re-substituted. This is the key safety
    property for user-controlled prompt-injection isolation."""
    out = sub(
        "X={selected}=Y",
        text="",
        selected="abc{clipboard}def",
        clipboard="ZZZ",
    )
    assert out == "X=abc{clipboard}def=Y"  # NOT "X=abcZZZdef=Y"


def test_value_containing_text_placeholder_is_not_re_expanded():
    """Same property in the other direction — value contains {text}."""
    out = sub(
        "{selected}",
        text="WILL-NOT-APPEAR",
        selected="{text}",
        clipboard="",
    )
    assert out == "{text}"


def test_gate_skips_built_in_mode():
    """For polish/strict/translate/prompt the template is returned
    unchanged, even if it has placeholder syntax."""
    for mode in ("polish", "strict_correction", "translate", "prompt"):
        out = gate(
            mode,
            "Has {selected} placeholder",
            text="t",
            selected="SHOULD-NOT-APPEAR",
            clipboard="c",
        )
        assert out == "Has {selected} placeholder"


def test_gate_skips_custom_with_empty_template():
    out = gate("custom", "", text="t", selected="s", clipboard="c")
    assert out == ""


def test_gate_skips_custom_with_whitespace_only_template():
    """llm_process treats whitespace-only as empty (falls back to
    LLM_PROMPT). Gate must agree so we don't substitute into garbage."""
    out = gate("custom", "   \n\t  ", text="t", selected="s", clipboard="c")
    assert out == "   \n\t  "  # returned unchanged; downstream falls back


def test_gate_fires_on_custom_with_nonempty_template():
    out = gate(
        "custom",
        "Selection: {selected}",
        text="t",
        selected="HELLO",
        clipboard="c",
    )
    assert out == "Selection: HELLO"

