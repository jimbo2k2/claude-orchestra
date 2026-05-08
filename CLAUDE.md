# Project: claude-orchestra

Autonomous multi-session orchestration runtime for Claude Code. Spawns
headless `claude --print` sessions inside a git worktree, watches for
hangs/crashes, runs a wind-down session that ingests run-level governance
into the parent project's governance shape, then merges to the base
branch.

## Tech stack

Bash, git, tmux, jq, inotify-tools. Linux-only.

## Layout

```
bin/
├── orchestra                       CLI dispatcher (init, run, status, test, reset)
└── orchestrator.sh                 session loop — runs inside the run worktree's tmux
lib/
├── config.sh                       CONFIG.md parser + validation (sourced)
├── winddown-prompt.txt             wind-down agent contract template
├── organiser-prompt.txt            Organiser inner-loop contract (Phase 1; wired in Phase 2)
└── executor-prompt-template.txt    Executor briefing skeleton
templates/
├── CONFIG.md                       user-editable runtime config (canonical key list)
├── OBJECTIVE.md                    user-editable run brief
└── orchestra-CLAUDE.md             agent-facing guidance for the installed `.orchestra/`
examples/
└── smoke-test/
    ├── empty/                      no parent governance — exercises no-op ingestion
    ├── with-governance/            pre-populated TODO/DECISIONS/CHANGELOG
    ├── with-conflict/              contradicting decision — exercises conflict surfacing
    ├── with-handover/              multi-session HANDOVER → COMPLETE flow
    ├── with-parcel/                parent uses Governance/pending/ parcel ingestion
    ├── with-organiser/             Organiser → Sonnet Executor dispatch via Agent tool
    ├── with-escalation/            Sonnet ESCALATE → re-dispatch on Opus, same task-id
    └── with-verify/                Organiser rejects DONE on verification → fix Executor
build-history/
├── archive/<version>/              frozen per-version specs, plans, transcripts
└── <topic>/                        active design work in progress (e.g. organiser-executor/)
tests/
└── test_*.sh                       unit tests (fake claude); plus run-tests.sh runner
CHANGES.md                          user-facing changes between releases
ROADMAP.md                          backlog of non-blocking improvements
MIGRATION.md                        Claude-readable prompt for migrating an old install (v2→v3)
MIGRATION-organiser.md              Claude-readable prompt for upgrading a post-v3 install to organiser-executor
README.md
```

## Conventions

- `set -euo pipefail` in every shipped script (except files that are
  sourced — `lib/config.sh` deliberately does not, to avoid leaking
  options into the caller's shell).
- Shipped scripts are `chmod +x`.
- Project-local install: `orchestra init` writes everything under
  `.orchestra/runtime/` in the user's project. No `~/` install, no global
  paths.
- `tests/run-tests.sh --fast` skips the long real-time-wait tests
  (hang detection, smoke). Run the full suite at end-of-phase / pre-merge.
- All run state lives inside the worktree at
  `<WORKTREE_BASE>/run-<ts>/.orchestra/runs/<ts>/`. The project tree's
  `.orchestra/runs/<ts>/` is just the atomic-mkdir uniqueness gate
  (Section 7 of the spec).

## Vocabulary (per spec Section 2)

- **Run** — a single user-initiated unit of work, defined by an
  `OBJECTIVE.md`. One run = one git worktree, one tmux session, one
  run-branch.
- **Working session** — one Claude invocation within a run. Working
  sessions repeat (HANDOVER → next session) until the agent emits
  `COMPLETE` or `BLOCKED`, or `MAX_SESSIONS`/`MAX_CONSECUTIVE_CRASHES` is
  reached.
- **Wind-down session** — one additional Claude invocation, exempt from
  `MAX_SESSIONS`, that runs only after a successful `COMPLETE`. It
  ingests run governance into parent governance and merges the
  run-branch into base.

## Where things live

- **Spec (canonical):** `build-history/archive/v0-cleanup/2026-04-29-orchestra-cleanup-design.md`
- **Plan:** `build-history/archive/v0-cleanup/2026-04-29-orchestra-cleanup-plan.md`
- **Smoke fixtures:** `examples/smoke-test/{empty,with-governance,with-conflict,with-handover,with-parcel,with-organiser,with-escalation,with-verify}/`
- **Migration prompt:** `MIGRATION.md` (Claude-readable; for users coming
  from an older orchestra install)
- **Backlog:** `ROADMAP.md` (non-blocking improvements identified during
  the rewrite — hardening, diagnostics, refactor, test coverage)
- **Releases:** `CHANGES.md` (user-facing changes between releases)
- **Build history:** `build-history/archive/<version>/` (per-version spec,
  plan, RESUME, and Claude transcripts that produced this codebase).
  Active in-progress design work lives under `build-history/<topic>/` at
  the top level until shipped, then archives.

## What this project does NOT have an opinion on

Orchestra runs autonomous Claude sessions inside a worktree but doesn't
prescribe how the parent project structures its own governance, builds,
tests, or commit conventions — that's the parent project's CLAUDE.md
hierarchy and the agent reads it. Wind-down ingestion follows whatever
governance shape the parent already has (or skips ingestion if it has
none).
