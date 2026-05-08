# Run Objective

This objective exercises the **Organiser-dispatches-Executor** path
end-to-end. Your job is to dispatch exactly ONE subagent via the Agent
tool, accept its work, log the dispatch, update governance, and emit
`COMPLETE`. Do NOT do the file-creation work yourself — the whole point
is to confirm the dispatch path works.

## Step 1 — Dispatch one Executor

Use the **Agent** tool with these parameters:

- `subagent_type`: `general-purpose`
- `model`: `sonnet`
- `description`: `smoke: write executor file`
- `prompt`: a brief that asks the subagent to:
  1. Create `file-executor.txt` in the worktree root containing exactly
     the literal text `executor wrote this` (no trailing newline issues
     — exact match).
  2. Return with the literal final-line signal `DONE: wrote file-executor.txt`.

You may compose the prompt body freely (it will be captured in the
session transcript regardless), but the constraints above must be in
the brief verbatim.

## Step 2 — Verify and accept

After the Agent tool returns:

1. Read `file-executor.txt` yourself with the Read tool to confirm it
   exists with the expected content.

2. Append exactly one line to
   `__RUN_DIR_ABSOLUTE_PATH__/9-sessions/executor-activity.log` in this
   CSV format (no header — the file was touch-created empty at run
   start):

       <iso8601-timestamp-utc>,1,smoke-T1,sonnet,DONE,<duration-seconds-integer>

   `1` is the session number; `smoke-T1` is the task id;
   `<duration-seconds-integer>` is your best-estimate of how long the
   Agent dispatch took (any non-negative integer is acceptable for
   smoke assertion).

   The actual run dir path is whatever the Organiser prompt told you
   the run dir is (the variable named in the prompt). Use that, not a
   placeholder.

## Step 3 — Update governance

Append to the run governance files in `__RUN_DIR_ABSOLUTE_PATH__/`:

- `3-TODO.md`: `[smoke-todo] Dispatch test complete.`
- `4-DECISIONS.md`: `[smoke-decision] Used Agent tool with sonnet for the file write.`
- `5-CHANGELOG.md`: `[smoke-changelog] file-executor.txt written via Sonnet Executor.`

## Step 4 — Commit and COMPLETE

`git add -A && git commit` everything, then emit `COMPLETE` as the LAST
line of your output, on its own line.

## Constraints

- Do NOT create `file-executor.txt` yourself with the Write tool. It
  must come from the Agent tool dispatch.
- Do NOT dispatch more than one Agent. The smoke assertion checks the
  activity log has exactly one entry.
