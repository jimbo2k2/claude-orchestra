#!/bin/bash
# Issue 2 regression: when claude exits non-zero, the watchdog must preserve
# stderr in $RUN_DIR/9-sessions/NNN-stderr.txt for wind-down diagnostics.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; [ -n "${RUN_TS:-}" ] && tmux kill-session -t "orch-stderr-$RUN_TS" 2>/dev/null || tmux kill-server 2>/dev/null || true' EXIT

# Fake claude that exits 1 with a recognisable diagnostic on stderr.
mkdir -p "$TMP/fake-bin"
cat > "$TMP/fake-bin/claude" <<'EOF'
#!/bin/bash
echo "FAKE_CLAUDE_DIAGNOSTIC_TOKEN: simulated failure" >&2
exit 1
EOF
chmod +x "$TMP/fake-bin/claude"

cd "$TMP"
git init -q --initial-branch=master
git -C . commit --allow-empty -q -m "init"
"$REPO/bin/orchestra" init . 2>&1

cat > .orchestra/CONFIG.md <<EOF
- \`MAX_SESSIONS\`: 1
- \`MAX_CONSECUTIVE_CRASHES\`: 2
- \`MODEL\`: opus
- \`WORKTREE_BASE\`: $TMP/wt
- \`BASE_BRANCH\`: master
- \`TMUX_PREFIX\`: orch-stderr
- \`QUOTA_PACING\`: false
- \`COOLDOWN_SECONDS\`: 0
- \`CRASH_COOLDOWN_SECONDS\`: 0
EOF
echo "stub" > .orchestra/OBJECTIVE.md
git add -A
git commit -q -m "config"

PATH="$TMP/fake-bin:$PATH" .orchestra/runtime/bin/orchestra run 2>&1

# Wait for orchestrator to bail (MAX_SESSIONS=1 → one crash then exit).
for _ in $(seq 1 30); do
    WT=$(ls -d "$TMP/wt"/run-* 2>/dev/null | head -1 || true)
    if [ -z "$WT" ]; then
        sleep 1
        continue
    fi
    RUN_TS="${WT##*/run-}"
    tmux has-session -t "orch-stderr-$RUN_TS" 2>/dev/null || break
    sleep 1
done

WORKTREE=$(ls -d "$TMP/wt"/run-* | head -1)
RUN_DIR=$(ls -d "$WORKTREE"/.orchestra/runs/*/ | head -1)

# Issue 2 assertion: stderr file must exist and contain the diagnostic.
STDERR_FILE="${RUN_DIR}9-sessions/001-stderr.txt"
[ -f "$STDERR_FILE" ] || { echo "expected $STDERR_FILE to exist"; ls -la "${RUN_DIR}9-sessions/" || true; exit 1; }
grep -q "FAKE_CLAUDE_DIAGNOSTIC_TOKEN" "$STDERR_FILE" \
    || { echo "expected diagnostic token in $STDERR_FILE; got:"; cat "$STDERR_FILE"; exit 1; }

echo "OK"
