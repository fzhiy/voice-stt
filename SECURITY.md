# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| `main` (latest) | Yes |
| older tags | No — please update |

## Reporting a vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Please report privately using one of:

1. **GitHub Security Advisories** — click "Report a vulnerability" on the
   [Security](../../security/advisories/new) tab of this repo.
2. **Email** — send details to the address in the repo owner's GitHub profile.

Include:
- A description of the vulnerability and its potential impact.
- Steps to reproduce, or a proof-of-concept if applicable.
- Which component is affected (AHK scripts, PowerShell, server, CI).

You will receive an acknowledgment within 5 business days.

---

## Scope

- **In scope:** code in `windows/`, `server/`, `scripts/`, `install.ps1`.
- **Out of scope:** third-party dependencies (AutoHotkey, FunASR, ffmpeg,
  vLLM). Please report those upstream.

---

## Known non-issues

- **SmartScreen warning on install.ps1** — expected for unsigned PowerShell
  scripts. The script is open-source and auditable here. There is no
  code-signing certificate at present.
- **Plaintext `.env` file** — `.env` is a local file on your own machine.
  It is `.gitignore`d and never transmitted anywhere.
