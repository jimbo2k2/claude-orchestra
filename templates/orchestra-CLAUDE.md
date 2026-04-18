# .orchestra — Autonomous Session Rules

Follow `DEVELOPMENT-PROTOCOL.md` in **auto-proceed mode** (all gates auto-accept).

## Session Workspace

Each task gets `.orchestra/sessions/<T-number>/` with:
- `tasks.md` — subtask decomposition + model recommendations
- `log.md` — session decisions, findings, parked issues

Archive completed workspaces to `.orchestra/sessions/archive/`.

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

When writing or modifying code, follow `logrings-app/CLAUDE.md` for commenting, logging, and naming conventions. Use `@shared/logging`, not bare `console.*`.

If a task adds, renames, or removes a screen, follow the screen-map workflow in `Product/CLAUDE.md § Screen Map (D182)`.
