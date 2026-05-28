# CLAUDE.md

> Vendored from [multica-ai/andrej-karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills) — MIT, based on Andrej Karpathy's [LLM-coding pitfalls thread](https://x.com/karpathy/status/2015883857489522876). Applied repo-wide; agent-team task specs add project-specific rules on top, never override these.

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

---

# Project-specific rules (ASR Anywhere, formerly voice-stt)

Added 2026-05-21. Calibrated against the Karpathy guidelines above (general behavior); this section adds project-specific operational rules. Private operational rules (host details, credentials, internal workflow) live in gitignored skill/agent files under `.claude/`, not here.

## 5. Git in worktrees: use `git -C <abs-path>`, not `cd <path> && git`

The Bash shell's cwd can shift unexpectedly between turns when subagents or MCP tools (Codex with `cwd:` parameter) run inside a worktree. The failure mode: a `git cherry-pick` runs on the wrong branch because the shell cwd had drifted into the worktree.

- Prefer `git -C /abs/path/to/repo cherry-pick <sha>` over `cd repo && git cherry-pick <sha>`.
- When you must combine, chain on a single Bash call (`cd <path> && git ...`) — but `git -C` is still cleaner.

## 6. For multi-surface tasks, prefer the agent-team Skill if installed

For tasks touching ≥3 files OR crossing client/server/docs surfaces, prefer invoking the `agent-team` Skill (when `.claude/skills/agent-team/` is present in this repo) over direct `mcp__codex__codex` calls. The Skill encodes calibrated rules (review-round caps, structured findings templates, worker isolation) that direct calls bypass. For ≤2-file local edits, direct Codex calls are fine.

The Skill files in `.claude/skills/` are gitignored by default — install them locally if you want this workflow; the repo functions without them.

## 7. Commit message prefixes (Conventional Commits with scopes)

- `feat(<scope>):` — new user-facing feature (e.g. `feat(asr):`, `feat(gateway):`, `feat(client):`)
- `fix(<scope>):` — bug fix
- `chore:` / `docs:` / `test:` / `refactor:` — supporting work
- `Phase B:` — Lead direct edits during agent-team protocol Round 2+ (reserved for the agent-team Skill workflow; never used by worker commits)

## 8. Worktree cleanup discipline

After cherry-picking a worktree's commit into main, in the same response sequence:
1. `git worktree remove <path> --force`
2. `git branch -D <worktree-branch>`
3. `git worktree list` to confirm

Stale worktrees from prior sessions visible in `.claude/worktrees/` (if that dir exists) are a sign of cleanup not happening — delete them when noticed.
