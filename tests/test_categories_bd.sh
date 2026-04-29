#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; tmux kill-server 2>/dev/null || true' EXIT

# Fake claude that exits 0 with no recognised signal (Category B)
mkdir -p "$TMP/fake-bin"
cat > "$TMP/fake-bin/claude" <<'EOF'
#!/bin/bash
echo "I did some thinking but forgot the signal"
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

# Wait
for i in $(seq 1 30); do
    tmux ls 2>/dev/null | grep -q orch-bd || break
    sleep 1
done

WORKTREE=$(ls -d "$TMP/wt"/run-* | head -1)
RUN_DIR=$(ls -d "$WORKTREE"/.orchestra/runs/*/ | head -1)

# Should have 2 session JSONs both with crash_category=B
for f in "${RUN_DIR}9-sessions/"*.json; do
    cat=$(jq -r '.crash_category' "$f")
    [ "$cat" = "B" ] || { echo "$f: expected B, got $cat"; exit 1; }
done

echo "OK"
