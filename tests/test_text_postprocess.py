"""Unit tests for deterministic ASR post-processing in server/text_postprocess.py.

Pure functions: homophone post-correct, filler removal, snippet expansion,
silence trim. No GPU / model needed (numpy is the only runtime dep).
"""
import numpy as np
import pytest

import text_postprocess as tp


@pytest.fixture(autouse=True)
def _isolate_snippets():
    """qwen3_post_correct() calls expand_snippets() which reads a module global;
    keep tests independent by clearing it around each test."""
    tp.set_snippets({})
    yield
    tp.set_snippets({})


# ---------- qwen3_post_correct (homophone fixes) ----------

def test_post_correct_cloud_to_claude_case_insensitive():
    assert tp.qwen3_post_correct("open Cloud Code now") == "open Claude Code now"
    assert tp.qwen3_post_correct("CLOUD CODE rocks") == "Claude Code rocks"


def test_post_correct_longest_key_wins():
    assert tp.qwen3_post_correct("run Cloud Code CLI") == "run Claude Code CLI"


def test_post_correct_qwen3_variants():
    assert tp.qwen3_post_correct("use queen 3 today") == "use Qwen3 today"
    assert tp.qwen3_post_correct("千问三很强") == "Qwen3很强"


def test_post_correct_empty_and_none():
    assert tp.qwen3_post_correct("") == ""
    assert tp.qwen3_post_correct(None) is None


# ---------- remove_fillers ----------

def test_remove_fillers_cn():
    assert tp.remove_fillers("嗯这个不错") == "这个不错"
    assert tp.remove_fillers("呃，我觉得对") == "我觉得对"


def test_remove_fillers_en():
    assert tp.remove_fillers("um actually yes") == "actually yes"
    assert tp.remove_fillers("hmm let me think") == "let me think"


def test_remove_fillers_preserves_content_words():
    assert tp.remove_fillers("I like this") == "I like this"  # "like" is not a filler
    assert tp.remove_fillers("这个方案可以") == "这个方案可以"  # 这个 is not a filler


def test_remove_fillers_empty():
    assert tp.remove_fillers("") == ""


# ---------- expand_snippets ----------

def test_expand_snippets_basic():
    tp.set_snippets({"my-email": "me@example.com"})
    assert tp.expand_snippets("send to my-email please") == "send to me@example.com please"


def test_expand_snippets_longest_first():
    tp.set_snippets({"foo": "X", "foo-bar": "Y"})
    assert tp.expand_snippets("foo-bar and foo") == "Y and X"


def test_expand_snippets_no_snippets():
    assert tp.expand_snippets("nothing to expand") == "nothing to expand"


# ---------- _trim_silence ----------

def test_trim_silence_all_silence_returns_empty():
    out, _stats = tp._trim_silence(np.zeros(16000, dtype=np.float32), 16000)
    assert out.size == 0


def test_trim_silence_keeps_a_loud_burst():
    sr = 16000
    arr = np.zeros(sr, dtype=np.float32)
    arr[8000:9000] = 0.5  # loud burst in the middle
    out, _stats = tp._trim_silence(arr, sr)
    # Must actually trim the leading/trailing silence (regression guard), while
    # keeping the burst plus its padding.
    assert 1000 <= out.size < arr.size


def test_trim_silence_empty_input():
    out, _stats = tp._trim_silence(np.array([], dtype=np.float32), 16000)
    assert out.size == 0
