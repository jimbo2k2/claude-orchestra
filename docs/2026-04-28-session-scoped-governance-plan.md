# Session-Scoped Governance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement Phase 1+2 of the session-scoped governance design — orchestra sessions write only to session-local files (`tasks.md`, `decisions.md`, `changelog.md`, `log.md`) using session-local numbering; main governance is read-only during runs; a Claude-Code merge protocol ingests session work into main on human trigger.

**Architecture:** Two coordinated changes: (a) the orchestra runtime (bash + prompt heredocs in `bin/orchestrator.sh`) stops asking Claude to write main governance and instead points it at the session folder; (b) the completion check reads from session `tasks.md` matched by `source: main:T<n>` rather than from the session-branch's main `TODO.md`. A new Claude-Code protocol document (`templates/MERGE-PROTOCOL.md`) defines how the human-triggered ingest works.

**Tech Stack:** Bash, Markdown templates, Claude Code as the protocol consumer. No new dependencies.

**Spec:** [`docs/2026-04-28-session-scoped-governance-design.md`](2026-04-28-session-scoped-governance-design.md)

**Out of scope:** T-number policy (Phase 3), TODO.md restructure (Phase 4), interactive-mode governance writes. Don't touch these.

---

## File Map

**Modified:**
- `templates/orchestra-CLAUDE.md` — governance section + exit signals reworked for session-local files
- `templates/DEVELOPMENT-PROTOCOL.md` — steps 15-18 split by mode, add W4.5 coverage evaluation
- `bin/orchestrator.sh` — session folder skeleton, prompt updates, completion check rewrite
- `install.sh` — copy MERGE-PROTOCOL.md into pinned templates
- `bin/orchestra` — `cmd_init` copies MERGE-PROTOCOL.md; `cmd_test` updated for new model
- `templates/test/TODO/TODO.md` — fixture entries get session-friendly format

**Created:**
- `templates/MERGE-PROTOCOL.md` — the human-triggered Claude-Code merge protocol

**Untouched in this plan (deferred):**
- `templates/governance/*` — main file shapes unchanged
- `lib/config.sh` — config schema unchanged
- `hooks/stage-changes.sh` — hook unchanged

---

## Task 1: Rework `orchestra-CLAUDE.md` governance section

**Files:**
- Modify: `templates/orchestra-CLAUDE.md`

**Goal:** Replace the Governance section so it instructs Claude to write to session-local files with session-local numbering, never to main governance during a run. Update Exit Signals section so COMPLETE references session `tasks.md`.

- [ ] **Step 1: Read the current file** to find the Governance and Exit Signals sections.

Run: `cat templates/orchestra-CLAUDE.md`

Locate the `## Governance` and `## Exit Signals` sections.

- [ ] **Step 2: Replace the `## Governance` section**

Replace the existing block (currently 4 short bullet lines) with:

```markdown
## Governance

During a run, **do not write to main `TODO.md`, `DECISIONS.md`, or `CHANGELOG.md`**. The session folder mirrors main's governance structure with **session-local numbering** (T1, T2, ...; D1, D2, ...; C1, C2, ...). Write to those files instead:

- **tasks.md** — one entry per assigned T-number plus any tasks discovered during the run.
  - Assigned tasks carry a `source: main:T<n>` field linking back to the brief.
  - Discovered tasks have no `source:` field — they are new and the merger will assign a fresh main T-number.
  - Format: `- T<n>: STATUS (source: main:T<m>) — Title`, then indented `Notes:` line(s).
  - Statuses: OPEN, IN_PROGRESS, COMPLETE, BLOCKED.
- **decisions.md** — proposed decisions in main `DECISIONS.md` format. Use session-local D-numbers (D1, D2, ...). Title, Alternatives, Rationale.
- **changelog.md** — proposed changelog entries in main `CHANGELOG.md` format. Use session-local C-numbers (C1, C2, ...).
- **log.md** — free-form session notes, findings, parked issues. Anything that is not a formal entry.

Cross-references **within the session** use session-local IDs (e.g. `see D2`). Cross-references **to main** use real main IDs (e.g. `supersedes main:D0017`). Reading main governance files for context is fine and encouraged — never write to them.

The orchestrator pre-creates skeleton `tasks.md`, `decisions.md`, `changelog.md`, and `log.md` in the session folder when the run starts. The skeleton `tasks.md` is pre-populated with one entry per assigned T-number, OPEN status, and a `source:` field — fill in title and notes as you work.

A separate, human-triggered merge protocol (`MERGE-PROTOCOL.md`) ingests the session governance into main after the run completes. You do not run the merge yourself.

- Commits: on branch, never to main. Do not merge.
```

- [ ] **Step 3: Replace the `## Exit Signals` section**

Replace with:

```markdown
## Exit Signals

Before signalling COMPLETE, you MUST run the coverage evaluation step (DEVELOPMENT-PROTOCOL.md Part 2 step W4.5). The orchestrator's mechanical check reads session `tasks.md`, but it trusts your evaluation.

- **HANDOVER** — tasks remain, spawn next session
- **COMPLETE** — every assigned T-number has its session-local counterpart marked COMPLETE in `tasks.md` AND has passed your coverage evaluation
- **BLOCKED** — needs human input (write to INBOX.md)
```

- [ ] **Step 4: Verify the file parses as markdown and reads coherently**

Run: `cat templates/orchestra-CLAUDE.md | head -80`

Expected: Governance and Exit Signals sections show the new content; surrounding sections (Run Workspace, Session Grouping, Task Input, Worktree + Branching Model, Conventions) are unchanged.

- [ ] **Step 5: Commit**

```bash
git add templates/orchestra-CLAUDE.md
git commit -m "feat(templates): orchestra session writes session-local governance"
```

---

## Task 2: Add W4.5 to `DEVELOPMENT-PROTOCOL.md` and split steps 15-18 by mode

**Files:**
- Modify: `templates/DEVELOPMENT-PROTOCOL.md`

**Goal:** Steps 15-18 currently say "write D-entries / T-entries / C-entry / mark task COMPLETE". In Orchestra mode they should write to session-local files instead. Add a new wrap-up step W4.5 (Coverage evaluation) before W5 (Write HANDOVER).

- [ ] **Step 1: Read the current file**

Run: `cat templates/DEVELOPMENT-PROTOCOL.md`

Locate the table rows for steps 15, 16, 17, 18 (Part 1) and the wrap-up rows W1-W6 (Part 2).

- [ ] **Step 2: Replace the steps 15-18 rows**

Replace the four existing rows with these (preserving the surrounding table structure):

```markdown
| 15 | **Governance: Decisions** | No decisions -> skip. | Interactive: write D-entry to main `DECISIONS.md`. Orchestra: write D-entry to session `decisions.md` with session-local D-number. | — | Interactive: ratified. Orchestra: PROPOSED. |
| 16 | **Governance: New tasks** | None discovered -> skip. | Interactive: write T-entry to main `TODO.md` as PROPOSED. Orchestra: write T-entry to session `tasks.md` with session-local T-number, no `source:` field. | — | Same |
| 17 | **Governance: Changelog** | No substantive changes -> skip. | Interactive: write C-entry to main `CHANGELOG.md`. Orchestra: write C-entry to session `changelog.md` with session-local C-number. | — | Same |
| 18 | **Governance: Complete task** | — | Interactive: mark COMPLETE in main `TODO.md` with note. Orchestra: mark COMPLETE in session `tasks.md` (find row by `source: main:T<n>`) with note. Flag human-verify items. | — | Same |
```

- [ ] **Step 3: Add W4.5 to Part 2 (Session Wrap-Up)**

In the Part 2 table, insert a new row between W4 and W5:

```markdown
| W4.5 | **Coverage evaluation** (Orchestra only) | Not Orchestra -> skip. | For each assigned main T-number from `.orchestra/config TASKS=`: read the main `TODO.md` snapshot in the worktree, find the matching session-local task in `tasks.md` via the `source:` field, and evaluate honestly: does the recorded work cover what the main TODO entry asks for? If a task is partially done, ambiguous, or COMPLETE-marked but undercooked, downgrade it to IN_PROGRESS or BLOCKED in `tasks.md` with a note. Only proceed past this step when every assigned task is honestly COMPLETE or has been honestly downgraded. |
```

- [ ] **Step 4: Update Gate Logic note** (the "Gate Logic" subsection just below the Part 1 table)

The current text has a bullet about Steps 5-6 and another about 9-14. Add a third bullet:

```markdown
- **Steps 15-18** branch by mode: Interactive writes to main governance; Orchestra writes to the session folder. The merger protocol later promotes session entries to main.
```

- [ ] **Step 5: Verify the file**

Run: `cat templates/DEVELOPMENT-PROTOCOL.md`

Expected: Part 1 table has the four updated rows for 15-18 with mode-split behaviour. Part 2 has the new W4.5 row between W4 and W5. Gate Logic has the new bullet.

- [ ] **Step 6: Commit**

```bash
git add templates/DEVELOPMENT-PROTOCOL.md
git commit -m "feat(templates): split governance steps by mode, add W4.5 coverage eval"
```

---

## Task 3: Pre-create session governance skeletons in `orchestrator.sh`

**Files:**
- Modify: `bin/orchestrator.sh:540-547` (the run workspace creation block)

**Goal:** When the orchestrator creates `.orchestra/sessions/run-<ts>/`, it currently only creates the directory. It should also pre-create empty `decisions.md`, `changelog.md`, `log.md` skeletons and a pre-populated `tasks.md` with one entry per assigned T-number.

- [ ] **Step 1: Read the current run-workspace creation block**

Run: `sed -n '540,550p' bin/orchestrator.sh`

Expected current content:

```bash
# ─── Create run workspace folder inside worktree ─────────────────────────────
# All session artifacts (JSON logs, tasks.md, log.md) go here — one folder
# per orchestra invocation, named to match the worktree/branch.
RUN_WORKSPACE="$WORKTREE_DIR/.orchestra/sessions/$RUN_NAME"
mkdir -p "$RUN_WORKSPACE"
notify "   Run workspace: .orchestra/sessions/$RUN_NAME"
```

- [ ] **Step 2: Replace with skeleton-creating version**

Use the Edit tool to replace the block above with:

```bash
# ─── Create run workspace folder inside worktree ─────────────────────────────
# All session artifacts (JSON logs, tasks.md, decisions.md, changelog.md,
# log.md) go here — one folder per orchestra invocation, named to match the
# worktree/branch.
RUN_WORKSPACE="$WORKTREE_DIR/.orchestra/sessions/$RUN_NAME"
mkdir -p "$RUN_WORKSPACE"

# Skeleton governance files for the session. Claude writes here, never to
# main TODO.md/DECISIONS.md/CHANGELOG.md during the run.
if [ ! -f "$RUN_WORKSPACE/tasks.md" ]; then
    {
        echo "# Session Tasks — $RUN_NAME"
        echo ""
        echo "Session-local T-numbers. Assigned tasks carry source: main:T<n>."
        echo "Discovered tasks have no source field."
        echo ""
        echo "## Assigned"
        echo ""
        local_tn=0
        IFS=',' read -ra _SKEL_TASKS <<< "$TASKS"
        for _tn in "${_SKEL_TASKS[@]}"; do
            _tn=$(echo "$_tn" | xargs)
            local_tn=$((local_tn + 1))
            echo "- T${local_tn}: OPEN (source: main:${_tn}) — (title pending)"
            echo "    Notes:"
        done
        echo ""
        echo "## Discovered"
        echo ""
        echo "<!-- Add discovered tasks here. No source: field. -->"
    } > "$RUN_WORKSPACE/tasks.md"
fi

if [ ! -f "$RUN_WORKSPACE/decisions.md" ]; then
    {
        echo "# Session Decisions — $RUN_NAME"
        echo ""
        echo "Session-local D-numbers (D1, D2, ...). Format mirrors main DECISIONS.md."
        echo "Promoted to main D-numbers by the merger."
        echo ""
    } > "$RUN_WORKSPACE/decisions.md"
fi

if [ ! -f "$RUN_WORKSPACE/changelog.md" ]; then
    {
        echo "# Session Changelog — $RUN_NAME"
        echo ""
        echo "Session-local C-numbers (C1, C2, ...). Format mirrors main CHANGELOG.md."
        echo "Promoted to main C-numbers by the merger."
        echo ""
    } > "$RUN_WORKSPACE/changelog.md"
fi

if [ ! -f "$RUN_WORKSPACE/log.md" ]; then
    {
        echo "# Session Log — $RUN_NAME"
        echo ""
        echo "Free-form notes, findings, parked issues. Not formal entries."
        echo ""
    } > "$RUN_WORKSPACE/log.md"
fi

notify "   Run workspace: .orchestra/sessions/$RUN_NAME (tasks/decisions/changelog/log seeded)"
```

- [ ] **Step 3: Bash syntax check**

Run: `bash -n bin/orchestrator.sh && echo "syntax OK"`

Expected: `syntax OK`

- [ ] **Step 4: Smoke-test the skeleton creation in isolation**

Create a quick standalone test:

```bash
mkdir -p /tmp/orch-skel-test/.orchestra/sessions/run-test
cat > /tmp/orch-skel-test/test.sh <<'EOF'
#!/bin/bash
set -e
RUN_NAME="run-test"
RUN_WORKSPACE="/tmp/orch-skel-test/.orchestra/sessions/$RUN_NAME"
TASKS="T100,T101,T102"
mkdir -p "$RUN_WORKSPACE"

# Paste the same skeleton-creation block from orchestrator.sh here:
# (For the test, copy lines from your edited orchestrator.sh starting at the
# "# Skeleton governance files" comment through the closing fi of log.md.)
EOF
```

Then paste the skeleton block (copied from the edited orchestrator.sh) into the test script after the `mkdir` line. Run:

```bash
bash /tmp/orch-skel-test/test.sh
ls /tmp/orch-skel-test/.orchestra/sessions/run-test/
cat /tmp/orch-skel-test/.orchestra/sessions/run-test/tasks.md
```

Expected: four files (`tasks.md`, `decisions.md`, `changelog.md`, `log.md`); `tasks.md` shows three Assigned entries `T1: OPEN (source: main:T100)` through `T3: OPEN (source: main:T102)`.

Cleanup: `rm -rf /tmp/orch-skel-test`

- [ ] **Step 5: Commit**

```bash
git add bin/orchestrator.sh
git commit -m "feat(orchestrator): pre-create session governance skeletons"
```

---

## Task 4: Update orchestrator prompts to point Claude at session-local governance

**Files:**
- Modify: `bin/orchestrator.sh:280-355` (the SESSION_PROMPT heredoc, specifically TASK EXECUTION section)

**Goal:** The big heredoc that becomes Claude's prompt currently references main TODO.md as the place to mark COMPLETE. It needs to point Claude at the session folder for governance writes, and reference the new W4.5 step.

- [ ] **Step 1: Locate the TASK EXECUTION block in the heredoc**

Run: `sed -n '311,355p' bin/orchestrator.sh`

You'll see the section starting with `TASK EXECUTION` and ending with the `Between tasks (protocol step 20)` block.

- [ ] **Step 2: Replace the existing item 2 (Run workspace) and add a new item about governance**

The current item 2 reads:

```
2. Create or update the run workspace at .orchestra/sessions/__RUN_NAME__/ with:
   - tasks.md — cumulative subtask list across all tasks in this run
   - log.md — cumulative session decisions, findings, parked issues
   If the files already exist from a previous session in this run, append to
   them rather than overwriting.
```

Replace it with:

```
2. The run workspace at .orchestra/sessions/__RUN_NAME__/ has been pre-seeded
   with skeleton governance files:
   - tasks.md — assigned tasks (one row per T-number from config) plus a
     "Discovered" section. Update statuses as you work. Use session-local
     T-numbers (T1, T2, ...) for any new tasks; do NOT reuse main T-numbers.
   - decisions.md — write decisions here using session-local D-numbers
     (D1, D2, ...) in main DECISIONS.md format. PROPOSED status.
   - changelog.md — write changelog entries here using session-local C-numbers.
   - log.md — free-form findings, parked issues, anything not a formal entry.

   Append to these files across sessions in the same run; do not overwrite.
   **Do NOT write to main TODO.md, DECISIONS.md, or CHANGELOG.md during the
   run.** Reading them for context is fine. The merge protocol promotes
   session entries to main after the human triggers it.
```

- [ ] **Step 3: Update the "Between tasks" block to reference W4.5**

The current block (item 4 in TASK EXECUTION) reads:

```
4. Between tasks (protocol step 20):
   a. Re-read __STATE_DIR__/INBOX.md for new human messages.
   b. Evaluate remaining context. If you have completed 3 or more tasks in
      this session, prefer a clean HANDOVER over risking context exhaustion.
   c. If continuing, return to step 1 for next task.
```

Add a sub-bullet:

```
4. Between tasks (protocol step 20):
   a. Re-read __STATE_DIR__/INBOX.md for new human messages.
   b. Evaluate remaining context. If you have completed 3 or more tasks in
      this session, prefer a clean HANDOVER over risking context exhaustion.
   c. If continuing, return to step 1 for next task.
   d. Before exiting with COMPLETE, run DEVELOPMENT-PROTOCOL.md Part 2 step
      W4.5 (Coverage evaluation): for each assigned main T-number, verify the
      session-local task honestly covers what the main TODO entry asks for.
      Downgrade any over-claimed status to IN_PROGRESS or BLOCKED.
```

- [ ] **Step 4: Bash syntax check** (the heredoc must remain valid)

Run: `bash -n bin/orchestrator.sh && echo "syntax OK"`

- [ ] **Step 5: Sanity-check the rendered prompt** (placeholders should still expand)

Run:

```bash
grep -E "__RUN_NAME__|__STATE_DIR__|__SESSION_BRANCH__|__ORCH_CONFIG__" bin/orchestrator.sh | head
```

Expected: the placeholders still appear in the heredoc (so the existing substitution code keeps working).

- [ ] **Step 6: Commit**

```bash
git add bin/orchestrator.sh
git commit -m "feat(orchestrator): point session prompt at session-local governance"
```

---

## Task 5: Replace completion check (Layer B) — read session `tasks.md`

**Files:**
- Modify: `bin/orchestrator.sh:461-470` (the `read_todo_from_session` function)
- Modify: `bin/orchestrator.sh:753-794` (the two completion checks in the main loop)
- Modify: `bin/orchestrator.sh:805-815` (the max-sessions completion check)

**Goal:** Replace the current logic — which reads main TODO.md from the session branch via `git show` — with a new function that reads `tasks.md` from the run workspace and matches `source: main:T<n>` lines with COMPLETE status.

- [ ] **Step 1: Replace `read_todo_from_session` with `is_main_task_complete`**

Find the existing function at lines 461-470:

```bash
read_todo_from_session() {
    local todo_rel="${TODO_FILE#$PROJECT_DIR/}"
    if [ -n "${SESSION_BRANCH:-}" ] && git rev-parse --verify "$SESSION_BRANCH" >/dev/null 2>&1; then
        git show "$SESSION_BRANCH:$todo_rel" 2>/dev/null
    else
        cat "$TODO_FILE" 2>/dev/null
    fi
}
```

Replace with:

```bash
# Returns 0 (true) if the assigned main T-number has been marked COMPLETE in
# the session's tasks.md. The session writes session-local T-numbers (T1, T2,
# ...) and tags each with `source: main:T<n>`. We grep for a COMPLETE line
# whose source matches the queried main T-number.
#
# Format expected in tasks.md:
#   - T1: COMPLETE (source: main:T384) — Title
#
# Returns 1 (false) on no match or missing file (conservative — assume work
# remains).
is_main_task_complete() {
    local main_tn="$1"
    local tasks_file="$RUN_WORKSPACE/tasks.md"

    if [ ! -f "$tasks_file" ]; then
        return 1
    fi

    grep -Eq "^- T[0-9]+: COMPLETE \(source: main:${main_tn}\)" "$tasks_file"
}
```

- [ ] **Step 2: Replace the post-COMPLETE-signal double-check (lines 753-770)**

Find:

```bash
    if echo "$FINAL" | grep -qi "COMPLETE"; then
        # Double-check: are all assigned tasks marked COMPLETE in TODO.md?
        REMAINING=0
        IFS=',' read -ra TASK_LIST <<< "$TASKS"
        for tn in "${TASK_LIST[@]}"; do
            tn=$(echo "$tn" | xargs)
            if read_todo_from_session | grep -A5 "### $tn" 2>/dev/null | grep -q 'Status:.*COMPLETE'; then
                : # done
            else
                REMAINING=$((REMAINING + 1))
            fi
        done
        if [ "$REMAINING" -eq 0 ]; then
            notify "All assigned tasks completed after $SESSION_COUNT sessions! ($TOTAL_CRASHES crashes recovered)"
            exit 0
        else
            notify "Claude signalled COMPLETE but $REMAINING assigned tasks remain. Continuing..."
        fi
    fi
```

Replace with:

```bash
    if echo "$FINAL" | grep -qi "COMPLETE"; then
        # Verify against session tasks.md (source-of-truth for this run).
        REMAINING=0
        IFS=',' read -ra TASK_LIST <<< "$TASKS"
        for tn in "${TASK_LIST[@]}"; do
            tn=$(echo "$tn" | xargs)
            if is_main_task_complete "$tn"; then
                : # done
            else
                REMAINING=$((REMAINING + 1))
            fi
        done
        if [ "$REMAINING" -eq 0 ]; then
            notify "All assigned tasks completed after $SESSION_COUNT sessions! ($TOTAL_CRASHES crashes recovered)"
            exit 0
        else
            notify "Claude signalled COMPLETE but $REMAINING assigned tasks not COMPLETE in session tasks.md. Continuing..."
        fi
    fi
```

- [ ] **Step 3: Replace the post-session source-of-truth check (lines 779-794)**

Find:

```bash
    # Check assigned tasks for completion (source of truth, regardless of signal)
    REMAINING=0
    IFS=',' read -ra TASK_LIST <<< "$TASKS"
    for tn in "${TASK_LIST[@]}"; do
        tn=$(echo "$tn" | xargs)
        if read_todo_from_session | grep -A5 "### $tn" 2>/dev/null | grep -q 'Status:.*COMPLETE'; then
            : # done
        else
            REMAINING=$((REMAINING + 1))
        fi
    done
```

Replace with:

```bash
    # Check assigned tasks for completion (source of truth: session tasks.md)
    REMAINING=0
    IFS=',' read -ra TASK_LIST <<< "$TASKS"
    for tn in "${TASK_LIST[@]}"; do
        tn=$(echo "$tn" | xargs)
        if is_main_task_complete "$tn"; then
            : # done
        else
            REMAINING=$((REMAINING + 1))
        fi
    done
```

- [ ] **Step 4: Replace the max-sessions check (lines 805-815)**

Find:

```bash
REMAINING=0
IFS=',' read -ra TASK_LIST <<< "$TASKS"
for tn in "${TASK_LIST[@]}"; do
    tn=$(echo "$tn" | xargs)
    if grep -A5 "### $tn" "$TODO_FILE" 2>/dev/null | grep -q 'Status:.*COMPLETE'; then
        : # done
    else
        REMAINING=$((REMAINING + 1))
    fi
done
```

Replace with:

```bash
REMAINING=0
IFS=',' read -ra TASK_LIST <<< "$TASKS"
for tn in "${TASK_LIST[@]}"; do
    tn=$(echo "$tn" | xargs)
    if is_main_task_complete "$tn"; then
        : # done
    else
        REMAINING=$((REMAINING + 1))
    fi
done
```

- [ ] **Step 5: Bash syntax check**

Run: `bash -n bin/orchestrator.sh && echo "syntax OK"`

- [ ] **Step 6: Unit-test `is_main_task_complete` in isolation**

Create a fixture and exercise the function:

```bash
mkdir -p /tmp/orch-check-test
cat > /tmp/orch-check-test/tasks.md <<'EOF'
# Session Tasks

## Assigned
- T1: COMPLETE (source: main:T100) — Did the thing
    Notes: it works
- T2: IN_PROGRESS (source: main:T101) — Working on it
    Notes: half done
- T3: BLOCKED (source: main:T102) — Stuck
    Notes: needs input

## Discovered
- T4: COMPLETE — Tightened error handling
EOF

cat > /tmp/orch-check-test/test.sh <<'EOF'
#!/bin/bash
set -e
RUN_WORKSPACE=/tmp/orch-check-test

# Paste the is_main_task_complete function from orchestrator.sh here:
is_main_task_complete() {
    local main_tn="$1"
    local tasks_file="$RUN_WORKSPACE/tasks.md"
    if [ ! -f "$tasks_file" ]; then
        return 1
    fi
    grep -Eq "^- T[0-9]+: COMPLETE \(source: main:${main_tn}\)" "$tasks_file"
}

# Assertions
is_main_task_complete T100 && echo "T100: COMPLETE ✓" || { echo "T100: FAIL"; exit 1; }
is_main_task_complete T101 && { echo "T101 wrongly reported COMPLETE"; exit 1; } || echo "T101: not complete ✓"
is_main_task_complete T102 && { echo "T102 wrongly reported COMPLETE"; exit 1; } || echo "T102: not complete ✓"
is_main_task_complete T999 && { echo "T999 wrongly reported COMPLETE"; exit 1; } || echo "T999 (absent): not complete ✓"
echo "ALL CHECKS PASSED"
EOF

bash /tmp/orch-check-test/test.sh
```

Expected output:
```
T100: COMPLETE ✓
T101: not complete ✓
T102: not complete ✓
T999 (absent): not complete ✓
ALL CHECKS PASSED
```

Cleanup: `rm -rf /tmp/orch-check-test`

- [ ] **Step 7: Commit**

```bash
git add bin/orchestrator.sh
git commit -m "fix(orchestrator): completion check reads session tasks.md, not main TODO

Resolves the recovery-loop bug where orchestra would spawn session after
session because the session branch never wrote COMPLETE to main TODO.md
(per the new governance rule). The check now reads the session's own
tasks.md and matches by source: main:T<n>, which is what Claude is
actually writing under the new protocol."
```

---

## Task 6: Create the merge protocol document

**Files:**
- Create: `templates/MERGE-PROTOCOL.md`

**Goal:** Provide the Claude-Code protocol the human invokes to ingest a session's governance into main. Self-contained — Claude reads this and follows it without needing to consult the spec.

- [ ] **Step 1: Create the file**

Use Write tool. Path: `templates/MERGE-PROTOCOL.md`. Content:

````markdown
# Orchestra Merge Protocol

**Trigger:** the human says something like "we're ready to merge run-<timestamp>" or "ingest session run-<timestamp> into main". Follow this protocol exactly.

**Purpose:** ingest a completed orchestra run's session-local governance (`tasks.md`, `decisions.md`, `changelog.md`, `log.md`) into the project's main governance files (`TODO.md`, `DECISIONS.md`, `CHANGELOG.md`), then merge the session branch into main.

**You do this in Claude Code, interactively. Not in bash. Not autonomously.** This protocol uses your judgement at the conflict-resolution checkpoint.

## Step 1 — Identify the run

Locate `.orchestra/sessions/run-<timestamp>/` in the worktree (the orchestrator preserved it). Read all four files:

- `tasks.md` — session-local T-numbers; assigned ones carry `source: main:T<n>`
- `decisions.md` — session-local D-numbers
- `changelog.md` — session-local C-numbers
- `log.md` — free-form notes

**Idempotency check:** if `log.md` contains an `## Ingested` marker section, this run has already been merged. Refuse with a clear message — tell the human to either skip or pass an explicit override flag.

## Step 2 — Read main's current state

Read in the project's main working tree:

- The configured `TODO_FILE`, `DECISIONS_FILE`, `CHANGELOG_FILE` (from `.orchestra/config`)
- The `<!-- Next number: TXXX -->` markers in each
- `INBOX.md` — for any human messages flagging concerns about this run

## Step 3 — Plan the ingest

Build a structured plan and present it to the human. The plan translates session-local IDs to main IDs:

**Task statuses to flip on main `TODO.md`:**
For each row in session `tasks.md` that has a `source: main:T<n>` field:
- "main T<n> → STATUS" where STATUS is the session-local row's status

**Decisions to add to main `DECISIONS.md`:**
For each entry in session `decisions.md` (in document order):
- Read main's `<!-- Next number -->` for D
- Assign D<next>, D<next+1>, ... in order
- Note any intra-session references (`see D2` inside a decision body) — these need rewriting to use the new main D-numbers

**Changelog entries to add to main `CHANGELOG.md`:**
Same pattern: assign next main C-numbers in order, rewrite intra-session references.

**Discovered tasks to add to main `TODO.md` as PROPOSED:**
For each row in session `tasks.md` with NO `source:` field:
- Assign next main T-number
- Status PROPOSED

**Notable items from `log.md`:**
Surface anything that looks important to the human — parked issues, open questions, environmental observations.

**Conflicts to flag:**
- Main governance changed since the run started. Compare main's current entries to anything that was visible at run start (use the worktree's snapshot if available; otherwise compare commit timestamps).
- A session decision touches the same area as a recent main D-entry.
- A session entry's content duplicates a recent main entry.

## Step 4 — Human checkpoint

Present the plan as a clear bullet list. Wait for the human to:
- Approve the whole plan
- Edit specific entries
- Reject specific entries (omit from ingest)
- Ask follow-up questions

This is the conflict-resolution moment. Do not proceed without explicit approval.

## Step 5 — Apply to main

In the main working tree (not the worktree):
1. Append approved entries to main `TODO.md`, `DECISIONS.md`, `CHANGELOG.md`. Use the assigned main numbers from Step 3. Preserve formatting and section structure.
2. Update each file's `<!-- Next number -->` marker.
3. Stage and commit on main:

```bash
git add TODO.md DECISIONS.md CHANGELOG.md
git commit -m "governance: ingest run-<timestamp>"
```

(Adjust paths to match the project's `TODO_FILE`/`DECISIONS_FILE`/`CHANGELOG_FILE` config.)

## Step 6 — Merge the session branch

```bash
git merge orchestra/run-<timestamp>
```

If fast-forward: done. If not, resolve code conflicts manually with the human's input. Push:

```bash
git push origin main
```

## Step 7 — Mark the run ingested

Append to the run's `log.md` (in the worktree):

```markdown

## Ingested

- Date: <ISO timestamp>
- Governance commit: <SHA from Step 5>
- Code merge commit: <SHA from Step 6 if a merge commit; otherwise "fast-forward to <SHA>">
- Main IDs assigned:
  - Tasks: T<n>, T<m>, ...
  - Decisions: D<n>, D<m>, ...
  - Changelog: C<n>, C<m>, ...
```

Commit on the session branch (or in the worktree, however the project's commit hooks expect it):

```bash
git add .orchestra/sessions/run-<timestamp>/log.md
git commit -m "chore: mark run-<timestamp> ingested"
```

This makes Step 1's idempotency check work for any future invocation.

## Error recovery

- **Run already ingested** (Step 1 idempotency check): refuse cleanly. Do not partially re-ingest.
- **Main governance changed during the run**: surface in Step 3's conflict list. Let the human decide per-entry.
- **Session branch merge fails** (Step 6): governance from Step 5 is already committed and consistent. Resolve the code conflict separately with the human; do not roll back governance unless the human asks for that.
- **Numbering collision** (rare — only if another writer hit main between Step 2 and Step 5): re-read main's next-numbers in Step 5 and re-assign. Mention the re-assignment in the Step 5 commit message.
````

- [ ] **Step 2: Verify the file**

Run: `head -30 templates/MERGE-PROTOCOL.md`

Expected: trigger, purpose, and start of Step 1.

- [ ] **Step 3: Commit**

```bash
git add templates/MERGE-PROTOCOL.md
git commit -m "feat(templates): add MERGE-PROTOCOL.md for human-triggered ingest"
```

---

## Task 7: Wire `MERGE-PROTOCOL.md` into install paths

**Files:**
- Modify: `install.sh` (the templates copy loop)
- Modify: `bin/orchestra` (`cmd_init` template copy block)

**Goal:** Both bootstrap paths must place `MERGE-PROTOCOL.md` into `.orchestra/` of new projects.

- [ ] **Step 1: Update `install.sh`**

Find the loop at line 39:

```bash
for f in config config.test HANDOVER.md INBOX.md README.md toolchain.md; do
```

Change to:

```bash
for f in config config.test HANDOVER.md INBOX.md README.md toolchain.md MERGE-PROTOCOL.md; do
```

- [ ] **Step 2: Update `bin/orchestra` cmd_init**

Find the template copy block in `cmd_init` (around line 233):

```bash
    for f in HANDOVER.md INBOX.md README.md; do
        if [ -f "$TEMPLATE_DIR/$f" ]; then
            cp "$TEMPLATE_DIR/$f" "$orchestra_dir/$f"
        fi
    done
```

Change to:

```bash
    for f in HANDOVER.md INBOX.md README.md MERGE-PROTOCOL.md; do
        if [ -f "$TEMPLATE_DIR/$f" ]; then
            cp "$TEMPLATE_DIR/$f" "$orchestra_dir/$f"
        fi
    done
```

- [ ] **Step 3: Bash syntax check both files**

```bash
bash -n install.sh && bash -n bin/orchestra && echo "syntax OK"
```

- [ ] **Step 4: Smoke-test bootstrapping into a fresh dir**

```bash
TMPDIR=$(mktemp -d)
cd "$TMPDIR" && git init -q && touch CLAUDE.md
/home/james/projects/claude-orchestra/install.sh "$TMPDIR" 2>&1 | grep -E "MERGE-PROTOCOL|Error"
ls "$TMPDIR/.orchestra/MERGE-PROTOCOL.md"
```

Expected: `MERGE-PROTOCOL.md` exists in the new project's `.orchestra/`.

Cleanup: `cd /home/james/projects/claude-orchestra && rm -rf "$TMPDIR"`

- [ ] **Step 5: Commit**

```bash
git add install.sh bin/orchestra
git commit -m "feat(install): include MERGE-PROTOCOL.md in scaffolded .orchestra/"
```

---

## Task 8: Update test fixtures and `cmd_test` for the new model

**Files:**
- Modify: `bin/orchestra` (`cmd_test` function, around lines 479-607)
- Inspect (and possibly modify): `templates/test/TODO/TODO.md`, `templates/test/HANDOVER.md`, `templates/test/INBOX.md`

**Goal:** The `orchestra test` integration test currently checks main `TODO.md` statuses to verify success. Switch it to check the run's `tasks.md`. Verify main governance is untouched after the test.

- [ ] **Step 1: Read the current test verification block**

Run: `sed -n '536,572p' bin/orchestra`

You'll see the "Report state" block that greps the test TODO.md for status.

- [ ] **Step 2: Identify the run workspace path the test should check**

The test's run workspace is at `<WORKTREE_BASE>/run-<timestamp>/.orchestra/sessions/run-<timestamp>/tasks.md`. The test's `WORKTREE_BASE` is `/tmp/orchestra-test/` per `templates/config.test`. The exact run name is timestamp-based and known after the run.

After the test loop, find the latest run workspace:

```bash
local latest_workspace
latest_workspace=$(find /tmp/orchestra-test -type d -name "run-*" -path "*/.orchestra/sessions/*" 2>/dev/null | sort | tail -1)
```

- [ ] **Step 3: Replace the `# ─── Report state ───` block**

Find:

```bash
    # ─── Report state ───────────────────────────────────────────────────────
    echo ""
    echo "==========================================="
    echo "Test complete — inspect results"
    echo "==========================================="
    echo ""

    local artifact_file="$project_dir/.orchestra/test/test-artifacts.md"
    if [ -f "$artifact_file" ]; then
        echo "test-artifacts.md:"
        sed 's/^/   /' "$artifact_file"
        echo ""
    else
        echo "NOTE: .orchestra/test/test-artifacts.md not in main tree."
        echo "      It lives on the session branch — check there."
        echo ""
    fi

    echo "TODO.md status (in main tree):"
    grep -A1 '### T999' "$project_dir/.orchestra/test/TODO/TODO.md" | grep -E "###|Status:" | sed 's/^/   /' || echo "   (could not read)"
    echo ""
```

Replace with:

```bash
    # ─── Report state ───────────────────────────────────────────────────────
    echo ""
    echo "==========================================="
    echo "Test complete — inspect results"
    echo "==========================================="
    echo ""

    local artifact_file="$project_dir/.orchestra/test/test-artifacts.md"
    if [ -f "$artifact_file" ]; then
        echo "test-artifacts.md:"
        sed 's/^/   /' "$artifact_file"
        echo ""
    else
        echo "NOTE: .orchestra/test/test-artifacts.md not in main tree."
        echo "      It lives on the session branch — check there."
        echo ""
    fi

    # New protocol: session writes to tasks.md in the run workspace, not main
    # TODO.md. Verify the session-local file shows our test T-numbers complete.
    local latest_workspace
    latest_workspace=$(find /tmp/orchestra-test -type d -name "run-*" -path "*/.orchestra/sessions/*" 2>/dev/null | sort | tail -1)
    if [ -n "$latest_workspace" ] && [ -f "$latest_workspace/tasks.md" ]; then
        echo "Session tasks.md (in run workspace):"
        grep -E "^- T[0-9]+: " "$latest_workspace/tasks.md" | sed 's/^/   /' || echo "   (no task entries)"
        echo ""
    else
        echo "WARN: no session tasks.md found under /tmp/orchestra-test"
        echo ""
    fi

    # Confirm main TODO.md was NOT written to (governance rule: read-only during run)
    echo "Main test TODO.md (should be unchanged from committed state):"
    if git -C "$project_dir" diff --quiet .orchestra/test/TODO/TODO.md 2>/dev/null; then
        echo "   ✓ unchanged (governance rule honoured)"
    else
        echo "   ✗ MAIN TODO.md MODIFIED — protocol violation"
        git -C "$project_dir" diff --stat .orchestra/test/TODO/TODO.md | sed 's/^/     /'
    fi
    echo ""
```

- [ ] **Step 4: Bash syntax check**

```bash
bash -n bin/orchestra && echo "syntax OK"
```

- [ ] **Step 5: Inspect the test fixtures to make sure they don't conflict with the new model**

Run:

```bash
cat templates/test/TODO/TODO.md
cat templates/test/HANDOVER.md
cat templates/test/INBOX.md
```

The fixtures should still describe T9998 and T9999 as the assigned tasks (those flow through `.orchestra/config.test TASKS=T9998,T9999`). No content change is needed in the fixtures themselves — the change is in how the orchestrator and test verify completion.

- [ ] **Step 6: Run the integration test end-to-end**

Run: `cd /home/james/projects/claude-orchestra && bash bin/orchestra test`

This will spawn a real orchestra run in a tmux session. Watch with `tmux attach -t orchestra-test`. The run should complete in under 15 minutes.

Expected at the end:
- "Session tasks.md (in run workspace):" lists `T1: COMPLETE (source: main:T9998)` and `T2: COMPLETE (source: main:T9999)`
- "Main test TODO.md (should be unchanged from committed state): ✓ unchanged"
- Orchestrator exited with `All assigned tasks completed`

If the run loops or fails: inspect `tmux attach -t orchestra-test` output, the run workspace at `/tmp/orchestra-test/run-*/.orchestra/sessions/run-*/`, and recent commits on the session branch.

- [ ] **Step 7: Commit**

```bash
git add bin/orchestra
git commit -m "test(orchestra): verify session tasks.md and main TODO untouched"
```

---

## Task 9: Final integration check and push

**Files:** none (verification only)

- [ ] **Step 1: Re-run the integration test from a clean state**

```bash
cd /home/james/projects/claude-orchestra
git status                     # should be clean after Task 8 commit
bash bin/orchestra test         # full smoke
```

Expected: same successful output as Task 8 Step 6. The test now exercises the full new protocol end-to-end.

- [ ] **Step 2: Update CHANGELOG / commit log summary** (canonical claude-orchestra has no formal CHANGELOG; the git log is the changelog)

Run: `git log --oneline 11a78b5..HEAD`

You should see eight or so commits (one per task above). Confirm titles read coherently.

- [ ] **Step 3: Push to origin**

```bash
git push origin main
```

- [ ] **Step 4: Logrings re-pinning** (separate concern, not done here)

The logrings project (`/home/james/projects/logrings/logrings-main`) currently has its own pinned copy of the orchestra runtime. To pick up the new protocol, the human will need to:
- Re-pin `.orchestra/bin/orchestra` and `.orchestra/bin/orchestrator.sh` from canonical
- Copy `templates/MERGE-PROTOCOL.md` into `.orchestra/MERGE-PROTOCOL.md`
- Update `.orchestra/CLAUDE.md` with the new Governance and Exit Signals sections (since logrings has a customised version with project-specific Conventions content, do this as a manual merge rather than overwrite)
- Update `Development/conventions/01-development-protocol.md` with the new steps 15-18 wording and W4.5

This is a separate task and explicitly out of scope for the canonical implementation plan.

---

## Spec coverage check

| Spec component | Implemented in |
|---|---|
| Session writes only to session-local files | Tasks 1, 4 (templates), Task 3 (skeleton creation) |
| `decisions.md` and `changelog.md` mirror main shapes | Task 3 (skeleton headers), Task 1 (instructions) |
| Session-local numbering (T1, T2, ...; D1, D2, ...; C1, C2, ...) | Task 1, Task 4 (Claude instructions), Task 3 (skeleton) |
| `source: main:T<n>` field on assigned tasks | Task 3 (skeleton), Task 1, Task 4 (Claude instructions), Task 5 (matched in completion check) |
| Discovered tasks have no `source:` field | Task 1 (Claude instructions), Task 3 (skeleton's "Discovered" section) |
| Main governance read-only during run | Task 1, Task 4 (Claude instructions). Test 8 verifies. |
| Layer A coverage evaluation (W4.5) | Task 2 (DEVELOPMENT-PROTOCOL.md), Task 4 (prompt reminder) |
| Layer B mechanical check reads tasks.md | Task 5 (`is_main_task_complete`) |
| Merge protocol document | Task 6 |
| Merge protocol installed by both bootstrap paths | Task 7 |
| Test fixtures + cmd_test exercise new model | Task 8 |
| Idempotency marker `## Ingested` in log.md | Task 6 (Step 7 of merge protocol) |
| Bug regression: orchestra completion loop | Task 5 (root fix) + Task 8 (regression test) |

No gaps.

---

## Notes on TDD

This codebase is bash + markdown. Where TDD adds value (the new `is_main_task_complete` function), Task 5 includes a standalone unit test before integration. For prompt-text and template-prose changes, the integration test (`orchestra test`) is the verification mechanism — it runs a real session against the new protocol end-to-end. Task 8's verification of "main TODO.md unchanged after test run" is the regression check that the protocol rule is being enforced in practice, not just stated.
