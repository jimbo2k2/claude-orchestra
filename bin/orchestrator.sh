#!/bin/bash
# orchestrator.sh — session loop running inside the run worktree's tmux.
# Spec: docs/superpowers/specs/2026-04-29-orchestra-cleanup-design.md Sections 6, 11.
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

WINDDOWN_LOCK="$WORKTREE_DIR/.orchestra/runs/.wind-down.lock"

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
    local cat="$1" out="$2" handover="$3"
    {
        echo "Failed at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "Category: $cat"
        echo ""
        echo "--- Last 50 lines of session output ---"
        echo "$out" | tail -50
        if [ "$cat" = "BLOCKED" ] && [ -n "$handover" ] && [ -f "$handover" ]; then
            echo ""
            echo "--- Conflict/push-failure details from 6-HANDOVER.md ---"
            cat "$handover"
        fi
    } > "$RUN_DIR/WIND-DOWN-FAILED"
}

print_winddown_recovery() {
    local cat="$1"
    cat <<EOF >&2

WIND-DOWN FAILED ($cat). Run preserved at:
  $RUN_DIR

Run branch: $RUN_BRANCH

EOF
    case "$cat" in
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
        --model "$MODEL" --thinking-effort "$EFFORT" \
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
- COMPLETE — objective met, ready for wind-down (worktree must be clean)
- HANDOVER — more work remains, write 6-HANDOVER.md briefing for the next session
- BLOCKED — external dependency missing; write 6-HANDOVER.md with remaining-work and dependency analysis

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
        cd "$WORKTREE_DIR"
        if [ -n "$(git status --porcelain)" ]; then
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
    elif [ "$category" = "D" ]; then
        # Spec Section 11.D: don't increment counter, don't restart;
        # wind-down's recovery prompt will assess the dirty state.
        echo "Category D: COMPLETE with dirty worktree — deferring to wind-down (Phase 9)"
        exit 0
    else
        crash_count=0
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

                # Wind-down runs under the same hang-detection watchdog as
                # working sessions so a stuck wind-down (e.g. claude blocked on
                # a prompt) is detectable as Cat C. Stderr is preserved on
                # failure into RUN_DIR/wind-down-stderr.txt — wind-down is a
                # single-attempt session, not a numbered series under
                # 9-sessions/, so the file lives directly under RUN_DIR.
                wd_stdout_log=$(mktemp)
                wd_stderr_log=$(mktemp)
                set +e
                run_session_with_watchdog "$wd_prompt" "$wd_stdout_log" "$wd_stderr_log"
                wd_code=$?
                set -e
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
            BLOCKED)  echo "BLOCKED — Phase 12 will handle this"; exit 0 ;;
        esac
    fi
done

if [ $crash_count -ge $MAX_CRASHES ]; then
    echo "Bailing: MAX_CONSECUTIVE_CRASHES reached"
    exit 1
fi

echo "MAX_SESSIONS reached without COMPLETE"
exit 0
