# Run Objective

Create one text file in the worktree, then record run-level governance
using EXACT marker prefixes so the smoke test can verify wind-down
parcel-mode behaviour.

## Work product

1. `file-a.txt` containing the literal text `alpha`

Commit it on the run-branch.

## Run governance markers

- In `3-TODO.md`, prefix each entry with `[smoke-todo]`.
- In `4-DECISIONS.md`, prefix each entry with `[smoke-decision]`.
- In `5-CHANGELOG.md`, prefix each entry with `[smoke-changelog]`.

These are required by the smoke test. Do NOT use any of these markers in
the wrong file.

Add at least one entry per file.

## What you should NOT do

- Do NOT edit `TODO.md`, `DECISIONS.md`, or `CHANGELOG.md` at the project
  root. This project uses the parcel mechanism — those files are
  read-only on non-`main` branches.
- Do NOT create parcel files in `Governance/pending/` yourself. The
  wind-down session is the one that converts run governance into parcels
  at the end of the run.

## Completion

Before emitting `COMPLETE`:
- `file-a.txt` exists with content `alpha`.
- Each rolling file (3-TODO.md, 4-DECISIONS.md, 5-CHANGELOG.md) contains
  its appropriate marker on at least one entry.
- Worktree is clean — `git status` shows no uncommitted or untracked files.
- Root `TODO.md`/`DECISIONS.md`/`CHANGELOG.md` are unchanged from the
  fixture's initial state.
