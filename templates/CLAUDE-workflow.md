
---

## Multi-Session Autonomous Workflow

This project uses **Orchestra v2** for autonomous multi-session development.

### How it works

Orchestra spawns Claude Code sessions that execute tasks from a shared governance system. Each session reads project state, picks up the next eligible task, completes it, and hands over to the next session.

### Governance files

Three numbered, archivable files track all project work:
- **TODO** (T-numbers) — tasks with status, tier, dependencies
- **DECISIONS** (D-numbers) — choices made with alternatives considered
- **CHANGELOG** (C-numbers) — what changed, which task drove it, which decisions influenced it

Paths are configured in `.orchestra/config`. Each governance file has an archiving protocol in its `CLAUDE.md`.

### Task statuses
- **OPEN** — ready for pickup (only OPEN tasks are eligible)
- **IN_PROGRESS** — a session is working on it
- **COMPLETE** — finished and verified
- **BLOCKED** — needs human input
- **PROPOSED** — awaiting human approval

### Three-tier planning
1. **Strategic** (Tier 1) — human-authored, feature scope. Triggers decomposition.
2. **Tactical** (Tier 2) — Claude-generated, component scope. Executed via codewriting loop.
3. **Tertiary** (Tier 3) — further decomposition if needed. Maximum depth.

### Session lifecycle
1. Read governance files, HANDOVER.md, INBOX.md
2. Pick next eligible task (OPEN, dependencies satisfied)
3. Execute (decompose if strategic, codewriting loop if implementation)
4. Update governance (T/D/C entries)
5. Check INBOX for human messages
6. Capacity check → continue or exit

### Exit signals
- **HANDOVER** — tasks remain, spawn next session
- **COMPLETE** — all tasks done
- **BLOCKED** — needs human input

### Model recommendation
Write `model:effort` recommendation to HANDOVER.md (default: `opus:high`).
Only recommend `sonnet:medium` for mechanical tasks. Valid effort values: `low`, `medium`, `high`, `max`.

### Key files
- `.orchestra/config` — governance paths, plan file, toolchain, standing AC
- `.orchestra/toolchain.md` — stack-specific build/test/capture commands
- `.orchestra/standing-ac.md` — acceptance criteria for every UI task
- `.orchestra/HANDOVER.md` — session-to-session context
- `.orchestra/INBOX.md` — async human messages
