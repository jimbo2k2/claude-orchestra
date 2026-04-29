#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; tmux kill-server 2>/dev/null || true' EXIT

# Fake claude that hangs forever (drains stdin first to avoid SIGPIPE race)
mkdir -p "$TMP/fake-bin"
cat > "$TMP/fake-bin/claude" <<'EOF'
#!/bin/bash
cat >/dev/null
sleep 9999
EOF
chmod +x "$TMP/fake-bin/claude"

cd "$TMP"
git init -q --initial-branch=master
git -C . commit --allow-empty -q -m "init"
"$REPO/bin/orchestra" init . 2>&1

cat > .orchestra/CONFIG.md <<EOF
- \`MAX_SESSIONS\`: 1
- \`MAX_CONSECUTIVE_CRASHES\`: 1
- \`MAX_HANG_SECONDS\`: 60
- \`MODEL\`: opus
- \`WORKTREE_BASE\`: $TMP/wt
- \`BASE_BRANCH\`: master
- \`TMUX_PREFIX\`: orch-c
- \`COOLDOWN_SECONDS\`: 0
- \`CRASH_COOLDOWN_SECONDS\`: 0
EOF
echo "stub" > .orchestra/OBJECTIVE.md
git add -A
git commit -q -m "config"

PATH="$TMP/fake-bin:$PATH" .orchestra/runtime/bin/orchestra run 2>&1

# Wait — should bail in ~90s (MAX_HANG_SECONDS=60 + 30s grace).
WORKTREE=""
for i in $(seq 1 14); do
    WORKTREE=$(ls -d "$TMP/wt"/run-* 2>/dev/null | head -1 || true)
    if [ -n "$WORKTREE" ]; then
        RUN_TS="${WORKTREE##*/run-}"
        tmux has-session -t "orch-c-$RUN_TS" 2>/dev/null || break
    fi
    sleep 10
done

WORKTREE=$(ls -d "$TMP/wt"/run-* | head -1)
RUN_DIR=$(ls -d "$WORKTREE"/.orchestra/runs/*/ | head -1)

cat=$(jq -r '.crash_category' "${RUN_DIR}9-sessions/001.json")
[ "$cat" = "C" ] || { echo "expected C, got $cat"; exit 1; }

echo "OK"
