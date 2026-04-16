# Orchestra — Quick Reference

Autonomous multi-session development. Claude Code sessions are spawned in sequence, each following `DEVELOPMENT-PROTOCOL.md` in auto-proceed mode.

## File Reference

| File/Dir | Purpose | Who writes |
|----------|---------|------------|
| `config` | Tasks, limits, model, governance paths | Human |
| `bin/orchestra` | CLI entry point | Bootstrap (from claude-orchestra) |
| `bin/orchestrator.sh` | Session loop manager | Bootstrap |
| `hooks/stage-changes.sh` | PostToolUse hook — stages edited files | Bootstrap |
| `lib/config.sh` | Shared config reader | Bootstrap |
| `lib/verify-completion.sh` | Completion verifier (invoked by orchestrator, not hooks) | Bootstrap |
| `lib/commit-and-update.sh` | Commit helper (invoked by orchestrator, not hooks) | Bootstrap |
| `toolchain.md` | Task-agnostic stack reference | Human |
| `CLAUDE.md` | Session rules — follow protocol in auto-proceed mode | Human |
| `HANDOVER.md` | Session-to-session context | Claude |
| `INBOX.md` | Human async messages | Human |
| `sessions/` | Per-task workspaces + session JSON logs | Claude / Orchestrator |
| `sessions/archive/` | Completed session workspaces | Claude |

Governance files (TODO, DECISIONS, CHANGELOG) live in the **project**, not here. Paths in `config`.

## Running

### 1. Set up config

Edit `config`: set `TASKS=T315,T325,T327` (comma-separated T-numbers). Set `MAX_SESSIONS`, `MODEL`, `EFFORT` as needed. All run parameters live in this file — no env vars, no CLI args.

### 2. Run

```bash
.orchestra/bin/orchestra run
```

Orchestra always runs inside a tmux session (name from `TMUX_SESSION` in config). It checks for name conflicts before creating. Each session runs in a **git worktree** at `WORKTREE_BASE` — your main working tree stays on `main` untouched.

### 2b. Pass queue-specific context (optional)

To give Orchestra context that goes beyond the config (e.g. queue-specific rules, dependency notes, a plan folder README to read), write it to `INBOX.md` before launching. The session reads INBOX at startup — it functions as a cold-start briefing unique to this run.

### 3. Monitor

```bash
.orchestra/bin/orchestra status
tmux attach -t orchestra            # View live session
```

Send a message to the running session:
```
# Edit .orchestra/INBOX.md, add under "## Messages":
- [ ] Your message here
```

### 4. Test mode

```bash
.orchestra/bin/orchestra test
```

Smoke test: creates throwaway branch, runs a synthetic task through the full protocol, reports which skills/gates fired, cleans up.

## Session Lifecycle

1. Read config, validate paths, check tmux conflicts
2. Create a **git worktree** at `WORKTREE_BASE/session-NNN` branching from main
3. Read T-numbers, fetch descriptions from TODO.md (ignores status field)
4. Read INBOX.md for queue-specific context
5. For each task: follow `DEVELOPMENT-PROTOCOL.md` in auto-proceed mode
6. Within session: complete tasks sequentially, evaluate context between tasks
7. Session wrap-up (protocol Part 2) before handoff
8. Push task branches, clean up worktree
9. On crash: partial state preserved for recovery; worktree cleaned up

## Exit Codes

| Code | Meaning | Action |
|------|---------|--------|
| 0 | All tasks COMPLETE | Done |
| 1 | Max consecutive crashes/stalls | Check session logs |
| 2 | BLOCKED — needs human input | Read HANDOVER.md |
| 3 | Max sessions reached, tasks remain | Increase MAX_SESSIONS or restart |

## Task Statuses (in TODO.md)

| Status | Meaning |
|--------|---------|
| OPEN | Ready for pickup |
| IN_PROGRESS | A session is working on it |
| COMPLETE | Done and verified |
| BLOCKED | Needs human input (reason in task detail) |
| PROPOSED | Awaiting human approval |
