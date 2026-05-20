#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

# Use a fake Claude binary that exits 1 immediately
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; [ -n "${RUN_TS:-}" ] && tmux kill-session -t "orch-test-$RUN_TS" 2>/dev/null || tmux kill-server 2>/dev/null || true' EXIT

mkdir -p "$TMP/fake-bin"
# Drain stdin before exit to avoid the SIGPIPE race against the orchestrator's
# heredoc-piped prompt (would otherwise occasionally surface as exit 141
# instead of 1 under set -o pipefail).
cat > "$TMP/fake-bin/claude" <<'EOF'
#!/bin/bash
cat >/dev/null
echo "simulated crash" >&2
exit 1
EOF
chmod +x "$TMP/fake-bin/claude"

cd "$TMP"
git init -q && git checkout -b feature/test-rip -q 2>/dev/null || git branch -m feature/test-rip 2>/dev/null
git -C . commit --allow-empty -q -m "init"
"$REPO/bin/orchestra" init . 2>&1

cat > .orchestra/CONFIG.md <<EOF
- \`MAX_SESSIONS\`: 5
- \`MAX_CONSECUTIVE_CRASHES\`: 2
- \`MODEL\`: opus
- \`WORKTREE_PATH\`: $(realpath "$TMP")
- \`TMUX_PREFIX\`: orch-test
- \`QUOTA_PACING\`: false
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
for _ in $(seq 1 30); do
    WT=$(find "$TMP/.orchestra/runs" -mindepth 1 -maxdepth 1 -type d -not -name archive 2>/dev/null | head -1 || true)
    if [ -z "$WT" ]; then
        sleep 1
        continue
    fi
    RUN_TS="$(basename "$WT")"
    tmux has-session -t "orch-test-$RUN_TS" 2>/dev/null || break
    sleep 1
done

WORKTREE=$(find "$TMP/.orchestra/runs" -mindepth 1 -maxdepth 1 -type d -not -name archive | head -1)
RUN_DIR="$WORKTREE/"

# Should have written 2 session transcripts (MAX_CONSECUTIVE_CRASHES=2).
# Match [0-9]*.json so summary.json doesn't inflate the count.
n=$(ls "${RUN_DIR}9-sessions/"[0-9]*.json 2>/dev/null | wc -l)
[ "$n" -eq 2 ] || { echo "expected 2 session transcripts, got $n"; exit 1; }

# Both summary entries should have crash_category=A and exit_code != 0
summary="${RUN_DIR}9-sessions/summary.json"
entries=$(jq 'length' "$summary")
[ "$entries" -eq 2 ] || { echo "expected 2 summary entries, got $entries"; exit 1; }
for i in 0 1; do
    cat=$(jq -r ".[$i].crash_category" "$summary")
    code=$(jq -r ".[$i].exit_code" "$summary")
    [ "$cat" = "A" ] || { echo "entry $i: expected category A, got $cat"; exit 1; }
    [ "$code" != "0" ] || { echo "entry $i: expected non-zero exit"; exit 1; }
done

echo "OK"
