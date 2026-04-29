#!/bin/bash
# Regression test: lock file must record the orchestrator's start-time, not
# awk's start-time (Phase 8 fix-up).
#
# The bug was `awk '{print $22}' /proc/self/stat` inside a command
# substitution — `/proc/self` resolves to awk's own PID, so the lock file
# recorded awk's start-time. The stale-detection branch later reads
# /proc/$lock_pid/stat (the orchestrator's PID) — the two start-times would
# never match, causing any contended acquire to falsely evict the live holder.
#
# This test inspects the lock file mid-flight while the wind-down session is
# sleeping, and asserts the recorded start-time matches what an external
# observer reads from /proc/$lock_pid/stat field 22 for the same PID.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; tmux kill-server 2>/dev/null || true' EXIT

# Fake claude: working session commits and emits COMPLETE; wind-down session
# sleeps long enough for us to inspect the lock file mid-flight.
mkdir -p "$TMP/fake-bin"
cat > "$TMP/fake-bin/claude" <<'EOF'
#!/bin/bash
prompt=$(cat)
if echo "$prompt" | grep -q "wind-down session"; then
    # Hold the lock long enough for the test to inspect it
    sleep 5
    git checkout master 2>/dev/null || true
    branch=$(echo "$prompt" | grep "Run branch:" | sed -E 's/.*Run branch:[[:space:]]+([^[:space:]]+).*/\1/')
    git merge --ff-only "$branch" 2>/dev/null || true
    echo "wind-down done"
    echo "COMPLETE"
else
    git add -A
    git -c user.email=t@t -c user.name=t commit --allow-empty -q -m "session" 2>/dev/null || true
    echo "all good"
    echo "COMPLETE"
fi
EOF
chmod +x "$TMP/fake-bin/claude"

cd "$TMP"
git init -q --initial-branch=master
git -c user.email=t@t -c user.name=t commit --allow-empty -q -m "init"
"$REPO/bin/orchestra" init . 2>&1
cat > .orchestra/CONFIG.md <<EOF
- \`MAX_SESSIONS\`: 1
- \`MAX_CONSECUTIVE_CRASHES\`: 1
- \`MODEL\`: opus
- \`WORKTREE_BASE\`: $TMP/wt
- \`BASE_BRANCH\`: master
- \`TMUX_PREFIX\`: orch-lk
- \`QUOTA_PACING\`: false
- \`COOLDOWN_SECONDS\`: 0
- \`CRASH_COOLDOWN_SECONDS\`: 0
EOF
echo "stub" > .orchestra/OBJECTIVE.md
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "config"

PATH="$TMP/fake-bin:$PATH" .orchestra/runtime/bin/orchestra run 2>&1

# Wait for the lock file to appear (wind-down has spawned and held it)
WORKTREE=""
for _ in $(seq 1 30); do
    WORKTREE=$(ls -d "$TMP/wt"/run-* 2>/dev/null | head -1 || true)
    if [ -n "$WORKTREE" ] && [ -f "$WORKTREE/.orchestra/runs/.wind-down.lock" ]; then
        break
    fi
    sleep 0.5
done

LOCK="$WORKTREE/.orchestra/runs/.wind-down.lock"
[ -f "$LOCK" ] || { echo "lock file never appeared"; exit 1; }

# Inspect the lock while wind-down session is sleeping
lock_pid=$(sed -n '1p' "$LOCK")
lock_starttime=$(sed -n '2p' "$LOCK")
[ -n "$lock_pid" ] || { echo "lock pid empty"; exit 1; }
[ -n "$lock_starttime" ] || { echo "lock starttime empty"; exit 1; }

# The lock file's start-time must match the orchestrator process's real
# start-time as observed externally — otherwise the stale-detection logic
# will always falsely evict.
real_starttime=$(awk '{print $22}' "/proc/$lock_pid/stat")
[ "$lock_starttime" = "$real_starttime" ] || {
    echo "FAIL: lock recorded starttime '$lock_starttime' but /proc/$lock_pid/stat field 22 is '$real_starttime' — stale-detection will always falsely evict"
    exit 1
}

# Wait for wind-down to finish
RUN_TS="${WORKTREE##*/run-}"
for _ in $(seq 1 30); do
    tmux has-session -t "orch-lk-$RUN_TS" 2>/dev/null || break
    sleep 1
done

# Lock should be released
[ ! -f "$LOCK" ] || { echo "lock not released after wind-down"; exit 1; }

echo "OK"
