# Orchestra v2 — Design Specification

*Three-tier autonomous development with DDD governance*

**Date:** 2026-03-25
**Status:** Draft — pending review
**Branch:** TBD (orchestra v2 feature branch)

---

## 1. Overview

Orchestra v2 replaces the "human writes plan, Claude executes checklist" model with a three-tier autonomous development system. The governance layer uses numbered, archivable protocols (T/D/C-numbers) instead of simple checkboxes and append-only notes. The execution layer includes a built-in codewriting loop for React Native + Expo + Supabase with mandatory code review, UI testing against two-layer acceptance criteria, and debug passes.

### 1.1 What stays from v1

- Session loop with crash recovery (orchestrator.sh core)
- Hook system (stage, verify, commit)
- Model selection (sonnet default, opus on recommendation)
- HANDOVER.md (session-to-session context transfer)
- INBOX.md (async human-to-Claude messaging)
- `orchestra init`, `orchestra run`, `orchestra status`, `orchestra reset`

### 1.2 What is removed

- `orchestra graduate` — removed entirely. Continuous DDD documentation passes replace end-of-build consolidation.
- `.orchestra/TODO.md` (checkbox format) — replaced by project-level T-numbered TODO
- `.orchestra/DECISIONS.md` (append-only) — replaced by project-level D-numbered DECISIONS
- `.orchestra/CHANGELOG.md` (append-only) — replaced by project-level C-numbered CHANGELOG
- `.orchestra/PLAN.md` (read-only) — replaced by a plan file the first session can decompose
- Generic `docs/` scaffolding and consolidation checklist

### 1.3 What is new

- Three-tier planning (Strategic, Tactical, Tertiary) with codewriting loop execution
- Numbered, archivable CHANGELOG protocol (C-numbers)
- Built-in codewriting inner loop (Code, Review, Conditional 2nd pass, UI Test, Debug)
- Two-layer acceptance criteria (Standing AC + Task AC)
- Decomposition review + plan coherence check (quality gates before execution)
- Task dependency tracking (`Depends:` field) with blocked-task skip
- React Native + Expo + Supabase toolchain (in separate toolchain file)
- Pre-flight validation at `orchestra run` (plan, toolchain, standing AC, governance, eligible tasks)
- `.orchestra/config` maps governance files to project-specific paths
- `.orchestra/toolchain.md` for stack-specific build/test/capture commands

---

## 2. Ubiquitous Language

Orchestra is treated as a micro-DDD project. The following terms are precise and must be used consistently in all session prompts, hooks, documentation, and CLAUDE.md files.

### Core Infrastructure

| Term | Definition | Not to be confused with |
|---|---|---|
| **Session** | A single Claude Code headless invocation, from spawn to exit signal. The atomic unit of autonomous work. | A tmux session (which hosts the orchestrator), or an interactive Claude conversation |
| **Orchestrator** | The bash process that manages the session loop — spawning sessions, handling crashes, enforcing limits. | Claude itself. The orchestrator is infrastructure; Claude is the worker inside each session. |
| **Config** | The `.orchestra/config` file mapping governance file paths, plan file location, and other project-specific settings. Read by sessions and hooks. | Project configuration (e.g. app.json, tsconfig) |
| **Toolchain** | The `.orchestra/toolchain.md` file describing stack-specific build, serve, capture, and verify commands. Read by sessions during the codewriting loop. | The tech stack itself — the toolchain file is instructions for *using* the stack |

### Three-Tier Planning

| Term | Definition | Not to be confused with |
|---|---|---|
| **Strategic Plan** | A human-authored document (tier 1) defining goals, constraints, and coarse tasks for a build phase. Lives in the project at the path specified by `PLAN_FILE` in config. | A tactical decomposition or the codewriting loop |
| **Strategic Task** | A tier 1 T-numbered entry in TODO.md, produced during strategic planning. Identified by `Tier: 1` and no `Parent` field. Coarse-grained — describes *what*, not *how*. When a session picks one up, it triggers tactical decomposition. | The Strategic Plan (which is the document); a tactical task (which is finer-grained) |
| **Tactical Decomposition** | Claude's autonomous breakdown (tier 2) of a strategic task into tactical tasks. Produces T-numbered entries with `Parent` and `Depends` links. | The strategic plan itself (which is human-directed) |
| **Tactical Task** | A tier 2 T-numbered entry, produced by tactical decomposition. Has `Tier: 2` and a `Parent` link to a strategic task. Screen/component scope. Executed via the codewriting loop. | A strategic task (which is coarser) or a tertiary task (which is finer) |
| **Tertiary Decomposition** | A further breakdown (tier 3) of a tactical task when implementation complexity exceeds expectations. Same pattern as tactical decomposition, one level deeper. Maximum depth. | A design flaw — it is a designed safety valve for underestimated scope, not a failure |
| **Tertiary Task** | A tier 3 T-numbered entry, produced by tertiary decomposition. Has `Tier: 3` and a `Parent` link to a tactical task. Implementation scope. If further decomposition is needed, the session signals BLOCKED — three tiers is the maximum. | A tactical task (which is one level coarser) |

### Tasks & Governance

| Term | Definition | Not to be confused with |
|---|---|---|
| **Task** | A T-numbered entry in TODO.md. Has a status, a tier (1/2/3), optional `Parent` and `Depends` links. The universal unit of trackable work. | A background process, a cron job, or a generic to-do item |
| **Decision** | A D-numbered entry in DECISIONS.md. Records a choice made during a session, including alternatives considered. Immutable once archived. | An opinion or preference — decisions are recorded because they constrain future work |
| **Changelog Entry** | A C-numbered entry in CHANGELOG.md. Records what changed in the codebase, which task drove it, and which decisions influenced it. | A git commit message (which is terser) or a handover note (which is session-scoped) |
| **Governance Files** | The three numbered, archivable project-level files: TODO.md, DECISIONS.md, CHANGELOG.md. Source of truth for what was planned, decided, and changed. | Operational files (HANDOVER.md, INBOX.md, config) which live in `.orchestra/` and serve the orchestrator, not the project record |

### Task Statuses

| Term | Definition | Not to be confused with |
|---|---|---|
| **OPEN** | Task created and ready for pickup. The default status for newly created tasks. Only OPEN tasks are eligible for selection. | IN_PROGRESS (which means a session has started work) |
| **IN_PROGRESS** | A session is actively working on this task. Set at the moment a session picks it up. | OPEN (which means no session has claimed it yet) |
| **COMPLETE** | Work finished and verified. For strategic tasks, set automatically when all children are COMPLETE. | BLOCKED (which means work cannot proceed) |
| **BLOCKED** | Cannot proceed without human input. The reason is noted in the task detail. Tasks depending on a BLOCKED task become ineligible but are not themselves BLOCKED — the session skips past them. | PROPOSED (which is a human-gated approval status, not a problem) |
| **PROPOSED** | Created by decomposition when scope expansion is detected. Skipped by sessions until a human changes the status to OPEN. A human gate, not an error. | BLOCKED (which means something went wrong, not that approval is pending) |

### Session Lifecycle

| Term | Definition | Not to be confused with |
|---|---|---|
| **Task Loop** | The outer loop within a session: pick task → execute → update governance → check inbox → capacity check → repeat or exit. | The codewriting loop (which is the inner loop for implementation tasks) |
| **Codewriting Loop** | The inner loop for implementation tasks: Write → Code Review → Conditional 2nd Pass → UI Test → Debug. Runs for each tactical or tertiary task that involves code changes. | The task loop (outer loop that iterates across tasks within a session) |
| **Handover** | The HANDOVER.md context document written by a session for the next session. Contains: what was done, what's next, gotchas, and model recommendation. Overwritten each session. | A governance file (which is permanent). Also the name of one of the three exit signal values — as an exit signal, HANDOVER means "tasks remain, spawn a new session"; as a file, it means the context document written at session end. |
| **Inbox** | The INBOX.md async human-to-Claude message channel. Read at session start and after each task completion. Messages move from unread to processed. | Handover (which is session-to-session, not human-to-session) |
| **Exit Signal** | One of three values a session outputs at termination: HANDOVER (normal, tasks remain), COMPLETE (all done), BLOCKED (needs human). Parsed by the orchestrator to determine next action. | A process exit code (which is numeric). Note: the HANDOVER signal shares its name with the HANDOVER.md file but refers to the session outcome, not the document. |
| **Capacity Check** | The assessment a session makes after each task: is there sufficient context window remaining to take on the next task? Determines whether to continue the task loop or exit. | A resource check on the server (CPU, memory) — this is purely about Claude's context window |
| **Model Recommendation** | Written to HANDOVER.md by the current session, advising the orchestrator on model and effort level for the next task. Format: `model:effort` (e.g. `opus:high`, `sonnet:medium`). Default is `opus:high` — only downgrade to sonnet for explicitly mechanical tasks (config changes, simple file moves, status updates). Valid effort values: `low`, `medium`, `high`, `max`. The orchestrator reads and applies both values. | A model selection by the user — the recommendation is Claude's assessment of the next task's complexity and the effort required |

### Acceptance Criteria

| Term | Definition | Not to be confused with |
|---|---|---|
| **Standing AC** | Permanent acceptance criteria in `.orchestra/standing-ac.md` that apply to every UI task. Human-authored. Categories under which task AC are generated. | Task AC (which are specific to one task) |
| **Task AC** | Acceptance criteria generated by Claude for a specific task, structured as children under standing AC categories. Written into the task detail before implementation. | Standing AC (which are generic and permanent) |

### Quality Gates

| Term | Definition | Not to be confused with |
|---|---|---|
| **Decomposition Review** | Internal consistency check after tactical or tertiary decomposition: are the resulting tasks sufficient, correctly ordered, non-overlapping, and free of circular dependencies? Maximum 2 retries before BLOCKED. | The plan coherence check (which validates against the wider project) |
| **Plan Coherence Check** | External validation after decomposition: does the decomposition align with strategic goals, bounded context definitions, published language, cross-context dependencies, and project phase? | The decomposition review (which checks internal consistency only) |
| **Pre-flight** | Validation run by `orchestra run` before spawning the first session. Confirms plan, toolchain, standing AC, governance files, and eligible tasks all exist and are non-empty. | Init (which creates the structure) — pre-flight validates it's ready to execute |

### Recovery & Error Handling

| Term | Definition | Not to be confused with |
|---|---|---|
| **Recovery** | A session mode triggered after a previous session crashed. The orchestrator sends a recovery prompt (a damage assessment sequence prepended to the normal session prompt) rather than the standard prompt. The session assesses build state, governance file consistency, and uncommitted work before entering the normal task loop. | A rollback or git reset — recovery preserves work, it doesn't discard it |
| **Recovery Commit** | A git commit the orchestrator makes when a crashed session leaves partial work (modified tracked files or updated governance files). Preserves the crashed session's changes before spawning the next session. | A normal session commit (made by the commit-and-update hook at session end) |

---

## 3. Governance Protocols

All three governance files follow the same structural pattern: a dedicated directory with an archiving protocol, numbered entries, and immutable archive files.

### 3.1 TODO Protocol

```
TODO/
  CLAUDE.md          # Archiving protocol (when to archive, batch size, naming)
  TODO.md            # Active file: summary index + current task detail
  archive/           # Immutable archived batches (e.g. T001-T020.md)
```

**Task entry format:**

```markdown
### T042: Build PostCard component
- **Status:** OPEN | IN_PROGRESS | COMPLETE | BLOCKED | PROPOSED
- **Tier:** 1 | 2 | 3
- **Added:** 2026-03-24
- **Context:** JNL
- **Parent:** T040
- **Depends:** T038, T039
- **Detail:** Reusable card showing post title, date, tag count, thumbnail.
  Must handle empty/loading states. Uses Supabase post query.
```

**Field definitions:**

- `Status` — task lifecycle state:
  - `OPEN` — created and ready for pickup. Default status for new tasks.
  - `IN_PROGRESS` — a session has started work on this task.
  - `COMPLETE` — work finished and verified.
  - `BLOCKED` — cannot proceed without human input. Reason noted in detail.
  - `PROPOSED` — created by tier 2 decomposition when scope expansion is flagged; skipped until a human changes status to OPEN.
- `Tier` — planning tier: `1` (strategic, human-authored), `2` (tactical, Claude-decomposed), `3` (tertiary, further decomposition). Makes the three-level maximum locally verifiable without walking the parent chain.
- `Context` — the bounded context code (FWK, JNL, AIT, etc.) where applicable.
- `Parent` — decomposition hierarchy. Links to the strategic/tactical task this was decomposed from.
- `Depends` — execution ordering. Lists T-numbers that must be COMPLETE before this task is eligible. Can cross parent boundaries.

**Eligibility rules:**

A task is eligible for pickup when:
1. Status is OPEN (not IN_PROGRESS, COMPLETE, BLOCKED, or PROPOSED)
2. All tasks listed in `Depends:` are COMPLETE
3. No circular dependency exists (caught during decomposition review)

Note: IN_PROGRESS tasks from a previous crashed session are re-eligible — the recovery prompt handles resuming partial work.

**Strategic task completion:**

A strategic task (tier 1) is marked COMPLETE when all its direct children (tactical tasks) are COMPLETE. This is checked by the session after completing the last child task — it walks the parent link and updates the parent's status automatically.

**Session behaviours:**
- Pick the next eligible task (by T-number order)
- Set status to IN_PROGRESS immediately when starting work on a task
- PROPOSED tasks exist in the file but are skipped until a human changes their status to OPEN
- When completing a task, update status to COMPLETE and add a completion note
- When adding tactical or tertiary tasks via decomposition, use the next sequential T-number, set Tier/Parent/Depends appropriately, and set status to OPEN
- After completing the last child of a parent task, mark the parent COMPLETE
- Never reorder or delete existing tasks — only add and update status

### 3.2 DECISIONS Protocol

```
Decisions/
  CLAUDE.md          # Archiving protocol
  DECISIONS.md       # Active file: summary index + current decisions
  archive/           # Immutable archived batches (e.g. D001-D030.md)
```

**Decision entry format:**

```markdown
### D059: Use FlatList for post listing instead of ScrollView
- **Date:** 2026-03-24
- **Status:** ACTIVE
- **Context:** JNL
- **Detail:** FlatList provides virtualisation for large post lists. ScrollView
  would render all posts at once, causing performance issues for learners with
  hundreds of journal entries.
- **Alternatives considered:** ScrollView (simpler but won't scale),
  FlashList (better performance but additional dependency not justified at MVP)
```

**Session behaviours:**
- Record decisions as they're made — don't batch them
- Include alternatives considered — critical for future sessions understanding *why*
- Reference the D-number in commit messages and HANDOVER when relevant

### 3.3 CHANGELOG Protocol (new)

```
Changelog/
  CLAUDE.md          # Archiving protocol
  CHANGELOG.md       # Active file: summary index + current entries
  archive/           # Immutable archived batches (e.g. C001-C050.md)
```

**Changelog entry format:**

```markdown
### C012: PostCard component — initial implementation
- **Date:** 2026-03-24
- **Task:** T042
- **Decision:** D059
- **Type:** FEATURE | FIX | REFACTOR | CONFIG | DOCS
- **Files:** src/components/PostCard.tsx, src/hooks/usePostQuery.ts
- **Summary:** Created PostCard with title, date, tag count, thumbnail.
  Uses FlatList per D059. Handles empty state and loading skeleton.
  Verified against standing AC — no console errors, correct Supabase query.
```

**Session behaviours:**
- One C-entry per logical change (not per file, not per commit)
- Always link back to the T-number that prompted the work
- Link to D-numbers when a decision influenced the implementation choice
- The `Files:` field gives future sessions a fast reference to what was touched

### 3.4 Archiving

All three governance files use the same archiving trigger: when the active file exceeds the threshold defined in its `CLAUDE.md` protocol file (defaults: 30 for TODO, 30 for DECISIONS, 50 for CHANGELOG). Sessions read the protocol files (paths in config as `TODO_PROTOCOL`, `DECISIONS_PROTOCOL`, `CHANGELOG_PROTOCOL`) to learn archiving rules, batch naming conventions, and threshold values. A session that notices the threshold is exceeded performs the archive as a housekeeping step:

1. Move completed/resolved entries to a new archive file (e.g. `T041-T070.md`)
2. Keep the summary index row for each archived entry (one line: number + title + status)
3. Update the next-number comment at the bottom of the active file
4. Archive files are immutable once created

---

## 4. Three-Tier Planning

### 4.1 Tier 1 — Strategic Planning (human + Claude, interactive)

Happens before `orchestra run` in a normal interactive Claude session. The output is a plan file and a set of T-numbered tasks in TODO.md.

**Characteristics:**
- Bounded context or feature scope
- Human directs, Claude assists — iterative dialogue until aligned
- Produces: a plan file (`.claude/plans/xxx.md`) with goals, constraints, acceptance criteria
- Tasks at this level are deliberately coarse — they describe *what* not *how*
- The plan file path is written to `.orchestra/config` as `PLAN_FILE`

**Example strategic tasks:**
```
T060: Build Journal post creation screen with media upload
T061: Build Journal post list with PostCard component and tag display
T062: Build Journal post detail view with full tag fingerprint
T063: Connect Journal screens to Supabase with offline-first sync
```

### 4.2 Tier 2 — Tactical Decomposition (Claude, autonomous)

When a session picks up a strategic task (`Tier: 1`, no `Parent` field), it reads the plan file and relevant bounded context docs, then decomposes into tactical tasks.

**Characteristics:**
- Screen / component / data flow scope
- Claude generates T-numbered tactical tasks with `Tier: 2`, `Parent`, and `Depends` links
- Not PROPOSED — the strategic plan already authorised the scope
- Execution begins immediately after quality gates pass
- If scope expansion detected: flag in INBOX.md, continue with safe subset

**Quality gates (run sequentially after decomposition):**

1. **Decomposition review** (internal consistency):
   - Are the resulting tasks collectively sufficient to satisfy the parent task?
   - Are dependencies correctly ordered (no circular refs)?
   - Is there overlap or duplication?

2. **Plan coherence check** (external validation):
   - Does the decomposition align with the strategic plan's goals and constraints?
   - Is it consistent with the bounded context's data model and module definition?
   - Do naming choices follow PUBLISHED-LANGUAGE.md?
   - Are cross-context dependencies accounted for?
   - Does the work fit the project's current phase?

**Outcomes:**
- Both pass → execute first tactical task
- Decomposition review fails (coverage gap, ordering issue, overlap) → revise and re-check (maximum 2 retries, then BLOCKED)
- Scope expansion or minor misalignment at coherence check → flag INBOX, continue with safe subset. The safe subset is: tasks that were directly implied by the strategic plan with no scope expansion. Excluded tasks are written as PROPOSED with a note referencing the INBOX flag, so a human can explicitly approve them.
- Fundamentally incoherent → BLOCKED

### 4.3 Tier 3 — Tertiary Decomposition (Claude, autonomous, rare)

If a tactical task is more complex than expected during execution, Claude decomposes further. Same pattern as tier 2, one level deeper.

**Constraint:** Maximum three levels of nesting (strategic → tactical → tertiary). If something needs a fourth level, the session signals BLOCKED — the strategic plan was too ambitious for a single task.

### 4.4 Execution — Codewriting Loop

Each tactical/tertiary implementation task runs through the codewriting inner loop:

```
1. GENERATE TASK AC
   Write task-level acceptance criteria as children under
   standing AC categories. Record in the task detail in TODO.md.

2. WRITE CODE
   Read toolchain.md for conventions and commands.
   Implement the component/hook/screen/query.

3. CODE REVIEW (mandatory)
   Run the code-review skill pass.
   Produces an issue list with severity ratings.

4. CONDITIONAL SECOND PASS
   If code review found issues:
     - Fix all issues
     - Re-run code review
   If clean (or clean after fix):
     - Continue to UI test

5. UI TEST
   a. Ensure Expo dev server is running (npx expo start --web).
      If the server fails to start or does not respond within timeout:
      mark task BLOCKED ("Expo build failed") and exit codewriting loop.
   b. Run Puppeteer at target viewport (393x852 iPhone 15 Pro).
      If Puppeteer crashes or fails to produce output:
      mark task BLOCKED ("UI test infrastructure failure") and exit codewriting loop.
   c. Navigate to the screen under test
   d. Two feedback channels:
      - Visual: screenshot capture → analyse layout/styling
      - Structural: DOM query via data-testid → assert elements
   e. Supabase verification: query database to confirm data
      operations (insert/update/RLS)
   f. Evaluate against Standing AC + Task AC

6. DEBUG PASS (maximum 3 iterations)
   If failures detected:
     - Diagnose: layout error vs logic error vs state error
     - Fix root cause
     - Loop back to step 5
   If all acceptance criteria pass:
     - Mark task COMPLETE
     - Write CHANGELOG entry (C-number)
     - Exit codewriting loop
   If 3 debug iterations exhausted without passing:
     - Mark task BLOCKED with diagnostic note
     - Write partial CHANGELOG entry noting what was attempted
     - Exit codewriting loop
```

### 4.5 Two-Layer Acceptance Criteria

**Standing AC** — lives in `.orchestra/standing-ac.md`. Human-authored, applies to every UI task. Categories provide the structure under which task AC are generated.

Example categories:
- Visual & Layout (rendering, viewport, regressions)
- Functional (interactivity, navigation, state handling)
- Data (Supabase persistence, RLS, optimistic updates)
- Code Quality (console errors, TypeScript, accessibility)
- Integration (navigation structure, no regressions)

**Task AC** — Claude-generated per task, specific children under standing AC categories. Written into the task detail in TODO.md before implementation begins.

This structure ensures Claude always generates specific criteria *under* the standing categories, preventing blind spots.

---

## 5. Session Lifecycle

### 5.1 Session start

```
1. Read .orchestra/config → find all file paths
2. Read governance files (TODO.md, DECISIONS.md, CHANGELOG.md)
   Each contains summary index of archived entries + full detail for current entries.
   One read per file gives both historical context and working state.
3. Read HANDOVER.md (previous session context)
4. Read INBOX.md (human messages)
5. If recovery mode: assess damage (build, governance, git), fix before continuing
```

### 5.2 Task loop (outer loop)

```
6. Pick next eligible task from TODO
   Eligible: status is OPEN, all Depends are COMPLETE
   If TODO.md is empty or has no entries → exit BLOCKED (not COMPLETE —
     an empty file suggests corruption or misconfiguration)
   If all tasks are COMPLETE → exit COMPLETE
   If all remaining are BLOCKED or dependent-on-BLOCKED → exit BLOCKED

7. If strategic task (no Parent): run tier 2 decomposition
   → decomposition review (internal)
   → plan coherence check (external)
   → begin executing first tactical task

8. If tactical/tertiary task: execute directly
   → if implementation: enter codewriting loop
   → if planning/docs/config: execute directly

9. Update governance:
   - TODO: mark task COMPLETE, add completion note
   - Parent check: if the completed task has a Parent, check whether
     all siblings under that parent are now COMPLETE. If so, mark
     the parent COMPLETE automatically. Recurse upward if needed.
   - DECISIONS: add D-entries for any choices made
   - CHANGELOG: add C-entry for work completed

10. Read INBOX.md (check for human messages between tasks)
    Process any new messages, mark as read.
    If a message contradicts the current plan or an in-progress task:
      - Complete governance cleanup for any work already done
      - Write HANDOVER note explaining the contradiction
      - Exit BLOCKED so a human can reconcile

11. Capacity check:
    - If sufficient capacity AND next task appropriate → loop to step 6
    - If low capacity OR complex next task → exit to step 12
```

### 5.3 Session end

```
12. Write HANDOVER.md:
    - What was accomplished (T-numbers completed)
    - What's next (next eligible task)
    - Gotchas or context for the next session
    - Model recommendation: `model:effort` (default `opus:high`; downgrade to `sonnet:medium` only for mechanical tasks like config changes or simple file moves). Valid effort values: `low`, `medium`, `high`, `max`.

13. Write COMMIT_MSG

14. Output exit signal:
    - HANDOVER: normal end, tasks remain
    - COMPLETE: all tasks done
    - BLOCKED: needs human input (reason written to INBOX)
```

---

## 6. Orchestrator

### 6.1 Pre-flight checks

`orchestra run` validates before spawning the first session:

| Check | Fails if |
|---|---|
| PLAN_FILE in config | Missing, nonexistent, or empty |
| TOOLCHAIN_FILE in config | Missing, nonexistent, or empty |
| STANDING_AC_FILE in config | Missing, nonexistent, or empty |
| Governance files at config paths | Nonexistent |
| Eligible tasks in TODO | No tasks with OPEN status and satisfied dependencies |

All checks must pass. Failure prints a specific error message and exits.

**Lockfile:** Before pre-flight, `orchestra run` acquires `.orchestra/orchestra.lock` (using `flock` or equivalent). If the lock already exists and the holding process is alive, exit with error: "Another orchestrator is already running (PID N)." The lock is released on exit (including crashes). This prevents concurrent sessions from reading the same TODO.md and picking up the same task.

### 6.2 Session loop

```
1. Snapshot governance file checksums
2. Read HANDOVER.md for model:effort recommendation (default: opus:high). Valid effort values: low, medium, high, max.
3. Spawn Claude session with recommended model and effort level
4. Wait for session to complete
5. Evaluate exit:
   - Clean exit → parse exit signal (HANDOVER/COMPLETE/BLOCKED)
   - Crash → check governance files for partial work → recovery commit if needed
6. If HANDOVER and eligible tasks remain → cooldown → loop to step 1
7. If COMPLETE → exit 0
8. If BLOCKED → exit 2
9. If max consecutive crashes → exit 1
10. If max sessions reached → exit 3
```

### 6.3 Crash recovery

When a session exits non-zero:
1. Compare governance file checksums to pre-session snapshot
2. If governance files changed: partial state — recovery commit, next session uses **recovery prompt** (governance may be inconsistent, needs damage assessment)
3. If governance files unchanged but tracked code files modified: recovery commit, next session uses **recovery prompt** (code changed without governance update)
4. If nothing changed: session died before doing anything — next session uses **normal prompt** (no damage to assess)
5. Increment consecutive crash counter (resets on any successful session)

### 6.4 Recovery prompt

The recovery session prompt differs from the normal prompt by prepending a damage assessment sequence before the task loop:

1. Run the build (`npx expo start --web`) — does it compile?
2. Check governance files — are they internally consistent (no half-written entries, next-number comment correct)?
3. Check `git status` — any uncommitted work from the crashed session?
4. For any task marked IN_PROGRESS: inspect the actual state of work files before deciding whether to redo from scratch or continue from the partial state.
5. If issues found: fix them (commit partial work, repair governance entries) before entering the normal task loop
6. If clean: enter the task loop normally

The rest of the session prompt (governance reading, task loop, codewriting loop, exit signals) is identical to the normal prompt.

### 6.5 Exit codes

| Code | Meaning |
|---|---|
| 0 | All tasks COMPLETE (COMPLETE signal received) |
| 1 | Max consecutive crashes reached |
| 2 | BLOCKED signal received (human intervention needed) |
| 3 | Max sessions limit reached |

---

## 7. Init, Reset, and Config

### 7.1 `orchestra init`

**Governance scanning** — for each governance file (TODO, DECISIONS, CHANGELOG):

1. Scan for existing folder structure matching the pattern: a directory containing a main `.md` file with numbered entries, a `CLAUDE.md` protocol file, and an `archive/` subdirectory
2. **If found and matches** → inherit. Write path to `.orchestra/config`.
3. **If nothing found** → create full structure (directory, main file with empty index, CLAUDE.md archiving protocol, archive/ subdirectory). Write path to config.
4. **If found but conflicts** → warn the user. Show what was found vs expected. Pause for input:
   - **Adopt**: migrate existing content into numbered/archivable format
   - **Point**: use existing file as-is (manual compatibility)
   - **Skip**: don't manage this governance file through orchestra

**Other init actions:**
- Create `.orchestra/` with: `config`, `toolchain.md` (template), `standing-ac.md` (template), `HANDOVER.md`, `INBOX.md`, `session-logs/`
- Create or append orchestra workflow section to project CLAUDE.md
- Create `.claude/settings.json` with hooks (skip if exists)

### 7.2 `.orchestra/config`

```bash
# Governance file locations
TODO_FILE=TODO/TODO.md
TODO_PROTOCOL=TODO/CLAUDE.md
DECISIONS_FILE=Decisions/DECISIONS.md
DECISIONS_PROTOCOL=Decisions/CLAUDE.md
CHANGELOG_FILE=Changelog/CHANGELOG.md
CHANGELOG_PROTOCOL=Changelog/CLAUDE.md

# Strategic plan for current build
PLAN_FILE=.claude/plans/build-journal-ui.md

# Toolchain (stack-specific build/test commands)
TOOLCHAIN_FILE=.orchestra/toolchain.md

# Standing acceptance criteria
STANDING_AC_FILE=.orchestra/standing-ac.md
```

### 7.3 `orchestra reset [--label NAME]`

Simplified from v1. The `--label` flag names the archive (e.g. `--label journal-mvp`). If omitted, a timestamp is used.

1. Archive `HANDOVER.md` and `session-logs/` to `.orchestra/archive/NNN-label/`
2. Reset `HANDOVER.md` to empty template
3. Clear `INBOX.md` processed messages
4. Optionally clear `PLAN_FILE` from config (ready for next strategic plan)

Governance files are **not** touched — they're project-level, not build-level.

### 7.4 `orchestra status`

Reads from config-mapped governance files:
- Tasks: COMPLETE / total from TODO.md
- Decisions: count from current build phase
- Changelog: count from current build phase
- Sessions: count from session-logs/
- Plan: objective from PLAN_FILE
- Last handover: summary from HANDOVER.md

---

## 8. Hooks

### 8.1 Hook inventory

| Hook | Trigger | Purpose |
|---|---|---|
| **stage-changes.sh** | PostToolUse (Edit/Write) | `git add` modified files. Unchanged from v1. |
| **verify-completion.sh** | Stop | Verify session progressed: T-numbered task status updated, C-numbered changelog entry added, D-entries if decisions made. Uses Haiku for fast verification. |
| **commit-and-update.sh** | Stop | Stage and commit work files + governance files. Reads COMMIT_MSG from `.orchestra/`. Reads governance paths from config. |

### 8.2 Changes from v1

**verify-completion.sh:**
- Checks T-numbered task moved to COMPLETE (or tactical/tertiary tasks added for decomposition sessions)
- Checks CHANGELOG has new C-numbered entry
- Checks DECISIONS has new D-entries if session made choices
- Reads governance file paths from `.orchestra/config`

**commit-and-update.sh:**
- Reads governance file paths from `.orchestra/config` (not hardcoded `.orchestra/` paths)
- Single commit per task completion (code + governance together)

### 8.3 Not carried forward

- Graduation-related logic — removed with graduation
- No new hooks needed — INBOX check between tasks handles mid-session human feedback

---

## 9. `.orchestra/` Directory Structure

```
.orchestra/
  config              # Key-value: governance paths, plan, toolchain, standing AC
  toolchain.md        # Stack-specific build/test/capture commands (React Native + Expo + Supabase)
  standing-ac.md      # Standing acceptance criteria (human-authored, applies to all UI tasks)
  HANDOVER.md         # Session-to-session context (overwritten each session)
  INBOX.md            # Async human-to-Claude messages
  COMMIT_MSG          # Temporary: single-line commit message written by session
  session-logs/       # Raw stream-json output from each session
  archive/            # Archived handovers + session logs after reset
```

Governance files (TODO, DECISIONS, CHANGELOG) live in the **project**, not in `.orchestra/`.

---

## 10. Files Changed (from v1 codebase)

| Action | File | Detail |
|---|---|---|
| Modify | `bin/orchestra` | Remove `cmd_graduate()`. Update `cmd_init()` with governance scanning. Update `cmd_run()` with pre-flight checks. Update `cmd_status()` to read from config. Update `cmd_reset()` to simplified form. |
| Modify | `lib/orchestrator.sh` | Update session prompt (three-tier planning, task loop, codewriting loop, ubiquitous language). Update recovery prompt. Read model from HANDOVER.md. |
| Modify | `lib/verify-completion.sh` | Check T/D/C-numbered entries via config paths. |
| Modify | `lib/commit-and-update.sh` | Read governance paths from config. |
| Modify | `templates/` | Replace TODO.md, DECISIONS.md, CHANGELOG.md templates with numbered format. Add config template, toolchain.md template, standing-ac.md template. Remove docs/ templates. Remove PLAN.md template. |
| Modify | `README.md` | Document v2 model, remove graduation, add ubiquitous language reference. |
| Modify | `CLAUDE.md` | Update with v2 ubiquitous language and workflow. |
| Create | `templates/CLAUDE-workflow.md` | Rewritten for v2 session behaviour. |
| Delete | `templates/docs/` | Entire directory — docs scaffolding removed. |
| Delete | `templates/CHANGELOG-fresh.md` | No longer needed without graduation. |
| Update | `docs/orchestra-v2-flow.html` | Visual flow diagrams for v2 architecture. |
| Create | `docs/orchestra-v2-spec.md` | This document. |

---

## 11. Verification

### 11.1 Init verification

1. Run `orchestra init` on a greenfield directory → should create full governance structure + `.orchestra/`
2. Run `orchestra init` on a LogRings-style project with existing TODO/DECISIONS → should inherit and write config paths
3. Run `orchestra init` on a project with a flat CHANGELOG.md → should warn and pause for input

### 11.2 Run verification

1. `orchestra run` with missing PLAN_FILE → should error with specific message
2. `orchestra run` with missing toolchain → should error
3. `orchestra run` with missing standing AC → should error
4. `orchestra run` with valid config and eligible tasks → should spawn first session

### 11.3 Session verification

1. Session picks up strategic task → decomposes → decomposition review passes → coherence check passes → executes first tactical task
2. Session encounters BLOCKED dependency → skips to next eligible task
3. Session completes task → writes T/D/C entries → checks INBOX → capacity check → continues or exits
4. Session runs codewriting loop → code review → UI test → all AC pass → marks complete

### 11.4 Crash recovery verification

1. Session crashes with state files updated → recovery commit → next session uses normal prompt
2. Session crashes with no state changes → next session uses recovery prompt
3. Three consecutive crashes → orchestrator exits with code 1
