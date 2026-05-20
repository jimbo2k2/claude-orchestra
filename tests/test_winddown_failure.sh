#!/bin/bash
# Wind-down failure test for run-in-place. Spec § 3.2.
#
# Run-in-place wind-down BLOCKED narrows to "Step 2 verification commit
# failed" (e.g. pre-commit hook regression). No more merge-conflict or
# push-rejection BLOCKED variants — there is no merge step.

set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; [ -n "${RUN_TS:-}" ] && tmux kill-session -t "orch-wf-$RUN_TS" 2>/dev/null || tmux kill-server 2>/dev/null || true' EXIT

# Fake claude: working session commits then COMPLETE; wind-down session
# emits BLOCKED with a verification-commit-failed HANDOVER.
mkdir -p "$TMP/fake-bin"
cat > "$TMP/fake-bin/claude" <<'EOF'
#!/bin/bash
prompt=$(cat)
if echo "$prompt" | grep -q "wind-down session"; then
    # Run-in-place wind-down BLOCKED shape: Step 2 verification commit failed.
    rd=$(echo "$prompt" | grep -oE '/[a-zA-Z0-9_/.-]*\.orchestra/runs/[^/ ]+' | head -1)
    cat > "$rd/6-HANDOVER.md" <<HOEOF
# Wind-down BLOCKED: Step 2 verification commit failed

## Commit error
Simulated pre-commit hook rejection

## Manual resolution
1. Resolve the underlying issue.
2. git add 7-SUMMARY.md && git commit -m "wind-down: governance verification (manual)"
HOEOF
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"verification commit rejected\nBLOCKED"}'
else
    git add -A
    git -c user.email=t@t -c user.name=t commit --allow-empty -q -m "session" 2>/dev/null || true
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"all good\nCOMPLETE"}'
fi
exit 0
EOF
chmod +x "$TMP/fake-bin/claude"

cd "$TMP"
git init -q
git checkout -b feature/wf-test -q 2>/dev/null || git branch -m feature/wf-test 2>/dev/null
git -c user.email=t@t -c user.name=t commit --allow-empty -q -m "init"
"$REPO/bin/orchestra" init . 2>&1

WT_PATH=$(realpath "$TMP")
cat > .orchestra/CONFIG.md <<EOF
- \`MAX_SESSIONS\`: 1
- \`MAX_CONSECUTIVE_CRASHES\`: 1
- \`MODEL\`: opus
- \`WORKTREE_PATH\`: $WT_PATH
- \`TMUX_PREFIX\`: orch-wf
- \`QUOTA_PACING\`: false
- \`COOLDOWN_SECONDS\`: 0
- \`CRASH_COOLDOWN_SECONDS\`: 0
EOF
echo "stub" > .orchestra/OBJECTIVE.md
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "config"

PATH="$TMP/fake-bin:$PATH" .orchestra/runtime/bin/orchestra run 2>&1

for _ in $(seq 1 60); do
    ACTIVE=$(find .orchestra/runs -mindepth 1 -maxdepth 1 -type d -not -name archive 2>/dev/null | head -1 || true)
    if [ -n "$ACTIVE" ]; then
        RUN_TS="$(basename "$ACTIVE")"
        tmux has-session -t "orch-wf-$RUN_TS" 2>/dev/null || break
    fi
    sleep 1
done

# Run folder must still exist (NOT archived on wind-down failure).
RUN=$(find .orchestra/runs -mindepth 1 -maxdepth 1 -type d -not -name archive 2>/dev/null | head -1)
[ -n "$RUN" ] || { echo "no active run folder found after wind-down failure"; exit 1; }

[ -f "$RUN/WIND-DOWN-FAILED" ] || { echo "no WIND-DOWN-FAILED marker"; exit 1; }
grep -q "Category: BLOCKED" "$RUN/WIND-DOWN-FAILED" || { echo "wrong category"; exit 1; }
grep -q "verification commit" "$RUN/WIND-DOWN-FAILED" || { echo "missing handover content (expected 'verification commit' in marker)"; exit 1; }
grep -q "Failed at: " "$RUN/WIND-DOWN-FAILED" || { echo "missing timestamp"; exit 1; }

# Run NOT archived (preserved for inspection).
[ ! -d ".orchestra/runs/archive/$(basename "$RUN")" ] || { echo "should not archive failed wind-down"; exit 1; }

echo "OK"
