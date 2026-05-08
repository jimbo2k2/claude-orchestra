# claude-orchestra

Autonomous multi-session orchestrator for [Claude Code](https://docs.claude.com/en/docs/claude-code). Runs Claude in headless mode (`claude --print`) across multiple working sessions inside an isolated git worktree, watches for hangs and crashes, then runs a wind-down session that ingests the run's governance into the parent project's governance shape and merges back into the base branch.

Linux-only. Bash, git, tmux, jq, inotify-tools.

## What it does

You point orchestra at a project, give it an objective, and it spawns Claude in a tmux session inside a fresh git worktree. Each Claude invocation is a **working session** that makes progress, writes a HANDOVER briefing, and exits — orchestra spawns the next one until Claude emits `COMPLETE`, `BLOCKED`, or limits are hit. After a successful `COMPLETE`, a single **wind-down session** ingests the run's TODO/DECISIONS/CHANGELOG into the parent project's existing governance files and merges the run-branch.

You can leave it running overnight. It paces itself against the Claude subscription quota and recovers from session crashes.

## Architecture: Organiser + Executor

Inside each working session the Claude instance acts as an **Organiser** that holds the run plan and governance state in context, and dispatches **Executor** subagents (via Claude Code's `Agent` tool) to do the actual task work. The Organiser decides per-task which model to dispatch — Sonnet by default for clear, bounded work; Opus for ambiguous design or cross-file judgement; Haiku for very mechanical edits. It runs verifications, escalates retries on the same task-id when an Executor returns `ESCALATE` or fails verification (two-attempt cap before going inline), and self-winds-down when its own context approaches `ORGANISER_CONTEXT_THRESHOLD`.

The motivation is cost. An overnight Opus-on-everything run is expensive; this pattern lets the Opus-quality direction sit at the Organiser layer while Sonnet executes the bulk of bounded sub-tasks at lower per-token cost. The Organiser still handles ambiguity itself or escalates to Opus on demand.

The contract is in [`lib/organiser-prompt.txt`](lib/organiser-prompt.txt); the briefing skeleton is in [`lib/executor-prompt-template.txt`](lib/executor-prompt-template.txt). Per-dispatch records land in `9-sessions/executor-activity.log` (one CSV line per Agent call), which the wind-down session reads to produce a per-run Executor summary in `7-SUMMARY.md`.

## Prerequisites

- [Claude Code CLI](https://docs.claude.com/en/docs/claude-code), globally installed and authenticated.
- `git`, `tmux`, `jq`, `inotify-tools`.
- A target project that is itself a git repo.

## Install

```bash
git clone https://github.com/jimbo2k2/claude-orchestra.git ~/tools/claude-orchestra
cd /path/to/your/project
~/tools/claude-orchestra/bin/orchestra init
```

`orchestra init` scaffolds `.orchestra/` inside your project: it copies the runtime scripts into `.orchestra/runtime/` (so the project pins its own copy) and creates editable templates `CONFIG.md` and `OBJECTIVE.md`. No global PATH changes, no `~/`-level state.

## Quick start

```bash
# 1. Scaffold orchestra into your project (once)
~/tools/claude-orchestra/bin/orchestra init

# 2. Edit the run config
$EDITOR .orchestra/CONFIG.md          # MAX_SESSIONS, ORGANISER_MODEL, WORKTREE_BASE, BASE_BRANCH
$EDITOR .orchestra/OBJECTIVE.md       # what this run is for
$EDITOR .orchestra/INBOX.md           # optional: cold-start briefing

# 3. Run
.orchestra/runtime/bin/orchestra run

# 4. Watch
tmux attach -t orchestra-<project>    # live tail
.orchestra/runtime/bin/orchestra status
```

## Commands

| Command | Purpose |
|---------|---------|
| `orchestra init [dir]` | Scaffold `.orchestra/` into the target project (default: current directory). |
| `orchestra run` | Start a run in tmux. Reads `.orchestra/CONFIG.md` + `.orchestra/OBJECTIVE.md`. |
| `orchestra status` | Summarise the current or most recent run. |
| `orchestra test [variant]` | Smoke test — throwaway worktree, synthetic task, full lifecycle, asserts and cleans up. Variants: `empty`, `with-governance`, `with-conflict`, `with-handover`, `with-parcel`, `with-organiser`, `with-escalation`, `with-verify`. |
| `orchestra reset` | Archive current run state, reset for the next run. Governance files untouched. |

## Configuration

All run parameters live in `.orchestra/CONFIG.md` as markdown bullets (`- KEY: VALUE`). No env vars, no CLI args. The full key list with defaults lives in [`templates/CONFIG.md`](templates/CONFIG.md). Headline keys:

| Key | Required | Default | Notes |
|-----|----------|---------|-------|
| `MAX_SESSIONS` | yes | — | Hard upper bound on working sessions per run. |
| `MAX_CONSECUTIVE_CRASHES` | yes | — | Run aborts after this many crashes in a row. |
| `ORGANISER_MODEL` | yes | — | `opus`, `sonnet`, or `haiku`. (Legacy `MODEL` still accepted with a deprecation warning.) |
| `EFFORT` | no | `high` | `low`, `medium`, or `high`. |
| `WORKTREE_BASE` | yes | — | Absolute path; runs create `<WORKTREE_BASE>/run-<ts>/`. |
| `BASE_BRANCH` | yes | — | Branch the run-branch is cut from and merged back to. |
| `ORGANISER_CONTEXT_THRESHOLD` | no | `75` | Integer percent; when reached, the Organiser self-winds-down to HANDOVER. |
| `MAX_HANG_SECONDS` | no | `1200` | Watchdog kills Claude if its log file stops growing for this long. |
| `QUOTA_PACING` | no | `true` | Pause new sessions while Claude subscription utilisation is high. |
| `QUOTA_THRESHOLD` | no | `80` | Utilisation percent at which pacing kicks in. |

See [`CHANGES.md`](CHANGES.md) for recent changes.

## Vocabulary (per spec)

- **Run** — one user-initiated unit of work, defined by `OBJECTIVE.md`. One run = one git worktree, one tmux session, one run-branch.
- **Working session** — one `claude --print` invocation within a run. Sessions repeat (HANDOVER → next session) until the agent emits `COMPLETE`, `BLOCKED`, or limits are hit.
- **Wind-down session** — one final Claude invocation, exempt from `MAX_SESSIONS`, that runs only after `COMPLETE`. Ingests run governance into the parent project's governance, merges the run-branch into base.

## Repository layout

```
bin/
├── orchestra              CLI dispatcher (init, run, status, test, reset)
└── orchestrator.sh        session loop — runs inside the run worktree's tmux

lib/
├── config.sh                       CONFIG.md parser + validation (sourced)
├── winddown-prompt.txt             wind-down agent contract template
├── organiser-prompt.txt            Organiser inner-loop contract (loaded by orchestrator.sh)
└── executor-prompt-template.txt    Executor briefing skeleton

templates/
├── CONFIG.md              user-editable runtime config (canonical key list)
├── OBJECTIVE.md           user-editable run brief
└── orchestra-CLAUDE.md    agent-facing guidance for the installed .orchestra/

examples/smoke-test/
├── empty/                 no parent governance — exercises no-op ingestion
├── with-governance/       pre-populated TODO/DECISIONS/CHANGELOG
├── with-conflict/         contradicting decision — exercises conflict surfacing
├── with-handover/         multi-session HANDOVER → COMPLETE flow
├── with-parcel/           parent uses Governance/pending/ parcel ingestion
├── with-organiser/        Organiser → Sonnet Executor dispatch via Agent tool
├── with-escalation/       Sonnet ESCALATE → re-dispatch on Opus, same task-id
└── with-verify/           Organiser rejects DONE on verification → fix Executor

build-history/             per-version specs, plans, and Claude transcripts that
                           produced this codebase (frozen historical record)

tests/                     unit tests (fake claude); plus run-tests.sh runner

CHANGES.md                 user-facing changes between releases
ROADMAP.md                 backlog of non-blocking improvements
MIGRATION.md               Claude-readable prompt for v2-era → v3 install upgrade
MIGRATION-organiser.md     Claude-readable prompt for adding the organiser-executor runtime to a post-v3 install
```

## Run-time storage layout

Inside the run worktree at `<WORKTREE_BASE>/run-<ts>/.orchestra/runs/<ts>/`:

```
1-INBOX.md          human → agent messages
2-OBJECTIVE.md      run brief (copied from project)
3-TODO.md           rolling task list (agent-maintained)
4-DECISIONS.md      rolling design decisions
5-CHANGELOG.md      what changed in this run
6-HANDOVER.md       briefing for the next session (regenerated each session)
7-SUMMARY.md        rolling per-session narrative
9-sessions/
├── NNN.json                  raw stream-json transcript per session (NDJSON; always archived)
├── summary.json              one metadata entry per session (timestamps, exit code, signal, crash category)
└── executor-activity.log     one CSV line per Agent dispatch (timestamp, session, task-id, model, outcome, duration)
```

After a successful wind-down the run folder moves to `.orchestra/runs/archive/<ts>/`.

## Crash recovery

If a working session crashes or hangs, orchestra classifies it (Cat A/B/C/D), prepends a recovery preamble to the next session's prompt, and continues. After `MAX_CONSECUTIVE_CRASHES` in a row the run aborts cleanly. Wind-down does not run on aborted runs — the run worktree is preserved for human inspection.

## Quota pacing

Enabled by default. Before each working session, orchestra checks Claude subscription utilisation. If the rolling 5-hour window exceeds `QUOTA_THRESHOLD`, it sleeps until the window resets. Designed for overnight runs that span multiple quota windows.

## Tests

```bash
tests/run-tests.sh          # full suite
tests/run-tests.sh --fast   # skip the long real-time-wait tests (hang detection, smoke)
```

Run the full suite at end-of-phase / pre-merge.

## License

MIT
