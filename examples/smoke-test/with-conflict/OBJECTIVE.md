# Run Objective

Record a single new executive decision in your `4-DECISIONS.md`:

> [smoke-decision] We will use Postgres for the database. SQLite was
> insufficient for our scaling needs.

This decision DIRECTLY CONTRADICTS the existing `[fixture-original] D001`
in the parent `DECISIONS.md` (which currently claims SQLite). The
wind-down agent is expected to detect this semantic conflict and surface
it in `7-SUMMARY.md` under a "Potential governance conflicts" subsection
following the schema from the wind-down contract.

## Completion

Before emitting `COMPLETE`:
- `4-DECISIONS.md` contains the new `[smoke-decision]` entry.
- Worktree is clean (`git status` shows no uncommitted or untracked files).

The contradiction in DECISIONS.md is intentional — do NOT try to "resolve"
it during the working session. Just record the decision and let wind-down
surface the conflict.
