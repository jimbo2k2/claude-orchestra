#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; [ -n "${RUN_TS:-}" ] && tmux kill-session -t "orch-bd-$RUN_TS" 2>/dev/null || tmux kill-server 2>/dev/null || true' EXIT

# Fake claude that exits 0 with no recognised signal (Category B)
mkdir -p "$TMP/fake-bin"
cat > "$TMP/fake-bin/claude" <<'EOF'
#!/bin/bash
# Stream-json result event whose .result text contains no recognised signal
# (Category B: clean exit, no COMPLETE/HANDOVER/BLOCKED).
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"I did some thinking but forgot the signal"}'
exit 0
EOF
chmod +x "$TMP/fake-bin/claude"

cd "$TMP"
git init -q --initial-branch=master
git -C . commit --allow-empty -q -m "init"
"$REPO/bin/orchestra" init . 2>&1

cat > .orchestra/CONFIG.md <<EOF
- \`MAX_SESSIONS\`: 5
- \`MAX_CONSECUTIVE_CRASHES\`: 2
- \`MODEL\`: opus
- \`WORKTREE_BASE\`: $TMP/wt
- \`BASE_BRANCH\`: master
- \`TMUX_PREFIX\`: orch-bd
- \`QUOTA_PACING\`: false
- \`COOLDOWN_SECONDS\`: 0
- \`CRASH_COOLDOWN_SECONDS\`: 0
EOF
echo "stub" > .orchestra/OBJECTIVE.md
git add -A
git commit -q -m "config"

PATH="$TMP/fake-bin:$PATH" .orchestra/runtime/bin/orchestra run 2>&1

# Wait — use precise has-session match, consistent with the rest of the suite.
for _ in $(seq 1 30); do
    WT=$(ls -d "$TMP/wt"/run-* 2>/dev/null | head -1 || true)
    if [ -z "$WT" ]; then
        sleep 1
        continue
    fi
    RUN_TS="${WT##*/run-}"
    tmux has-session -t "orch-bd-$RUN_TS" 2>/dev/null || break
    sleep 1
done

WORKTREE=$(ls -d "$TMP/wt"/run-* | head -1)
RUN_DIR=$(ls -d "$WORKTREE"/.orchestra/runs/*/ | head -1)

# Both summary entries should have crash_category=B
summary="${RUN_DIR}9-sessions/summary.json"
entries=$(jq 'length' "$summary")
[ "$entries" -ge 1 ] || { echo "expected at least 1 summary entry"; exit 1; }
for i in $(seq 0 $((entries - 1))); do
    cat=$(jq -r ".[$i].crash_category" "$summary")
    [ "$cat" = "B" ] || { echo "entry $i: expected B, got $cat"; exit 1; }
done

echo "OK"
