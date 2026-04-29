# Run Objective

Create two text files in the worktree, then record run-level governance
using EXACT marker prefixes so the smoke test can verify that wind-down
ingestion lands each source-file's content in the CORRECT parent destination.

## Work products

1. `file-a.txt` containing the literal text `alpha`
2. `file-b.txt` containing the literal text `beta`

Commit each file separately on the run-branch.

## Run governance markers

- In `3-TODO.md`, prefix each entry with `[smoke-todo]`.
- In `4-DECISIONS.md`, prefix each entry with `[smoke-decision]`.
- In `5-CHANGELOG.md`, prefix each entry with `[smoke-changelog]`.

These are required by the smoke test. Do NOT use any of these markers in
the wrong file (e.g. do NOT put `[smoke-decision]` in `3-TODO.md`).

Add at least one entry per file.

## Completion

Before emitting `COMPLETE`:
- Both work products exist with correct content.
- Each rolling file (3-TODO.md, 4-DECISIONS.md, 5-CHANGELOG.md) contains
  its appropriate marker on at least one entry.
- Worktree is clean — `git status` shows no uncommitted or untracked files.
