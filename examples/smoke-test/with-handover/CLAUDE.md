# Smoke-test project (with handover)

Trivial fixture exercising the **multi-session HANDOVER → next-session
pickup → COMPLETE** path.

## Governance

- TODO entries live in `TODO.md` at root (legacy mode).

The wind-down ingestion path is identical to `with-governance` — what
differs is the working-session lifecycle: this objective forces the
agent to emit `HANDOVER` after Phase 1 instead of `COMPLETE`, so a
second session must pick up from `6-HANDOVER.md` and complete Phase 2.

## Conventions

- Plain text files only.
- Append-only governance.
