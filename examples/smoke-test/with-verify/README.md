# With-verify smoke-test fixture

Exercises the **verification-rejection → fix-Executor** retry path.

The OBJECTIVE.md instructs the Organiser to dispatch Sonnet to write
intentionally-wrong content, verify the result against an exact-match
acceptance condition, reject the work, and re-dispatch the same
task-id (`smoke-T1`) with a sharper brief that produces the correct
content. Both attempts log as `sonnet,DONE` in the activity log — the
rejection lives in `4-DECISIONS.md`, not in the activity-log outcome.

`smoke_assert_with_verify()` in `bin/orchestra` verifies:

- A single working session ran to `COMPLETE`.
- `9-sessions/executor-activity.log` has exactly two non-empty CSV
  lines, both with task-id `smoke-T1` and both `sonnet,DONE`.
- The session transcript at `9-sessions/001.json` contains two `Agent`
  tool-use events.
- `verify-result.txt` lands on the merged base with content exactly
  `correct content` (the second dispatch's output, not the first).
- `4-DECISIONS.md` contains the verification-rejection note.
- Governance markers landed; originals preserved.
