# claude-orchestra

Autonomous multi-session orchestrator for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Runs Claude in headless mode across multiple sessions with protocol-driven task execution, git worktree isolation, config-driven governance, crash recovery, and quota pacing.

## v3 Architecture

Orchestra v3 is **project-local** — no global install, no `~/claude-scripts/`. Everything lives in `.orchestra/` within your project.

Key changes from v2:
- **Protocol-driven:** sessions follow `DEVELOPMENT-PROTOCOL.md` (a 20-step task sequence with gates)
- **Config-driven:** all run parameters in `.orchestra/config` — no env vars, no CLI args
- **Worktree isolation:** each run gets a persistent git worktree so your main working tree stays on `main`
- **Single settings.json:** no more settings swap between interactive and autonomous
- **Staging hook only:** Stop hooks removed — the protocol defines when commits happen

## How it works

1. You set `TASKS=T001,T002,T003` in `.orchestra/config`
2. Orchestra creates a tmux session and a persistent git worktree for the run
3. Claude reads `DEVELOPMENT-PROTOCOL.md` and follows it in auto-proceed mode
4. Each task gets its own branch within the worktree, merged back into the session branch
5. Governance files (TODO, DECISIONS, CHANGELOG) are synced back to the main tree
6. Between sessions, the worktree is reset to a clean state and reused
7. Orchestra spawns the next session until all tasks are complete
8. The worktree is preserved after the run for human review

## Installation

```bash
git clone https://github.com/jimbo2k2/claude-orchestra.git
cd /path/to/your/project
/path/to/claude-orchestra/install.sh
```

This copies scripts into `.orchestra/bin/`, `.orchestra/hooks/`, `.orchestra/lib/` and creates governance directories if needed. No global PATH changes required.

### Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (globally installed)
- `jq` for JSON processing
- `git`
- `tmux`

## Quick start

```bash
# 1. Bootstrap orchestra into your project
/path/to/claude-orchestra/install.sh

# 2. Configure
$EDITOR .orchestra/config          # Set TASKS, governance paths, WORKTREE_BASE
$EDITOR .orchestra/toolchain.md    # Add your build/test commands

# 3. Create development protocol (or use the template)
$EDITOR DEVELOPMENT-PROTOCOL.md

# 4. Add tasks to TODO
$EDITOR TODO/TODO.md

# 5. Run
.orchestra/bin/orchestra run       # Starts in tmux with worktree isolation

# 6. Monitor
tmux attach -t orchestra           # Watch live
.orchestra/bin/orchestra status    # Progress summary
```

### Passing queue-specific context

Write to `.orchestra/INBOX.md` before launching. The session reads it at startup — it functions as a cold-start briefing for this run.

## Commands

### `.orchestra/bin/orchestra run`

Starts the session loop in a tmux session. Creates one persistent git worktree for the run (named by run timestamp). Runs until all assigned tasks are complete, BLOCKED, or limits reached. The worktree is preserved after the run for review.

### `.orchestra/bin/orchestra test`

Smoke test — creates a throwaway worktree, runs a synthetic task through the full protocol, reports which steps and gates fired, cleans up.

### `.orchestra/bin/orchestra status`

Shows current progress: tasks assigned vs complete, sessions logged.

### `.orchestra/bin/orchestra reset [--label NAME]`

Archives session state (HANDOVER, session logs) and resets for the next run. Governance files are untouched.

## Configuration

All settings live in `.orchestra/config`. No env vars, no CLI args.

```ini
TASKS=T001,T002,T003          # Comma-separated T-numbers
MAX_SESSIONS=10                # Session limit
MODEL=opus                     # Default model
EFFORT=high                    # Default effort
WORKTREE_BASE=/tmp/orchestra   # Worktree parent (run folder created inside)
TMUX_SESSION=orchestra         # Tmux session name
QUOTA_PACING=true              # Pause when quota is high
QUOTA_THRESHOLD=80             # Utilization % to trigger pause
TODO_FILE=TODO/TODO.md         # Governance paths
DECISIONS_FILE=Decisions/DECISIONS.md
CHANGELOG_FILE=Changelog/CHANGELOG.md
DEVELOPMENT_PROTOCOL=DEVELOPMENT-PROTOCOL.md
TOOLCHAIN_FILE=.orchestra/toolchain.md
```

## Directory layout

```
your-project/
├── DEVELOPMENT-PROTOCOL.md     # Authoritative task sequence
├── .orchestra/
│   ├── config                  # All run parameters
│   ├── bin/
│   │   ├── orchestra           # CLI entry point
│   │   └── orchestrator.sh     # Session loop
│   ├── hooks/
│   │   └── stage-changes.sh    # PostToolUse hook (staging only)
│   ├── lib/
│   │   ├── config.sh           # Config reader + preflight
│   │   ├── verify-completion.sh # Invoked by orchestrator, not hooks
│   │   └── commit-and-update.sh # Invoked by orchestrator, not hooks
│   ├── sessions/               # Per-task workspaces + session logs
│   │   └── archive/
│   ├── CLAUDE.md               # Autonomous session rules
│   ├── README.md               # Quick reference
│   ├── toolchain.md            # Stack-specific commands
│   ├── HANDOVER.md             # Session-to-session context
│   └── INBOX.md                # Human async messages
├── .claude/
│   └── settings.json           # Staging hook only
├── CLAUDE.md                   # Project instructions
├── TODO/                       # Governance (path configurable)
├── Decisions/
└── Changelog/
```

## Crash recovery

If a session crashes:
1. Orchestra syncs governance files from the worktree
2. Creates a recovery commit if partial work exists
3. Spawns a recovery session that assesses damage before continuing

After `MAX_CONSECUTIVE_CRASHES` in a row, the orchestrator stops.

## Quota pacing

Enabled by default. Before each session, checks subscription utilization via the OAuth usage endpoint. If the 5-hour window exceeds `QUOTA_THRESHOLD`, pauses until it resets. Safe to leave running overnight.

## License

MIT
