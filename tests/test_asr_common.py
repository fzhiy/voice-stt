"""Unit tests for the shared ASR helpers in server/asr_common.py.

Pure functions only (no GPU / model / network): the vocab loading + secrets
parsing + post-correct core that every cloud provider depends on.
"""
from pathlib import Path

import pytest

import asr_common as ac


def _write(p: Path, text: str) -> str:
    p.write_text(text, encoding="utf-8")
    return str(p)


# ---------- parse_env_file ----------

def test_parse_env_file_strips_quotes_and_filters_keys(tmp_path):
    p = tmp_path / "secrets.env"
    _write(p,
        "# a comment\n"
        'API_KEY="abc123"\n'
        "SECRET = 'xyz'\n"
        "EXTRA=should_be_ignored\n"
        "\n",
    )
    out = ac.parse_env_file(p, ["API_KEY", "SECRET"])
    assert out == {"API_KEY": "abc123", "SECRET": "xyz"}


def test_parse_env_file_missing_file_raises(tmp_path):
    with pytest.raises(FileNotFoundError):
        ac.parse_env_file(tmp_path / "nope.env", ["A"])


def test_parse_env_file_missing_required_key_raises(tmp_path):
    p = tmp_path / "s.env"
    _write(p, "A=1\n")
    with pytest.raises(ValueError):
        ac.parse_env_file(p, ["A", "B"])


# ---------- load_hotwords_terms ----------

def test_load_hotwords_terms_flattens_and_skips_mappings(tmp_path):
    path = _write(tmp_path / "hw.yaml",
        "ai_agent:\n"
        "  - Claude Code\n"
        "  - Codex\n"
        "mappings:\n"
        '  "cloud code": "Claude Code"\n',
    )
    terms = ac.load_hotwords_terms(path)
    assert "Claude Code" in terms
    assert "Codex" in terms
    assert "cloud code" not in terms  # mappings section must not leak in as a term


def test_load_hotwords_terms_dedup_case_insensitive(tmp_path):
    path = _write(tmp_path / "hw.yaml", "a:\n  - Tailscale\n  - tailscale\n")
    assert ac.load_hotwords_terms(path) == ["Tailscale"]


def test_load_hotwords_terms_length_filters(tmp_path):
    path = _write(tmp_path / "hw.yaml", "a:\n  - ab\n  - abc\n  - 中\n  - 中文\n")
    terms = ac.load_hotwords_terms(path)  # defaults: min_ascii_len=3, min_cjk_len=2
    assert "ab" not in terms   # ASCII shorter than 3 dropped
    assert "abc" in terms
    assert "中" not in terms     # single CJK char dropped
    assert "中文" in terms


def test_load_hotwords_terms_max_count(tmp_path):
    body = "a:\n" + "".join(f"  - term{i:03d}\n" for i in range(10))
    path = _write(tmp_path / "hw.yaml", body)
    assert len(ac.load_hotwords_terms(path, max_count=5)) == 5


def test_load_hotwords_terms_missing_file():
    assert ac.load_hotwords_terms("/no/such/file.yaml") == []


# ---------- load_mappings ----------

def test_load_mappings_quoted_and_unquoted(tmp_path):
    path = _write(tmp_path / "hw.yaml",
        "other:\n  - x\n"
        "mappings:\n"
        '  "cloud code": "Claude Code"\n'
        "  ghosty: Ghostty\n",
    )
    assert ac.load_mappings(path) == {"cloud code": "Claude Code", "ghosty": "Ghostty"}


def test_load_mappings_missing_file():
    assert ac.load_mappings("/no/such.yaml") == {}


# ---------- apply_mappings ----------

def test_apply_mappings_longest_first_case_insensitive():
    mp = {"cloud code cli": "Claude Code CLI", "cloud code": "Claude Code"}
    assert ac.apply_mappings("run CLOUD CODE CLI now", mp) == "run Claude Code CLI now"
    assert ac.apply_mappings("run cloud code now", mp) == "run Claude Code now"


def test_apply_mappings_ascii_word_boundary():
    mp = {"ai": "AI"}
    assert ac.apply_mappings("the rain in spain", mp) == "the rain in spain"  # no match inside word
    assert ac.apply_mappings("an ai tool", mp) == "an AI tool"


def test_apply_mappings_cjk_substring():
    assert ac.apply_mappings("我说福川对吗", {"福川": "浮窗"}) == "我说浮窗对吗"


def test_apply_mappings_empty_inputs():
    assert ac.apply_mappings("", {"a": "b"}) == ""
    assert ac.apply_mappings("x", {}) == "x"


# ---------- env helpers ----------

def test_env_helpers(monkeypatch, tmp_path):
    monkeypatch.setenv("VS_STR", "hello")
    monkeypatch.setenv("VS_INT", "42")
    monkeypatch.setenv("VS_PATH", str(tmp_path))
    assert ac.env_str("VS_STR", "def") == "hello"
    assert ac.env_str("VS_MISSING", "def") == "def"
    assert ac.env_int("VS_INT", 0) == 42
    assert ac.env_int("VS_MISSING", 7) == 7
    assert ac.env_path("VS_PATH", lambda: Path("/default")) == tmp_path
    assert ac.env_path("VS_MISSING", lambda: Path("/default")) == Path("/default")
