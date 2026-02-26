# Project: claude-orchestra

Autonomous multi-session orchestrator for Claude Code.

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
├── PLAN.md, TODO.md, CHANGELOG.md, HANDOVER.md, INBOX.md, DECISIONS.md
examples/
└── test-orchestrator/     — Self-contained test fixture
install.sh                 — Installs to ~/claude-scripts/
```

## Conventions
- All scripts use `set -euo pipefail`
- Scripts must be executable (`chmod +x`)
- State files always live in `.orchestra/` subdirectory of user projects
- CLAUDE.md always lives at project root (Claude Code convention)
- Hook scripts reference `~/claude-scripts/` as the installed path

## Key Concepts
- **STATE_DIR**: Always `$PROJECT_DIR/.orchestra` — all state file paths use this
- **Hook scripts** (lib/): Read from stdin or env vars, never hardcode project paths
- **Templates**: Copied by `orchestra init`, all state file references use `.orchestra/` prefix
- **CLAUDE-workflow.md**: The workflow section only, for appending to existing CLAUDE.md files
