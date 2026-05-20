"""Tests for mini-gateway mode prompt registry."""
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

    # Defensive: ensure no stray GATEWAY_PORT trips port_from_env at import.
    os.environ.pop("GATEWAY_PORT", None)

    repo_root = Path(__file__).resolve().parent.parent
    server_dir = repo_root / "server"
    # mini-gateway.py does `import config_validation` (sibling module).
    # pytest config already adds server/ via pythonpath, but be explicit so
    # this helper is safe outside the pytest harness too.
    if str(server_dir) not in sys.path:
        sys.path.insert(0, str(server_dir))

    gw_path = server_dir / "mini-gateway.py"
    spec = importlib.util.spec_from_file_location("mini_gateway", gw_path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


gw = _import_gateway()


def test_strict_correction_mode_registered():
    assert "strict_correction" in gw.MODE_PROMPTS
    prompt = gw.MODE_PROMPTS["strict_correction"]
    assert isinstance(prompt, str) and prompt.strip()


def test_strict_correction_uses_named_constant():
    """Catches a worker who inlines the prompt literally into the dict."""
    assert gw.MODE_PROMPTS["strict_correction"] is gw.STRICT_CORRECTION_PROMPT


def test_strict_correction_preserves_fillers():
    """Discriminator #1: must tell LLM to keep fillers, else it's just polish.
    Allowlist phrases are filler-specific (require an explicit filler-noun
    or filler-anchored verb) to avoid false-positives like '保留术语'."""
    prompt = gw.MODE_PROMPTS["strict_correction"].lower()
    keep_filler_phrases = (
        "保留 filler",
        "保留口头填充",
        "保留语气词",
        "不移除填充",
        "不移除口头",
        "不删填充",
        "不要删填充",
        "do not remove filler",
        "don't remove filler",
        "preserve filler",
        "keep filler",
        "preserves filler",
        "keeps filler",
    )
    assert any(p.lower() in prompt for p in keep_filler_phrases)


def test_strict_correction_forbids_punctuation_addition():
    """Discriminator #2: separates strict from polish, which ADDS punctuation.
    Allowlist requires an explicit no-ADD instruction (not a vague
    'preserve punctuation' which could still permit additions)."""
    prompt = gw.MODE_PROMPTS["strict_correction"].lower()
    no_punct_phrases = (
        "不添加标点",
        "不加标点",
        "不新增标点",
        "不要加标点",
        "do not add punctuation",
        "don't add punctuation",
        "do not add new punctuation",
        "no punctuation added",
        "no new punctuation",
    )
    assert any(p.lower() in prompt for p in no_punct_phrases)


def test_existing_modes_unchanged():
    for key in ("polish", "translate", "prompt"):
        assert key in gw.MODE_PROMPTS
    # quick / custom intentionally bypass MODE_PROMPTS (handled in llm_process).
    assert "quick" not in gw.MODE_PROMPTS
    assert "custom" not in gw.MODE_PROMPTS


def test_strict_correction_not_alias_of_polish():
    assert gw.MODE_PROMPTS["strict_correction"] is not gw.MODE_PROMPTS["polish"]
    assert gw.MODE_PROMPTS["strict_correction"] != gw.MODE_PROMPTS["polish"]

