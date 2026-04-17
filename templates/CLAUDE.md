# Project: [Your Project Name]

## Tech Stack
<!-- Customise this section for your project -->
- Runtime: [e.g. Node.js 20 / Python 3.12]
- Framework: [e.g. Fastify, Next.js, Django]
- Database: [e.g. PostgreSQL]
- Testing: [e.g. Vitest, Jest, pytest]

## Architecture
<!-- Describe your project structure so Claude can navigate effectively -->
```
src/
├── routes/       — HTTP route handlers
├── models/       — Database schema definitions
├── services/     — Business logic
└── utils/        — Shared helpers
```

## Conventions
<!-- Document the rules every contributor (human or AI) follows -->
- Code style, linting, formatter (e.g. prettier, ruff)
- Commit message conventions
- Branch naming
- PR review expectations

---

## Development Protocol

All work — interactive and autonomous — follows `DEVELOPMENT-PROTOCOL.md` at repo root. This is the authoritative sequence from task intake to governance close-out.

- **Interactive mode:** gates pause for human input at checkpoints
- **Orchestra mode (autonomous):** gates auto-proceed; decisions logged as PROPOSED for human ratification

## Multi-Session Autonomous Workflow

This project uses **Orchestra v3** for autonomous multi-session development. Full details in `.orchestra/CLAUDE.md`.

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
.orchestra/bin/orchestra test    # Smoke test — verify protocol wiring with synthetic tasks
.orchestra/bin/orchestra status  # Show progress
```

Orchestra runs in a **git worktree** so your main working tree stays on `main` untouched. All sessions in one orchestra run share a single session branch (`orchestra/run-<timestamp>`); task branches are created from it and merged back as each task completes.
