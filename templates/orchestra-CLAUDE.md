# Orchestra (in this project)

This file is for INTERACTIVE Claude sessions helping prepare/invoke orchestra runs in this project. Autonomous run sessions operate inside the worktree under the parent project's CLAUDE.md hierarchy and don't read this file.

## What orchestra is

Orchestra is a session-orchestration runtime. It runs autonomous multi-session Claude work against an objective:

- **Run** — one `orchestra run` invocation. Owns one git worktree, one run-branch (`orchestra/run-<timestamp>`), one tmux session, one folder under `.orchestra/runs/`.
- **Session** — a single Claude chat (one process, one 1M-context window) within a run. A run typically contains multiple sessions chained by HANDOVER.
- **Wind-down** — final session of a run that ingests run governance into parent project docs and merges to base branch.

## Invocation

```bash
.orchestra/runtime/bin/orchestra run     # start a run (after CONFIG.md + OBJECTIVE.md committed)
.orchestra/runtime/bin/orchestra status  # show active/archived run state
.orchestra/runtime/bin/orchestra test    # run end-to-end smoke test
.orchestra/runtime/bin/orchestra reset   # archive any in-progress runs
```

Suggested alias for convenience: `alias orchestra=.orchestra/runtime/bin/orchestra`.

## Preparing OBJECTIVE.md

Before each run, edit `.orchestra/OBJECTIVE.md` to brief the agent. Free-form markdown — typically:
- A short goal statement
- References to spec/plan/design files the agent should read
- Constraints, non-goals, or things explicitly out of scope

**Important:** `OBJECTIVE.md` and `CONFIG.md` must be committed to `BASE_BRANCH` before `orchestra run` for the changes to be picked up. Uncommitted edits don't take effect (the worktree clones from the branch's HEAD).

## Reading run output

Each run creates a numbered file layout under `<worktree>/.orchestra/runs/<run-timestamp>/`:

- `1-INBOX.md` — live human → run channel for mid-run redirection (edit during a run to inject instructions)
- `2-OBJECTIVE.md` — snapshot of the brief (read-only after run start)
- `3-TODO.md` — agent's rolling subtask list
- `4-DECISIONS.md` — exec decisions taken to keep running
- `5-CHANGELOG.md` — what changed in this run
- `6-HANDOVER.md` — briefing for the next session (regenerated each session)
- `7-SUMMARY.md` — rolling per-session narrative
- `9-sessions/NNN.json` — raw stream-json transcript per session (NDJSON, always archived)
- `9-sessions/summary.json` — single JSON array, one metadata entry per session (timestamps, exit code, signal, crash category)

After successful wind-down the folder moves to `.orchestra/runs/archive/<timestamp>/`.

## Markers and recovery

- **`BLOCKED` marker** in a run folder: agent halted; read `6-HANDOVER.md` for the blocker. Resolve and start a fresh run.
- **`WIND-DOWN-FAILED` marker**: wind-down crashed or couldn't complete the merge. The orchestrator's exit message includes copy-paste recovery commands.

## Smoke tests

`orchestra test <variant>` exercises the full run + wind-down lifecycle against a fixture project. **The fixtures live in the canonical orchestra repo only**, not in this project's bundled runtime. Run smoke tests from `~/projects/claude-orchestra/` (or wherever the canonical repo is checked out), not from the bundled `.orchestra/runtime/` here:

```bash
cd ~/projects/claude-orchestra
bin/orchestra test empty             # baseline: no parent governance
bin/orchestra test with-governance   # legacy per-file ingestion (TODO/DECISIONS/CHANGELOG)
bin/orchestra test with-conflict     # legacy ingestion + conflict-detection in 7-SUMMARY
bin/orchestra test with-parcel       # parcel-mode wind-down (Governance/pending/<hex>.md)
bin/orchestra test with-handover     # multi-session HANDOVER → next-session pickup → COMPLETE
```

Each variant has a fixture folder under `examples/smoke-test/<variant>/` (containing `CLAUDE.md`, `OBJECTIVE.md`, and any pre-populated governance files) and a matching `smoke_assert_<variant>()` in `bin/orchestra`. Each smoke run takes ~3-10 minutes (15 min hard timeout). Output tempdir is `/tmp/orchestra-smoke-<timestamp>-<variant>/` — kept for inspection on PASS or FAIL.

Running `.orchestra/runtime/bin/orchestra test ...` from a project that has the bundled runtime will fail with `Fixture not found` because the bundle deliberately excludes `examples/`.

## Migration from old orchestra

If you're upgrading an existing orchestra install (the bash-config + governance-paths era), see the orchestra source repo's `MIGRATION.md` and ask Claude to follow that prompt: "follow the orchestra migration prompt at <orchestra-repo>/MIGRATION.md to migrate this project".
