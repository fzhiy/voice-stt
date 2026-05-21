"""Tests for OpenAICompatProvider (HTTP-based ASR backend)."""

import asyncio
import importlib.util
import io
import sys
import urllib.error
from pathlib import Path


def _import_provider():
    repo_root = Path(__file__).resolve().parent.parent
    server_dir = repo_root / "server"
    if str(server_dir) not in sys.path:
        sys.path.insert(0, str(server_dir))
    src = server_dir / "openai-compat-stream-server.py"
    spec = importlib.util.spec_from_file_location("openai_compat_stream_server", src)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


mod = _import_provider()
OpenAICompatProvider = mod.OpenAICompatProvider


def _run(coro):
    loop = asyncio.new_event_loop()
    try:
        asyncio.set_event_loop(loop)
        return loop.run_until_complete(coro)
    finally:
        exc = getattr(loop, "_default_executor", None)
        if exc is not None:
            exc.shutdown(wait=True)
        loop.close()
        asyncio.set_event_loop(None)


def _make_provider(**overrides):
    kw = dict(
        api_key="sk-test-fake",
        base_url="https://api.example.test/v1",
        model="whisper-1",
        language="zh",
        timeout_s=5,
        mappings={},
    )
    kw.update(overrides)
    return OpenAICompatProvider(**kw)


class _FakeResp:
    def __init__(self, body: bytes):
        self._body = body

    def read(self) -> bytes:
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        pass


def _drive_session(provider, pcm_chunks: list[bytes], fake_urlopen):
    """Helper: simulate connect → N×send_audio → end_audio → collect events."""

    async def go():
        await provider.connect()
        for chunk in pcm_chunks:
            await provider.send_audio(chunk)
        await provider.end_audio()
        events = []
        async for ev in provider.events():
            events.append(ev)
        await provider.close()
        return events

    orig = mod.urllib.request.urlopen
    mod.urllib.request.urlopen = fake_urlopen
    try:
        return _run(go())
    finally:
        mod.urllib.request.urlopen = orig


def test_happy_path_yields_single_final_and_sets_headers():
    captured = {}

    def fake_urlopen(req, timeout):
        captured["url"] = req.full_url
        captured["headers"] = dict(req.headers)
        captured["body"] = req.data
        return _FakeResp('{"text": "你好"}'.encode("utf-8"))

    provider = _make_provider()
    events = _drive_session(provider, [b"\x00\x01" * 1000], fake_urlopen)
    assert events == [{"type": "final", "text": "你好"}]
    assert captured["url"] == "https://api.example.test/v1/audio/transcriptions"
    assert captured["headers"]["Authorization"] == "Bearer sk-test-fake"
    assert captured["headers"]["Content-type"].startswith("multipart/form-data; boundary=")


def test_multipart_body_contains_wav_model_language_and_preserves_chunk_order():
    captured = {}

    def fake_urlopen(req, timeout):
        captured["body"] = req.data
        return _FakeResp(b'{"text": ""}')

    provider = _make_provider(language="en")
    chunk_a = b"\xaa" * 200
    chunk_b = b"\xbb" * 200
    _drive_session(provider, [chunk_a, chunk_b], fake_urlopen)
    body = captured["body"]
    assert b'name="model"' in body
    assert b"whisper-1" in body
    assert b'name="language"' in body
    assert b"en" in body
    assert b'name="file"; filename="audio.wav"' in body
    assert b"RIFF" in body
    assert b"WAVE" in body
    pos_a = body.find(b"\xaa" * 50)
    pos_b = body.find(b"\xbb" * 50)
    assert pos_a > 0 and pos_b > 0
    assert pos_a < pos_b


def test_language_omitted_when_empty():
    captured = {}

    def fake_urlopen(req, timeout):
        captured["body"] = req.data
        return _FakeResp(b'{"text": ""}')

    provider = _make_provider(language="")
    _drive_session(provider, [b"\x00\x01" * 100], fake_urlopen)
    assert b'name="language"' not in captured["body"]


def test_http_401_surfaces_error():
    def fake_urlopen(req, timeout):
        raise urllib.error.HTTPError(
            req.full_url, 401, "Unauthorized", {}, io.BytesIO(b'{"error": "bad key"}')
        )

    provider = _make_provider()
    events = _drive_session(provider, [b"\x00\x01" * 100], fake_urlopen)
    assert len(events) == 1
    ev = events[0]
    assert ev["type"] == "final"
    assert ev["text"] == ""
    assert ev["error_code"] == 401
    assert "401" in ev["error_message"]


def test_no_audio_skips_post_and_yields_no_audio_error():
    called = {"n": 0}

    def fake_urlopen(req, timeout):
        called["n"] += 1
        return _FakeResp(b'{"text": "should-not-see"}')

    provider = _make_provider()
    events = _drive_session(provider, [], fake_urlopen)
    assert called["n"] == 0
    assert len(events) == 1
    assert events[0]["type"] == "final"
    assert events[0]["text"] == ""
    assert events[0]["error_code"] == "no_audio"
    assert "no audio" in events[0]["error_message"].lower()


def test_mappings_applied_to_final_text():
    def fake_urlopen(req, timeout):
        return _FakeResp(b'{"text": "use state hook"}')

    provider = _make_provider(mappings={"use state": "useState"})
    events = _drive_session(provider, [b"\x00\x01" * 100], fake_urlopen)
    assert events[0]["text"] == "useState hook"


def test_non_json_200_yields_invalid_json_error():
    def fake_urlopen(req, timeout):
        return _FakeResp(b"<html><body>oops</body></html>")

    provider = _make_provider()
    events = _drive_session(provider, [b"\x00\x01" * 100], fake_urlopen)
    assert len(events) == 1
    assert events[0]["type"] == "final"
    assert events[0]["text"] == ""
    assert events[0]["error_code"] == "invalid_json"
    assert events[0]["error_message"]


def test_null_text_in_200_response_coerces_to_empty_string():
    def fake_urlopen(req, timeout):
        return _FakeResp(b'{"text": null}')

    provider = _make_provider()
    events = _drive_session(provider, [b"\x00\x01" * 100], fake_urlopen)
    assert len(events) == 1
    assert events[0]["type"] == "final"
    assert events[0]["text"] == ""
    assert "error_code" not in events[0]


def test_network_error_sets_truthy_error_code_and_close_is_idempotent():
    def fake_urlopen(req, timeout):
        raise ConnectionRefusedError("ECONNREFUSED")

    provider = _make_provider()
    events = _drive_session(provider, [b"\x00\x01" * 100], fake_urlopen)
    assert events[0]["error_code"] == "network_error"
    assert "ConnectionRefusedError" in events[0]["error_message"]

    provider2 = _make_provider()

    async def go():
        await provider2.connect()
        await provider2.send_audio(b"\x00" * 100)
        await provider2.close()
        await provider2.close()
        events2 = []
        async for ev in provider2.events():
            events2.append(ev)
        return events2

    events2 = _run(go())
    assert len(events2) == 1
    assert events2[0]["type"] == "final"
    assert events2[0]["error_code"] == "closed"
