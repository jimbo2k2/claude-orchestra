#!/bin/bash
# Tests for `orchestra status` and `orchestra reset` (Phase 15).
#
# Two scenarios run in separate tmpdirs (different TMUX_PREFIXes) to keep
# fixtures simple:
#   1. COMPLETE path — fake claude commits + emits COMPLETE; orchestrator
#      runs wind-down, archives the run. status should report archived count
#      and "(no active runs)".
#   2. BLOCKED path — fake claude emits BLOCKED, leaving a BLOCKED marker in
#      the worktree run dir (not archived). status should show "BLOCKED".
#      reset should move the BLOCKED run into archive. status afterward should
#      reflect the new archived count.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

TMP_COMPLETE=$(mktemp -d)
TMP_BLOCKED=$(mktemp -d)
trap 'rm -rf "$TMP_COMPLETE" "$TMP_BLOCKED"; tmux kill-server 2>/dev/null || true' EXIT

# ---------- Scenario 1: COMPLETE path (run gets archived by wind-down) ----------

mkdir -p "$TMP_COMPLETE/fake-bin"
cat > "$TMP_COMPLETE/fake-bin/claude" <<'EOF'
#!/bin/bash
prompt=$(cat)
if echo "$prompt" | grep -q "wind-down session"; then
    # Wind-down session: nothing to ingest, just merge + push.
    rd=$(echo "$prompt" | grep "Run dir:" | grep -oE '/[^ ]+\.orchestra/runs/[^ ]+' | head -1)
    branch=$(git rev-parse --abbrev-ref HEAD)
    git -c user.email=t@t -c user.name=t checkout master 2>/dev/null
    git -c user.email=t@t -c user.name=t merge --no-ff "$branch" -m "merge $branch" 2>/dev/null
    git -c user.email=t@t -c user.name=t push origin master 2>/dev/null
    echo "merged"
    echo "COMPLETE"
else
    git add -A 2>/dev/null || true
    git -c user.email=t@t -c user.name=t commit --allow-empty -q -m "session work" 2>/dev/null || true
    echo "doing work"
    echo "COMPLETE"
fi
exit 0
EOF
chmod +x "$TMP_COMPLETE/fake-bin/claude"

cd "$TMP_COMPLETE"
git init -q --initial-branch=master
git -c user.email=t@t -c user.name=t commit --allow-empty -q -m "init"

# Bare remote so wind-down's `git push origin master` succeeds.
BARE_C="$TMP_COMPLETE/origin.git"
git init -q --bare "$BARE_C"
git remote add origin "$BARE_C"
git -c user.email=t@t -c user.name=t push -q origin master

"$REPO/bin/orchestra" init . >/dev/null

cat > .orchestra/CONFIG.md <<EOF
- \`MAX_SESSIONS\`: 1
- \`MAX_CONSECUTIVE_CRASHES\`: 1
- \`MODEL\`: opus
- \`WORKTREE_BASE\`: $TMP_COMPLETE/wt
- \`BASE_BRANCH\`: master
- \`TMUX_PREFIX\`: orch-sr-c
- \`QUOTA_PACING\`: false
- \`COOLDOWN_SECONDS\`: 0
- \`CRASH_COOLDOWN_SECONDS\`: 0
EOF
echo "stub" > .orchestra/OBJECTIVE.md
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "config"
git -c user.email=t@t -c user.name=t push -q origin master

PATH="$TMP_COMPLETE/fake-bin:$PATH" .orchestra/runtime/bin/orchestra run 2>&1

# Wait for tmux session to end (run completes + archives).
WORKTREE=""
for _ in $(seq 1 60); do
    WORKTREE=$(find "$TMP_COMPLETE/wt" -mindepth 1 -maxdepth 1 -type d -name 'run-*' -print -quit 2>/dev/null)
    if [ -n "$WORKTREE" ]; then
        RUN_TS="${WORKTREE##*/run-}"
        tmux has-session -t "orch-sr-c-$RUN_TS" 2>/dev/null || break
    fi
    sleep 1
done

# Verify the run was archived.
ARCHIVED=$(find "$TMP_COMPLETE/wt" -mindepth 5 -maxdepth 5 -type d -path '*/runs/archive/*' -print -quit 2>/dev/null)
[ -n "$ARCHIVED" ] || { echo "scenario 1: expected archived run, none found"; exit 1; }

# Run `orchestra status` and capture output.
STATUS_OUT=$("$REPO/bin/orchestra" status 2>&1)

echo "$STATUS_OUT" | grep -q "Archived runs: 1" \
    || { echo "scenario 1: expected 'Archived runs: 1'; got:"; echo "$STATUS_OUT"; exit 1; }

# After wind-down archives the run dir, the gate folder remains but the
# worktree run dir is gone — status reports it as "archived".
echo "$STATUS_OUT" | grep -qE "($RUN_TS: archived|\(no active runs\))" \
    || { echo "scenario 1: expected archived/no-active line; got:"; echo "$STATUS_OUT"; exit 1; }

# ---------- Scenario 2: BLOCKED path + reset ----------

mkdir -p "$TMP_BLOCKED/fake-bin"
cat > "$TMP_BLOCKED/fake-bin/claude" <<'EOF'
#!/bin/bash
prompt=$(cat)
rd=$(echo "$prompt" | grep -oE '/[a-zA-Z0-9_/.-]*\.orchestra/runs/[^/ ]+' | head -1)
echo "Cannot proceed without API key" > "$rd/6-HANDOVER.md"
echo "stuck"
echo "BLOCKED"
exit 0
EOF
chmod +x "$TMP_BLOCKED/fake-bin/claude"

cd "$TMP_BLOCKED"
git init -q --initial-branch=master
git -c user.email=t@t -c user.name=t commit --allow-empty -q -m "init"
"$REPO/bin/orchestra" init . >/dev/null

cat > .orchestra/CONFIG.md <<EOF
- \`MAX_SESSIONS\`: 5
- \`MAX_CONSECUTIVE_CRASHES\`: 2
- \`MODEL\`: opus
- \`WORKTREE_BASE\`: $TMP_BLOCKED/wt
- \`BASE_BRANCH\`: master
- \`TMUX_PREFIX\`: orch-sr-b
- \`QUOTA_PACING\`: false
- \`COOLDOWN_SECONDS\`: 0
- \`CRASH_COOLDOWN_SECONDS\`: 0
EOF
echo "stub" > .orchestra/OBJECTIVE.md
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "config"

PATH="$TMP_BLOCKED/fake-bin:$PATH" .orchestra/runtime/bin/orchestra run 2>&1

# Wait for tmux session to terminate (BLOCKED halts immediately).
WORKTREE=""
for _ in $(seq 1 60); do
    WORKTREE=$(find "$TMP_BLOCKED/wt" -mindepth 1 -maxdepth 1 -type d -name 'run-*' -print -quit 2>/dev/null)
    if [ -n "$WORKTREE" ]; then
        RUN_TS="${WORKTREE##*/run-}"
        tmux has-session -t "orch-sr-b-$RUN_TS" 2>/dev/null || break
    fi
    sleep 1
done

WORKTREE=$(find "$TMP_BLOCKED/wt" -mindepth 1 -maxdepth 1 -type d -name 'run-*' -print -quit)
RUN_TS="${WORKTREE##*/run-}"
RUN_DIR="$WORKTREE/.orchestra/runs/$RUN_TS"

[ -f "$RUN_DIR/BLOCKED" ] || { echo "scenario 2: expected BLOCKED marker"; exit 1; }

# `orchestra status` should report BLOCKED.
STATUS_OUT=$("$REPO/bin/orchestra" status 2>&1)
echo "$STATUS_OUT" | grep -q "BLOCKED" \
    || { echo "scenario 2: status missing BLOCKED; got:"; echo "$STATUS_OUT"; exit 1; }
echo "$STATUS_OUT" | grep -q "Archived runs: 0" \
    || { echo "scenario 2: expected 'Archived runs: 0'; got:"; echo "$STATUS_OUT"; exit 1; }

# `orchestra reset` should archive the BLOCKED run.
RESET_OUT=$("$REPO/bin/orchestra" reset 2>&1)
echo "$RESET_OUT" | grep -qE "Reset: 1 run folder\(s\) archived\." \
    || { echo "scenario 2: reset summary unexpected: $RESET_OUT"; exit 1; }

[ -d "$WORKTREE/.orchestra/runs/archive/$RUN_TS" ] \
    || { echo "scenario 2: BLOCKED run not moved to archive"; exit 1; }
[ ! -d "$RUN_DIR" ] \
    || { echo "scenario 2: original run dir still present after reset"; exit 1; }

# `orchestra status` after reset: archived count incremented to 1, no active runs.
STATUS_OUT=$("$REPO/bin/orchestra" status 2>&1)
echo "$STATUS_OUT" | grep -q "Archived runs: 1" \
    || { echo "scenario 2: post-reset expected 'Archived runs: 1'; got:"; echo "$STATUS_OUT"; exit 1; }
echo "$STATUS_OUT" | grep -q "(no active runs)" \
    || { echo "scenario 2: post-reset expected '(no active runs)'; got:"; echo "$STATUS_OUT"; exit 1; }

echo "OK"
