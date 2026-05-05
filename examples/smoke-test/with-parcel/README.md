# With-parcel smoke-test fixture

Exercises the **parcel-mode** wind-down ingestion path (Step 1a of
`lib/winddown-prompt.txt`, added 2026-05-05).

The fixture has both:
- Pre-populated TODO/DECISIONS/CHANGELOG with `[fixture-original]`
  markers (must NOT be touched by wind-down — parcel mode leaves
  parent governance files alone).
- A `Governance/CLAUDE.md` + empty `Governance/pending/.gitkeep` that
  signals to the wind-down: this is parcel mode.

The OBJECTIVE.md instructs the agent to use the same `[smoke-todo]` /
`[smoke-decision]` / `[smoke-changelog]` markers in run governance
(3-TODO.md, 4-DECISIONS.md, 5-CHANGELOG.md). Wind-down should:

1. Detect parcel mode (file + folder both present).
2. Convert run governance into one or more `Governance/pending/<hex>.md`
   parcels with the markers preserved.
3. Commit the parcels with `wind-down: convert run governance to parcels`.
4. Record the conversion in `7-SUMMARY.md` § Parcel conversion.
5. Leave root TODO/DECISIONS/CHANGELOG untouched.

`smoke_assert_with_parcel()` in `bin/orchestra` verifies all five.
