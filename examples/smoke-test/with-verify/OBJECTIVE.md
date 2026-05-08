# Run Objective

This objective exercises the **verification-rejection → fix-Executor**
path. You will deliberately brief a Sonnet Executor to write the WRONG
content, fail the verification check yourself, then dispatch a fix
Executor with a sharper brief. Both attempts share task-id `smoke-T1`.

## Step 1 — First dispatch (Sonnet, deliberately wrong content)

Use the Agent tool with:

- `subagent_type`: `general-purpose`
- `model`: `sonnet`
- `description`: `smoke: write wrong content (intentional)`
- `prompt`: a brief that asks the subagent to:
  1. Create `verify-result.txt` in the worktree root containing
     exactly the literal text `wrong content`.
  2. Return with the literal final-line signal `DONE: wrote verify-result.txt`.

The subagent will return `DONE` having written the wrong content. That
is intentional — the verification step in this Organiser session is
the one that catches the error, simulating a real-world DONE-but-
verification-failed outcome.

After it returns, append to
`<run-dir>/9-sessions/executor-activity.log`:

    <iso8601-timestamp>,1,smoke-T1,sonnet,DONE,<duration>

Note: the activity log line records what the **Executor returned**.
The Organiser is the one who decides verification fails — that
decision lives in the second dispatch's brief and in
`4-DECISIONS.md`, not in the activity log entry.

## Step 2 — Verify and reject

Read `verify-result.txt` with the Read tool. Acceptance is "exact
content `correct content`". The actual content is `wrong content`, so
acceptance fails.

Append to `<run-dir>/4-DECISIONS.md`:
`[smoke-decision] First dispatch returned DONE but verification rejected: content mismatch.`

## Step 3 — Fix dispatch (same task-id, Sonnet again with sharper brief)

Use the Agent tool with:

- `subagent_type`: `general-purpose`
- `model`: `sonnet`
- `description`: `smoke: fix verify-result.txt content`
- `prompt`: a brief that asks the subagent to:
  1. Overwrite `verify-result.txt` in the worktree root with exactly
     the literal text `correct content` (no trailing newline issues —
     exact match).
  2. Return with the literal final-line signal `DONE: rewrote verify-result.txt with correct content`.

After it returns, append a SECOND activity-log line with the SAME
task-id:

    <iso8601-timestamp>,1,smoke-T1,sonnet,DONE,<duration>

## Step 4 — Verify pass

Read `verify-result.txt` again. Content should now be `correct
content`. Acceptance passes.

Append to the run governance files in `<run-dir>/`:

- `3-TODO.md`: `[smoke-todo] Verify-reject test complete.`
- `4-DECISIONS.md`: `[smoke-decision] Second dispatch fixed the content; verification passed.`
- `5-CHANGELOG.md`: `[smoke-changelog] verify-result.txt fixed via second Sonnet dispatch after verification rejected first attempt.`

## Step 5 — Commit and COMPLETE

`git add -A && git commit` everything, then emit `COMPLETE` as the
LAST line of your output, on its own line.

## Constraints

- Do NOT do more than two Agent dispatches total. The smoke assertion
  checks for exactly two activity-log lines.
- Both lines must have task-id `smoke-T1`.
- Both dispatches use Sonnet (this fixture is about verification
  rejection, not model escalation).
- Do NOT hand-edit `verify-result.txt` yourself. Both writes must come
  from Agent dispatches.
