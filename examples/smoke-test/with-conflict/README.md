# With-conflict smoke-test fixture

Pre-populated `DECISIONS.md` with `[fixture-original] D001` claiming
SQLite. The OBJECTIVE.md instructs the agent to record a contradicting
`[smoke-decision]` choosing Postgres. The wind-down agent should detect
the semantic conflict and surface it in `7-SUMMARY.md` under
"Potential governance conflicts" using the schema from spec Section 6.3
step 4a.

Used by `./bin/orchestra test with-conflict`.
