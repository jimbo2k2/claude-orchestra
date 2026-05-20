# Orchestra (in this project)

This file is for INTERACTIVE Claude sessions helping prepare/invoke orchestra runs in this project. Autonomous run sessions operate inside the worktree under the parent project's CLAUDE.md hierarchy and don't read this file.

## What orchestra is

Orchestra is a session-orchestration runtime. It runs autonomous multi-session Claude work against an objective:

- **Run** — one `orchestra run` invocation. Runs **in place** inside the operator-prepared worktree on whatever branch HEAD points to (typically a feature branch). One tmux session, one folder under `<project>/.orchestra/runs/<timestamp>/`.
- **Session** — a single Claude chat (one process, one 1M-context window) within a run. A run typically contains multiple sessions chained by HANDOVER.
- **Wind-down** — final session of a run that verifies governance coverage, writes the run summary, and archives the run folder. The operator handles the feature → main rollup manually after wind-down.

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

**Important:** commit `OBJECTIVE.md` and `CONFIG.md` to your feature branch before `orchestra run`. Orchestra runs in place on whatever branch HEAD points to — uncommitted edits at the time of `orchestra run` aren't visible to the first session via the run-folder snapshot of `OBJECTIVE.md`.

## `cmd_run` preflight

Before launching, `orchestra run` enforces four refusals (spec § 3.4):

1. **Branch refusal.** Refuses on `main`/`master` (hardcoded) or any entry in `PROTECTED_BRANCHES` (CONFIG.md, defaults to `main,master`). Switch to a feature branch first.
2. **Obsolete-key refusal.** Refuses if CONFIG.md still contains `BASE_BRANCH` or `WORKTREE_BASE` (left over from the pre-run-in-place era). Remove them and add `WORKTREE_PATH`.
3. **WORKTREE_PATH canary.** Refuses if `WORKTREE_PATH` doesn't match this worktree's absolute path (`realpath`-compared). Catches stale CONFIG.md inherited from a sibling worktree via `git worktree add`.
4. **No prior run folder.** Refuses if any non-archive subfolder exists under `.orchestra/runs/`. Run `orchestra reset` to archive previous runs.

## Project protocol discoverability

If your project has a task protocol (e.g. `Development/conventions/` with per-task code-review or simplify-pass gates), set `PROTOCOL_FOLDER` in `.orchestra/CONFIG.md` to point at it. The Organiser, Executor briefs, and Wind-down all gain a one-line sentence telling them where to find it. Soft signal — orchestra does not enforce that working sessions follow it. Leave `PROTOCOL_FOLDER` empty to opt out.

## Reading run output

Each run creates a numbered file layout under `<project>/.orchestra/runs/<run-timestamp>/`:

- `1-INBOX.md` — live human → run channel for mid-run redirection (edit during a run to inject instructions)
- `2-OBJECTIVE.md` — snapshot of the brief (read-only after run start)
- `3-TODO.md` / `4-DECISIONS.md` / `5-CHANGELOG.md` — **legacy-mode only**. In parcel-mode (project has `Governance/CLAUDE.md` + `Governance/pending/`), these files are NOT created — governance lives in `Governance/pending/<hex>.md` parcels written directly by the working sessions.
- `6-HANDOVER.md` — briefing for the next session (regenerated each session)
- `7-SUMMARY.md` — rolling per-session narrative. Includes a `### Governance verification` block from wind-down's parcel-coverage check.
- `9-sessions/NNN.json` — raw stream-json transcript per session (NDJSON, always archived). Queryable via `jq`/`grep` for retrospective analysis.
- `9-sessions/summary.json` — single JSON array, one metadata entry per session (timestamps, exit code, signal, crash category)
- `9-sessions/executor-activity.log` — CSV log of Executor dispatches (timestamp,session,task,model,outcome,duration).

After successful wind-down the folder moves to `.orchestra/runs/archive/<timestamp>/`.

## Governance model

- **Parcel-mode** (project has `Governance/CLAUDE.md` + `Governance/pending/`): working sessions author `Governance/pending/<hex>.md` parcels directly before emitting their terminal signal. Wind-down's Step 2 is parcel-coverage verification (read activity log, list parcels committed during the run window, flag gaps in `7-SUMMARY.md`). No retroactive parcel creation. Operator-driven feature → main rollup triggers the W4 ingestion pass that allocates real T/D/C/B numbers.
- **Legacy-mode** (project lacks the parcel mechanism): working sessions write to `3-TODO.md` / `4-DECISIONS.md` / `5-CHANGELOG.md` in the run folder; wind-down's Step 2 appends to parent `TODO.md` / `DECISIONS.md` / `CHANGELOG.md` (or per the project's discovered shape).

## Markers and recovery

- **`BLOCKED` marker** in a run folder: agent halted; read `6-HANDOVER.md` for the blocker. Resolve and start a fresh run.
- **`WIND-DOWN-FAILED` marker**: wind-down crashed or couldn't complete the verification commit. The orchestrator's exit message points at `6-HANDOVER.md` for the diagnosis; recovery is manual.

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

## Migration from older orchestra installs

Three Claude-readable migration prompts live in the orchestra source repo, depending on what install you're starting from:

- **`MIGRATION.md`** — for v2-era installs (bash config in `.orchestra/config`, hooks in `.orchestra/hooks/`, governance paths in config). Heavyweight: file moves, config rename, hook removal.
- **`MIGRATION-organiser.md`** — for post-v3 installs adding the organiser-executor runtime (the `lib/organiser-prompt.txt` + `lib/executor-prompt-template.txt` Agent-tool dispatch model). Refresh-only: idempotent re-run of `orchestra init`.
- **`MIGRATION-run-in-place.md`** — for installs upgrading to run-in-place. Drops `BASE_BRANCH` + `WORKTREE_BASE` from CONFIG.md, adds `WORKTREE_PATH` and optional `PROTECTED_BRANCHES` / `PROTOCOL_FOLDER`. Refresh the runtime + edit CONFIG.md per-worktree.

To migrate, ask Claude: "follow the orchestra migration prompt at `<orchestra-repo>/MIGRATION-run-in-place.md`" — Claude will read the file and walk you through it.
