# Contributing to voice-stt

Thanks for your interest in contributing.

---

## Ground rules

- **No CLA or DCO required.** By submitting a pull request you agree your
  contribution is released under the [MIT License](LICENSE).
- **Conventional Commits encouraged, not required.** Prefixes like
  `feat:`, `fix:`, `docs:`, `refactor:` help with changelog generation, but
  plain descriptions are fine too.
- **Semver v0.x.** The project is pre-1.0 (`v0.1.0`). Breaking changes are
  allowed with a `BREAKING CHANGE:` footer in the commit message.

---

## How to contribute

1. Fork the repo and create a branch from `main`.
2. Make your change. Keep diffs focused — one logical change per PR.
3. Test on a real Windows machine (or document what you tested).
4. Open a pull request against `main`.

---

## Running the tests / local dev

The Python server has a unit-test suite + lint + type-check, mirrored by CI
(`.github/workflows/ci.yml`). Run them locally with [uv](https://docs.astral.sh/uv/):

```bash
uv venv --python 3.12
uv pip install pytest ruff mypy numpy pyyaml websockets
uv run pytest -q                    # unit tests (deterministic core; no GPU needed)
uv run ruff check server tests      # lint
uv run mypy                         # type-check (scoped to the typed core)
```

All three must pass before a PR merges. The tests stub the heavy ML deps, so
they run on any machine without a GPU or the FunASR/Qwen3 stack installed.

---

## What to work on

- **Bug reports** — open an issue first; attach `stream-debug.log` if it is a transcription problem.
- **Docs improvements** — QUICKSTART, CONFIG, ARCHITECTURE, and the GPU
  server setup (`server/README.md`) are the highest-value targets.
- **New hotkeys / AHK features** — discuss in an issue before building.
- **Server-side improvements** — FunASR/Qwen3 config, VAD tuning, hotword pipeline.

---

## Code style

- PowerShell: match the existing style in `windows/`.
  - `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`
  - Functions `PascalCase`, variables `$CamelCase`
- AutoHotkey v2: match the existing style in `windows/voice-hotkey.ahk`.
- New source files must carry `# SPDX-License-Identifier: MIT` at the top.

## Privacy

Transcript data written by the client (recovery JSONL) is local-only and must
never be sent to a remote endpoint by default. Server-side history is
opt-in per connection via `?persist_history=1`; the default is off for
client-initiated connections. Any contribution that adds a new data-collection
path must document the data destination, retention policy, and opt-out
mechanism in the PR description.

Any new server-side call site that writes transcript text (beyond
`_history_append`) MUST be gated with `should_persist_for(websocket)`. This
keeps the "user-facing transcript history is local-only by default" claim
honest as new telemetry/research code is added. Lead enforces in PR review.

---

## Security issues

Please do **not** open public issues for security vulnerabilities.
See [SECURITY.md](SECURITY.md) for the reporting process.
