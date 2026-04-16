# Project: claude-orchestra

Autonomous multi-session orchestrator for Claude Code (v3). Protocol-driven, project-local, worktree-isolated.

## Tech Stack
- Runtime: Bash (POSIX-compatible where possible)
- No framework, no package manager

## Architecture
```
bin/
└── orchestra              — CLI entry point (run, test, status, reset, init)
lib/
├── orchestrator.sh        — Main session loop with worktree lifecycle + crash recovery
├── config.sh              — Config reader + preflight validation
├── stage-changes.sh       — PostToolUse hook: git staging
├── commit-and-update.sh   — Commit helper (invoked by orchestrator, not hooks)
└── verify-completion.sh   — Completion verifier (invoked by orchestrator, not hooks)
templates/
├── DEVELOPMENT-PROTOCOL.md — Generic 20-step protocol template
├── CLAUDE-workflow.md     — Workflow section appended to project CLAUDE.md
├── settings.json          — .claude/settings.json (staging hook only, project-local path)
├── config                 — .orchestra/config template
├── toolchain.md           — .orchestra/toolchain.md skeleton
├── README.md              — .orchestra/README.md template
├── governance/            — Governance file templates (TODO, DECISIONS, CHANGELOG + CLAUDE.md protocols)
├── HANDOVER.md, INBOX.md  — Session state templates
install.sh                 — Bootstraps into project .orchestra/ (no global install)
docs/
└── archive/               — Historical v2 spec and flow diagram (superseded)
```

## Key Design Decisions (v3)

- **Project-local:** No `~/claude-scripts/`. Everything in `.orchestra/bin/`, `.orchestra/hooks/`, `.orchestra/lib/`.
- **Protocol-driven:** Sessions follow `DEVELOPMENT-PROTOCOL.md`, not inline prompt steps.
- **Config-driven:** All parameters in `.orchestra/config`. No env var overrides, no CLI args.
- **Worktree isolation:** Each session gets a git worktree. Main working tree stays on `main`.
- **Single settings.json:** No settings swap between interactive and autonomous modes.
- **Staging hook only:** Stop hooks removed. The protocol defines when commits happen.
- **INBOX as cold-start briefing:** Queue-specific context passed via INBOX.md, not template modifications.
- **Governance sync:** After each session, governance files are synced from worktree to main tree.

## Conventions
- All scripts use `set -euo pipefail`
- Scripts must be executable (`chmod +x`)
- State files live in `.orchestra/` within user projects
- Hook paths in `.claude/settings.json` are project-relative (`.orchestra/hooks/`)
- Config is the single source of truth — no env var fallbacks

## Governance
Three numbered, archivable files:
- **TODO** (T-numbers) — tasks with status, dependencies
- **DECISIONS** (D-numbers) — choices with alternatives considered
- **CHANGELOG** (C-numbers) — what changed, linked to tasks and decisions

Session state:
- **HANDOVER.md** — session-to-session context
- **INBOX.md** — human-to-Claude async messages (also used as cold-start briefing)
