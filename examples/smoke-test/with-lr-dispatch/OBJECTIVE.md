# Run Objective

This objective exercises the **Organiser-dispatches-worker-via-lr-tmux**
path end-to-end. Your job is to dispatch exactly ONE worker through the
`lr-dispatch-wait.sh` blocking wrapper, accept its work, log the dispatch,
update governance, and emit `COMPLETE`. Do NOT do the file-creation work
yourself — the whole point is to confirm the lr-tmux dispatch path works.

> This fixture requires a real `claude` CLI and the LogRings `lr-tmux`
> harness present in the worktree (`Development/scripts/lr-tmux/`), with the
> isolated home set up via `lr-home-setup.sh`. It is OPERATOR-GATED — it
> bills real tokens. See this fixture's `README.md`.

## Step 1 — Dispatch one worker via the wrapper

1. Write a lean task file to `<LR_STATE>/smoke-task.md` (where `<LR_STATE>`
   defaults to `~/projects/logrings/.lr-sessions`) asking the worker to:
   - Create `file-worker.txt` in the worktree root containing exactly the
     literal text `worker wrote this` (no trailing-newline surprises).
   - Commit it (the worker owns its own code commit).
   Do NOT add a protocol-folder pointer or a role preamble — the `lr-*`
   worker reads the project cascade itself.

2. Dispatch through the blocking wrapper (it launches the worker detached in
   tmux session `lr-smoke`, blocks until it returns, prints the result):

       bash <worktree>/Development/scripts/lr-tmux/lr-dispatch-wait.sh \
            init lr-codewriter-o <worktree> <LR_STATE>/smoke-task.md smoke

   Exit 0 + stdout = the worker's result. A non-zero exit = treat as
   ESCALATE/failure (read the stderr it printed).

## Step 2 — Verify and accept

After the wrapper returns:

1. Read `file-worker.txt` yourself to confirm it exists with the expected
   content and that the worker committed it (`git log` shows its commit).

2. Append exactly one line to
   `__RUN_DIR_ABSOLUTE_PATH__/9-sessions/executor-activity.log` in this
   CSV format (no header):

       <iso8601-timestamp-utc>,1,smoke,<real-model>,DONE,<duration-seconds-integer>

   `<real-model>` is the worker's ACTUAL model — read it from the worker's
   out-file (resolve `.out` from `<LR_STATE>/ledger.json` for label `smoke`,
   then `grep -E '"type": *"assistant"' "$out" | head -1 | jq -r '.message.model'`)
   and map it to the `sonnet|opus|haiku` family. Do NOT guess it from the
   agent name suffix.

## Step 3 — Update governance

Append to the run governance files in `__RUN_DIR_ABSOLUTE_PATH__/`:

- `3-TODO.md`: `[smoke-todo] lr-tmux dispatch test complete.`
- `4-DECISIONS.md`: `[smoke-decision] Dispatched lr-codewriter-o via lr-dispatch-wait.sh.`
- `5-CHANGELOG.md`: `[smoke-changelog] file-worker.txt written by a tmux-dispatched worker.`

(Parcel-mode projects: author a `Governance/pending/<hex>.md` parcel instead,
per the Organiser contract Step 5.)

## Step 4 — COMPLETE

The worker already committed its own code. Commit the governance/parcel
yourself, then emit `COMPLETE` as the LAST line of your output, on its own
line.

## Constraints

- Do NOT create `file-worker.txt` yourself — it must come from the worker.
- Do NOT dispatch more than one worker. The activity log must have exactly
  one entry.
- Do NOT use the Agent tool — this fixture tests the lr-tmux path.
