
---

## Multi-Session Autonomous Workflow

This project uses **Orchestra v3** for autonomous multi-session development. Full details in `.orchestra/CLAUDE.md`.

### Development Protocol

All work — interactive and autonomous — follows `DEVELOPMENT-PROTOCOL.md` at repo root. This is the authoritative sequence from task intake to governance close-out.

- **Interactive mode:** gates pause for human input at checkpoints
- **Orchestra mode:** gates auto-proceed; decisions logged as PROPOSED for human ratification

### Governance

Three numbered, archivable files track all project work:
- **TODO** (T-numbers) — tasks with status, dependencies
- **DECISIONS** (D-numbers) — choices made with alternatives considered
- **CHANGELOG** (C-numbers) — what changed, which task drove it

Paths configured in `.orchestra/config`. Each governance file has an archiving protocol in its `CLAUDE.md`.

### Running Orchestra

```bash
# Edit .orchestra/config — set TASKS=T001,T002,...
.orchestra/bin/orchestra run     # Starts in tmux, uses git worktree for isolation
.orchestra/bin/orchestra test    # Smoke test — verify protocol wiring
.orchestra/bin/orchestra status  # Show progress
```

Orchestra runs in a **git worktree** so your main working tree stays on `main` untouched.
