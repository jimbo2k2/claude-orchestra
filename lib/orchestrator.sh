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

# ─── Pre-flight checks ───────────────────────────────────────────────────────

if ! command -v claude &>/dev/null; then
    echo "ERROR: Claude Code CLI not found. Install with: npm install -g @anthropic-ai/claude-code"
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq not found. Install with: sudo apt-get install jq"
    exit 1
fi

if [ ! -d "$STATE_DIR" ]; then
    echo "ERROR: .orchestra/ directory not found. Run 'orchestra init' first."
    exit 1
fi

for STATE_FILE in PLAN.md TODO.md CHANGELOG.md HANDOVER.md INBOX.md; do
    if [ ! -f "$STATE_DIR/$STATE_FILE" ]; then
        echo "ERROR: $STATE_FILE not found in .orchestra/. Run 'orchestra init' or create it manually."
        exit 1
    fi
done

if [ ! -f "$PROJECT_DIR/CLAUDE.md" ]; then
    echo "ERROR: CLAUDE.md not found in project root."
    exit 1
fi

# Check TODO.md actually has tasks
INITIAL_TASKS=$(grep -c '^\- \[ \]' "$STATE_DIR/TODO.md" 2>/dev/null) || INITIAL_TASKS=0
if [ "$INITIAL_TASKS" -eq 0 ]; then
    echo "ERROR: No incomplete tasks in .orchestra/TODO.md. Add tasks before starting."
    exit 1
fi

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

# ─── State file change detection ─────────────────────────────────────────────
# Snapshots state file checksums so we can detect if a crashed session
# managed to update them before dying.

snapshot_state_files() {
    STATE_SNAPSHOT=""
    for f in TODO.md CHANGELOG.md HANDOVER.md; do
        if [ -f "$STATE_DIR/$f" ]; then
            STATE_SNAPSHOT="$STATE_SNAPSHOT$(md5sum "$STATE_DIR/$f")"
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

    # Stage any modified tracked files (catches PostToolUse staged files
    # plus any state file updates Claude made before crashing)
    git add -u 2>/dev/null || true

    # Also stage state files explicitly
    for f in TODO.md CHANGELOG.md HANDOVER.md DECISIONS.md INBOX.md; do
        [ -f "$STATE_DIR/$f" ] && git add ".orchestra/$f" 2>/dev/null || true
    done

    if ! git diff --cached --quiet 2>/dev/null; then
        git commit -m "auto: recovery commit after session $session_num crash

This commit captures work from a session that exited abnormally.
Some changes may be incomplete. Check .orchestra/HANDOVER.md for context.
Time: $(date -u +%Y-%m-%dT%H:%M:%SZ)" --no-verify 2>/dev/null || true

        notify "Recovery commit saved work from crashed session $session_num"
        return 0
    fi
    return 1
}

# ─── Session prompts ──────────────────────────────────────────────────────────
#
# Layer 2: Multi-task sessions with context capacity check.
# Sessions complete one task, then evaluate whether to continue with the next.
# Detailed instructions and context management rules live in CLAUDE.md.

SESSION_PROMPT='You are starting an autonomous work session. Follow these steps exactly:

1. Read .orchestra/PLAN.md (skim for overall goal and acceptance criteria)
2. Read .orchestra/HANDOVER.md, then .orchestra/INBOX.md, then .orchestra/TODO.md
   Do NOT read .orchestra/CHANGELOG.md unless HANDOVER.md refers you to it for specific context
3. If .orchestra/INBOX.md has unprocessed messages, follow those instructions first
4. BEFORE starting work, classify the next task'"'"'s complexity:
   - SONNET tasks: Single file creation from clear spec, CRUD server actions, UI
     components with known patterns, config/manifest files, dependency installs,
     build verification, documentation updates, file renames
   - OPUS tasks: Cross-file reasoning, complex business logic with edge cases,
     data transformation with merging/linking, design audits across multiple files,
     cron job logic with idempotency, seed scripts with data relationships
   Default to SONNET. Only classify as OPUS when the task genuinely requires
   multi-step reasoning or judgment calls. Write your classification in
   .orchestra/HANDOVER.md under "Model recommendation for next task:" so the
   orchestrator can act on it.
5. Pick up the next incomplete task from .orchestra/TODO.md (the first unchecked item)
6. Complete that task fully.
7. Run tests after each significant change.

AFTER COMPLETING A TASK — Mandatory debug pass:
Before checking off ANY task, you MUST do a self-review:

PASS 1 (mandatory):
- Re-read every file you created or modified in this session
- Check for: missing imports, wrong variable names, hardcoded values that should
  reference constants/config, unclosed tags/brackets, incorrect function signatures,
  props that don'"'"'t match component interfaces, SQL column names that don'"'"'t match
  the schema, server actions missing "use server", client components missing
  "use client"
- Run the build/test command to confirm no regressions
- Rate the issues found on a 3-point scale:
  CLEAN — no issues found, or only trivial (whitespace, formatting)
  MINOR — 1-2 small issues (missing optional prop, imprecise type) that you fixed
  SIGNIFICANT — logic errors, broken data flow, missing functionality, wrong API
    usage, or 3+ minor issues

PASS 2 (conditional — only if Pass 1 rated SIGNIFICANT):
- After fixing all Pass 1 issues, do a second review focusing on:
  - Does the fix introduce new problems?
  - Does the component/action integrate correctly with existing code?
  - Are edge cases handled (empty state, error state, loading state)?
  - Run build/tests again
- If Pass 2 still finds issues, fix them but do NOT do a third pass — note
  remaining concerns in HANDOVER.md for the next session

Log your debug pass results in .orchestra/CHANGELOG.md:
  "Debug: CLEAN" or "Debug: MINOR (fixed X)" or "Debug: SIGNIFICANT → Pass 2 (fixed X, Y)"

AFTER DEBUG PASS — Context capacity check:
- Evaluate how much of your context window you have used so far (rough percentage)
- If you estimate you are BELOW 50% context usage AND the next TODO item is a
  straightforward task (single file creation, config change, CRUD actions, UI component
  from clear spec), then:
  a. Update .orchestra/TODO.md immediately (check off the completed task)
  b. Pick up the next incomplete task and continue working
  c. Repeat this check after each task
- If you are ABOVE 50% context usage, OR the next task requires complex reasoning
  (cross-file refactoring, business logic with edge cases, design audits across multiple
  files), then stop and proceed to state file updates below.
- When in doubt, stop — it is better to hand over cleanly than to run out of context.

CRITICAL — State file updates (do this BEFORE exiting):
- Run /compact to free context
- .orchestra/TODO.md: check off ALL tasks you completed this session
- .orchestra/CHANGELOG.md: append ONE session entry listing all completed tasks
- .orchestra/HANDOVER.md: overwrite with context the next session needs
- .orchestra/COMMIT_MSG: write a single-line commit message (max 68 chars) summarizing
  what you built this session, e.g. "Create pocket-money-balance component (R29)" or
  "Daily accrual cron with idempotent upsert (R27, R33)". Reference requirement numbers
  from TODO.md where possible.

Your final output line must be exactly one of:
- HANDOVER — you completed one or more tasks but more remain in .orchestra/TODO.md
- COMPLETE — all TODO items are done and tests pass
- BLOCKED — you need human input (explain in .orchestra/HANDOVER.md)'

# Recovery prompt — used when the previous session crashed
RECOVERY_PROMPT='You are starting an autonomous work session after a PREVIOUS SESSION CRASHED.

The previous session exited abnormally. There may be partial or broken work.

1. Read .orchestra/HANDOVER.md, .orchestra/TODO.md, and .orchestra/CHANGELOG.md
2. Run tests immediately to assess the state of the codebase
3. If tests fail, investigate and fix what the previous session broke
4. If tests pass, check whether the last TODO item was fully completed
5. Either finish the in-progress item or revert partial work cleanly
6. Then pick up the next incomplete task from .orchestra/TODO.md (first unchecked item)
7. Complete that task fully.
8. Run tests after each significant change.

AFTER COMPLETING A TASK — Mandatory debug pass:
Before checking off ANY task (including the crash fix), you MUST do a self-review:

PASS 1 (mandatory):
- Re-read every file you created or modified in this session
- Check for: missing imports, wrong variable names, hardcoded values that should
  reference constants/config, unclosed tags/brackets, incorrect function signatures,
  props that don'"'"'t match component interfaces, SQL column names that don'"'"'t match
  the schema, server actions missing "use server", client components missing
  "use client"
- Run the build/test command to confirm no regressions
- Rate the issues found on a 3-point scale:
  CLEAN — no issues found, or only trivial (whitespace, formatting)
  MINOR — 1-2 small issues (missing optional prop, imprecise type) that you fixed
  SIGNIFICANT — logic errors, broken data flow, missing functionality, wrong API
    usage, or 3+ minor issues

PASS 2 (conditional — only if Pass 1 rated SIGNIFICANT):
- After fixing all Pass 1 issues, do a second review focusing on:
  - Does the fix introduce new problems?
  - Does the component/action integrate correctly with existing code?
  - Are edge cases handled (empty state, error state, loading state)?
  - Run build/tests again
- If Pass 2 still finds issues, fix them but do NOT do a third pass — note
  remaining concerns in HANDOVER.md for the next session

Log your debug pass results in .orchestra/CHANGELOG.md:
  "Debug: CLEAN" or "Debug: MINOR (fixed X)" or "Debug: SIGNIFICANT → Pass 2 (fixed X, Y)"

AFTER DEBUG PASS — Context capacity check:
- Evaluate how much of your context window you have used so far (rough percentage)
- If you estimate you are BELOW 50% context usage AND the next TODO item is a
  straightforward task, then:
  a. Update .orchestra/TODO.md immediately (check off the completed task)
  b. Pick up the next incomplete task and continue working
  c. Repeat this check after each task
- If you are ABOVE 50% context usage, OR the next task requires complex reasoning,
  then stop and proceed to state file updates below.
- When in doubt, stop — it is better to hand over cleanly than to run out of context.

CRITICAL — State file updates (do this BEFORE exiting):
- Run /compact to free context
- .orchestra/TODO.md: check off ALL tasks you completed this session
- .orchestra/CHANGELOG.md: append ONE session entry listing all completed tasks.
  Note that this was a recovery session.
- .orchestra/HANDOVER.md: overwrite with context the next session needs
- .orchestra/COMMIT_MSG: write a single-line commit message (max 68 chars) summarizing
  what you built/fixed this session. Reference requirement numbers where possible.

Your final output line must be exactly one of:
- HANDOVER — you completed one or more tasks but more remain
- COMPLETE — all TODO items done and tests pass
- BLOCKED — needs human input (explain in .orchestra/HANDOVER.md)'

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

trap stop_ram_monitor EXIT
start_ram_monitor

# ─── Main loop state ─────────────────────────────────────────────────────────

SESSION_COUNT=0
CONSECUTIVE_CRASHES=0
TOTAL_CRASHES=0
START_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
USE_RECOVERY_PROMPT=false

notify "Orchestrator started at $START_TIME"
notify "   Project: $(basename "$PROJECT_DIR")"
notify "   Tasks: $INITIAL_TASKS incomplete in .orchestra/TODO.md"
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
