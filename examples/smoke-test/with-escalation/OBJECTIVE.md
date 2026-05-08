# Run Objective

This objective exercises the **ESCALATE → re-dispatch on Opus** path.
You will deliberately under-brief a Sonnet Executor so it returns
`ESCALATE`, then re-dispatch the same task on Opus with a sharper
brief.

## Step 1 — First dispatch (Sonnet, deliberately ambiguous)

Use the Agent tool with:

- `subagent_type`: `general-purpose`
- `model`: `sonnet`
- `description`: `smoke: ambiguous task`
- `prompt`: this exact text:

  ```
  Do the thing the user wants. The user has not said what the thing
  is. Use whatever tools you think are appropriate. End your final
  message with EXACTLY one of:
  - DONE: <one-line summary of what you did>
  - ESCALATE: <one-line reason>
  - BLOCKED: <one-line reason>
  ```

The Sonnet subagent should return `ESCALATE` (the brief has no actual
task). If it returns `DONE` or `BLOCKED` instead, the smoke run fails
the assertion.

After it returns, append to
`<run-dir>/9-sessions/executor-activity.log`:

    <iso8601-timestamp>,1,smoke-T1,sonnet,ESCALATE,<duration>

(`<run-dir>` is the run dir path the Organiser prompt named you.
`smoke-T1` is the task-id. Duration is any non-negative integer.)

## Step 2 — Re-dispatch on Opus with a sharper brief

Same task-id (`smoke-T1`). Use the Agent tool with:

- `subagent_type`: `general-purpose`
- `model`: `opus`
- `description`: `smoke: clear task on opus retry`
- `prompt`: a clear brief that asks the subagent to:
  1. Create `escalation-result.txt` in the worktree root containing
     exactly the literal text `opus completed this`.
  2. Return with the literal final-line signal `DONE: wrote escalation-result.txt`.

After Opus returns DONE, append a SECOND activity-log line with the
SAME task-id:

    <iso8601-timestamp>,1,smoke-T1,opus,DONE,<duration>

## Step 3 — Update governance

Append to the run governance files in `<run-dir>/`:

- `3-TODO.md`: `[smoke-todo] Escalation retry test complete.`
- `4-DECISIONS.md`: `[smoke-decision] Sonnet ESCALATEd; reran on Opus per two-attempt cap rule.`
- `5-CHANGELOG.md`: `[smoke-changelog] escalation-result.txt written via Opus after Sonnet ESCALATE.`

## Step 4 — Commit and COMPLETE

`git add -A && git commit` everything, then emit `COMPLETE` as the
LAST line of your output, on its own line.

## Constraints

- Do NOT pass the clear brief to Sonnet on the first dispatch. The
  ambiguity is the point.
- Do NOT do more than two Agent dispatches total. Two attempts is the
  cap; the smoke assertion checks for exactly two activity-log lines.
- Both lines must have task-id `smoke-T1`.
