"""Characterization tests for asr_common._handle_one_client (Tier 1 T1.2).

Locks in the EXISTING voice-stt WS protocol behavior — connect-failure
surfacing, the EOF-with-no-audio short-circuit, normal final drain, and
teardown — so a future refactor can't silently regress it. Drives the async
handler with asyncio.run() + an in-process fake websocket and fake
ASRProvider, so no pytest-asyncio dependency is needed.
"""
import asyncio
import json

import asr_common as ac


class FakeWS:
    """Minimal stand-in for a websockets server connection."""

    def __init__(self, incoming):
        self.remote_address = ("test", 0)
        self._incoming = list(incoming)
        self.sent = []

    def __aiter__(self):
        return self._aiter()

    async def _aiter(self):
        for m in self._incoming:
            yield m

    async def send(self, data):
        self.sent.append(data)


class FakeProvider(ac.ASRProvider):
    BACKEND_TAG = "fake"

    def __init__(self, events=(), connect_error=None):
        self._events = list(events)
        self._connect_error = connect_error
        self.audio_chunks = []
        self.ended = False
        self.closed = False

    async def connect(self):
        if self._connect_error is not None:
            raise self._connect_error

    async def send_audio(self, pcm):
        self.audio_chunks.append(pcm)

    async def end_audio(self):
        self.ended = True

    async def events(self):
        for e in self._events:
            yield e

    async def close(self):
        self.closed = True


def _sent(ws):
    return [json.loads(s) for s in ws.sent]


def test_connect_failure_sends_error_final_and_closes():
    ws = FakeWS([])
    prov = FakeProvider(connect_error=RuntimeError("upstream down"))
    asyncio.run(ac._handle_one_client(ws, lambda: prov))
    msgs = _sent(ws)
    assert len(msgs) == 1
    assert msgs[0]["type"] == "final" and msgs[0]["text"] == ""
    assert "error_message" in msgs[0]
    assert prov.closed is True  # outer finally always tears the provider down


def test_eof_no_audio_returns_empty_final_without_touching_provider():
    ws = FakeWS(["EOF"])
    prov = FakeProvider(events=[])  # no audio → a real provider emits nothing
    asyncio.run(ac._handle_one_client(ws, lambda: prov))
    assert _sent(ws) == [{"type": "final", "text": "", "backend": "fake"}]
    # Narrowed claim (Codex M4): the short-circuit sends no audio / end_audio.
    assert prov.audio_chunks == [] and prov.ended is False


def test_normal_audio_then_eof_emits_backend_tagged_final():
    ws = FakeWS([b"\x00\x01\x02\x03", "EOF"])
    prov = FakeProvider(events=[{"type": "final", "text": "hello", "language": "en"}])
    asyncio.run(ac._handle_one_client(ws, lambda: prov))
    msgs = _sent(ws)
    assert prov.audio_chunks == [b"\x00\x01\x02\x03"]
    assert prov.ended is True
    assert any(
        m["type"] == "final" and m["text"] == "hello" and m["backend"] == "fake"
        for m in msgs
    )


def test_disconnect_without_eof_still_closes_provider():
    ws = FakeWS([b"\x00\x01"])  # audio, then client disconnects (no EOF)
    prov = FakeProvider(events=[{"type": "final", "text": "bye"}])
    asyncio.run(ac._handle_one_client(ws, lambda: prov))
    assert prov.closed is True


# ---------- T1.3 observability ----------

def test_format_session_metric():
    assert (
        ac.format_session_metric("vol", 32000, 3, 850.4, None)
        == "[session] backend=vol audio_bytes=32000 partials=3 final_latency=850ms result=ok"
    )
    assert (
        ac.format_session_metric("ten", 0, 0, None, "connect_failed")
        == "[session] backend=ten audio_bytes=0 partials=0 final_latency=n/a result=connect_failed"
    )


def test_session_metric_logged_on_normal_flow(capsys):
    ws = FakeWS([b"\x00\x01\x02\x03", "EOF"])
    prov = FakeProvider(events=[
        {"type": "partial", "text": "he"},
        {"type": "final", "text": "hello"},
    ])
    asyncio.run(ac._handle_one_client(ws, lambda: prov))
    out = capsys.readouterr().out
    assert "[session] backend=fake" in out
    assert "audio_bytes=4" in out
    assert "partials=1" in out
    assert "result=ok" in out
    assert "final_latency=-" not in out  # a final seen before EOF must not log negative latency


def test_session_metric_records_connect_failure(capsys):
    ws = FakeWS([])
    prov = FakeProvider(connect_error=RuntimeError("down"))
    asyncio.run(ac._handle_one_client(ws, lambda: prov))
    out = capsys.readouterr().out
    assert "[session]" in out and "result=connect_failed" in out


def test_session_metric_no_final_after_eof(capsys):
    # EOF after audio but the provider never emits a final → must NOT log result=ok.
    ws = FakeWS([b"\x00\x01\x02\x03", "EOF"])
    prov = FakeProvider(events=[{"type": "partial", "text": "x"}])
    asyncio.run(ac._handle_one_client(ws, lambda: prov))
    out = capsys.readouterr().out
    assert "result=no_final" in out
