# claude-orchestra

Autonomous multi-session orchestrator for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Runs Claude in headless mode across multiple sessions using three-tier planning, DDD-style governance, and config-driven project integration — with crash recovery, automatic git commits, and work verification.

## How it works

Orchestra manages a session loop with structured governance:

1. Spawns a Claude Code session in `--print` mode
2. Claude reads governance files (TODO, DECISIONS, CHANGELOG) and session state (HANDOVER, INBOX)
3. Claude picks the next eligible task, executes it, updates governance
4. Orchestra commits the work, runs pre-flight checks, spawns the next session

Governance is config-driven — projects point Orchestra at their existing file structure rather than adopting a fixed layout. Three numbered, archivable files track all work:

| File | Purpose | Written by |
|------|---------|------------|
| **TODO** (T-numbers) | Tasks with status, tier, dependencies | Human + Claude |
| **DECISIONS** (D-numbers) | Choices made with alternatives considered | Human + Claude |
| **CHANGELOG** (C-numbers) | What changed, which task drove it | Claude |
| `HANDOVER.md` | Session-to-session context (overwritten each time) | Claude |
| `INBOX.md` | Human-to-Claude async messages | Human writes, Claude reads |

Governance file paths are configured in `.orchestra/config`. Each governance file has a companion `CLAUDE.md` with its archiving protocol.

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

# 2. Configure governance paths (if project has existing structure)
$EDITOR .orchestra/config

# 3. Write your plan
$EDITOR .orchestra/PLAN.md   # or set PLAN_FILE in config

# 4. Add strategic tasks to TODO
$EDITOR TODO/TODO.md          # path depends on config

# 5. Run the orchestrator (in tmux recommended)
orchestra run
```

### Adding to an existing project

`orchestra init` scans for existing governance files (TODO.md, DECISIONS.md, CHANGELOG.md). If found, it inherits their paths into `.orchestra/config`. If not found, it creates them in the default structure. If partial matches are found, it warns and asks for confirmation.

If your project already has a `CLAUDE.md`, `orchestra init` appends the workflow section rather than overwriting it.

## Commands

### `orchestra init [dir]`

Scaffolds a project for autonomous work:

- Creates `.orchestra/` with config, toolchain, standing AC templates
- Scans for existing governance files and inherits or creates them
- Creates or appends to `CLAUDE.md`
- Creates `.claude/settings.json` with hook definitions (if not present)
- Initialises a git repo if needed

### `orchestra run`

Starts the session loop. Runs pre-flight checks (config valid, governance files exist, plan file set), then spawns Claude Code sessions until all tasks are complete, a `BLOCKED` signal is received, or limits are reached.

**Environment variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_SESSIONS` | `10` | Safety limit on total sessions |
| `MAX_CONSECUTIVE_CRASHES` | `3` | Stop after N crashes in a row |
| `COOLDOWN_SECONDS` | `15` | Pause between normal handovers |
| `CRASH_COOLDOWN_SECONDS` | `30` | Longer pause after crash recovery |
| `NOTIFY_WEBHOOK` | | Optional webhook URL for notifications |
| `QUOTA_PACING` | `true` | Subscription quota monitoring — pauses when 5-hour window is near-exhausted |
| `QUOTA_THRESHOLD` | `80` | Utilization percentage at which to pause (0–100) |
| `QUOTA_POLL_INTERVAL` | `120` | Seconds between quota checks while paused |

#### Quota pacing

Enabled by default. Before each session spawn, the orchestrator checks subscription utilization via the OAuth `/api/oauth/usage` endpoint (zero tokens, ~200ms). If the 5-hour rolling window exceeds `QUOTA_THRESHOLD`, it pauses and sleeps until the window resets, polling every `QUOTA_POLL_INTERVAL` seconds to confirm. After each session, it also extracts `rate_limit_event` data from the session log for awareness.

This means `orchestra run` is safe to leave running overnight — it will pace itself around quota limits, resume after each window reset, and continue until all tasks are complete or `MAX_SESSIONS` is reached.

**Overnight / large job:**
```bash
# Run up to 30 sessions, pacing automatically around quota limits
MAX_SESSIONS=30 orchestra run
```

**Quick burst (disable pacing if you know you have quota):**
```bash
QUOTA_PACING=false orchestra run
```

The session limit (`MAX_SESSIONS`) is always enforced regardless of pacing. The orchestrator will never spawn more than `MAX_SESSIONS` sessions, even if it has been paused and resumed multiple times.

### `orchestra reset [--label LABEL]`

Resets session state (HANDOVER.md, INBOX.md, session logs) while leaving governance files untouched.

The `--label` flag names the archive (e.g. `--label mvp-build`). Current session state is archived to `.orchestra/archive/NNN-label/` before resetting.

### `orchestra status`

Shows current progress: tasks complete/remaining, sessions logged, plan objective, and last handover.

## Three-tier planning

Orchestra uses a three-tier task hierarchy:

1. **Strategic** (Tier 1) — human-authored, feature scope. When a session picks up a strategic task, it decomposes it into tactical sub-tasks.
2. **Tactical** (Tier 2) — Claude-generated, component scope. Executed via the codewriting loop (implement → build → test → capture).
3. **Tertiary** (Tier 3) — further decomposition if a tactical task is still too large. Maximum depth.

Tasks track status (`OPEN`, `IN_PROGRESS`, `COMPLETE`, `BLOCKED`, `PROPOSED`) and dependencies between T-numbers.

## Hook scripts

Orchestra uses three Claude Code hooks (configured in `.claude/settings.json`):

| Hook | Trigger | Script | Purpose |
|------|---------|--------|---------|
| PostToolUse | Edit/Write | `stage-changes.sh` | Auto-stages modified files |
| Stop | Session end | `verify-completion.sh` | Verifies work via Haiku before allowing stop |
| Stop | Session end | `commit-and-update.sh` | Commits staged changes + state files |

## Directory layout

```
your-project/
├── .orchestra/                 # Orchestra configuration and session state
│   ├── config                  # Governance paths, plan file, toolchain, standing AC
│   ├── toolchain.md            # Stack-specific build/test/capture commands
│   ├── standing-ac.md          # Acceptance criteria applied to every UI task
│   ├── HANDOVER.md             # Session-to-session context
│   ├── INBOX.md                # Human-to-Claude async messages
│   ├── session-logs/           # Raw session output (stream-json)
│   └── archive/                # Archived session state from orchestra reset
│       └── 001-build-api/
├── .claude/
│   └── settings.json           # Hook definitions
├── CLAUDE.md                   # Project instructions + workflow section
├── TODO/                       # Governance: tasks (path configurable)
│   ├── TODO.md
│   └── CLAUDE.md               # Archiving protocol
├── Decisions/                  # Governance: decisions (path configurable)
│   ├── DECISIONS.md
│   └── CLAUDE.md
├── Changelog/                  # Governance: changelog (path configurable)
│   ├── CHANGELOG.md
│   └── CLAUDE.md
└── ... your code ...
```

Governance file locations are configured in `.orchestra/config` — the paths above are defaults. Projects with existing file structures can point Orchestra at their own locations.

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

## Specification

See `docs/orchestra-v2-spec.md` for the full v2 design specification, including the ubiquitous language, detailed session algorithms, and governance protocols.

## License

MIT
