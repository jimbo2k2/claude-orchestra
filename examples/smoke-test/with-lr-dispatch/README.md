# With-lr-dispatch smoke-test fixture

Exercises the **Organiser → worker dispatch via the `lr-tmux` harness** path
end-to-end — the dispatch model introduced by the lr-tmux Executor swap
(`build-history/lr-tmux-executor/`). It is the successor to `with-organiser/`
(which exercises the legacy Agent-tool dispatch path).

## What it proves

The `OBJECTIVE.md` instructs the Organiser to dispatch exactly one worker
through `lr-dispatch-wait.sh` (the blocking wrapper), accept its result,
append a CSV line to `9-sessions/executor-activity.log`, update governance,
and `COMPLETE`. A successful run demonstrates:

- The Organiser dispatches via `lr-dispatch-wait.sh` (a worker tmux session
  appears as `lr-<label>`, visible on `lr-dashboard`), NOT via the Agent tool.
- The wrapper blocks the Organiser until the worker returns, then hands back
  the worker's result text on stdout — the Agent-tool blocking shape preserved.
- The activity-log CSV line carries the worker's REAL model (read from the
  worker's out-file), so wind-down's Executor summary stays accurate.
- The worker's code commit is its own; the Organiser commits only the parcel.

## Running it (OPERATOR-GATED — costs real tokens)

Unlike the fake-`claude` smoke fixtures, this path needs (a) a real `claude`
CLI and (b) the LogRings `lr-tmux` harness present on disk
(`<worktree>/Development/scripts/lr-tmux/`) with its isolated config home set
up (`lr-home-setup.sh`). It therefore has **no automated `smoke_assert` in
`bin/orchestra`** — running it dispatches a live worker and bills tokens, so
it is gated behind explicit operator action rather than the `--fast` suite.

To run it manually against a prepared LogRings worktree:

```sh
# 1. Ensure the harness is set up (idempotent):
bash <worktree>/Development/scripts/lr-tmux/lr-home-setup.sh
# 2. Start an orchestra run whose OBJECTIVE is this fixture's OBJECTIVE.md,
#    inside the prepared worktree on a feature branch. The Organiser contract
#    (lib/organiser-prompt.txt) drives the lr-dispatch-wait.sh dispatch.
# 3. Watch the worker live:
tmux attach -t lr-<label>          # or the lr-dashboard web view
# 4. After COMPLETE, confirm:
#    - 9-sessions/executor-activity.log has one CSV line with a real model
#      (sonnet|opus|haiku), outcome DONE.
#    - the worker's file/commit landed; the parcel (or 3/4/5) is committed.
```

The wrapper's own non-live behaviour (done/error/collision/empty-result) is
covered automatically by `Development/scripts/lr-tmux/test-dispatch-wait.sh`
on the LogRings side — run that for fast wrapper-regression coverage without
the live-token gate.
