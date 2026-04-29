#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

# Use a fake Claude binary that exits 1 immediately
TMP=$(mktemp -d)
trap "rm -rf $TMP; tmux kill-server 2>/dev/null || true" EXIT

mkdir -p "$TMP/fake-bin"
cat > "$TMP/fake-bin/claude" <<'EOF'
#!/bin/bash
echo "simulated crash" >&2
exit 1
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
- \`TMUX_PREFIX\`: orch-test
- \`COOLDOWN_SECONDS\`: 0
- \`CRASH_COOLDOWN_SECONDS\`: 0
EOF
echo "stub" > .orchestra/OBJECTIVE.md
git add -A
git commit -q -m "config"

# Inject fake claude onto PATH for the orchestrator
PATH="$TMP/fake-bin:$PATH" .orchestra/runtime/bin/orchestra run 2>&1

# Wait for orchestrator to bail. Resolve the actual run timestamp from
# the worktree path (the project's .orchestra/runs/ contains an "archive"
# entry from init, so picking the newest entry there is unreliable).
for i in $(seq 1 30); do
    WT=$(ls -d "$TMP/wt"/run-* 2>/dev/null | head -1 || true)
    if [ -z "$WT" ]; then
        sleep 1
        continue
    fi
    RUN_TS="${WT##*/run-}"
    tmux has-session -t "orch-test-$RUN_TS" 2>/dev/null || break
    sleep 1
done

WORKTREE=$(ls -d "$TMP/wt"/run-* | head -1)
RUN_DIR=$(ls -d "$WORKTREE"/.orchestra/runs/*/ | head -1)

# Should have written 2 session JSONs (MAX_CONSECUTIVE_CRASHES=2)
n=$(ls "${RUN_DIR}9-sessions/"*.json 2>/dev/null | wc -l)
[ "$n" -eq 2 ] || { echo "expected 2 session JSONs, got $n"; exit 1; }

# Each should have crash_category=A and exit_code != 0
for f in "${RUN_DIR}9-sessions/"*.json; do
    cat=$(jq -r '.crash_category' "$f")
    code=$(jq -r '.exit_code' "$f")
    [ "$cat" = "A" ] || { echo "$f: expected category A, got $cat"; exit 1; }
    [ "$code" != "0" ] || { echo "$f: expected non-zero exit"; exit 1; }
done

echo "OK"
