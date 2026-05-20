#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; [ -n "${RUN_TS:-}" ] && tmux kill-session -t "orch-wd-$RUN_TS" 2>/dev/null || tmux kill-server 2>/dev/null || true' EXIT

# Fake claude: working session commits run-folder state then COMPLETE;
# wind-down session pretends to merge and prints COMPLETE.
mkdir -p "$TMP/fake-bin"
cat > "$TMP/fake-bin/claude" <<'EOF'
#!/bin/bash
prompt=$(cat)
if echo "$prompt" | grep -q "wind-down session"; then
    # Wind-down: do best-effort merge ops; failures swallowed because the
    # fixture has no real remote.
    git checkout master 2>/dev/null || true
    git pull origin master 2>/dev/null || true
    branch=$(echo "$prompt" | grep "Run branch:" | sed -E 's/.*Run branch:[[:space:]]+([^[:space:]]+).*/\1/')
    git merge --ff-only "$branch" 2>/dev/null || true
    git push origin master 2>/dev/null || true
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"wind-down done\nCOMPLETE"}'
else
    # Working session: commit the run-folder state files cmd_run created so
    # the worktree is clean (otherwise Cat D fires and wind-down never runs).
    git add -A
    git -c user.email=test@test -c user.name=test commit --allow-empty -q -m "session work" 2>/dev/null || true
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"all good\nCOMPLETE"}'
fi
exit 0
EOF
chmod +x "$TMP/fake-bin/claude"

cd "$TMP"
git init -q && git checkout -b feature/test-rip -q 2>/dev/null || git branch -m feature/test-rip 2>/dev/null
git -c user.email=test@test -c user.name=test commit --allow-empty -q -m "init"

"$REPO/bin/orchestra" init . 2>&1

cat > .orchestra/CONFIG.md <<EOF
- \`MAX_SESSIONS\`: 1
- \`MAX_CONSECUTIVE_CRASHES\`: 1
- \`MODEL\`: opus
- \`WORKTREE_PATH\`: $(realpath "$TMP")
- \`TMUX_PREFIX\`: orch-wd
- \`QUOTA_PACING\`: false
- \`COOLDOWN_SECONDS\`: 0
- \`CRASH_COOLDOWN_SECONDS\`: 0
EOF
echo "stub" > .orchestra/OBJECTIVE.md
git add -A
git -c user.email=test@test -c user.name=test commit -q -m "config"

PATH="$TMP/fake-bin:$PATH" .orchestra/runtime/bin/orchestra run 2>&1

# Wait for orchestrator to finish (working session + wind-down + archive).
# The break exits the loop on the first iteration where WORKTREE is non-empty
# AND the tmux session is gone (i.e. orchestrator has exited).
RUN_TS=""
for _ in $(seq 1 60); do
    # Active or archived — whichever appears
    WT=$(find "$TMP/.orchestra/runs" -mindepth 1 -maxdepth 1 -type d -not -name archive 2>/dev/null | head -1 || true)
    if [ -z "$WT" ]; then
        WT=$(find "$TMP/.orchestra/runs/archive" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 || true)
    fi
    if [ -n "$WT" ]; then
        RUN_TS="$(basename "$WT")"
        tmux has-session -t "orch-wd-$RUN_TS" 2>/dev/null || break
    fi
    sleep 1
done

# Run should be archived (run-in-place: archive at <project>/.orchestra/runs/archive/<ts>/).
ls -d "$TMP/.orchestra/runs/archive"/*/ >/dev/null 2>&1 || { echo "run not archived"; exit 1; }

# Lock file should be released.
[ ! -f "$TMP/.orchestra/runs/.wind-down.lock" ] || { echo "lock not released"; exit 1; }

echo "OK"
