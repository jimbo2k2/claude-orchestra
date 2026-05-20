# MIGRATION: orchestra run-in-place

This document describes the upgrade from the worktree-spawning model to the run-in-place model.

## Summary of the breaking change

**Before** (pre-run-in-place): `cmd_run` spawned a sibling worktree at `$WORKTREE_BASE/run-<ts>/`, branched `orchestra/run-<ts>` off `$BASE_BRANCH`, ran inside that worktree, and ff-merged back into `$BASE_BRANCH` at wind-down. The operator preset `WORKTREE_BASE` and `BASE_BRANCH` in CONFIG.md.

**After**: `cmd_run` runs **inside the worktree the operator has checked out**, on whatever branch HEAD points to. No spawned worktree, no run-branch, no merge-to-base, no push-to-base. The operator handles the feature → main rollup manually after wind-down.

## What this means for an existing project

1. Your existing `.orchestra/CONFIG.md` contains `BASE_BRANCH` and `WORKTREE_BASE` keys. These are **now obsolete**, and `cmd_run` will refuse to start until they're removed.
2. A new required key `WORKTREE_PATH` must be present. It serves as a "canary" — `cmd_run` resolves both `WORKTREE_PATH` and the actual worktree path via `realpath` and refuses to start on mismatch. This catches stale CONFIG.md inherited from sibling worktrees via `git worktree add` (a tracked file's content follows the new worktree but its path doesn't).
3. An optional new key `PROTECTED_BRANCHES` (default `main,master`) extends the set of branches `cmd_run` refuses to operate on. Useful if your repo's primary branch is `develop` / `trunk` / similar.
4. An optional new key `PROTOCOL_FOLDER` points working sessions at the project's task-protocol folder (e.g. `Development/conventions/`). Soft signal substituted into the organiser, executor, and wind-down prompts. Leave empty to opt out — the templated sentence is removed from the prompts entirely.
5. `cmd_run` now refuses if any non-archive run folder still exists under `.orchestra/runs/`. Archive or remove old folders before starting a new run (e.g. `orchestra reset`).

## Upgrade recipe

In each worktree where orchestra has been initialised:

```bash
# 1. Pull the new orchestra runtime
cd /path/to/your/worktree
git fetch origin
git rebase origin/main    # picks up the new .orchestra/runtime/ files
# (Or: rerun `orchestra init` if orchestra lives outside the project repo and you
#  haven't tracked .orchestra/runtime/ in your project. The init step
#  overwrites runtime/ but skips templates/CONFIG.md.)

# 2. Clean .orchestra/CONFIG.md
$EDITOR .orchestra/CONFIG.md
# - Remove the `BASE_BRANCH: <value>` line.
# - Remove the `WORKTREE_BASE: <value>` line.
# - Add `WORKTREE_PATH: <absolute path of this worktree>` (run `pwd` to confirm).
# - Optionally add `PROTECTED_BRANCHES: main,master,<your-extras>` if your
#   primary branch isn't main/master.
# - Optionally add `PROTOCOL_FOLDER: <relative path>` (e.g. `Development/conventions/`)
#   to point working sessions at your project's task-protocol folder.

# 3. Archive any old run folders
ls .orchestra/runs/
orchestra reset    # archives all non-archive subfolders into .orchestra/runs/archive/

# 4. Try a run — preflight will tell you if anything is still off
orchestra run
```

If `orchestra run` refuses, the error message names the specific check that failed and the fix.

## The new operator workflow

1. `cd` into the worktree you want orchestra to run in (a feature branch, not main/master).
2. Stage `.orchestra/OBJECTIVE.md` + any seed parcels.
3. `orchestra run`. Preflight checks fire before anything happens; on pass, orchestra runs in place and commits on HEAD.
4. After the run, the work is on your feature branch. You handle the feature → main rollup yourself (the wind-down session no longer does this).

## What does NOT change

- Per-step commit discipline (the W2 hook, if you have one configured in the parent project).
- Run folder layout for the surviving files: `1-INBOX.md`, `2-OBJECTIVE.md`, `6-HANDOVER.md`, `7-SUMMARY.md`, `9-sessions/`.
- Cat A/B/C/D classification + watchdog hang detection.
- The two-attempt cap per Executor task-id.
- `ORGANISER_CONTEXT_THRESHOLD` (default 75%).
- Wind-down legacy-mode (append-to-parent-files) for projects that don't use the parcel mechanism — retained as a compat path.

## What is new in the prompts

- **Organiser writes parcels directly** (parcel-mode). The Organiser writes `Governance/pending/<hex>.md` parcels in place of the legacy `3-TODO.md` / `4-DECISIONS.md` / `5-CHANGELOG.md` files. Wind-down's Step 2 changes from "convert 3/4/5 to parcels" to "verify parcels were committed during the run window".
- **Tightened BLOCKED definition.** BLOCKED is reserved for external dependencies the Organiser cannot satisfy in-session, or operator-only questions whose answers materially change the work. Tests failing, acceptance commands failing, an Executor returning BLOCKED on one task, ambiguous design choices — none of these are session BLOCKED anymore. The Organiser persists through failed acceptance commands (read → hypothesise → fix → retest), and an Executor's BLOCKED is taken inline by the Organiser (with the task captured as deferred in the parcel if still stuck), not auto-promoted to session BLOCKED.
- **Slicing autonomy.** Each session attempts its full slice before HANDOVER. HANDOVER is for context exhaustion, not difficulty.
- **Operator-watching verbosity.** Three structured-narration clauses for the operator watching via `tmux capture-pane`: a dispatch announcement before each Agent tool call, a status update block when an Executor's wall-clock duration was ≥ 300s, an inline-work header/footer when the Organiser takes a task inline.
- **Gate-application discipline.** When the project's task protocol prescribes per-task gates (code-review, simplify, test-suite checks), the Organiser chooses per-task application (default; high-risk or interdependent tasks) or batched application (parallel mechanical low-risk tasks like symbol renames). The choice is recorded in the active session parcel under `## Decisions`.

## Run-folder layout differences

| File | Parcel-mode | Legacy-mode |
|---|---|---|
| `1-INBOX.md` | ✓ | ✓ |
| `2-OBJECTIVE.md` | ✓ | ✓ |
| `3-TODO.md` | ✗ (governance in parcels) | ✓ |
| `4-DECISIONS.md` | ✗ (governance in parcels) | ✓ |
| `5-CHANGELOG.md` | ✗ (governance in parcels) | ✓ |
| `6-HANDOVER.md` | ✓ | ✓ |
| `7-SUMMARY.md` | ✓ (includes `### Governance verification` block) | ✓ |
| `9-sessions/` | ✓ | ✓ |
| `Governance/pending/<hex>.md` | ✓ (written by working sessions) | ✗ (legacy path uses 3/4/5 + parent files) |

## Troubleshooting

**`Refusing to run on protected branch 'main'.`** — You're on `main` (or `master`, or a `PROTECTED_BRANCHES` entry). Switch to a feature branch: `git checkout -b feature/<your-slug>`.

**`CONFIG.md contains obsolete key 'BASE_BRANCH'...`** — Remove the `BASE_BRANCH` line (and `WORKTREE_BASE` if also present) from `.orchestra/CONFIG.md`.

**`WORKTREE_PATH canary mismatch.`** — Edit `.orchestra/CONFIG.md` and set `WORKTREE_PATH` to this worktree's absolute path (`pwd`). The error message names the expected vs actual path.

**`A previous run folder still exists under .orchestra/runs/...`** — A prior run crashed and left an unarchived folder, OR a concurrent run is still active in another tmux session. Inspect the folder; if it's a leftover, `orchestra reset` archives it; if it's live, attach the existing tmux session instead.

**`required config key 'WORKTREE_PATH' is missing`** — Add `- \`WORKTREE_PATH\`: <absolute path>` to `.orchestra/CONFIG.md`.

## Spec reference

The canonical design is in the LogRings repo at
`Pipeline/--inflight/2026-05-10-orchestra-run-in-place/spec.md` (will move to
`Pipeline/executed/orchestra/2026-05-10-orchestra-run-in-place/spec.md` once
the work fully lands).
