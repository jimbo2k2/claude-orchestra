
---

## Multi-Session Autonomous Workflow

This project uses an orchestrated multi-session workflow. You are a stateless
worker. Persistent state lives in files, not in your context. An external
orchestrator will spawn new sessions after you finish.

**State files live in `.orchestra/`.** Do NOT create state files at the project root.

### Session Start — Read State Files

At the start of every session, read these files IN THIS ORDER:
1. `.orchestra/PLAN.md` — the overall goal, requirements, and acceptance criteria (skim; do not re-read every section if you already know the plan)
2. `.orchestra/HANDOVER.md` — context from the previous session (most important for immediate work)
3. `.orchestra/INBOX.md` — messages from the human operator (check for new instructions)
4. `.orchestra/TODO.md` — the task backlog
5. `.orchestra/DECISIONS.md` — autonomous decisions made by previous sessions (skim recent entries)
6. `.orchestra/CHANGELOG.md` — history of what's been done (skim recent entries only)

When making judgment calls — how to handle an edge case, whether to split a
task, what to name something — refer back to `.orchestra/PLAN.md`. It is the
source of truth for intent and design decisions.

If `.orchestra/INBOX.md` has unprocessed messages (in the Messages section but
not in Processed), follow those instructions BEFORE picking up your next TODO
task. This may mean changing priorities, adjusting your approach, or adding new
tasks. After acting on a message, copy it to the Processed section with a brief
note.

**Important:** INBOX.md is only read and updated at session START — never during
the wrap-up/state-file-update phase. This avoids edit clashes with the human
operator who may write to it at any time.

### Single-Task Discipline

- Pick up ONLY the first unchecked item in `.orchestra/TODO.md`
- Complete that ONE task fully before doing anything else
- Do NOT start a second task, even if the first one was quick
- If a task is too large for one session, break it into sub-tasks in `.orchestra/TODO.md`,
  complete the first sub-task, and hand over

### Context Management — CRITICAL

Your session WILL be terminated if context is exhausted. Any work not saved
to disk is lost. Protect yourself:

1. **Use sub-agents** for exploratory work (reading files, investigating bugs).
   Sub-agents have their own context and don't fill up yours.
2. **Avoid reading large files entirely.** Read only the sections you need.
   Use grep/search to find relevant lines first.
3. **Monitor your own context.** If you've been working for a while and have
   done significant back-and-forth, it's time to wrap up.
4. **When in doubt, hand over early.** A clean handover with one task done is
   far better than a crash with no state saved.
5. **Run `/compact` BEFORE writing state files.** This frees context space
   to ensure your state file updates complete successfully.

### State File Updates — HIGHEST PRIORITY

Updating state files is the SINGLE MOST IMPORTANT thing you do in a session.
The orchestrator and future sessions depend entirely on these files.

**When to update:** Immediately after finishing your task (or deciding to stop).
After running `/compact`. Before any other wrap-up work.

**Update order:**
1. `.orchestra/TODO.md` — Check off completed items. Add any sub-tasks you discovered.
   Move completed items to the Completed section.
2. `.orchestra/DECISIONS.md` — If you made any autonomous decisions this session (chose an
   approach not explicitly specified in PLAN.md, resolved an ambiguity, picked
   between alternatives), append an entry. Skip if no decisions were needed.
3. `.orchestra/CHANGELOG.md` — Append a new entry at the top of the session log:
   ```
   ## Session — [YYYY-MM-DD HH:MM UTC]
   - What you did (be specific about files and changes)
   - Decisions made (reference DECISIONS.md entries if any)
   - Issues encountered
   - Test results
   ```
4. `.orchestra/HANDOVER.md` — OVERWRITE completely (don't append). Include:
   - **What just happened** — summary of this session's work
   - **Watch out for** — gotchas, quirks, things that might trip up the next session
   - **Key files modified** — list of files changed and why
   - **Current test status** — do tests pass? any known failures?
   - **Next step** — what the next session should do

**After updating state files:** Stop immediately. Output your exit signal.
Do NOT do further work after writing state files.

### Exit Signals

Your final output line must be EXACTLY one of these (no extra text on the line):
- `HANDOVER` — you completed your task, more tasks remain in `.orchestra/TODO.md`
- `COMPLETE` — ALL items in `.orchestra/TODO.md` are checked off AND tests pass
- `BLOCKED` — you need human input to proceed (explain why in `.orchestra/HANDOVER.md`)

### Recovery Sessions

If your session prompt mentions a previous crash, the codebase may be in a
partially modified state. Always run tests first to assess the damage before
picking up new work.

### Graduation

When a build phase is complete, run `orchestra graduate` to:
- Archive state files and session logs
- Create a `docs/` skeleton for long-lived documentation
- Reset orchestra for the next build

See the graduation checklist output for consolidation steps.
