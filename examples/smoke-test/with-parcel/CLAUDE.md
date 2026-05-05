# Smoke-test project (with parcel mechanism)

Trivial fixture exercising the **parcel-mode** wind-down ingestion path
(introduced 2026-05-05 in `lib/winddown-prompt.txt` Step 1a).

## Governance

This project uses the parcel-and-ingest mechanism. Direct edits to
`TODO.md`, `DECISIONS.md`, `CHANGELOG.md`, and `bug-log.md` are reserved
for `main`; non-`main` branches (including orchestra run worktrees) write
governance content into a single parcel file at `Governance/pending/<hex>.md`.

The wind-down session is expected to detect this project's parcel-mode
shape (presence of `Governance/CLAUDE.md` + `Governance/pending/`) and:

1. Convert run-local `3-TODO.md` / `4-DECISIONS.md` / `5-CHANGELOG.md`
   into one or more `Governance/pending/<hex>.md` parcel files,
2. Commit those parcels on the run-branch with the canonical
   `wind-down: convert run governance to parcels (<N> parcels created)`
   message,
3. Record the conversion in `7-SUMMARY.md` under
   `## Wind-down → ### Parcel conversion`,
4. Leave the parent project's `TODO.md` / `DECISIONS.md` / `CHANGELOG.md`
   untouched — number allocation is the parent project's W4 responsibility,
   not orchestra wind-down's.

See [Governance/CLAUDE.md](Governance/CLAUDE.md) for the parcel format.
