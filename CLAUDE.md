# Project: claude-orchestra

Autonomous multi-session orchestrator for Claude Code (v2).

## Tech Stack
- Runtime: Bash (POSIX-compatible where possible)
- Testing: `bash examples/test-orchestrator/tests/run.sh` (example project tests)
- No framework, no package manager

## Architecture
```
bin/
└── orchestra              — CLI entry point (subcommand dispatch)
lib/
├── orchestrator.sh        — Main session loop with crash recovery
├── stage-changes.sh       — PostToolUse hook: git staging
├── commit-and-update.sh   — Stop hook: git commits
└── verify-completion.sh   — Stop hook: model verification
templates/
├── CLAUDE.md              — Full project template (new projects)
├── CLAUDE-workflow.md     — Workflow section only (existing projects)
├── settings.json          — .claude/settings.json template
├── settings-autonomous.json — Autonomous-mode settings template
├── config                 — .orchestra/config template
├── toolchain.md           — .orchestra/toolchain.md template
├── standing-ac.md         — .orchestra/standing-ac.md template
├── governance/            — Governance file templates (TODO, DECISIONS, CHANGELOG + CLAUDE.md protocols)
├── HANDOVER.md, INBOX.md  — Session state templates
examples/
└── test-orchestrator/     — Self-contained test fixture
docs/
└── orchestra-v2-spec.md   — Full v2 design specification
install.sh                 — Installs to ~/claude-scripts/
```

## Conventions
- All scripts use `set -euo pipefail`
- Scripts must be executable (`chmod +x`)
- State files always live in `.orchestra/` subdirectory of user projects
- CLAUDE.md always lives at project root (Claude Code convention)
- Hook scripts reference `~/claude-scripts/` as the installed path

## Key Concepts

### Config-driven governance
Governance file paths are defined in `.orchestra/config`, not hardcoded. Projects can point Orchestra at their existing file structure:
- `TODO_FILE` / `TODO_PROTOCOL` — task backlog and its archiving protocol
- `DECISIONS_FILE` / `DECISIONS_PROTOCOL` — decision log and protocol
- `CHANGELOG_FILE` / `CHANGELOG_PROTOCOL` — changelog and protocol
- `PLAN_FILE` — strategic plan for the current build
- `TOOLCHAIN_FILE` — stack-specific build/test commands
- `STANDING_AC_FILE` — acceptance criteria for every UI task

### Three-tier planning
Tasks use T-numbers and have a tier (1=Strategic, 2=Tactical, 3=Tertiary). Strategic tasks are decomposed into tactical sub-tasks. Tactical tasks are executed via the codewriting loop.

### Governance triad
Three numbered, archivable files form the governance system:
- **TODO** (T-numbers) — tasks with status, tier, dependencies
- **DECISIONS** (D-numbers) — choices with alternatives considered
- **CHANGELOG** (C-numbers) — what changed, linked to tasks and decisions

### Session state
- **HANDOVER.md** — overwritten each session; carries context to the next session
- **INBOX.md** — human writes async messages, Claude reads at session start

### Exit signals
Sessions end with exactly one of: `HANDOVER`, `COMPLETE`, or `BLOCKED`.

### Ubiquitous language
See `docs/orchestra-v2-spec.md` for the full v2 ubiquitous language table defining terms like Strategic Task, Tactical Task, Governance Triad, Codewriting Loop, Standing AC, Toolchain, Pre-flight Check, Capacity Check, and more.
