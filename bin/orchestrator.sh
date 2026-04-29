#!/bin/bash
# orchestrator.sh — session loop running inside the run worktree's tmux.
# Spec: build-history/archive/v0-cleanup/2026-04-29-orchestra-cleanup-design.md Sections 6, 11.
#
# 9-sessions/NNN.json schema:
# {
#   "session_num": 1,
#   "started_at": "2026-04-29T15:30:22Z",
#   "ended_at": "2026-04-29T15:35:10Z",
#   "exit_code": 0,
#   "exit_signal": "COMPLETE" | "HANDOVER" | "BLOCKED" | null,
#   "crash_category": null | "A" | "B" | "C" | "D",
#   "rate_limit_events": []
# }
set -euo pipefail

: "${RUN_DIR:?RUN_DIR not set}"
: "${WORKTREE_DIR:?WORKTREE_DIR not set}"
: "${PROJECT_DIR:?PROJECT_DIR not set}"
: "${RUN_TS:?RUN_TS not set}"
: "${RUN_BRANCH:?RUN_BRANCH not set}"
: "${BASE_BRANCH:?BASE_BRANCH not set}"

# Load config from the worktree's CONFIG.md
declare -gA ORCHESTRA_CONFIG
# shellcheck source=/dev/null
source "$WORKTREE_DIR/.orchestra/runtime/lib/config.sh"
parse_config_md "$WORKTREE_DIR/.orchestra/CONFIG.md"
apply_config_defaults

MAX_SESSIONS="${ORCHESTRA_CONFIG[MAX_SESSIONS]}"
MAX_CRASHES="${ORCHESTRA_CONFIG[MAX_CONSECUTIVE_CRASHES]}"
MODEL="${ORCHESTRA_CONFIG[MODEL]}"
EFFORT="${ORCHESTRA_CONFIG[EFFORT]}"
COOLDOWN="${ORCHESTRA_CONFIG[COOLDOWN_SECONDS]}"
CRASH_COOLDOWN="${ORCHESTRA_CONFIG[CRASH_COOLDOWN_SECONDS]}"
QUOTA_PACING="${ORCHESTRA_CONFIG[QUOTA_PACING]}"
QUOTA_THRESHOLD="${ORCHESTRA_CONFIG[QUOTA_THRESHOLD]}"
QUOTA_POLL_INTERVAL="${ORCHESTRA_CONFIG[QUOTA_POLL_INTERVAL]}"
CREDENTIALS_FILE="${HOME}/.claude/.credentials.json"

# Spec Section 7: the wind-down lock lives in the PROJECT TREE, not per-
# worktree, so concurrent runs (each in their own worktree) actually
# serialise their pushes to origin/<BASE_BRANCH>. Per-worktree placement
# would defeat the lock's purpose.
WINDDOWN_LOCK="$PROJECT_DIR/.orchestra/runs/.wind-down.lock"

# Spec Section 6.1: orchestrator-owned lock file. Line 1 is the holder PID,
# line 2 is /proc/<pid>/stat field 22 (process start time in clock ticks).
# Storing start time defends against PID recycling — a different process
# reusing the same PID will have a different start time so we treat the lock
# as stale.
acquire_winddown_lock() {
    local backoff=30
    while true; do
        # `$$` (the parent shell's PID), not `self` — `$(awk ... /proc/self/stat)`
        # resolves to awk's own PID inside the command substitution, recording
        # awk's start-time on line 2 instead of the orchestrator's. The stale-
        # detection branch below reads `/proc/$lock_pid/stat` for the
        # orchestrator PID, so the two values would never match and any
        # contended acquire would falsely evict the live holder.
        if (set -C; printf '%d\n%s\n' $$ "$(awk '{print $22}' /proc/$$/stat)" > "$WINDDOWN_LOCK") 2>/dev/null; then
            return 0
        fi

        # Lock exists — check liveness
        local lock_pid lock_starttime live_starttime
        lock_pid=$(sed -n '1p' "$WINDDOWN_LOCK" 2>/dev/null) || lock_pid=""
        lock_starttime=$(sed -n '2p' "$WINDDOWN_LOCK" 2>/dev/null) || lock_starttime=""

        if [ -z "$lock_pid" ] || ! kill -0 "$lock_pid" 2>/dev/null; then
            rm -f "$WINDDOWN_LOCK"
            continue
        fi

        # PID alive — verify start-time matches (defends against PID recycling)
        if [ -e "/proc/$lock_pid/stat" ]; then
            live_starttime=$(awk '{print $22}' "/proc/$lock_pid/stat" 2>/dev/null)
            if [ "$live_starttime" != "$lock_starttime" ]; then
                rm -f "$WINDDOWN_LOCK"
                continue
            fi
        fi

        # Genuinely held by live orchestrator — backoff
        sleep "$backoff"
        backoff=$((backoff * 2))
        [ $backoff -gt 300 ] && backoff=300
    done
}

write_winddown_failed_marker() {
    # Note: parameter is `category` (not `cat`) — `cat` would shadow the
    # cat(1) command name we use below to dump the handover.
    local category="$1" out="$2" handover="$3"
    {
        echo "Failed at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "Category: $category"
        echo ""
        echo "--- Last 50 lines of session output ---"
        echo "$out" | tail -50
        if [ "$category" = "BLOCKED" ] && [ -n "$handover" ] && [ -f "$handover" ]; then
            echo ""
            echo "--- Conflict/push-failure details from 6-HANDOVER.md ---"
            # Cap handover at 500 lines so a runaway agent producing
            # megabytes of HANDOVER doesn't bloat the marker file.
            head -n 500 "$handover"
        fi
    } > "$RUN_DIR/WIND-DOWN-FAILED"
}

print_winddown_recovery() {
    local category="$1"
    cat <<EOF >&2

WIND-DOWN FAILED ($category). Run preserved at:
  $RUN_DIR

Run branch: $RUN_BRANCH

EOF
    case "$category" in
        A|B|C)
            cat <<EOF >&2
Recovery (the merge step did not complete):
  cd $WORKTREE_DIR
  git checkout $BASE_BRANCH
  git merge --ff-only $RUN_BRANCH
  git push origin $BASE_BRANCH

EOF
            ;;
        BLOCKED)
            cat <<EOF >&2
Recovery (resolve merge/push manually):
  cd $WORKTREE_DIR
  cat $RUN_DIR/6-HANDOVER.md
  # Resolve conflicts following the manual-resolution instructions in HANDOVER, then:
  git add .
  git commit
  git push origin $BASE_BRANCH

EOF
            ;;
    esac
}

# ─── Quota pacing ────────────────────────────────────────────────────────────
# Cherry-picked from main:bin/orchestrator.sh. Polls the OAuth usage endpoint
# and pauses between sessions when 5-hour utilization is at or above
# QUOTA_THRESHOLD. Falls back to a no-op (no sleep) on any auth/network
# failure so missing credentials never block progress.

# Fetch current quota utilization from the OAuth usage endpoint.
# Returns JSON: {"five_hour": N, "seven_day": N, "resets_at": "ISO8601"}
# Returns non-zero on failure (no creds, endpoint unavailable, auth expired).
# Bails immediately on missing credentials — no curl call, no network timeout.
fetch_quota() {
    if [ ! -f "$CREDENTIALS_FILE" ]; then
        return 1
    fi

    local token
    token=$(python3 -c "import json; print(json.load(open('$CREDENTIALS_FILE'))['claudeAiOauth']['accessToken'])" 2>/dev/null) || return 1
    [ -n "$token" ] || return 1

    local response
    response=$(curl -s --max-time 10 \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null) || return 1

    if ! echo "$response" | jq -e '.five_hour.utilization' &>/dev/null; then
        return 1
    fi

    local five_hour seven_day resets_at
    five_hour=$(echo "$response" | jq -r '.five_hour.utilization // 0')
    seven_day=$(echo "$response" | jq -r '.seven_day.utilization // 0')
    resets_at=$(echo "$response" | jq -r '.five_hour.resets_at // empty')

    echo "{\"five_hour\": $five_hour, \"seven_day\": $seven_day, \"resets_at\": \"$resets_at\"}"
}

# Wait for quota to drop below threshold. Called before each claude --print
# invocation when QUOTA_PACING=true. Logs to stderr so smoke-output capture
# (stdout) is not polluted.
#
# API utilization fields are integer percentages (0-100), so plain bash
# integer comparison suffices — no bc dependency.
wait_for_quota() {
    if [ "$QUOTA_PACING" != "true" ]; then
        return 0
    fi

    local quota_json
    quota_json=$(fetch_quota) || {
        echo "   Quota check failed (auth/network). Proceeding without pacing." >&2
        return 0
    }

    local five_hour seven_day resets_at
    five_hour=$(echo "$quota_json" | jq -r '.five_hour')
    seven_day=$(echo "$quota_json" | jq -r '.seven_day')
    resets_at=$(echo "$quota_json" | jq -r '.resets_at')

    echo "   Quota: 5h=${five_hour}% 7d=${seven_day}% (threshold: ${QUOTA_THRESHOLD}%)" >&2

    if [ "$five_hour" -ge "$QUOTA_THRESHOLD" ]; then
        local reset_epoch now_epoch wait_seconds
        reset_epoch=$(date -d "$resets_at" +%s 2>/dev/null) || reset_epoch=0
        now_epoch=$(date +%s)
        wait_seconds=$((reset_epoch - now_epoch))

        if [ "$wait_seconds" -gt 0 ]; then
            local wait_minutes=$((wait_seconds / 60))
            local reset_time
            reset_time=$(date -d "$resets_at" '+%H:%M:%S UTC' 2>/dev/null || echo "$resets_at")
            echo "   5-hour quota at ${five_hour}% (>= ${QUOTA_THRESHOLD}%). Pausing until reset at $reset_time (~${wait_minutes}m)" >&2

            while [ "$wait_seconds" -gt 0 ]; do
                local sleep_for=$QUOTA_POLL_INTERVAL
                if [ "$wait_seconds" -lt "$sleep_for" ]; then
                    sleep_for=$((wait_seconds + 10))  # small buffer past reset
                fi
                sleep "$sleep_for"

                quota_json=$(fetch_quota) || break
                five_hour=$(echo "$quota_json" | jq -r '.five_hour')
                resets_at=$(echo "$quota_json" | jq -r '.resets_at')

                if [ "$five_hour" -lt "$QUOTA_THRESHOLD" ]; then
                    echo "   Quota dropped to ${five_hour}%. Resuming." >&2
                    return 0
                fi

                reset_epoch=$(date -d "$resets_at" +%s 2>/dev/null) || break
                now_epoch=$(date +%s)
                wait_seconds=$((reset_epoch - now_epoch))
            done

            echo "   Quota window reset. Resuming." >&2
        fi
    fi
}

session_num=0
crash_count=0
prev_category=""

write_session_json() {
    local n="$1" started="$2" ended="$3" code="$4" signal="$5" cat="$6"
    local fname
    fname="$RUN_DIR/9-sessions/$(printf '%03d' "$n").json"
    jq -n \
        --argjson n "$n" \
        --arg s "$started" \
        --arg e "$ended" \
        --argjson c "$code" \
        --arg sig "$signal" \
        --arg cat "$cat" \
        '{session_num: $n, started_at: $s, ended_at: $e, exit_code: $c,
          exit_signal: ($sig | select(. != "") // null),
          crash_category: ($cat | select(. != "") // null),
          rate_limit_events: []}' \
        > "$fname"
}

run_session_with_watchdog() {
    local prompt="$1"
    local stdout_log="$2"
    local stderr_log="$3"

    local inotify_log inotify_err
    inotify_log=$(mktemp)
    inotify_err=$(mktemp)
    inotifywait -mr --format '.' "$WORKTREE_DIR" >> "$inotify_log" 2>"$inotify_err" &
    local inotify_pid=$!

    # Verify inotifywait is actually watching. inotifywait prints
    # "Watches established." to stderr once it's up. If it failed at startup
    # (max_user_watches, EACCES, etc.), bailing here is correct — running with
    # only stdout-silence detection guarantees false-positive Cat C hangs.
    local startup_deadline=$(($(date +%s) + 5))
    while [ "$(date +%s)" -lt "$startup_deadline" ]; do
        if ! kill -0 "$inotify_pid" 2>/dev/null; then
            echo "ERROR: inotifywait died at startup. stderr:" >&2
            cat "$inotify_err" >&2
            rm -f "$inotify_log" "$inotify_err"
            return 125  # distinguish from 124 timeout / claude exit codes
        fi
        if grep -q "Watches established" "$inotify_err" 2>/dev/null; then
            break
        fi
        sleep 0.2
    done

    if ! grep -q "Watches established" "$inotify_err" 2>/dev/null; then
        echo "ERROR: inotifywait did not establish watches within 5s. stderr:" >&2
        cat "$inotify_err" >&2
        kill -TERM "$inotify_pid" 2>/dev/null || true
        rm -f "$inotify_log" "$inotify_err"
        return 125
    fi
    rm -f "$inotify_err"  # drop after startup; main monitoring uses inotify_log only

    echo "$prompt" | claude --print --dangerously-skip-permissions \
        --model "$MODEL" --effort "$EFFORT" \
        > "$stdout_log" 2> "$stderr_log" &
    local claude_pid=$!

    local last_inotify_size=0
    local last_stdout_size=0
    local quiet_seconds=0
    # Poll on a 5s interval rather than 30s so a fast-exiting claude is
    # detected promptly (the wider 30s sleep would otherwise pad every
    # session by 30s). The MAX_HANG_SECONDS threshold is still enforced
    # in real wall-clock time via accumulated quiet_seconds.
    local poll_interval=5

    while kill -0 "$claude_pid" 2>/dev/null; do
        sleep "$poll_interval"

        local i_size s_size
        i_size=$(stat -c %s "$inotify_log" 2>/dev/null || echo 0)
        s_size=$(stat -c %s "$stdout_log" 2>/dev/null || echo 0)

        if [ "$i_size" -eq "$last_inotify_size" ] && [ "$s_size" -eq "$last_stdout_size" ]; then
            quiet_seconds=$((quiet_seconds + poll_interval))
            if [ "$quiet_seconds" -ge "${ORCHESTRA_CONFIG[MAX_HANG_SECONDS]}" ]; then
                kill -TERM "$claude_pid" 2>/dev/null || true
                sleep 30
                kill -KILL "$claude_pid" 2>/dev/null || true
                kill -TERM "$inotify_pid" 2>/dev/null || true
                wait "$claude_pid" 2>/dev/null || true
                rm -f "$inotify_log"
                return 124  # standard timeout exit code
            fi
        else
            quiet_seconds=0
            last_inotify_size=$i_size
            last_stdout_size=$s_size
        fi
    done

    # `wait` may return non-zero (claude exited non-zero); avoid set -e abort.
    local code=0
    wait "$claude_pid" || code=$?
    kill -TERM "$inotify_pid" 2>/dev/null || true
    rm -f "$inotify_log"
    return "$code"
}

build_session_prompt() {
    local n="$1"
    cat <<EOF
You are an autonomous Claude Code session in orchestra run $RUN_TS, session $n.

Read the following files in $WORKTREE_DIR/.orchestra/runs/$RUN_TS/ for context:
- 2-OBJECTIVE.md (the run objective — read first)
- 1-INBOX.md (any human messages — check on cold-start)
- 6-HANDOVER.md (briefing from previous session, if any)
- 3-TODO.md, 4-DECISIONS.md, 5-CHANGELOG.md, 7-SUMMARY.md (rolling state)

Make progress against the objective. Update the rolling files as you work.

When done with this session, exit with EXACTLY one of:
- COMPLETE — objective met. **Before emitting COMPLETE you MUST commit any
  work to the run-branch.** Run \`git status\` first; \`git add\` + \`git commit\`
  any uncommitted or untracked files. Orchestra enforces a clean-worktree
  invariant at COMPLETE — dirty state will be flagged as Category D and
  wind-down will then have to commit on your behalf during damage assessment.
- HANDOVER — more work remains, write 6-HANDOVER.md briefing for the next
  session. Dirty state is OK on HANDOVER (next session picks up from the
  worktree).
- BLOCKED — external dependency missing; write 6-HANDOVER.md with remaining
  work and dependency analysis. Dirty state is OK on BLOCKED.

The signal is the LAST line of your output, on its own line.
EOF
}

while [ $session_num -lt $MAX_SESSIONS ] && [ $crash_count -lt $MAX_CRASHES ]; do
    session_num=$((session_num + 1))
    started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Per spec Section 11: when a previous session ended with a crash
    # category, prepend a damage-assessment preamble so the next session
    # inspects the worktree before resuming the main task.
    if [ -n "$prev_category" ]; then
        case "$prev_category" in
            A|B|C) recovery_note="The previous session crashed or hung. Inspect git status and any work-in-progress files before continuing the main task." ;;
            D)     recovery_note="The previous session emitted COMPLETE but left uncommitted changes. Assess each modification, decide whether to keep or discard, commit deliberately on the run-branch, then either re-emit COMPLETE (if objective met) or continue with HANDOVER." ;;
            *)     recovery_note="" ;;
        esac
        base_prompt=$(build_session_prompt "$session_num")
        prompt=$(cat <<EOF
RECOVERY PREAMBLE — the previous session ended with category $prev_category.

$recovery_note

---

$base_prompt
EOF
)
    else
        prompt=$(build_session_prompt "$session_num")
    fi

    # Run claude headlessly under the hang-detection watchdog
    # (per spec Section 11.C: inotify + stdout silence with SIGTERM/SIGKILL).
    stdout_log=$(mktemp)
    stderr_log=$(mktemp)
    # Quota pacing: pause if 5-hour utilization is at or above threshold.
    # No-op when QUOTA_PACING != true or credentials are unavailable.
    wait_for_quota
    set +e
    run_session_with_watchdog "$prompt" "$stdout_log" "$stderr_log"
    code=$?
    set -e
    out=$(cat "$stdout_log")

    # On crash/hang, preserve stderr in the run folder for diagnosis.
    # Spec Section 11 makes wind-down failure handling depend on this evidence.
    if [ "$code" -ne 0 ]; then
        cp "$stderr_log" "$RUN_DIR/9-sessions/$(printf '%03d' "$session_num")-stderr.txt"
    fi

    rm -f "$stdout_log" "$stderr_log"

    # Exit code 125 from the watchdog signals an infrastructure failure
    # (inotifywait could not start). This is not a Cat A/B/C session crash
    # — the orchestrator itself cannot run safely, so bail without writing
    # session JSON or incrementing crash_count.
    if [ "$code" -eq 125 ]; then
        echo "Orchestrator infrastructure failure (inotifywait) — cannot continue safely" >&2
        exit 3
    fi

    ended_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Determine exit signal and crash category.
    # Per spec Section 11: parse the final non-empty line of stdout — awk
    # tracks the last line with any non-blank content so trailing blank
    # lines don't mask a clean COMPLETE/HANDOVER/BLOCKED.
    last_line=$(printf '%s' "$out" | awk 'NF{line=$0} END{print line}' | tr -d '[:space:]')
    signal=""
    category=""

    if [ $code -ne 0 ]; then
        category="A"
    elif [ "$last_line" = "COMPLETE" ]; then
        # Subshell-scoped cd so this branch can't leak the working directory
        # into later iterations of the session loop. Behaviour is unchanged
        # today (tmux launches the orchestrator with cwd=$WORKTREE_DIR), but
        # this guards against a future refactor that changes the entry cwd.
        if [ -n "$(cd "$WORKTREE_DIR" && git status --porcelain)" ]; then
            signal="COMPLETE"
            category="D"
        else
            signal="COMPLETE"
        fi
    elif [ "$last_line" = "HANDOVER" ] || [ "$last_line" = "BLOCKED" ]; then
        signal="$last_line"
    else
        category="B"
    fi

    # Watchdog timeout (124) means the session hung, not crashed.
    # Override category to C — spec Section 11.C.
    if [ "$code" -eq 124 ]; then
        category="C"
        signal=""
    fi

    write_session_json "$session_num" "$started_at" "$ended_at" "$code" "$signal" "$category" \
        || { echo "ERROR: failed writing session JSON (session $session_num, exit $code)" >&2; exit 2; }

    # Reset prev_category before potentially setting it from this iteration
    # so it doesn't stay sticky after a successful (non-categorical) session.
    prev_category=""

    if [ "$category" = "A" ] || [ "$category" = "B" ] || [ "$category" = "C" ]; then
        crash_count=$((crash_count + 1))
        prev_category="$category"
        sleep "$CRASH_COOLDOWN"
        continue
    fi

    # Below: clean COMPLETE/HANDOVER/BLOCKED signals OR Cat D (carries
    # signal=COMPLETE). Cat D resets the crash counter the same way COMPLETE
    # does — agent's intent was clean (spec Section 11.D), counter is not
    # incremented and the merge sequence still proceeds.
    crash_count=0

    # Spec Section 11.D: Cat D triggers wind-down with a damage-assessment
    # preamble. Wind-down's first job becomes "commit the dirty worktree on
    # the run-branch", then the normal merge sequence runs.
    winddown_damage_assessment=0
    if [ "$category" = "D" ]; then
        winddown_damage_assessment=1
        echo "Category D: COMPLETE with dirty worktree — wind-down will commit before merge"
    fi

    case "$signal" in
            COMPLETE)
                echo "Run COMPLETE — entering wind-down"

                acquire_winddown_lock

                # Trap discipline (spec Section 6.1) — EXIT INT TERM are reserved
                # for the wind-down lock. Phase 4's ERR trap was already cleared
                # in cmd_run before exec'ing the orchestrator, so no overlap.
                trap 'rm -f "$WINDDOWN_LOCK"' EXIT INT TERM

                # Build wind-down prompt from template
                wd_prompt=$(cat "$WORKTREE_DIR/.orchestra/runtime/lib/winddown-prompt.txt" \
                    | sed "s|__RUN_DIR__|$RUN_DIR|g" \
                    | sed "s|__BASE_BRANCH__|$BASE_BRANCH|g" \
                    | sed "s|__RUN_BRANCH__|$RUN_BRANCH|g")

                # Spec Section 11.D: prepend damage-assessment preamble when
                # the previous working session was Cat D (clean intent + dirty
                # worktree). Wind-down's first job is to commit deliberately
                # on the run-branch before the normal merge sequence runs.
                if [ "$winddown_damage_assessment" -eq 1 ]; then
                    wd_prompt=$(cat <<DA_EOF
DAMAGE ASSESSMENT — the previous working session emitted COMPLETE but left
uncommitted or untracked changes in the worktree. **Before** the wind-down
sequence below: run \`git status\`, assess each modification, and commit any
keepers on the run-branch ($RUN_BRANCH) with sensible messages. After the
worktree is clean, proceed with the normal wind-down sequence.

---

$wd_prompt
DA_EOF
)
                fi

                # Wind-down runs under the same hang-detection watchdog as
                # working sessions so a stuck wind-down (e.g. claude blocked on
                # a prompt) is detectable as Cat C. Stderr is preserved on
                # failure into RUN_DIR/wind-down-stderr.txt — wind-down is a
                # single-attempt session, not a numbered series under
                # 9-sessions/, so the file lives directly under RUN_DIR.
                wd_stdout_log=$(mktemp)
                wd_stderr_log=$(mktemp)
                # Quota pacing: pause if 5-hour utilization is at or above
                # threshold. No-op when QUOTA_PACING != true or credentials
                # are unavailable.
                wait_for_quota
                set +e
                run_session_with_watchdog "$wd_prompt" "$wd_stdout_log" "$wd_stderr_log"
                wd_code=$?
                set -e

                # Mirror the working-session 125 early-bail (above, after the
                # main run_session_with_watchdog call). 125 means inotifywait
                # could not start — an A/B/C category and "git merge --ff-only"
                # recovery recipe would be misleading. Preserve stderr, clean
                # the temp logs explicitly (we bail before the shared cleanup
                # below), and exit 3 to match the working-session contract.
                if [ "$wd_code" -eq 125 ]; then
                    cp "$wd_stderr_log" "$RUN_DIR/wind-down-stderr.txt" 2>/dev/null || true
                    rm -f "$wd_stdout_log" "$wd_stderr_log"
                    echo "Wind-down infrastructure failure (inotifywait) — cannot diagnose further" >&2
                    exit 3
                fi

                wd_out=$(cat "$wd_stdout_log")

                if [ "$wd_code" -ne 0 ]; then
                    cp "$wd_stderr_log" "$RUN_DIR/wind-down-stderr.txt"
                fi
                rm -f "$wd_stdout_log" "$wd_stderr_log"

                # Same awk-based last-non-empty-line extractor as the working
                # session (spec Section 11; Phase 5 fix-up).
                wd_last=$(printf '%s' "$wd_out" | awk 'NF{line=$0} END{print line}' | tr -d '[:space:]')

                # Spec Section 6.4 + Category E: wind-down failures don't auto-
                # retry. Categorise the failure, write the marker, print user-
                # facing recovery commands, exit non-zero. The run folder is
                # NOT archived — preserved for inspection. Lock is released
                # via the EXIT trap installed above.
                if [ $wd_code -ne 0 ] || ! [[ "$wd_last" =~ ^(COMPLETE|BLOCKED)$ ]]; then
                    # Wind-down crash (A/B/C) — order matters: 124 (watchdog
                    # timeout) first, then 0 (clean exit but missing signal),
                    # else default A (non-zero non-124).
                    failure_cat="A"
                    [ $wd_code -eq 124 ] && failure_cat="C"
                    [ $wd_code -eq 0 ] && failure_cat="B"
                    write_winddown_failed_marker "$failure_cat" "$wd_out" ""
                    print_winddown_recovery "$failure_cat"
                    exit 1
                fi

                if [ "$wd_last" = "BLOCKED" ]; then
                    # Wind-down BLOCKED — agent gave up on merge conflict /
                    # push failure. Marker includes 6-HANDOVER.md content.
                    write_winddown_failed_marker "BLOCKED" "$wd_out" "$RUN_DIR/6-HANDOVER.md"
                    print_winddown_recovery "BLOCKED"
                    exit 1
                fi

                # Successful wind-down — archive (spec Section 6.3)
                archive_dir="$WORKTREE_DIR/.orchestra/runs/archive"
                mkdir -p "$archive_dir"
                mv "$RUN_DIR" "$archive_dir/$RUN_TS"
                echo "Run archived at $archive_dir/$RUN_TS"
                exit 0
                ;;
            HANDOVER) sleep "$COOLDOWN"; continue ;;
            BLOCKED)
                blocker_text=""
                [ -f "$RUN_DIR/1-INBOX.md" ] && blocker_text+=$'\n\n--- 1-INBOX.md ---\n'$(cat "$RUN_DIR/1-INBOX.md")
                [ -f "$RUN_DIR/6-HANDOVER.md" ] && blocker_text+=$'\n\n--- 6-HANDOVER.md ---\n'$(cat "$RUN_DIR/6-HANDOVER.md")

                {
                    echo "Blocked at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
                    echo "Session: $session_num"
                    echo "$blocker_text"
                } > "$RUN_DIR/BLOCKED"

                cat <<EOF >&2

RUN BLOCKED. Run preserved at:
  $RUN_DIR

The agent could not proceed without an external dependency. See:
  $RUN_DIR/BLOCKED
  $RUN_DIR/6-HANDOVER.md (remaining work + dependency analysis)
  $RUN_DIR/1-INBOX.md (any inline blocker text)

After resolving the blocker, prepare a fresh OBJECTIVE.md and run again.
EOF
                exit 0
                ;;
    esac
done

if [ $crash_count -ge $MAX_CRASHES ]; then
    echo "Bailing: MAX_CONSECUTIVE_CRASHES reached"
    exit 1
fi

echo "MAX_SESSIONS reached without COMPLETE"
exit 0
