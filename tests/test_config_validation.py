"""Unit tests for server/config_validation.py (startup fail-fast helpers)."""
import pytest

import config_validation as cfg


def test_port_from_env_default(monkeypatch):
    monkeypatch.delenv("VS_PORT", raising=False)
    assert cfg.port_from_env("VS_PORT", 8082) == 8082


def test_port_from_env_valid(monkeypatch):
    monkeypatch.setenv("VS_PORT", "9090")
    assert cfg.port_from_env("VS_PORT", 8082) == 9090


def test_port_from_env_non_numeric_exits(monkeypatch, capsys):
    monkeypatch.setenv("VS_PORT", "abc")
    with pytest.raises(SystemExit) as ei:
        cfg.port_from_env("VS_PORT", 8082)
    assert ei.value.code == 2
    err = capsys.readouterr().err
    assert "VS_PORT" in err and "config error" in err


def test_port_from_env_out_of_range_exits(monkeypatch):
    monkeypatch.setenv("VS_PORT", "70000")
    with pytest.raises(SystemExit) as ei:
        cfg.port_from_env("VS_PORT", 8082)
    assert ei.value.code == 2


def test_fail_exits_with_code_2(capsys):
    with pytest.raises(SystemExit) as ei:
        cfg.fail("boom")
    assert ei.value.code == 2
    assert "boom" in capsys.readouterr().err


def test_warn_is_non_fatal(capsys):
    cfg.warn("heads up")  # must not raise
    assert "heads up" in capsys.readouterr().err


def test_warn_if_path_missing(tmp_path, capsys):
    cfg.warn_if_path_missing("HOTWORDS_FILE", str(tmp_path / "nope.yaml"))
    assert "missing file" in capsys.readouterr().err
    p = tmp_path / "exists.yaml"
    p.write_text("x", encoding="utf-8")
    cfg.warn_if_path_missing("HOTWORDS_FILE", str(p))
    assert capsys.readouterr().err == ""  # present file → silent
    cfg.warn_if_path_missing("HOTWORDS_FILE", None)
    assert capsys.readouterr().err == ""  # unset → silent
