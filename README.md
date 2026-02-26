# claude-orchestra

Autonomous multi-session orchestrator for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Runs Claude in headless mode across multiple sessions, each completing one task from a shared backlog — with crash recovery, automatic git commits, and work verification.

## How it works

Orchestra manages a loop:

1. Spawns a Claude Code session in `--print` mode
2. Claude reads state files from `.orchestra/`, picks up the next task
3. Claude completes the task, updates state files, outputs an exit signal
4. Orchestra commits the work, checks for remaining tasks, spawns the next session

Each session is stateless. All context passes through files in `.orchestra/`:

| File | Purpose | Written by |
|------|---------|------------|
| `PLAN.md` | Project plan, requirements, acceptance criteria | Human (read-only for Claude) |
| `TODO.md` | Task backlog with checkboxes | Human + Claude |
| `HANDOVER.md` | Context for the next session (overwritten each time) | Claude |
| `CHANGELOG.md` | Append-only session history | Claude |
| `DECISIONS.md` | Autonomous decision log | Claude |
| `INBOX.md` | Human-to-Claude async messages | Human writes, Claude reads |

## Installation

```bash
git clone https://github.com/jameswillett/claude-orchestra.git
cd claude-orchestra
./install.sh              # installs to ~/claude-scripts/
# Add to PATH:
export PATH="$HOME/claude-scripts:$PATH"
```

### Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`npm install -g @anthropic-ai/claude-code`)
- `jq` for JSON processing
- `git`

## Quick start

```bash
# 1. Scaffold a new project
cd ~/my-project
orchestra init

# 2. Write your plan
$EDITOR .orchestra/PLAN.md

# 3. Add tasks
$EDITOR .orchestra/TODO.md

# 4. Customise CLAUDE.md for your project
$EDITOR CLAUDE.md

# 5. Run the orchestrator (in tmux recommended)
orchestra run
```

### Adding to an existing project

If your project already has a `CLAUDE.md`, `orchestra init` will append just the workflow section rather than overwriting it. Your existing project instructions are preserved.

## Commands

### `orchestra init [dir]`

Scaffolds a project for autonomous work:

- Creates `.orchestra/` with all state file templates
- Creates or appends to `CLAUDE.md`
- Creates `.claude/settings.json` with hook definitions (if not present)
- Initialises a git repo if needed

### `orchestra run`

Starts the session loop. Spawns Claude Code sessions until all tasks are complete, a `BLOCKED` signal is received, or limits are reached.

**Environment variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_SESSIONS` | `10` | Safety limit on total sessions |
| `MAX_CONSECUTIVE_CRASHES` | `3` | Stop after N crashes in a row |
| `COOLDOWN_SECONDS` | `15` | Pause between normal handovers |
| `CRASH_COOLDOWN_SECONDS` | `30` | Longer pause after crash recovery |
| `NOTIFY_WEBHOOK` | | Optional webhook URL for notifications |

### `orchestra reset [--archive]`

Resets all state files to blank templates.

With `--archive`: copies current state files and session logs to `.orchestra/archive/NNN-label/` before resetting. The label is extracted from the PLAN.md objective.

### `orchestra status`

Shows current progress: tasks complete/remaining, sessions logged, archived plans, plan objective, and last handover.

## Hook scripts

Orchestra uses three Claude Code hooks (configured in `.claude/settings.json`):

| Hook | Trigger | Script | Purpose |
|------|---------|--------|---------|
| PostToolUse | Edit/Write | `stage-changes.sh` | Auto-stages modified files |
| Stop | Session end | `verify-completion.sh` | Verifies work via Haiku before allowing stop |
| Stop | Session end | `commit-and-update.sh` | Commits staged changes + state files |

## Writing good plans

The quality of autonomous execution depends heavily on `PLAN.md`. A good plan:

- Has **specific, numbered requirements** (R1, R2, ...) so tasks can reference them
- Includes **architecture details** — where to put files, how components connect
- Lists **acceptance criteria** (AC1, AC2, ...) that the verification hook checks
- Defines **non-goals** to prevent scope creep
- Breaks work into **single-session tasks** (1-15 minutes each)

See `examples/test-orchestrator/.orchestra/PLAN.md` for a complete example.

## Directory layout

```
your-project/
├── .orchestra/                 # State files (managed by orchestra)
│   ├── PLAN.md
│   ├── TODO.md
│   ├── CHANGELOG.md
│   ├── HANDOVER.md
│   ├── INBOX.md
│   ├── DECISIONS.md
│   ├── session-logs/           # Raw session output (stream-json)
│   └── archive/                # Archived plans from orchestra reset --archive
│       └── 001-build-api/
├── .claude/
│   └── settings.json           # Hook definitions
├── CLAUDE.md                   # Project instructions + workflow section
└── ... your code ...
```

## Example

The `examples/test-orchestrator/` directory is a self-contained test fixture. To try it:

```bash
# Install orchestra
./install.sh

# Copy the example to a working directory
cp -r examples/test-orchestrator ~/test-orchestra
cd ~/test-orchestra
git init && git add -A && git commit -m "Initial setup"

# Run it
MAX_SESSIONS=5 COOLDOWN_SECONDS=5 orchestra run
```

## Crash recovery

If a session crashes (context exhaustion, network error, etc.):

1. Orchestra detects the non-zero exit code
2. Checks if state files were updated (partial work)
3. Creates a recovery commit with whatever was staged
4. Spawns a recovery session that assesses damage before continuing

After `MAX_CONSECUTIVE_CRASHES` in a row, the orchestrator stops to avoid loops.

## License

MIT
