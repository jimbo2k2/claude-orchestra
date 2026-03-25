#!/bin/bash
# orchestrator.sh — Manages autonomous multi-session Claude Code workflows
# Run this in a tmux session on your remote server.
#
# Usage:
#   cd /path/to/your/project
#   orchestra run     (preferred — via the CLI wrapper)
#   — or —
#   ~/claude-scripts/orchestrator.sh
#
# The script will keep spawning Claude Code sessions until either:
#   - All tasks in .orchestra/TODO.md are complete
#   - Claude signals COMPLETE
#   - MAX_SESSIONS is reached
#   - Too many consecutive crashes occur
#   - A BLOCKED signal is received (needs human input)

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

MAX_SESSIONS="${MAX_SESSIONS:-10}"              # Safety limit on total sessions
MAX_CONSECUTIVE_CRASHES="${MAX_CONSECUTIVE_CRASHES:-3}"  # Abort after this many crashes in a row
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-15}"     # Pause between normal handovers
CRASH_COOLDOWN_SECONDS="${CRASH_COOLDOWN_SECONDS:-30}"  # Longer pause after crash recovery
NOTIFY_WEBHOOK="${NOTIFY_WEBHOOK:-}"           # Optional webhook (Telegram, Slack, etc.)

# ─── Clear nested-session guard ──────────────────────────────────────────────
# When orchestra is invoked from within a Claude Code session (e.g. user asks
# Claude to start orchestra), the CLAUDECODE env var is inherited. This causes
# `claude -p` to refuse to launch ("cannot be launched inside another session").
# Orchestra sessions are independent — clear the guard.
unset CLAUDECODE

# ─── Ensure we're in a git repo ───────────────────────────────────────────────

if ! git rev-parse --show-toplevel &>/dev/null; then
    echo "ERROR: Not in a git repository. Run this from your project root."
    exit 1
fi

PROJECT_DIR="$(git rev-parse --show-toplevel)"
STATE_DIR="${STATE_DIR:-${PROJECT_DIR}/.orchestra}"
LOG_DIR="${LOG_DIR:-${STATE_DIR}/session-logs}"

cd "$PROJECT_DIR"
mkdir -p "$LOG_DIR"

# ─── Load config ────────────────────────────────────────────────────────────
SCRIPT_DIR_ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR_ORCH/config.sh"
load_orchestra_config "$PROJECT_DIR" || exit 1

# ─── Pre-flight checks ─────────────────────────────────────────────────────
if ! command -v claude &>/dev/null; then
    echo "ERROR: Claude Code CLI not found. Install with: npm install -g @anthropic-ai/claude-code"
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq not found. Install with: sudo apt-get install jq"
    exit 1
fi

preflight_check || exit 1
check_eligible_tasks || exit 1

# ─── Lockfile ───────────────────────────────────────────────────────────────
LOCKFILE="$STATE_DIR/orchestra.lock"
cleanup_lock() { rm -f "$LOCKFILE"; }

if [ -f "$LOCKFILE" ]; then
    LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null)
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "ERROR: Another orchestrator is already running (PID $LOCK_PID)." >&2
        echo "If stale, delete $LOCKFILE" >&2
        exit 1
    else
        echo "WARNING: Stale lockfile (PID $LOCK_PID not running). Removing."
        rm -f "$LOCKFILE"
    fi
fi
echo $$ > "$LOCKFILE"

# ─── Notification helper ─────────────────────────────────────────────────────

notify() {
    local message="$1"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $message"
    if [ -n "$NOTIFY_WEBHOOK" ]; then
        curl -s -X POST "$NOTIFY_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "{\"text\": \"$message\"}" &>/dev/null || true
    fi
}

# ─── Configure lean settings for autonomous sessions ─────────────────────────
# Back up interactive settings and install autonomous config (no heavy plugins)
CLAUDE_SETTINGS="$PROJECT_DIR/.claude/settings.json"
CLAUDE_SETTINGS_BACKUP="$PROJECT_DIR/.claude/settings.interactive.json"

if [ -f "$CLAUDE_SETTINGS" ]; then
    cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS_BACKUP"
fi

AUTONOMOUS_SETTINGS="$(dirname "$(realpath "$0")")/../templates/settings-autonomous.json"
if [ -f "$AUTONOMOUS_SETTINGS" ]; then
    mkdir -p "$PROJECT_DIR/.claude"
    cp "$AUTONOMOUS_SETTINGS" "$CLAUDE_SETTINGS"
    notify "Installed autonomous settings (lean plugin set)"
fi

restore_settings() {
    if [ -f "$CLAUDE_SETTINGS_BACKUP" ]; then
        cp "$CLAUDE_SETTINGS_BACKUP" "$CLAUDE_SETTINGS"
        rm -f "$CLAUDE_SETTINGS_BACKUP"
    fi
}

# ─── State file change detection ─────────────────────────────────────────────
# Snapshots state file checksums so we can detect if a crashed session
# managed to update them before dying.

snapshot_state_files() {
    STATE_SNAPSHOT=""
    # Checksum governance files + HANDOVER (HANDOVER included for stall detection)
    for f in "$TODO_FILE" "$DECISIONS_FILE" "$CHANGELOG_FILE" "$STATE_DIR/HANDOVER.md"; do
        if [ -f "$f" ]; then
            STATE_SNAPSHOT="$STATE_SNAPSHOT$(md5sum "$f")"
        fi
    done
    echo "$STATE_SNAPSHOT"
}

state_files_changed() {
    local before="$1"
    local after
    after=$(snapshot_state_files)
    [ "$before" != "$after" ]
}

# ─── Recovery commit ─────────────────────────────────────────────────────────
# After a crash, commit whatever work was staged or modified.

recovery_commit() {
    local session_num="$1"
    git add -u 2>/dev/null || true
    # Stage governance files from config paths
    for f in "$TODO_FILE" "$DECISIONS_FILE" "$CHANGELOG_FILE"; do
        [ -f "$f" ] && git add "$f" 2>/dev/null || true
    done
    # Stage operational files
    for f in HANDOVER.md INBOX.md; do
        [ -f "$STATE_DIR/$f" ] && git add "$STATE_DIR/$f" 2>/dev/null || true
    done
    if ! git diff --cached --quiet 2>/dev/null; then
        # --no-verify is intentional: recovery commits bypass hooks to avoid
        # recursive verification (verify-completion.sh would trigger on the commit)
        git commit -m "auto: recovery commit after session $session_num crash" --no-verify 2>/dev/null || true
        notify "Recovery commit saved work from crashed session $session_num"
        return 0
    fi
    return 1
}

# ─── Session prompts ──────────────────────────────────────────────────────────
#
# v2: Three-tier planning with governance protocols and codewriting loop.
# Sessions read config-mapped governance files, execute the task loop, and
# update T/D/C-numbered entries before exiting.

read -r -d '' SESSION_PROMPT << 'PROMPT_EOF' || true
You are an autonomous Claude Code session managed by Orchestra v2. You will
read project state, execute tasks from a three-tier planning system, update
governance files with numbered entries, and exit with a signal.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
UBIQUITOUS LANGUAGE — Key terms used throughout this prompt
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Session: A single Claude Code headless invocation, from spawn to exit signal.
Task: A T-numbered entry in TODO.md with Status, Tier, optional Parent/Depends.
Strategic Task: Tier 1, human-authored, coarse-grained. Triggers decomposition.
Tactical Task: Tier 2, Claude-decomposed from a strategic task. Screen/component scope.
Tertiary Task: Tier 3, further decomposition of a tactical task. Max depth.
Decision: A D-numbered entry in DECISIONS.md recording a choice and alternatives.
Changelog Entry: A C-numbered entry in CHANGELOG.md recording what changed and why.
Task Loop: The outer loop — pick task, execute, update governance, check inbox, repeat.
Codewriting Loop: The inner loop for implementation — write, review, test, debug.
Standing AC: Permanent acceptance criteria in standing-ac.md (human-authored).
Task AC: Per-task acceptance criteria generated under standing AC categories.
Decomposition Review: Internal consistency check after decomposition (max 2 retries).
Plan Coherence Check: External validation — alignment with project goals and language.

Task statuses:
  OPEN — ready for pickup (default for new tasks)
  IN_PROGRESS — a session is actively working on it
  COMPLETE — work finished and verified
  BLOCKED — cannot proceed without human input (reason noted)
  PROPOSED — created by decomposition when scope expansion detected; skipped until
              a human changes status to OPEN

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
STEP 1 — READ PROJECT STATE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1a. Read .orchestra/config to find all file paths (governance, plan, toolchain,
    standing AC). All subsequent file reads use paths from config.
1b. Read the three governance files — one read each:
    - TODO file: contains archived summary index + current task detail
    - DECISIONS file: contains archived summary index + current decisions
    - CHANGELOG file: contains archived summary index + current entries
1c. Read .orchestra/HANDOVER.md (previous session context)
1d. Read .orchestra/INBOX.md — if unprocessed messages exist in the "Messages"
    section, follow those instructions first, then move them to "Processed".
    If a message contradicts the current plan or an in-progress task, complete
    governance cleanup for any work done, write a HANDOVER note explaining the
    contradiction, and exit BLOCKED.
1e. Read the strategic plan file (PLAN_FILE from config) — understand goals,
    constraints, and acceptance criteria for the current build.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
STEP 2 — TASK LOOP (outer loop)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Repeat until exit condition:

2a. PICK NEXT ELIGIBLE TASK
    Eligible = Status is OPEN AND all tasks in Depends are COMPLETE.
    Select by T-number order (lowest eligible first).
    Edge cases:
    - TODO has no entries at all → exit BLOCKED (empty file = misconfiguration)
    - All tasks are COMPLETE → exit COMPLETE
    - All remaining tasks are BLOCKED or depend on BLOCKED tasks → exit BLOCKED
    - No eligible tasks but some are IN_PROGRESS from a crashed session →
      treat the lowest IN_PROGRESS task as eligible (resume it)

2b. SET STATUS TO IN_PROGRESS immediately in TODO.md.

2c. ROUTE BY TIER:

    ── If Tier 1 (strategic task, no Parent field) ──
    Run TACTICAL DECOMPOSITION (see Step 3 below).
    After decomposition passes quality gates, execute the first tactical task.

    ── If Tier 2 or Tier 3 ──
    Execute directly:
    - If the task involves code changes → enter CODEWRITING LOOP (Step 4)
    - If planning/docs/config only → execute directly, no codewriting loop

2d. UPDATE GOVERNANCE after task completion:
    - TODO: set task status to COMPLETE, add a brief completion note
    - Parent check: if the completed task has a Parent, check whether ALL
      sibling tasks under that parent are now COMPLETE. If so, mark the parent
      COMPLETE automatically. Recurse upward if the parent's parent should
      also complete.
    - DECISIONS: add a D-numbered entry for every non-trivial choice made
      during this task. Include alternatives considered. Use the next sequential
      D-number (check the <!-- Next number: DXXX --> comment).
    - CHANGELOG: add a C-numbered entry for the work completed. Link to the
      T-number and any D-numbers. Use the next sequential C-number. Include
      the Files: field listing files created or modified.

2e. READ INBOX.md between tasks — check for new human messages.
    Process any new messages, mark as read.
    If a message contradicts the current plan or an in-progress task:
    - Complete governance cleanup for work already done
    - Write HANDOVER note explaining the contradiction
    - Exit BLOCKED

2f. CAPACITY CHECK:
    Estimate context window usage.
    - If sufficient capacity AND next eligible task is appropriate → loop to 2a
    - If low capacity OR next task is complex → proceed to Step 5 (exit)
    When in doubt, exit — clean handover beats running out of context.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
STEP 3 — TACTICAL DECOMPOSITION (when picking up a Tier 1 task)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

3a. Read the plan file (PLAN_FILE) and any relevant bounded context docs
    referenced in the plan (data models, module definitions, published language).

3b. Generate tactical tasks:
    - Each gets the next sequential T-number
    - Set Tier: 2, Parent: <strategic task T-number>
    - Set Depends: links where execution order matters
    - Set Status: OPEN
    - Write them into TODO.md under the current tasks section

3c. DECOMPOSITION REVIEW (internal consistency):
    - Are the tasks collectively sufficient to satisfy the parent strategic task?
    - Are dependencies correctly ordered (no circular refs)?
    - Is there overlap or duplication between tasks?
    - Maximum 2 retries if issues found. If still failing → mark strategic task
      BLOCKED with diagnostic note and exit the decomposition.

3d. PLAN COHERENCE CHECK (external validation):
    - Does the decomposition align with the strategic plan's goals/constraints?
    - Is it consistent with the bounded context's data model and module definition?
    - Do naming choices follow PUBLISHED-LANGUAGE.md?
    - Are cross-context dependencies accounted for?
    - Does the work fit the project's current phase?
    Outcomes:
    - Pass → execute first tactical task immediately
    - Scope expansion detected → flag in INBOX.md, continue with safe subset
      (tasks directly implied by the plan). Write excluded tasks as PROPOSED
      with a note referencing the INBOX flag.
    - Fundamentally incoherent → mark strategic task BLOCKED, exit BLOCKED

3e. If a tactical task proves more complex than expected during execution,
    decompose it further into Tier 3 (tertiary) tasks using the same pattern.
    Three tiers is the maximum — if a fourth level would be needed, mark
    BLOCKED (the strategic plan was too ambitious for a single task).

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
STEP 4 — CODEWRITING LOOP (inner loop for implementation tasks)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

For each tactical or tertiary task that involves code changes:

4a. GENERATE TASK AC
    Read standing-ac.md (STANDING_AC_FILE from config).
    Write task-level acceptance criteria as children under the standing AC
    categories. Record them in the task detail in TODO.md before implementation.

4b. WRITE CODE
    Read toolchain.md (TOOLCHAIN_FILE from config) for build, test, and
    capture commands and conventions.
    Implement the component/hook/screen/query/migration.

4c. CODE REVIEW (mandatory self-review pass)
    Re-read every file created or modified for this task.
    Check for: missing imports, wrong variable names, hardcoded values that
    should reference constants/config, unclosed tags/brackets, incorrect
    function signatures, props that don't match interfaces, SQL column names
    that don't match the schema, incorrect platform-specific code.
    Run the build command from toolchain.md to confirm compilation.
    Produce an issue list with severity ratings.

4d. CONDITIONAL SECOND PASS
    If code review found issues:
    - Fix all issues
    - Re-run code review
    If clean (or clean after fix) → continue to UI test.

4e. UI TEST (if applicable — skip for non-UI tasks)
    Read toolchain.md for the exact serve and capture commands.
    a. Ensure dev server is running (start command from toolchain).
       If it fails to start → mark task BLOCKED ("build failed"), exit loop.
    b. Run the capture/test tool at the viewport specified in toolchain.
       If the tool crashes → mark task BLOCKED ("UI test infra failure"), exit loop.
    c. Navigate to the screen under test.
    d. Two feedback channels:
       - Visual: screenshot capture → analyse layout/styling
       - Structural: DOM query via data-testid → assert elements present
    e. Data verification: query database to confirm data operations if applicable.
    f. Evaluate against Standing AC + Task AC.

4f. DEBUG PASS (maximum 3 iterations)
    If failures detected at 4e:
    - Diagnose: layout error vs logic error vs state error
    - Fix root cause
    - Loop back to 4e (UI test)
    If all acceptance criteria pass:
    - Task is done — exit codewriting loop, return to task loop step 2d
    If 3 debug iterations exhausted without passing:
    - Mark task BLOCKED with diagnostic note listing what was attempted
    - Write partial CHANGELOG entry noting the attempts
    - Exit codewriting loop, return to task loop step 2d

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
STEP 5 — STATE FILE UPDATES (before exiting)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

5a. Run /compact to free context.

5b. TODO.md: verify all tasks you completed this session show Status: COMPLETE
    with T-numbers. Ensure any decomposed tasks are written with correct Tier,
    Parent, Depends, and Status fields.

5c. DECISIONS.md: add D-numbered entries for all choices made this session.
    Each entry must include: Date, Status (ACTIVE), Context (bounded context
    code if applicable), Detail, and Alternatives considered.

5d. CHANGELOG.md: add C-numbered entries for all changes made this session.
    Each entry must include: Date, Task (T-number), Decision (D-numbers if
    applicable), Type (FEATURE/FIX/REFACTOR/CONFIG/DOCS), Files (list of
    files touched), Summary.

5e. HANDOVER.md: overwrite with:
    - What was accomplished (T-numbers completed, D-numbers recorded)
    - What's next (next eligible task by T-number, brief description)
    - Gotchas or context the next session needs
    - Model recommendation: model:effort (default opus:high — only downgrade
      to sonnet:standard for mechanical tasks like config changes, simple file
      moves, or status updates)

5f. .orchestra/COMMIT_MSG: write a single-line commit message, max 68 chars.
    Reference T-numbers where possible. Example:
    "Build PostCard component with tag display (T042)"

5g. Check if any governance file exceeds its archiving threshold. If so, read
    the protocol file (TODO_PROTOCOL, DECISIONS_PROTOCOL, or CHANGELOG_PROTOCOL
    from config) and perform the archive as a housekeeping step.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
STEP 6 — EXIT SIGNAL
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Your final output line must be EXACTLY one of these three words:
- HANDOVER — you completed one or more tasks but eligible tasks remain
- COMPLETE — all tasks in TODO are COMPLETE
- BLOCKED — you need human input (reason written to INBOX.md and HANDOVER.md)
PROMPT_EOF

# ─── Recovery prompt ──────────────────────────────────────────────────────────
# Used when the previous session crashed. Prepends damage assessment to the
# normal task loop.

read -r -d '' RECOVERY_PROMPT << 'PROMPT_EOF' || true
You are an autonomous Claude Code session managed by Orchestra v2. The previous
session CRASHED — there may be partial or broken work. You must assess damage
before entering the normal task loop.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
UBIQUITOUS LANGUAGE — Key terms used throughout this prompt
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Session: A single Claude Code headless invocation, from spawn to exit signal.
Task: A T-numbered entry in TODO.md with Status, Tier, optional Parent/Depends.
Strategic Task: Tier 1, human-authored, coarse-grained. Triggers decomposition.
Tactical Task: Tier 2, Claude-decomposed from a strategic task. Screen/component scope.
Tertiary Task: Tier 3, further decomposition of a tactical task. Max depth.
Decision: A D-numbered entry in DECISIONS.md recording a choice and alternatives.
Changelog Entry: A C-numbered entry in CHANGELOG.md recording what changed and why.
Task Loop: The outer loop — pick task, execute, update governance, check inbox, repeat.
Codewriting Loop: The inner loop for implementation — write, review, test, debug.
Standing AC: Permanent acceptance criteria in standing-ac.md (human-authored).
Task AC: Per-task acceptance criteria generated under standing AC categories.
Decomposition Review: Internal consistency check after decomposition (max 2 retries).
Plan Coherence Check: External validation — alignment with project goals and language.

Task statuses:
  OPEN — ready for pickup (default for new tasks)
  IN_PROGRESS — a session is actively working on it
  COMPLETE — work finished and verified
  BLOCKED — cannot proceed without human input (reason noted)
  PROPOSED — created by decomposition when scope expansion detected; skipped until
              a human changes status to OPEN

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
STEP 0 — DAMAGE ASSESSMENT (recovery only — do this BEFORE the normal flow)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

0a. Read .orchestra/config to find all file paths.

0b. Run the build command from toolchain.md (TOOLCHAIN_FILE in config).
    Does the project compile? Record the result.

0c. Check governance files for consistency:
    - TODO.md: are there half-written entries? Is the next-number comment correct?
    - DECISIONS.md: same checks — incomplete entries, correct next-number?
    - CHANGELOG.md: same checks.
    If any governance file has corrupt or incomplete entries, repair them:
    - Complete partial entries if the intent is clear
    - Remove fragments if the intent is unclear
    - Fix next-number comments

0d. Run git status — check for uncommitted work from the crashed session.
    If there are staged or unstaged changes, review them to understand what
    the previous session was working on.

0e. For any task marked IN_PROGRESS in TODO.md:
    - Inspect the actual state of the files the task would have touched
    - Determine: is the work mostly done (continue), partially done (evaluate),
      or barely started (redo from scratch)?
    - If continuing: pick up where it left off
    - If redoing: revert partial changes for that task, then start fresh

0f. If issues were found in 0b-0e, fix them and commit the repairs before
    proceeding. Use commit message: "fix: recovery repairs after session crash"

After damage assessment, proceed to the normal session flow below.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
STEP 1 — READ PROJECT STATE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1a. Read .orchestra/config to find all file paths (governance, plan, toolchain,
    standing AC). All subsequent file reads use paths from config.
    (Skip if already read during damage assessment.)
1b. Read the three governance files — one read each:
    - TODO file: contains archived summary index + current task detail
    - DECISIONS file: contains archived summary index + current decisions
    - CHANGELOG file: contains archived summary index + current entries
1c. Read .orchestra/HANDOVER.md (previous session context)
1d. Read .orchestra/INBOX.md — if unprocessed messages exist in the "Messages"
    section, follow those instructions first, then move them to "Processed".
    If a message contradicts the current plan or an in-progress task, complete
    governance cleanup for any work done, write a HANDOVER note explaining the
    contradiction, and exit BLOCKED.
1e. Read the strategic plan file (PLAN_FILE from config) — understand goals,
    constraints, and acceptance criteria for the current build.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
STEP 2 — TASK LOOP (outer loop)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Repeat until exit condition:

2a. PICK NEXT ELIGIBLE TASK
    Eligible = Status is OPEN AND all tasks in Depends are COMPLETE.
    Select by T-number order (lowest eligible first).
    Edge cases:
    - TODO has no entries at all → exit BLOCKED (empty file = misconfiguration)
    - All tasks are COMPLETE → exit COMPLETE
    - All remaining tasks are BLOCKED or depend on BLOCKED tasks → exit BLOCKED
    - No eligible tasks but some are IN_PROGRESS from a crashed session →
      treat the lowest IN_PROGRESS task as eligible (resume it)

2b. SET STATUS TO IN_PROGRESS immediately in TODO.md.

2c. ROUTE BY TIER:

    ── If Tier 1 (strategic task, no Parent field) ──
    Run TACTICAL DECOMPOSITION (see Step 3 below).
    After decomposition passes quality gates, execute the first tactical task.

    ── If Tier 2 or Tier 3 ──
    Execute directly:
    - If the task involves code changes → enter CODEWRITING LOOP (Step 4)
    - If planning/docs/config only → execute directly, no codewriting loop

2d. UPDATE GOVERNANCE after task completion:
    - TODO: set task status to COMPLETE, add a brief completion note
    - Parent check: if the completed task has a Parent, check whether ALL
      sibling tasks under that parent are now COMPLETE. If so, mark the parent
      COMPLETE automatically. Recurse upward if the parent's parent should
      also complete.
    - DECISIONS: add a D-numbered entry for every non-trivial choice made
      during this task. Include alternatives considered. Use the next sequential
      D-number (check the <!-- Next number: DXXX --> comment).
    - CHANGELOG: add a C-numbered entry for the work completed. Link to the
      T-number and any D-numbers. Use the next sequential C-number. Include
      the Files: field listing files created or modified.

2e. READ INBOX.md between tasks — check for new human messages.
    Process any new messages, mark as read.
    If a message contradicts the current plan or an in-progress task:
    - Complete governance cleanup for work already done
    - Write HANDOVER note explaining the contradiction
    - Exit BLOCKED

2f. CAPACITY CHECK:
    Estimate context window usage.
    - If sufficient capacity AND next eligible task is appropriate → loop to 2a
    - If low capacity OR next task is complex → proceed to Step 5 (exit)
    When in doubt, exit — clean handover beats running out of context.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
STEP 3 — TACTICAL DECOMPOSITION (when picking up a Tier 1 task)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

3a. Read the plan file (PLAN_FILE) and any relevant bounded context docs
    referenced in the plan (data models, module definitions, published language).

3b. Generate tactical tasks:
    - Each gets the next sequential T-number
    - Set Tier: 2, Parent: <strategic task T-number>
    - Set Depends: links where execution order matters
    - Set Status: OPEN
    - Write them into TODO.md under the current tasks section

3c. DECOMPOSITION REVIEW (internal consistency):
    - Are the tasks collectively sufficient to satisfy the parent strategic task?
    - Are dependencies correctly ordered (no circular refs)?
    - Is there overlap or duplication between tasks?
    - Maximum 2 retries if issues found. If still failing → mark strategic task
      BLOCKED with diagnostic note and exit the decomposition.

3d. PLAN COHERENCE CHECK (external validation):
    - Does the decomposition align with the strategic plan's goals/constraints?
    - Is it consistent with the bounded context's data model and module definition?
    - Do naming choices follow PUBLISHED-LANGUAGE.md?
    - Are cross-context dependencies accounted for?
    - Does the work fit the project's current phase?
    Outcomes:
    - Pass → execute first tactical task immediately
    - Scope expansion detected → flag in INBOX.md, continue with safe subset
      (tasks directly implied by the plan). Write excluded tasks as PROPOSED
      with a note referencing the INBOX flag.
    - Fundamentally incoherent → mark strategic task BLOCKED, exit BLOCKED

3e. If a tactical task proves more complex than expected during execution,
    decompose it further into Tier 3 (tertiary) tasks using the same pattern.
    Three tiers is the maximum — if a fourth level would be needed, mark
    BLOCKED (the strategic plan was too ambitious for a single task).

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
STEP 4 — CODEWRITING LOOP (inner loop for implementation tasks)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

For each tactical or tertiary task that involves code changes:

4a. GENERATE TASK AC
    Read standing-ac.md (STANDING_AC_FILE from config).
    Write task-level acceptance criteria as children under the standing AC
    categories. Record them in the task detail in TODO.md before implementation.

4b. WRITE CODE
    Read toolchain.md (TOOLCHAIN_FILE from config) for build, test, and
    capture commands and conventions.
    Implement the component/hook/screen/query/migration.

4c. CODE REVIEW (mandatory self-review pass)
    Re-read every file created or modified for this task.
    Check for: missing imports, wrong variable names, hardcoded values that
    should reference constants/config, unclosed tags/brackets, incorrect
    function signatures, props that don't match interfaces, SQL column names
    that don't match the schema, incorrect platform-specific code.
    Run the build command from toolchain.md to confirm compilation.
    Produce an issue list with severity ratings.

4d. CONDITIONAL SECOND PASS
    If code review found issues:
    - Fix all issues
    - Re-run code review
    If clean (or clean after fix) → continue to UI test.

4e. UI TEST (if applicable — skip for non-UI tasks)
    Read toolchain.md for the exact serve and capture commands.
    a. Ensure dev server is running (start command from toolchain).
       If it fails to start → mark task BLOCKED ("build failed"), exit loop.
    b. Run the capture/test tool at the viewport specified in toolchain.
       If the tool crashes → mark task BLOCKED ("UI test infra failure"), exit loop.
    c. Navigate to the screen under test.
    d. Two feedback channels:
       - Visual: screenshot capture → analyse layout/styling
       - Structural: DOM query via data-testid → assert elements present
    e. Data verification: query database to confirm data operations if applicable.
    f. Evaluate against Standing AC + Task AC.

4f. DEBUG PASS (maximum 3 iterations)
    If failures detected at 4e:
    - Diagnose: layout error vs logic error vs state error
    - Fix root cause
    - Loop back to 4e (UI test)
    If all acceptance criteria pass:
    - Task is done — exit codewriting loop, return to task loop step 2d
    If 3 debug iterations exhausted without passing:
    - Mark task BLOCKED with diagnostic note listing what was attempted
    - Write partial CHANGELOG entry noting the attempts
    - Exit codewriting loop, return to task loop step 2d

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
STEP 5 — STATE FILE UPDATES (before exiting)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

5a. Run /compact to free context.

5b. TODO.md: verify all tasks you completed this session show Status: COMPLETE
    with T-numbers. Ensure any decomposed tasks are written with correct Tier,
    Parent, Depends, and Status fields.

5c. DECISIONS.md: add D-numbered entries for all choices made this session.
    Each entry must include: Date, Status (ACTIVE), Context (bounded context
    code if applicable), Detail, and Alternatives considered.

5d. CHANGELOG.md: add C-numbered entries for all changes made this session.
    Each entry must include: Date, Task (T-number), Decision (D-numbers if
    applicable), Type (FEATURE/FIX/REFACTOR/CONFIG/DOCS), Files (list of
    files touched), Summary.

5e. HANDOVER.md: overwrite with:
    - What was accomplished (T-numbers completed, D-numbers recorded)
    - What's next (next eligible task by T-number, brief description)
    - Gotchas or context the next session needs
    - Model recommendation: model:effort (default opus:high — only downgrade
      to sonnet:standard for mechanical tasks like config changes, simple file
      moves, or status updates)
    - Note: this was a RECOVERY session — mention any repairs made in Step 0

5f. .orchestra/COMMIT_MSG: write a single-line commit message, max 68 chars.
    Reference T-numbers where possible. Example:
    "Build PostCard component with tag display (T042)"

5g. Check if any governance file exceeds its archiving threshold. If so, read
    the protocol file (TODO_PROTOCOL, DECISIONS_PROTOCOL, or CHANGELOG_PROTOCOL
    from config) and perform the archive as a housekeeping step.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
STEP 6 — EXIT SIGNAL
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Your final output line must be EXACTLY one of these three words:
- HANDOVER — you completed one or more tasks but eligible tasks remain
- COMPLETE — all tasks in TODO are COMPLETE
- BLOCKED — you need human input (reason written to INBOX.md and HANDOVER.md)
PROMPT_EOF

# ─── Main loop ────────────────────────────────────────────────────────────────

# ─── RAM monitor ─────────────────────────────────────────────────────────────
# Background process that logs memory usage every 10s and captures top processes
# when available RAM drops below threshold. Killed on orchestrator exit.

RAM_LOG="$LOG_DIR/ram.log"
RAM_LOW_THRESHOLD_KB="${RAM_LOW_THRESHOLD_KB:-512000}"  # 500MB default

start_ram_monitor() {
    (
        echo "# RAM monitor started $(date -u +%Y-%m-%dT%H:%M:%SZ) (threshold: ${RAM_LOW_THRESHOLD_KB}kB)" >> "$RAM_LOG"
        while true; do
            if [ -f /proc/meminfo ]; then
                # Linux
                avail_kb=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
                total_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
                used_kb=$((total_kb - avail_kb))
                pct=$((used_kb * 100 / total_kb))
                echo "$(date -u +%H:%M:%S) used:${used_kb}kB avail:${avail_kb}kB (${pct}%)" >> "$RAM_LOG"

                if [ "$avail_kb" -lt "$RAM_LOW_THRESHOLD_KB" ]; then
                    echo "=== LOW RAM WARNING $(date -u +%Y-%m-%dT%H:%M:%SZ) avail:${avail_kb}kB ===" >> "$RAM_LOG"
                    ps aux --sort=-%mem | head -8 >> "$RAM_LOG"
                fi
            else
                # macOS fallback (for local testing)
                vm_stat 2>/dev/null | head -5 >> "$RAM_LOG" || echo "$(date -u +%H:%M:%S) /proc/meminfo not available" >> "$RAM_LOG"
            fi
            sleep 10
        done
    ) &
    RAM_MONITOR_PID=$!
}

stop_ram_monitor() {
    if [ -n "${RAM_MONITOR_PID:-}" ] && kill -0 "$RAM_MONITOR_PID" 2>/dev/null; then
        kill "$RAM_MONITOR_PID" 2>/dev/null || true
        wait "$RAM_MONITOR_PID" 2>/dev/null || true
    fi
}

trap 'stop_ram_monitor; restore_settings; cleanup_lock' EXIT
start_ram_monitor

# ─── Main loop state ─────────────────────────────────────────────────────────

SESSION_COUNT=0
CONSECUTIVE_CRASHES=0
TOTAL_CRASHES=0
START_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
USE_RECOVERY_PROMPT=false

notify "Orchestrator started at $START_TIME"
notify "   Project: $(basename "$PROJECT_DIR")"
INITIAL_OPEN=$(grep -c 'Status:.*OPEN' "$TODO_FILE" 2>/dev/null) || INITIAL_OPEN=0
notify "   Tasks: $INITIAL_OPEN open in $TODO_FILE"
notify "   Max sessions: $MAX_SESSIONS | Max consecutive crashes: $MAX_CONSECUTIVE_CRASHES"

while [ "$SESSION_COUNT" -lt "$MAX_SESSIONS" ]; do
    SESSION_COUNT=$((SESSION_COUNT + 1))
    SESSION_TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
    SESSION_LOG="$LOG_DIR/session-$(printf '%03d' $SESSION_COUNT)-$SESSION_TIMESTAMP.json"

    # Choose prompt based on whether previous session crashed
    if [ "$USE_RECOVERY_PROMPT" = true ]; then
        CURRENT_PROMPT="$RECOVERY_PROMPT"
        notify "Starting RECOVERY session $SESSION_COUNT/$MAX_SESSIONS (after crash)"
    else
        CURRENT_PROMPT="$SESSION_PROMPT"
        notify "Starting session $SESSION_COUNT/$MAX_SESSIONS"
    fi

    # Snapshot state files before the session runs
    PRE_STATE=$(snapshot_state_files)

    # ─── Model selection ─────────────────────────────────────────────────────
    # Read model recommendation from HANDOVER.md (written by previous session)
    RECOMMENDED_MODEL=""
    if [ -f "$STATE_DIR/HANDOVER.md" ]; then
        RECOMMENDED_MODEL=$(grep -i 'model recommendation' "$STATE_DIR/HANDOVER.md" \
            | tail -1 | grep -oi 'opus\|sonnet' || echo "")
    fi

    # Default to sonnet (cheaper), use opus only when explicitly recommended
    # First session can be overridden via INITIAL_MODEL env var
    MODEL_FLAG=""
    if [ "$SESSION_COUNT" -eq 1 ] && [ -n "${INITIAL_MODEL:-}" ]; then
        MODEL_FLAG="--model ${INITIAL_MODEL}"
        notify "   Model: ${INITIAL_MODEL} (INITIAL_MODEL override)"
    elif [ "${RECOMMENDED_MODEL,,}" = "opus" ]; then
        MODEL_FLAG="--model opus"
        notify "   Model: opus (recommended by previous session)"
    else
        MODEL_FLAG="--model sonnet"
        notify "   Model: sonnet (default)"
    fi

    # ─── Run Claude Code in headless mode ─────────────────────────────────────
    # stream-json goes to the log file for full metadata;
    # a jq filter extracts readable text for the terminal.

    set +eo pipefail
    claude -p "$CURRENT_PROMPT" \
        $MODEL_FLAG \
        --output-format stream-json \
        --verbose \
        --dangerously-skip-permissions \
        2>&1 | tee "$SESSION_LOG" \
        | jq -r --unbuffered '
            if .type == "assistant" then
                (.message.content[]? | select(.type == "text") | .text) // empty
            elif .type == "result" then
                "\n--- Session result: \(.result // "no result") ---"
            else empty end
        ' 2>/dev/null
    EXIT_CODE=${PIPESTATUS[0]}
    set -eo pipefail

    # ─── Handle crash (non-zero exit) ─────────────────────────────────────────
    # Layer 3: Crash recovery — detect partial work, commit it, continue.

    if [ $EXIT_CODE -ne 0 ]; then
        CONSECUTIVE_CRASHES=$((CONSECUTIVE_CRASHES + 1))
        TOTAL_CRASHES=$((TOTAL_CRASHES + 1))

        notify "Session $SESSION_COUNT crashed (exit code $EXIT_CODE). Consecutive: $CONSECUTIVE_CRASHES/$MAX_CONSECUTIVE_CRASHES"

        # Check if the crashing session managed to update state files
        if state_files_changed "$PRE_STATE"; then
            notify "   State files were updated — partial work detected"
            recovery_commit "$SESSION_COUNT"
            USE_RECOVERY_PROMPT=false  # State is consistent, normal prompt is fine
        else
            # State files unchanged — check for staged or unstaged file changes
            STAGED_COUNT=$(git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
            MODIFIED_COUNT=$(git diff --name-only 2>/dev/null | wc -l | tr -d ' ')

            if [ "$STAGED_COUNT" -gt 0 ] || [ "$MODIFIED_COUNT" -gt 0 ]; then
                notify "   No state file updates, but $STAGED_COUNT staged / $MODIFIED_COUNT modified files"
                recovery_commit "$SESSION_COUNT"
                USE_RECOVERY_PROMPT=true  # State files are stale, recovery prompt needed
            else
                notify "   No work detected from crashed session"
                USE_RECOVERY_PROMPT=true  # Previous session produced nothing
            fi
        fi

        # Abort if too many consecutive crashes
        if [ "$CONSECUTIVE_CRASHES" -ge "$MAX_CONSECUTIVE_CRASHES" ]; then
            notify "$MAX_CONSECUTIVE_CRASHES consecutive crashes. Orchestrator stopping."
            notify "   Check $LOG_DIR for session logs. Last: $SESSION_LOG"
            exit 1
        fi

        notify "   Retrying in ${CRASH_COOLDOWN_SECONDS}s..."
        sleep "$CRASH_COOLDOWN_SECONDS"
        continue
    fi

    # ─── Session exited cleanly (exit code 0) ─────────────────────────────────

    CONSECUTIVE_CRASHES=0
    USE_RECOVERY_PROMPT=false

    # Extract exit signal from the stream-json result event
    FINAL=$(grep '"type":"result"' "$SESSION_LOG" | tail -1 | jq -r '.result // empty' 2>/dev/null || echo "")

    # ─── Detect stalled progress (clean exit but no state changes) ────────────
    # This catches sessions that ran but didn't actually do or record anything.

    if ! state_files_changed "$PRE_STATE"; then
        CONSECUTIVE_CRASHES=$((CONSECUTIVE_CRASHES + 1))
        notify "Session $SESSION_COUNT exited cleanly but state files unchanged. Stall $CONSECUTIVE_CRASHES/$MAX_CONSECUTIVE_CRASHES"

        if [ "$CONSECUTIVE_CRASHES" -ge "$MAX_CONSECUTIVE_CRASHES" ]; then
            notify "$MAX_CONSECUTIVE_CRASHES consecutive stalls. Orchestrator stopping."
            exit 1
        fi

        USE_RECOVERY_PROMPT=true
        sleep "$CRASH_COOLDOWN_SECONDS"
        continue
    fi

    # ─── Evaluate exit signal ─────────────────────────────────────────────────

    if echo "$FINAL" | grep -qi "COMPLETE"; then
        # Double-check: does TODO.md actually have no remaining tasks?
        REMAINING=$(grep -c '^\- \[ \]' "$STATE_DIR/TODO.md" 2>/dev/null) || REMAINING=0
        if [ "$REMAINING" -eq 0 ]; then
            notify "All tasks completed after $SESSION_COUNT sessions! ($TOTAL_CRASHES crashes recovered)"
            exit 0
        else
            notify "Claude signalled COMPLETE but $REMAINING tasks remain. Continuing..."
        fi
    fi

    if echo "$FINAL" | grep -qi "BLOCKED"; then
        notify "Session $SESSION_COUNT BLOCKED. Check .orchestra/HANDOVER.md for details."
        notify "   Orchestrator pausing. Resolve the issue and restart."
        exit 2
    fi

    # Check TODO.md for remaining tasks (source of truth, regardless of signal)
    REMAINING=$(grep -c '^\- \[ \]' "$STATE_DIR/TODO.md" 2>/dev/null) || REMAINING=0

    if [ "$REMAINING" -eq 0 ]; then
        notify "No remaining tasks in .orchestra/TODO.md after $SESSION_COUNT sessions."
        exit 0
    fi

    notify "Session $SESSION_COUNT handed over. $REMAINING tasks remain. Next in ${COOLDOWN_SECONDS}s..."
    sleep "$COOLDOWN_SECONDS"
done

# ─── Max sessions reached ─────────────────────────────────────────────────────

REMAINING=$(grep -c '^\- \[ \]' "$STATE_DIR/TODO.md" 2>/dev/null) || REMAINING=0
notify "Reached max session limit ($MAX_SESSIONS). $REMAINING tasks remain. $TOTAL_CRASHES crashes recovered."
exit 3
