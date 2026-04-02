# Orchestra — Quick Reference

This folder powers autonomous multi-session development using [claude-orchestra](https://github.com/jimbo2k2/claude-orchestra). Claude Code sessions are spawned in sequence, each picking up tasks from a shared governance system.

## File Reference

| File | Purpose | Who writes |
|------|---------|------------|
| `config` | Paths to governance files, plan, toolchain, standing AC | `orchestra init` / human |
| `toolchain.md` | Stack-specific build, test, and capture commands | Human |
| `standing-ac.md` | Acceptance criteria applied to every UI task | Human |
| `HANDOVER.md` | Session-to-session context (overwritten each session) | Claude |
| `INBOX.md` | Async human-to-Claude message channel | Human writes, Claude reads and marks processed |
| `COMMIT_MSG` | Temporary commit message for hooks | Claude (transient) |
| `quota-state` | Latest rate limit utilization (transient, auto-cleaned) | Orchestrator |
| `session-logs/` | Raw stream-json output from each session | Orchestrator |
| `archive/` | Archived handovers and session logs after `orchestra reset` | Orchestrator |

Governance files (TODO, DECISIONS, CHANGELOG) live in the **project**, not here. Their paths are in `config`.

## Running a Build

### 1. Strategic planning (interactive)

Open a normal Claude Code session and plan the work. This produces:
- A plan file (typically in `.claude/plans/`)
- Strategic tasks (Tier 1, T-numbered) in TODO.md

Set the plan path in `config`:
```
PLAN_FILE=.claude/plans/your-plan.md
```

### 2. Pre-flight check

Ensure these are ready before running:
- `config` — all paths set and pointing to real files
- `toolchain.md` — customised for your stack (not the template placeholder)
- `standing-ac.md` — acceptance criteria defined (if doing UI work)
- TODO.md — has at least one OPEN task with satisfied dependencies
- Plan file — exists and is non-empty at the `PLAN_FILE` path

### 3. Start the orchestrator

```bash
orchestra run                            # Default: up to 10 sessions, quota pacing ON
MAX_SESSIONS=30 orchestra run            # Overnight / large job: more sessions, pacing handles quota
QUOTA_PACING=false orchestra run         # Quick burst: skip pacing if you know you have quota
```

**Quota pacing** is enabled by default. Before each session, the orchestrator checks your subscription's 5-hour rolling quota (via the OAuth usage endpoint — zero tokens). If utilization exceeds `QUOTA_THRESHOLD`, it pauses until the window resets, then resumes. This makes it safe to leave running overnight.

The session limit (`MAX_SESSIONS`) is always enforced regardless of pacing.

All environment variables:
```bash
MAX_SESSIONS=10              # Safety limit on total sessions (default: 10)
MAX_CONSECUTIVE_CRASHES=3    # Abort after N crashes in a row (default: 3)
COOLDOWN_SECONDS=15          # Pause between normal handovers (default: 15)
CRASH_COOLDOWN_SECONDS=30    # Longer pause after crash recovery (default: 30)
INITIAL_MODEL=sonnet         # Override model for the first session only
NOTIFY_WEBHOOK=https://...   # Webhook for Telegram/Slack notifications
QUOTA_PACING=true            # Subscription quota monitoring (default: true)
QUOTA_THRESHOLD=80           # Pause when 5-hour utilization exceeds this % (default: 80)
QUOTA_POLL_INTERVAL=120      # Seconds between quota checks while paused (default: 120)
```

### 4. Monitor progress

```bash
orchestra status             # Task counts, session count, last handover summary
tail -f .orchestra/session-logs/ram.log   # RAM usage
```

To send a message to the running session (picked up after current task):
```
# Edit .orchestra/INBOX.md, add under "## Messages":
- [ ] Your message here
```

## Session Lifecycle

Each session follows this loop:

1. **Read** governance files, HANDOVER.md, INBOX.md
2. **Pick** next eligible task (status OPEN, all dependencies COMPLETE)
3. **Execute** — strategic tasks trigger decomposition; tactical/tertiary tasks enter the codewriting loop
4. **Update** governance (mark task COMPLETE, add D-entries and C-entries)
5. **Check** INBOX for human messages
6. **Capacity check** — estimate context window usage; exit if low or next task is complex
7. **Repeat** or exit with signal: HANDOVER, COMPLETE, or BLOCKED

## Exit Codes

| Code | Meaning | Action |
|------|---------|--------|
| 0 | All tasks COMPLETE | Done |
| 1 | Max consecutive crashes/stalls | Check session logs for errors |
| 2 | BLOCKED — needs human input | Read HANDOVER.md for what's needed |
| 3 | Max sessions reached, tasks remain | Increase MAX_SESSIONS or restart |

## Troubleshooting

### Session exited without doing anything (stall)
The orchestrator detects stalls (clean exit but no governance changes). After `MAX_CONSECUTIVE_CRASHES` stalls it stops. Check the session log — common causes:
- Vercel plugin false positives consuming the session
- Session stuck processing INBOX messages
- Plan file or toolchain misconfigured

### Subscription quota exhaustion
Quota pacing is on by default and should prevent this. If you see it anyway (symptoms: `rate_limit_event` entries in session logs showing utilization > 0.9, no `result` entry at end of log), check that pacing wasn't disabled and consider lowering the threshold:
```bash
QUOTA_THRESHOLD=70 orchestra run
```

### Crash recovery
After a crash, the orchestrator:
1. Checks if governance files or code changed (partial work)
2. Makes a recovery commit if needed
3. Sends the next session a recovery prompt to assess damage before continuing

### Task stuck as IN_PROGRESS
If a session crashed mid-task, the next recovery session will find the IN_PROGRESS task and assess whether to resume or restart it.

## Task Statuses

| Status | Meaning |
|--------|---------|
| OPEN | Ready for pickup |
| IN_PROGRESS | A session is working on it |
| COMPLETE | Done and verified |
| BLOCKED | Needs human input (reason in task detail) |
| PROPOSED | Awaiting human approval — change to OPEN to authorise |

## Three-Tier Planning

| Tier | Scope | Created by |
|------|-------|------------|
| 1 — Strategic | Feature / bounded context | Human + Claude (interactive) |
| 2 — Tactical | Screen / component / data flow | Claude (autonomous decomposition) |
| 3 — Tertiary | Implementation detail | Claude (if tactical task is too complex) |

Maximum depth is 3 tiers. If a tertiary task needs further decomposition, the session signals BLOCKED.

## Useful Commands

```bash
orchestra init [dir]         # Scaffold .orchestra/ and governance files
orchestra run                # Start the session loop
orchestra status             # Show progress summary
orchestra reset [--label X]  # Archive session logs, reset HANDOVER, prepare for next build
```
