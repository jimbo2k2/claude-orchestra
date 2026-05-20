#!/bin/bash
# Tests for `orchestra status` and `orchestra reset` in run-in-place.
# Spec §§ 3.1, 4 (cmd_status, cmd_reset).
#
# Two scenarios run in separate tmpdirs (different TMUX_PREFIXes) to keep
# fixtures simple:
#   1. COMPLETE path — fake claude commits + emits COMPLETE; orchestrator
#      runs wind-down, archives the run. status should report archived count
#      and "(no active runs)".
#   2. BLOCKED path — fake claude emits BLOCKED, leaving a BLOCKED marker.
#      status should show "BLOCKED". reset should archive it. status after
#      should reflect the new archived count.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

TMP_COMPLETE=$(mktemp -d)
TMP_BLOCKED=$(mktemp -d)
trap 'rm -rf "$TMP_COMPLETE" "$TMP_BLOCKED" 2>/dev/null || true; tmux kill-session -t "orch-sr-c-${RUN_TS:-x}" 2>/dev/null || true; tmux kill-session -t "orch-sr-b-${RUN_TS:-x}" 2>/dev/null || true' EXIT

# ---------- Scenario 1: COMPLETE path (run gets archived by wind-down) ----------

mkdir -p "$TMP_COMPLETE/fake-bin"
cat > "$TMP_COMPLETE/fake-bin/claude" <<'EOF'
#!/bin/bash
prompt=$(cat)
if echo "$prompt" | grep -q "wind-down session"; then
    # Wind-down session: legacy-mode here (no Governance/), so Step 2 would
    # append 3/4/5 to parent files. We fake the verification commit by writing
    # an empty SUMMARY update and committing.
    rd=$(echo "$prompt" | grep -oE '/[a-zA-Z0-9_/.-]*\.orchestra/runs/[^/ ]+' | head -1)
    if [ -n "$rd" ] && [ -d "$rd" ]; then
        echo "## Wind-down" >> "$rd/7-SUMMARY.md"
        git -c user.email=t@t -c user.name=t add "$rd/7-SUMMARY.md" 2>/dev/null || true
        git -c user.email=t@t -c user.name=t commit -q -m "wind-down: governance verification (fake)" 2>/dev/null || true
    fi
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"COMPLETE"}'
else
    git add -A 2>/dev/null || true
    git -c user.email=t@t -c user.name=t commit --allow-empty -q -m "session work" 2>/dev/null || true
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"doing work\nCOMPLETE"}'
fi
exit 0
EOF
chmod +x "$TMP_COMPLETE/fake-bin/claude"

cd "$TMP_COMPLETE"
git init -q
git checkout -b feature/sr-complete -q 2>/dev/null || git branch -m feature/sr-complete 2>/dev/null
git -c user.email=t@t -c user.name=t commit --allow-empty -q -m "init"

"$REPO/bin/orchestra" init . >/dev/null

WT_PATH_C=$(realpath "$TMP_COMPLETE")
cat > .orchestra/CONFIG.md <<EOF
- \`MAX_SESSIONS\`: 1
- \`MAX_CONSECUTIVE_CRASHES\`: 1
- \`MODEL\`: opus
- \`WORKTREE_PATH\`: $WT_PATH_C
- \`TMUX_PREFIX\`: orch-sr-c
- \`QUOTA_PACING\`: false
- \`COOLDOWN_SECONDS\`: 0
- \`CRASH_COOLDOWN_SECONDS\`: 0
EOF
echo "stub" > .orchestra/OBJECTIVE.md
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "config"

PATH="$TMP_COMPLETE/fake-bin:$PATH" .orchestra/runtime/bin/orchestra run 2>&1

# Wait for tmux session to end (run completes + archives).
for _ in $(seq 1 60); do
    RUN_FOLDER=$(find .orchestra/runs/archive -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 || true)
    if [ -n "$RUN_FOLDER" ]; then
        RUN_TS="$(basename "$RUN_FOLDER")"
        tmux has-session -t "orch-sr-c-$RUN_TS" 2>/dev/null || break
    else
        ACTIVE=$(find .orchestra/runs -mindepth 1 -maxdepth 1 -type d -not -name archive 2>/dev/null | head -1 || true)
        if [ -n "$ACTIVE" ]; then
            RUN_TS="$(basename "$ACTIVE")"
            tmux has-session -t "orch-sr-c-$RUN_TS" 2>/dev/null || break
        fi
    fi
    sleep 1
done

ARCHIVED=$(find .orchestra/runs/archive -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
[ -n "$ARCHIVED" ] || { echo "scenario 1: expected archived run, none found"; exit 1; }

STATUS_OUT=$("$REPO/bin/orchestra" status 2>&1)

echo "$STATUS_OUT" | grep -q "Archived runs: 1" \
    || { echo "scenario 1: expected 'Archived runs: 1'; got:"; echo "$STATUS_OUT"; exit 1; }

echo "$STATUS_OUT" | grep -qE "(no active runs)" \
    || { echo "scenario 1: expected '(no active runs)' line; got:"; echo "$STATUS_OUT"; exit 1; }

# ---------- Scenario 2: BLOCKED path + reset ----------

mkdir -p "$TMP_BLOCKED/fake-bin"
cat > "$TMP_BLOCKED/fake-bin/claude" <<'EOF'
#!/bin/bash
prompt=$(cat)
rd=$(echo "$prompt" | grep -oE '/[a-zA-Z0-9_/.-]*\.orchestra/runs/[^/ ]+' | head -1)
echo "Cannot proceed without API key" > "$rd/6-HANDOVER.md"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"stuck\nBLOCKED"}'
exit 0
EOF
chmod +x "$TMP_BLOCKED/fake-bin/claude"

cd "$TMP_BLOCKED"
git init -q
git checkout -b feature/sr-blocked -q 2>/dev/null || git branch -m feature/sr-blocked 2>/dev/null
git -c user.email=t@t -c user.name=t commit --allow-empty -q -m "init"
"$REPO/bin/orchestra" init . >/dev/null

WT_PATH_B=$(realpath "$TMP_BLOCKED")
cat > .orchestra/CONFIG.md <<EOF
- \`MAX_SESSIONS\`: 5
- \`MAX_CONSECUTIVE_CRASHES\`: 2
- \`MODEL\`: opus
- \`WORKTREE_PATH\`: $WT_PATH_B
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
for _ in $(seq 1 60); do
    ACTIVE=$(find .orchestra/runs -mindepth 1 -maxdepth 1 -type d -not -name archive 2>/dev/null | head -1 || true)
    if [ -n "$ACTIVE" ]; then
        RUN_TS="$(basename "$ACTIVE")"
        tmux has-session -t "orch-sr-b-$RUN_TS" 2>/dev/null || break
    fi
    sleep 1
done

ACTIVE=$(find .orchestra/runs -mindepth 1 -maxdepth 1 -type d -not -name archive 2>/dev/null | head -1)
[ -n "$ACTIVE" ] || { echo "scenario 2: expected active BLOCKED run folder"; exit 1; }
RUN_TS="$(basename "$ACTIVE")"
RUN_DIR="$ACTIVE"

[ -f "$RUN_DIR/BLOCKED" ] || { echo "scenario 2: expected BLOCKED marker in $RUN_DIR"; exit 1; }

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

[ -d ".orchestra/runs/archive/$RUN_TS" ] \
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
