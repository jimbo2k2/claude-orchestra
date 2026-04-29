#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="$(pwd)"
TMP=$(mktemp -d)
trap "rm -rf $TMP; tmux kill-server 2>/dev/null || true" EXIT

# Inject a fake claude so we don't invoke the real CLI from a test.
# A bare "COMPLETE" output produces a clean session_signal, exit 0 — perfect
# for verifying that the worktree/run-dir/files lifecycle is set up.
mkdir -p "$TMP/fake-bin"
cat > "$TMP/fake-bin/claude" <<'EOF'
#!/bin/bash
# Drain stdin so the orchestrator's prompt heredoc doesn't SIGPIPE us.
cat >/dev/null
echo "COMPLETE"
EOF
chmod +x "$TMP/fake-bin/claude"

# Set up a fixture project
cd "$TMP"
git init -q --initial-branch=master
git -C . commit --allow-empty -q -m "init"

"$REPO/bin/orchestra" init . 2>&1

# Replace CONFIG.md with workable test config
cat > .orchestra/CONFIG.md <<EOF
- \`MAX_SESSIONS\`: 1
- \`MAX_CONSECUTIVE_CRASHES\`: 1
- \`MODEL\`: opus
- \`WORKTREE_BASE\`: $TMP/wt
- \`BASE_BRANCH\`: master
- \`TMUX_PREFIX\`: orch-test
- \`COOLDOWN_SECONDS\`: 0
- \`CRASH_COOLDOWN_SECONDS\`: 0
EOF

cat > .orchestra/OBJECTIVE.md <<'EOF'
Stub objective.
EOF

git add -A
git commit -q -m "config + objective"

# Run with fake claude on PATH (real claude would run and do real work)
PATH="$TMP/fake-bin:$PATH" .orchestra/runtime/bin/orchestra run 2>&1

# Wait for orchestrator to finish (one session, COMPLETE signal, exits fast)
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

# Assertions
ls "$TMP/wt"/run-* >/dev/null 2>&1 || { echo "no worktree created"; exit 1; }
WORKTREE=$(ls -d "$TMP/wt"/run-* | head -1)
[ -d "$WORKTREE/.orchestra/runs" ] || { echo "no runs dir in worktree"; exit 1; }
RUN_DIR=$(ls -d "$WORKTREE"/.orchestra/runs/*/ | head -1)
[ -d "${RUN_DIR}9-sessions" ] || { echo "no 9-sessions in run dir"; exit 1; }

# Orchestrator wrote a session JSON for the COMPLETE run
[ -f "${RUN_DIR}9-sessions/001.json" ] || { echo "session JSON missing"; exit 1; }

# Required files exist (created by cmd_run, not the agent yet)
for f in 1-INBOX.md 2-OBJECTIVE.md 3-TODO.md 4-DECISIONS.md 5-CHANGELOG.md 6-HANDOVER.md 7-SUMMARY.md; do
    [ -f "${RUN_DIR}$f" ] || { echo "missing $f"; exit 1; }
done

# OBJECTIVE.md was snapshotted (within-worktree copy, per spec Section 4)
grep -q "Stub objective" "${RUN_DIR}2-OBJECTIVE.md" || { echo "OBJECTIVE.md not snapshotted"; exit 1; }

# --- Setup-failure cleanup test ---
# Bad CONFIG: WORKTREE_BASE is a path that can't be written to
TMP3=$(mktemp -d)
cd "$TMP3"
git init -q --initial-branch=master
git -C . commit --allow-empty -q -m "init"
"$REPO/bin/orchestra" init . 2>&1
cat > .orchestra/CONFIG.md <<EOF
- \`MAX_SESSIONS\`: 1
- \`MAX_CONSECUTIVE_CRASHES\`: 1
- \`MODEL\`: opus
- \`WORKTREE_BASE\`: /proc/orchestra-cant-write
- \`BASE_BRANCH\`: master
EOF
echo "stub" > .orchestra/OBJECTIVE.md
git add -A
git commit -q -m "bad config"

if .orchestra/runtime/bin/orchestra run 2>/dev/null; then
    rm -rf "$TMP3"
    echo "expected run to fail with bad WORKTREE_BASE"
    exit 1
fi

# After failure, no orphan run folder should remain
if ls -d .orchestra/runs/2*/ 2>/dev/null | grep -q .; then
    rm -rf "$TMP3"
    echo "orphan run folder not cleaned up after setup failure"
    exit 1
fi
rm -rf "$TMP3"

echo "OK"
