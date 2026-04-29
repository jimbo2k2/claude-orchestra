# With-governance smoke-test fixture

Pre-populated TODO/DECISIONS/CHANGELOG with `[fixture-original]` markers.
The OBJECTIVE.md instructs the agent to use `[smoke-todo]`/
`[smoke-decision]`/`[smoke-changelog]` markers in its run governance so
the smoke driver can verify each marker lands in the correct destination
file (and no marker leaks across files).

Used by `./bin/orchestra test with-governance`.
