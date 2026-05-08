# With-organiser smoke-test fixture

Exercises the **Organiser → Sonnet Executor dispatch via the Agent
tool** path end-to-end.

The OBJECTIVE.md instructs the Organiser to dispatch exactly one
subagent on Sonnet, accept its work product, append a CSV line to
`9-sessions/executor-activity.log`, update governance, and `COMPLETE`.

`smoke_assert_with_organiser()` in `bin/orchestra` verifies:

- A single working session ran to `COMPLETE` (1 numbered transcript in
  `9-sessions/`, plus the rolling `summary.json`).
- `9-sessions/executor-activity.log` exists and has exactly one
  non-empty CSV line.
- That CSV line names model `sonnet` and outcome `DONE`.
- The session transcript at `9-sessions/001.json` contains an `Agent`
  tool-use event (so we know the dispatch went through the Agent tool,
  not a plain Write).
- `file-executor.txt` lands on the merged base with exactly the content
  `executor wrote this`.
- Governance markers landed (legacy ingestion same as `with-governance`
  / `with-handover`).
- Run governance originals preserved.
