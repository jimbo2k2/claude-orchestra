# .orchestra — Autonomous Session Rules

Follow `DEVELOPMENT-PROTOCOL.md` in **auto-proceed mode** (all gates auto-accept).

## Run Workspace

Each orchestra run gets a single folder at `.orchestra/sessions/run-<timestamp>/` (the orchestrator creates it and passes the name via the prompt). Inside:
- `tasks.md` — cumulative subtask list across all tasks in this run
- `log.md` — cumulative session decisions, findings, parked issues

If files already exist from a previous session in this run, append rather than overwrite. The orchestrator also writes session JSON logs into this folder.

## Session Grouping

Complete as many assigned T-numbers as context allows per session. Between tasks: evaluate remaining context window (protocol step 20). If sufficient, continue. If low, run session wrap-up (protocol Part 2) and write HANDOVER.md.

## Task Input

Read T-numbers from `.orchestra/config` `TASKS` field. Ignore TODO.md status field — work the tasks you've been given. If a task has a genuine blocker, mark it BLOCKED in TODO.md with a reason and move to the next task.

## Worktree + Branching Model

Orchestra sessions run in a **persistent git worktree** — an isolated copy of the repo at `WORKTREE_BASE/run-<timestamp>`. The main working tree stays on `main` untouched. The worktree is created once per run and reused across sessions (reset to a clean state between sessions).

The worktree is checked out on a **session branch** named `orchestra/run-<timestamp>` that's shared across all sessions in the same orchestra run. The session branch accumulates all completed task work. The worktree is preserved after the run for human review.

For each task:
1. Return to the session branch: `git checkout <session-branch>` (the orchestrator passes you the name)
2. Create the task branch from there: `git checkout -b orchestra/<t-number>-<slug>`
3. Do the task work, commit, push the task branch
4. Merge the task branch back into the session branch (fast-forward) so the next task inherits the work

This means dependent tasks see prior work, and the session branch is a coherent "all work this run" branch ready for human merge review.

## Governance

- Decisions: log as PROPOSED in DECISIONS.md (human ratifies)
- New tasks discovered: log as PROPOSED in TODO.md
- Commits: on branch, never to main. Do not merge.

## Exit Signals

- **HANDOVER** — tasks remain, spawn next session
- **COMPLETE** — all assigned tasks done
- **BLOCKED** — needs human input (write to INBOX.md)

## Conventions

Project-specific conventions for code style, logging, naming, and per-feature workflows are defined in the project's root `CLAUDE.md` (and any nested `CLAUDE.md` files in subdirectories). Read those first and follow them when modifying code.

Examples of conventions that typically belong in the root `CLAUDE.md`:
- Code style and formatter (e.g. prettier, ruff, gofmt)
- Logging conventions (e.g. use a shared logger module, never bare `console.*`/`print`)
- Test layout and naming
- Branch and commit message formats

If your project has subsystem-specific protocols (e.g. a screen-map workflow, a migrations checklist, a public-API change process), document them in the relevant subdirectory's `CLAUDE.md` and reference them here.
