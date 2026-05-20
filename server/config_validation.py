"""Startup config validation — fail fast with one clear line, not a traceback.

Kept separate from asr_common.py (the cloud-WS protocol layer) and free of
third-party deps so every entry point — the local FunASR server, the HTTP
gateway, and the cloud providers — can import it without new coupling.

Validation runs at the env-parse site (module import), BEFORE models load, so
a misconfiguration exits cleanly instead of half-loading the server or dumping
a raw ValueError stack trace on a new user.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import NoReturn


def fail(msg: str) -> NoReturn:
    """Print one actionable error to stderr and exit(2) — no stack trace."""
    print(f"[voice-stt config error] {msg}", file=sys.stderr, flush=True)
    raise SystemExit(2)


def warn(msg: str) -> None:
    """Non-fatal config notice (e.g. an optional file is missing)."""
    print(f"[voice-stt config warning] {msg}", file=sys.stderr, flush=True)


def port_from_env(name: str, default: int) -> int:
    """Read a TCP port from env, validating it's an int in 1-65535.

    Replaces `int(os.environ.get(NAME, "..."))` so a typo'd port yields a
    clear message instead of a `ValueError` traceback at import time.
    """
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    try:
        port = int(raw)
    except ValueError:
        fail(f"{name}={raw!r} is not an integer (expected a port in 1-65535)")
    if not (1 <= port <= 65535):
        fail(f"{name}={port} is out of range (expected a port in 1-65535)")
    return port


def warn_if_path_missing(name: str, value: str | None) -> None:
    """Warn (non-fatal) if an optional path is configured but absent."""
    if value and not Path(value).exists():
        warn(f"{name} points to a missing file: {value} (continuing without it)")
