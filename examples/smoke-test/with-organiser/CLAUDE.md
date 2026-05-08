# Smoke-test project (with organiser)

Trivial fixture exercising the **Organiser → Sonnet Executor dispatch**
path end-to-end via Claude Code's `Agent` tool.

## Governance

- TODO entries live in `TODO.md` at root (legacy mode — same shape as
  `with-handover`).

The wind-down ingestion path is identical to `with-governance`. What
differs is that the working session must dispatch a subagent via the
Agent tool to do the actual file-creation work — the Organiser does not
write the work product itself. The smoke assertion checks the activity
log, the dispatched subagent's output file, and the per-session JSON
transcript for the `Agent` tool-use event.

## Conventions

- Plain text files only.
- Append-only governance.
