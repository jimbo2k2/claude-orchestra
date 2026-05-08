# With-escalation smoke-test fixture

Exercises the **Sonnet ESCALATE → re-dispatch on Opus with same
task-id** retry path.

The OBJECTIVE.md instructs the Organiser to dispatch a deliberately
ambiguous brief on Sonnet (no actual task — Sonnet should return
`ESCALATE`), then re-dispatch the same task-id (`smoke-T1`) on Opus
with a clear brief that completes the work.

`smoke_assert_with_escalation()` in `bin/orchestra` verifies:

- A single working session ran to `COMPLETE`.
- `9-sessions/executor-activity.log` has exactly two non-empty CSV
  lines, both with task-id `smoke-T1`.
- First line: model `sonnet`, outcome `ESCALATE`.
- Second line: model `opus`, outcome `DONE`.
- The session transcript at `9-sessions/001.json` contains two `Agent`
  tool-use events.
- `escalation-result.txt` lands on the merged base with content
  exactly `opus completed this`.
- Governance markers landed; originals preserved.
