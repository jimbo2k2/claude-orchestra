#!/bin/bash
# orchestrator.sh — Manages autonomous multi-session Claude Code workflows
# Run this in a tmux session on your remote server.
#
# Usage:
#   cd /path/to/your/project
#   orchestra run     (preferred — via the CLI wrapper)
#   — or —
#   .orchestra/bin/orchestrator.sh
#
# The script will keep spawning Claude Code sessions until either:
#   - All tasks listed in config TASKS are marked COMPLETE
#   - Claude signals COMPLETE
#   - MAX_SESSIONS is reached
#   - Too many consecutive crashes occur
#   - A BLOCKED signal is received (needs human input)

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
# All settings come from .orchestra/config. No env var overrides.
# Values are loaded by load_orchestra_config() below.

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

cd "$PROJECT_DIR"

# ─── Load config (sets STATE_DIR if config provides it) ──────────────────────
source "$PROJECT_DIR/.orchestra/lib/config.sh"
load_orchestra_config "$PROJECT_DIR" || exit 1

# Default STATE_DIR after config load (config may have overridden it)
STATE_DIR="${STATE_DIR:-${PROJECT_DIR}/.orchestra}"
LOG_DIR="${STATE_DIR}/sessions"
mkdir -p "$LOG_DIR"

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
validate_toolchain_prereqs || exit 1
# check_eligible_tasks removed — tasks come from config TASKS field, not TODO.md OPEN scan

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
    if [ -n "${NOTIFY_WEBHOOK:-}" ]; then
        curl -s -X POST "${NOTIFY_WEBHOOK}" \
            -H "Content-Type: application/json" \
            -d "{\"text\": \"$message\"}" &>/dev/null || true
    fi
}

# ─── Settings ────────────────────────────────────────────────────────────────
# One settings.json for both interactive and Orchestra — no swap needed.
# The project's .claude/settings.json is used as-is.

# Optional webhook for notifications (not in config — set as env var if needed)
NOTIFY_WEBHOOK="${NOTIFY_WEBHOOK:-}"

# ─── Quota pacing ────────────────────────────────────────────────────────────
# Monitors subscription quota via the OAuth usage endpoint and rate_limit_event
# entries in session stream output. Pauses between sessions when quota is high.

QUOTA_STATE_FILE="$STATE_DIR/quota-state"
CREDENTIALS_FILE="${HOME}/.claude/.credentials.json"

# Fetch current quota utilization from the OAuth usage endpoint.
# Returns JSON: {"five_hour": N, "seven_day": N, "resets_at": "ISO8601"}
# Returns empty string on failure (endpoint unavailable, auth expired, rate-limited).
fetch_quota() {
    if [ ! -f "$CREDENTIALS_FILE" ]; then
        return 1
    fi

    local token
    token=$(python3 -c "import json; print(json.load(open('$CREDENTIALS_FILE'))['claudeAiOauth']['accessToken'])" 2>/dev/null) || return 1

    local response
    response=$(curl -s --max-time 10 \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null) || return 1

    # Validate response has expected structure
    if ! echo "$response" | jq -e '.five_hour.utilization' &>/dev/null; then
        return 1
    fi

    local five_hour seven_day resets_at
    five_hour=$(echo "$response" | jq -r '.five_hour.utilization // 0')
    seven_day=$(echo "$response" | jq -r '.seven_day.utilization // 0')
    resets_at=$(echo "$response" | jq -r '.five_hour.resets_at // empty')

    echo "{\"five_hour\": $five_hour, \"seven_day\": $seven_day, \"resets_at\": \"$resets_at\"}"
}

# Wait for quota to drop below threshold. Called between sessions when pacing is enabled.
# Sleeps until the 5-hour window resets, polling periodically to confirm.
wait_for_quota() {
    local quota_json
    quota_json=$(fetch_quota) || {
        notify "   Quota check failed (auth/network). Proceeding without pacing."
        return 0
    }

    local five_hour resets_at
    five_hour=$(echo "$quota_json" | jq -r '.five_hour')
    local seven_day
    seven_day=$(echo "$quota_json" | jq -r '.seven_day')
    resets_at=$(echo "$quota_json" | jq -r '.resets_at')

    notify "   Quota: 5h=${five_hour}% 7d=${seven_day}% (threshold: ${QUOTA_THRESHOLD}%)"

    if [ "$(echo "$five_hour >= $QUOTA_THRESHOLD" | bc -l)" -eq 1 ]; then
        # Calculate seconds until reset
        local reset_epoch now_epoch wait_seconds
        reset_epoch=$(date -d "$resets_at" +%s 2>/dev/null) || reset_epoch=0
        now_epoch=$(date +%s)
        wait_seconds=$((reset_epoch - now_epoch))

        if [ "$wait_seconds" -gt 0 ]; then
            local wait_minutes=$((wait_seconds / 60))
            local reset_time
            reset_time=$(date -d "$resets_at" '+%H:%M:%S UTC' 2>/dev/null || echo "$resets_at")
            notify "   5-hour quota at ${five_hour}% (>= ${QUOTA_THRESHOLD}%). Pausing until reset at $reset_time (~${wait_minutes}m)"

            # Sleep in intervals, re-checking quota periodically
            while [ "$wait_seconds" -gt 0 ]; do
                local sleep_for=$QUOTA_POLL_INTERVAL
                if [ "$wait_seconds" -lt "$sleep_for" ]; then
                    sleep_for=$((wait_seconds + 10))  # small buffer past reset
                fi
                sleep "$sleep_for"

                # Re-check quota
                quota_json=$(fetch_quota) || break
                five_hour=$(echo "$quota_json" | jq -r '.five_hour')
                resets_at=$(echo "$quota_json" | jq -r '.resets_at')

                if [ "$(echo "$five_hour < $QUOTA_THRESHOLD" | bc -l)" -eq 1 ]; then
                    notify "   Quota dropped to ${five_hour}%. Resuming."
                    return 0
                fi

                # Recalculate remaining wait
                reset_epoch=$(date -d "$resets_at" +%s 2>/dev/null) || break
                now_epoch=$(date +%s)
                wait_seconds=$((reset_epoch - now_epoch))
            done

            notify "   Quota window reset. Resuming."
        fi
    fi
}

# Extract the latest rate_limit_event from a session log and write to quota-state.
# Called after each session completes.
extract_session_quota() {
    local session_log="$1"
    if [ ! -f "$session_log" ]; then
        return
    fi

    # Find the last rate_limit_event in the session log
    local last_event
    last_event=$(grep '"rate_limit_event"' "$session_log" | tail -1 || echo "")
    if [ -z "$last_event" ]; then
        return
    fi

    # Write to quota state file for the orchestrator to read
    echo "$last_event" | jq -c '{
        utilization: .rate_limit_info.utilization,
        resetsAt: .rate_limit_info.resetsAt,
        rateLimitType: .rate_limit_info.rateLimitType,
        status: .rate_limit_info.status,
        timestamp: now | todate
    }' > "$QUOTA_STATE_FILE" 2>/dev/null || true
}

# ─── State file change detection ─────────────────────────────────────────────
# Snapshots state file checksums so we can detect if a crashed session
# managed to update them before dying.

snapshot_state_files() {
    # State = session branch HEAD. If the branch advances, state changed.
    # Falls back to main-tree file checksums if no session branch yet.
    if [ -n "${SESSION_BRANCH:-}" ] && git rev-parse --verify "$SESSION_BRANCH" >/dev/null 2>&1; then
        git rev-parse "$SESSION_BRANCH"
    else
        local snap=""
        for f in "$TODO_FILE" "$DECISIONS_FILE" "$CHANGELOG_FILE" "$STATE_DIR/HANDOVER.md"; do
            [ -f "$f" ] && snap="$snap$(md5sum "$f")"
        done
        echo "$snap"
    fi
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
You are an autonomous Claude Code session managed by Orchestra v2. Follow
DEVELOPMENT-PROTOCOL.md at the project root in auto-proceed mode.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SESSION SETUP
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

You are working in a **git worktree** — an isolated copy of the repo on its own
branch. Your main working tree is untouched. Create task branches with
`git checkout -b orchestra/<t-number>-<slug>` as normal. Push branches when done.
The orchestrator cleans up the worktree after your session exits.

1. Read __ORCH_CONFIG__ — **the TASKS field is the AUTHORITATIVE list of
   T-numbers you must work on this session. Nothing else overrides this.**
   The config also contains governance file paths and the protocol reference.
2. Read DEVELOPMENT-PROTOCOL.md — this is your authoritative task sequence.
   Follow it in auto-proceed mode (all gates auto-accept).
3. Read .orchestra/CLAUDE.md — session-specific rules for autonomous mode.
4. Read __STATE_DIR__/HANDOVER.md — **historical context only**. This describes
   what happened in PREVIOUS sessions. Do NOT confuse it with your current
   assignment. If HANDOVER says tasks were completed, those are done — your
   job is the NEW tasks listed in config TASKS, not re-verifying old ones.
5. Read __STATE_DIR__/INBOX.md — check for human messages. Process any unread
   messages before starting task work. After processing each message, MOVE it
   from the Messages section to the Processed section and add a brief response
   note. Do not leave processed messages in the Messages section.
   If a message contradicts your assigned tasks, write a HANDOVER note and
   exit BLOCKED.
6. Read the governance files (TODO, DECISIONS, CHANGELOG) at the paths in config.
   **Use these to find the DETAIL for each T-number in your TASKS list. Do not
   pick tasks from these files — your task list comes from config.**

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
TASK EXECUTION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Your assigned T-numbers are in the TASKS field of .orchestra/config. For each task:

1. Follow DEVELOPMENT-PROTOCOL.md Part 1 (steps 1-20) in auto-proceed mode.
   - All checkpoint gates auto-accept.
   - Decisions are logged as PROPOSED (human ratifies later).
   - New tasks discovered are logged as PROPOSED in TODO.md.
   - Commits go on a task branch, never on main.

   **Branching model (IMPORTANT):** Your worktree started on a session branch
   (look at `git branch --show-current` — it will be `orchestra/session-NNN-*`).
   For each task:
   a. `git checkout __SESSION_BRANCH__` — return to the session branch
   b. `git checkout -b orchestra/<t-number>-<slug>` — create task branch from
      current session state (which includes all previously completed tasks)
   c. Do the task work, commit, push the task branch
   d. After step 19 commit & push, merge the task branch back into the session
      branch so the next task sees the cumulative state:
         git checkout __SESSION_BRANCH__
         git merge orchestra/<t-number>-<slug>
      (This will be a fast-forward merge since the task branch was the only
      thing modifying the session branch.)

   This means each task branch exists independently on the remote (for per-task
   review) AND the session branch accumulates all completed work (for session-wide
   review and for downstream tasks to build on).

2. Create or update the run workspace at .orchestra/sessions/__RUN_NAME__/ with:
   - tasks.md — cumulative subtask list across all tasks in this run
   - log.md — cumulative session decisions, findings, parked issues
   If the files already exist from a previous session in this run, append to
   them rather than overwriting.

3. If a task has a genuine blocker you cannot resolve autonomously, mark it
   BLOCKED in TODO.md with a reason and move to the next task.

4. Between tasks (protocol step 20):
   a. Re-read __STATE_DIR__/INBOX.md for new human messages.
   b. Evaluate remaining context. If you have completed 3 or more tasks in
      this session, prefer a clean HANDOVER over risking context exhaustion.
   c. If continuing, return to step 1 for next task.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SESSION WRAP-UP
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Before exiting, follow DEVELOPMENT-PROTOCOL.md Part 2 (steps W1-W6).

**Important — wrap-up runs on the session branch directly.** After your last
task's merge-back, you're on the session branch. Wrap-up changes (learnings
updates, Product doc propagation, governance archival, HANDOVER, INBOX cleanup)
all commit directly to the session branch — no task branch is needed for these.
After committing the wrap-up, push the session branch one more time so the
next session sees these changes.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EXIT SIGNAL
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Your final output line must be EXACTLY one of these three words:
- HANDOVER — you completed one or more tasks but assigned tasks remain
- COMPLETE — all assigned tasks are done
- BLOCKED — you need human input (reason written to INBOX.md and HANDOVER.md)
PROMPT_EOF

# ─── Recovery prompt ──────────────────────────────────────────────────────────
# Used when the previous session crashed. Prepends damage assessment to the
# normal task loop.

read -r -d '' RECOVERY_PROMPT << 'PROMPT_EOF' || true
You are an autonomous Claude Code session managed by Orchestra v2. The previous
session CRASHED — there may be partial or broken work. You must assess damage
before entering the normal task flow.

Follow DEVELOPMENT-PROTOCOL.md at the project root in auto-proceed mode.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
STEP 0 — DAMAGE ASSESSMENT (recovery only — do this BEFORE the normal flow)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

0a. Read .orchestra/config to find all file paths and assigned T-numbers.
0b. Read .orchestra/toolchain.md. Run the type check command. Does it compile?
0c. Check governance files (TODO, DECISIONS, CHANGELOG) for corrupt or
    incomplete entries. Repair if intent is clear, remove fragments if not.
0d. Run git status — check for uncommitted work from the crashed session.
0e. For any task marked IN_PROGRESS in TODO.md: inspect actual file state,
    determine whether to continue, restart, or revert.
0f. If issues found, commit repairs: "fix: recovery repairs after session crash"

After damage assessment, proceed to the normal session flow: read SESSION SETUP,
then TASK EXECUTION, SESSION WRAP-UP, and EXIT SIGNAL sections from the normal
session prompt. All the same rules apply — DEVELOPMENT-PROTOCOL.md in auto-proceed
mode. Note in the HANDOVER that this was a recovery session and mention any
repairs made in Step 0.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EXIT SIGNAL
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Your final output line must be EXACTLY one of these three words:
- HANDOVER — you completed one or more tasks but assigned tasks remain
- COMPLETE — all assigned tasks are done
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

# Read the TODO file from the session branch (which has all completed work
# accumulated). The main working tree may be stale.
read_todo_from_session() {
    local todo_rel="${TODO_FILE#$PROJECT_DIR/}"
    if [ -n "${SESSION_BRANCH:-}" ] && git rev-parse --verify "$SESSION_BRANCH" >/dev/null 2>&1; then
        git show "$SESSION_BRANCH:$todo_rel" 2>/dev/null
    else
        cat "$TODO_FILE" 2>/dev/null
    fi
}

# Push branches created during this run to origin
push_branches() {
    if [ -n "${WORKTREE_DIR:-}" ] && [ -d "${WORKTREE_DIR:-}" ]; then
        cd "$PROJECT_DIR"
        git push origin "$SESSION_BRANCH" 2>/dev/null && notify "   Pushed session branch: $SESSION_BRANCH" || true
        for branch in $(git -C "$WORKTREE_DIR" branch --list 'orchestra/t*' 2>/dev/null | tr -d ' *+' || true); do
            # Only push branches created during this run (skip pre-existing ones)
            if ! echo "$PRE_RUN_TASK_BRANCHES" | grep -qx "$branch"; then
                git push origin "$branch" 2>/dev/null && notify "   Pushed task branch: $branch" || true
            fi
        done
    fi
}

# Reset worktree to clean session-branch state for next session
reset_worktree() {
    if [ -n "${WORKTREE_DIR:-}" ] && [ -d "${WORKTREE_DIR:-}" ]; then
        cd "$WORKTREE_DIR"
        git checkout "$SESSION_BRANCH" 2>/dev/null || true
        git reset --hard 2>/dev/null || true
        git clean -fd 2>/dev/null || true
    fi
}

trap 'push_branches; stop_ram_monitor; cleanup_lock; rm -f "$QUOTA_STATE_FILE"; [ -n "${WORKTREE_DIR:-}" ] && [ -d "${WORKTREE_DIR:-}" ] && notify "   Worktree preserved for review: ${WORKTREE_DIR}"' EXIT
start_ram_monitor

# ─── Main loop state ─────────────────────────────────────────────────────────

SESSION_COUNT=0
CONSECUTIVE_CRASHES=0
TOTAL_CRASHES=0
START_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
USE_RECOVERY_PROMPT=false

notify "Orchestrator started at $START_TIME"
notify "   Project: $(basename "$PROJECT_DIR")"
notify "   Assigned tasks: $TASKS"
notify "   Max sessions: $MAX_SESSIONS | Max consecutive crashes: $MAX_CONSECUTIVE_CRASHES"
if [ "$QUOTA_PACING" = "true" ]; then
    notify "   Quota pacing: ON (threshold: ${QUOTA_THRESHOLD}%)"
fi

# ─── Session branch (one per orchestra run, used by all sessions) ────────────
# Created once here, reused across all sessions. Each session worktree checks
# out THIS branch. Task branches branch from it and merge back into it.
# Base branch defaults to main; override via BASE_BRANCH in .orchestra/config
# when reviewing or building on top of a feature branch.
BASE_BRANCH="${BASE_BRANCH:-main}"
git fetch origin "$BASE_BRANCH" 2>/dev/null || true
SESSION_BRANCH="orchestra/run-$(date -u +%Y%m%d-%H%M%S)"
git branch "$SESSION_BRANCH" "origin/$BASE_BRANCH" 2>/dev/null || git branch "$SESSION_BRANCH" "$BASE_BRANCH"
notify "   Session branch: $SESSION_BRANCH (base: $BASE_BRANCH)"

# ─── Run worktree (one per orchestra run, reused across sessions) ─────────
RUN_NAME="${SESSION_BRANCH#orchestra/}"
WORKTREE_DIR="${WORKTREE_BASE:-/tmp/orchestra-$(basename "$PROJECT_DIR")}/$RUN_NAME"

# Clean up any stale worktree at this path (filesystem AND git registry)
git worktree remove --force "$WORKTREE_DIR" 2>/dev/null || true
rm -rf "$WORKTREE_DIR" 2>/dev/null
git worktree prune 2>/dev/null

if ! git worktree add "$WORKTREE_DIR" "$SESSION_BRANCH" 2>&1; then
    notify "ERROR: Could not create worktree at $WORKTREE_DIR"
    exit 1
fi
notify "   Worktree: $WORKTREE_DIR (branch: $SESSION_BRANCH)"

# ─── Create run workspace folder inside worktree ─────────────────────────────
# All session artifacts (JSON logs, tasks.md, log.md) go here — one folder
# per orchestra invocation, named to match the worktree/branch.
RUN_WORKSPACE="$WORKTREE_DIR/.orchestra/sessions/$RUN_NAME"
mkdir -p "$RUN_WORKSPACE"
notify "   Run workspace: .orchestra/sessions/$RUN_NAME"

# ─── Copy gitignored env files into worktree ─────────────────────────────────
# These are gitignored so worktrees don't inherit them. Copy from the main
# project so the worktree is immediately testable. Since they're gitignored,
# git clean -fd won't remove them between sessions — one-time copy suffices.
if [ -n "${ENV_FILES:-}" ]; then
    IFS=',' read -ra ENV_LIST <<< "$ENV_FILES"
    for env_file in "${ENV_LIST[@]}"; do
        env_file=$(echo "$env_file" | xargs)
        if [ -f "$PROJECT_DIR/$env_file" ]; then
            mkdir -p "$(dirname "$WORKTREE_DIR/$env_file")"
            cp -P "$PROJECT_DIR/$env_file" "$WORKTREE_DIR/$env_file"
        fi
    done
    notify "   Copied env files: $ENV_FILES"
fi

# Snapshot existing task branches so push_branches only pushes new ones
PRE_RUN_TASK_BRANCHES=$(git branch --list 'orchestra/t*' 2>/dev/null | tr -d ' *+')

while [ "$SESSION_COUNT" -lt "$MAX_SESSIONS" ]; do
    # ─── Quota pacing: check before spawning ─────────────────────────────
    if [ "$QUOTA_PACING" = "true" ]; then
        wait_for_quota
    fi

    SESSION_COUNT=$((SESSION_COUNT + 1))
    SESSION_TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
    SESSION_LOG="$RUN_WORKSPACE/session-$(printf '%03d' $SESSION_COUNT).json"

    # Choose prompt based on whether previous session crashed
    if [ "$USE_RECOVERY_PROMPT" = true ]; then
        CURRENT_PROMPT="$RECOVERY_PROMPT"
        notify "Starting RECOVERY session $SESSION_COUNT/$MAX_SESSIONS (after crash)"
    else
        CURRENT_PROMPT="$SESSION_PROMPT"
        notify "Starting session $SESSION_COUNT/$MAX_SESSIONS"
    fi

    # Substitute placeholders with concrete paths (relative to project root)
    STATE_DIR_REL="${STATE_DIR#$PROJECT_DIR/}"
    CONFIG_PATH_REL="${ORCHESTRA_CONFIG:-.orchestra/config}"
    if [ "${CONFIG_PATH_REL:0:1}" = "/" ]; then
        CONFIG_PATH_REL="${CONFIG_PATH_REL#$PROJECT_DIR/}"
    fi
    CURRENT_PROMPT="${CURRENT_PROMPT//__STATE_DIR__/$STATE_DIR_REL}"
    CURRENT_PROMPT="${CURRENT_PROMPT//__ORCH_CONFIG__/$CONFIG_PATH_REL}"
    CURRENT_PROMPT="${CURRENT_PROMPT//__SESSION_BRANCH__/$SESSION_BRANCH}"
    CURRENT_PROMPT="${CURRENT_PROMPT//__RUN_NAME__/$RUN_NAME}"

    # ─── Worktree reset ─────────────────────────────────────────────────────
    # Persistent worktree: reset to clean session-branch state between sessions.
    # First session uses the worktree as-is (just created before the loop).
    if [ "$SESSION_COUNT" -gt 1 ]; then
        reset_worktree
    fi

    cd "$WORKTREE_DIR"
    PRE_STATE=$(snapshot_state_files)

    # ─── Model selection ─────────────────────────────────────────────────────
    # Model and effort come from config file. No env var overrides.
    # HANDOVER can still recommend a downgrade for the next session.
    RECOMMENDED_MODEL="${MODEL:-opus}"
    RECOMMENDED_EFFORT="${EFFORT:-high}"

    if [ -f "$STATE_DIR/HANDOVER.md" ]; then
        REC_LINE=$(grep -i 'model recommendation' "$STATE_DIR/HANDOVER.md" | tail -1 || echo "")
        if echo "$REC_LINE" | grep -qi 'sonnet'; then
            RECOMMENDED_MODEL="sonnet"
        fi
        if echo "$REC_LINE" | grep -qi 'medium'; then
            RECOMMENDED_EFFORT="medium"
        fi
    fi

    # Map effort labels to valid CLI values
    case "$RECOMMENDED_EFFORT" in
        low|medium|high|max) ;; # already valid
        *) notify "   WARNING: unknown effort '${RECOMMENDED_EFFORT}', defaulting to high"
           RECOMMENDED_EFFORT="high" ;;
    esac

    MODEL_FLAG="--model ${RECOMMENDED_MODEL}"
    EFFORT_FLAG="--effort ${RECOMMENDED_EFFORT}"
    notify "   Model: ${RECOMMENDED_MODEL}:${RECOMMENDED_EFFORT}"

    # ─── Run Claude Code in headless mode ─────────────────────────────────────
    # stream-json goes to the log file for full metadata;
    # a jq filter extracts readable text for the terminal.
    # Session runs in the worktree directory, not the main working tree.

    set +eo pipefail
    cd "$WORKTREE_DIR"
    claude -p "$CURRENT_PROMPT" \
        $MODEL_FLAG \
        $EFFORT_FLAG \
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

    # ─── Snapshot state after Claude, before orchestrator bookkeeping ──────────
    # Captures whether Claude did real work. Must be taken BEFORE the session-log
    # commit, which advances HEAD and would pollute the comparison.
    POST_CLAUDE_STATE=$(snapshot_state_files)

    # ─── Commit session log into worktree ──────────────────────────────────────
    # The session JSON was written by tee (not a Claude tool call), so the
    # staging hook never fires for it. Commit it now so reset_worktree can't
    # destroy it, and so it appears in the session branch history alongside
    # the T-folder artifacts (tasks.md, log.md) that Claude committed.
    if [ -f "$SESSION_LOG" ]; then
        cd "$WORKTREE_DIR"
        git add "$SESSION_LOG" 2>/dev/null || true
        git commit -m "auto: session $SESSION_COUNT log ($SESSION_TIMESTAMP)" --no-verify 2>/dev/null || true
    fi

    # ─── Extract quota state from session log ─────────────────────────────────
    if [ "$QUOTA_PACING" = "true" ]; then
        extract_session_quota "$SESSION_LOG"
    fi

    # ─── Handle crash (non-zero exit) ─────────────────────────────────────────
    # Layer 3: Crash recovery — detect partial work, commit it, continue.

    if [ $EXIT_CODE -ne 0 ]; then
        CONSECUTIVE_CRASHES=$((CONSECUTIVE_CRASHES + 1))
        TOTAL_CRASHES=$((TOTAL_CRASHES + 1))
        notify "Session $SESSION_COUNT crashed (exit $EXIT_CODE). Consecutive: $CONSECUTIVE_CRASHES/$MAX_CONSECUTIVE_CRASHES"

        # Sync governance from worktree before checking state

        if [ "$PRE_STATE" != "$POST_CLAUDE_STATE" ]; then
            # v2 INVERSION: v1 treated governance-changed as safe (USE_RECOVERY_PROMPT=false).
            # v2 treats it as needing damage assessment because governance may be
            # half-written (e.g. task set to IN_PROGRESS but not completed). See spec 6.3.
            notify "   Governance files changed — partial state, recovery needed"
            recovery_commit "$SESSION_COUNT"
            USE_RECOVERY_PROMPT=true
        else
            STAGED_COUNT=$(git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
            MODIFIED_COUNT=$(git diff --name-only 2>/dev/null | wc -l | tr -d ' ')
            if [ "$STAGED_COUNT" -gt 0 ] || [ "$MODIFIED_COUNT" -gt 0 ]; then
                notify "   Code files modified without governance update — recovery needed"
                recovery_commit "$SESSION_COUNT"
                USE_RECOVERY_PROMPT=true
            else
                # Nothing changed — session died before acting
                notify "   No work detected — using normal prompt"
                USE_RECOVERY_PROMPT=false
            fi
        fi

        if [ "$CONSECUTIVE_CRASHES" -ge "$MAX_CONSECUTIVE_CRASHES" ]; then
            notify "$MAX_CONSECUTIVE_CRASHES consecutive crashes. Stopping."
            exit 1
        fi

        push_branches
        cd "$PROJECT_DIR"
        notify "   Retrying in ${CRASH_COOLDOWN_SECONDS}s..."
        sleep "$CRASH_COOLDOWN_SECONDS"
        continue
    fi

    # ─── Sync governance from worktree and clean up ─────────────────────────
    cd "$PROJECT_DIR"

    # ─── Session exited cleanly (exit code 0) ─────────────────────────────────

    CONSECUTIVE_CRASHES=0
    USE_RECOVERY_PROMPT=false

    # Extract exit signal from the stream-json result event
    # Extract exit signal from the last few lines of text output
    FINAL=$(grep '"type":"result"' "$SESSION_LOG" | tail -1 | jq -r '.result // empty' 2>/dev/null || echo "")

    # ─── Detect stalled progress (clean exit but no state changes) ────────────
    # This catches sessions that ran but didn't actually do or record anything.

    if [ "$PRE_STATE" = "$POST_CLAUDE_STATE" ]; then
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

    if echo "$FINAL" | grep -qi "BLOCKED"; then
        notify "Session $SESSION_COUNT BLOCKED. Check .orchestra/HANDOVER.md for details."
        notify "   Orchestrator pausing. Resolve the issue and restart."
        exit 2
    fi

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

    if [ "$REMAINING" -eq 0 ]; then
        notify "All assigned tasks completed after $SESSION_COUNT sessions."
        exit 0
    fi

    # Push completed work (worktree persists for next session)
    push_branches

    notify "Session $SESSION_COUNT handed over. $REMAINING assigned tasks remain. Next in ${COOLDOWN_SECONDS}s..."
    sleep "$COOLDOWN_SECONDS"
done

# ─── Max sessions reached ─────────────────────────────────────────────────────

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
notify "Reached max session limit ($MAX_SESSIONS). $REMAINING assigned tasks remain. $TOTAL_CRASHES crashes recovered."
exit 3
