# Smoke-test project (with verify)

Trivial fixture exercising the **verification rejection → fix-Executor**
retry path. Two Agent dispatches under the same task-id, both Sonnet,
both `DONE` — but the Organiser rejects the first on verification and
re-dispatches with a sharper brief.

## Governance

- TODO entries live in `TODO.md` at root (legacy mode).

## Conventions

- Plain text files only.
- Append-only governance.
