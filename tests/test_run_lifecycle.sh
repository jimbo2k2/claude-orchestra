#!/bin/bash
# Run lifecycle test for run-in-place. Spec §§ 3.1, 3.2.
# Uses a fake `claude` so we don't invoke the real CLI from a test.

set -euo pipefail
cd "$(dirname "$0")/.."

REPO="$(pwd)"
TMP=$(mktemp -d)
# Scope the tmux kill to this test's session if RUN_TS gets set below; fall
# back to kill-server only as a last resort (RUN_TS may never be set if the
# orchestra run aborted before launching tmux).
trap 'rm -rf "$TMP"; [ -n "${RUN_TS:-}" ] && tmux kill-session -t "orch-test-$RUN_TS" 2>/dev/null || tmux kill-server 2>/dev/null || true' EXIT

# Inject a fake claude so we don't invoke the real CLI from a test.
# A bare "COMPLETE" output produces a clean session_signal, exit 0 — perfect
# for verifying that the run-dir/files lifecycle is set up.
mkdir -p "$TMP/fake-bin"
cat > "$TMP/fake-bin/claude" <<'EOF'
#!/bin/bash
# Drain stdin so the orchestrator's prompt heredoc doesn't SIGPIPE us.
cat >/dev/null
# Stream-json output. Single result event with COMPLETE.
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"COMPLETE"}'
EOF
chmod +x "$TMP/fake-bin/claude"

# Set up a fixture project on a feature branch (run-in-place refuses on main/master).
cd "$TMP"
git init -q
git checkout -b feature/lifecycle-test -q 2>/dev/null || git branch -m feature/lifecycle-test 2>/dev/null
git -C . commit --allow-empty -q -m "init"

"$REPO/bin/orchestra" init . 2>&1

# Substitute __WORKTREE_PATH__ in CONFIG.md (the init step sed-substituted it
# from the template, but the test re-writes CONFIG.md below). Resolve the
# realpath of TMP so the WORKTREE_PATH canary matches.
WT_PATH=$(realpath "$TMP")

# Replace CONFIG.md with workable test config — feature-branch + WORKTREE_PATH
cat > .orchestra/CONFIG.md <<EOF
- \`MAX_SESSIONS\`: 1
- \`MAX_CONSECUTIVE_CRASHES\`: 1
- \`MODEL\`: opus
- \`WORKTREE_PATH\`: $WT_PATH
- \`TMUX_PREFIX\`: orch-test
- \`QUOTA_PACING\`: false
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

# Wait for orchestrator to finish (one session, COMPLETE signal, exits fast).
# Run-in-place: the run folder lives directly at <project>/.orchestra/runs/<ts>/.
for _ in $(seq 1 30); do
    RUN_FOLDER=$(find .orchestra/runs/archive -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 || true)
    if [ -z "$RUN_FOLDER" ]; then
        # Not yet archived; check if it's still active in tmux
        ACTIVE=$(find .orchestra/runs -mindepth 1 -maxdepth 1 -type d -not -name archive 2>/dev/null | head -1 || true)
        if [ -n "$ACTIVE" ]; then
            RUN_TS="$(basename "$ACTIVE")"
            tmux has-session -t "orch-test-$RUN_TS" 2>/dev/null || break
        fi
        sleep 1
        continue
    fi
    RUN_TS="$(basename "$RUN_FOLDER")"
    tmux has-session -t "orch-test-$RUN_TS" 2>/dev/null || break
    sleep 1
done

# Assertions — run-in-place layout
RUN_DIR=$(find .orchestra/runs/archive -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
[ -n "$RUN_DIR" ] || { echo "no archived run found at .orchestra/runs/archive/"; exit 1; }
[ -d "$RUN_DIR/9-sessions" ] || { echo "no 9-sessions in run dir"; exit 1; }

# Orchestrator wrote both the per-session transcript and the summary file.
[ -f "$RUN_DIR/9-sessions/001.json" ] || { echo "session transcript missing"; exit 1; }
[ -f "$RUN_DIR/9-sessions/summary.json" ] || { echo "session summary missing"; exit 1; }

# Required files exist (created by cmd_run, not the agent yet).
# In legacy-mode (no Governance/CLAUDE.md + Governance/pending/), 3/4/5 ARE created.
# This test fixture is legacy-mode (no Governance/ dir set up).
for f in 1-INBOX.md 2-OBJECTIVE.md 3-TODO.md 4-DECISIONS.md 5-CHANGELOG.md 6-HANDOVER.md 7-SUMMARY.md; do
    [ -f "$RUN_DIR/$f" ] || { echo "missing $f in $RUN_DIR (legacy-mode fixture, all should exist)"; exit 1; }
done

# OBJECTIVE.md was snapshotted (within run folder, per spec § 3.1)
grep -q "Stub objective" "$RUN_DIR/2-OBJECTIVE.md" || { echo "OBJECTIVE.md not snapshotted"; exit 1; }

# Verify NO orchestra/run-<ts> branch was created — run-in-place commits on HEAD
if git -C . branch --list "orchestra/run-*" | grep -q .; then
    echo "run-in-place should NOT create orchestra/run-<ts> branch"
    exit 1
fi

# Verify current branch is still feature/lifecycle-test (orchestra didn't switch)
current_branch=$(git -C . branch --show-current)
[ "$current_branch" = "feature/lifecycle-test" ] || { echo "expected current branch 'feature/lifecycle-test', got '$current_branch'"; exit 1; }

# --- Parcel-mode fixture: 3/4/5 should NOT be created ---
TMP2=$(mktemp -d)
WT2_PATH=$(realpath "$TMP2")
cd "$TMP2"
git init -q
git checkout -b feature/parcel-mode-test -q 2>/dev/null || git branch -m feature/parcel-mode-test 2>/dev/null
git commit --allow-empty -q -m "init"

# Scaffold parcel-mode signals
mkdir -p Governance/pending
echo "# Governance" > Governance/CLAUDE.md
touch Governance/pending/.gitkeep
git add Governance && git commit -q -m "scaffold parcel-mode"

"$REPO/bin/orchestra" init . 2>&1 >/dev/null
cat > .orchestra/CONFIG.md <<EOF
- \`MAX_SESSIONS\`: 1
- \`MAX_CONSECUTIVE_CRASHES\`: 1
- \`MODEL\`: opus
- \`WORKTREE_PATH\`: $WT2_PATH
- \`TMUX_PREFIX\`: orch-pmode
- \`QUOTA_PACING\`: false
- \`COOLDOWN_SECONDS\`: 0
- \`CRASH_COOLDOWN_SECONDS\`: 0
EOF
echo "Stub objective" > .orchestra/OBJECTIVE.md
git add -A && git commit -q -m "config + objective"

PATH="$TMP/fake-bin:$PATH" .orchestra/runtime/bin/orchestra run 2>&1

# Wait for completion
for _ in $(seq 1 30); do
    RUN_FOLDER=$(find .orchestra/runs/archive -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 || true)
    if [ -z "$RUN_FOLDER" ]; then
        ACTIVE=$(find .orchestra/runs -mindepth 1 -maxdepth 1 -type d -not -name archive 2>/dev/null | head -1 || true)
        if [ -n "$ACTIVE" ]; then
            RUN_TS_2="$(basename "$ACTIVE")"
            tmux has-session -t "orch-pmode-$RUN_TS_2" 2>/dev/null || break
        fi
        sleep 1
        continue
    fi
    RUN_TS_2="$(basename "$RUN_FOLDER")"
    tmux has-session -t "orch-pmode-$RUN_TS_2" 2>/dev/null || break
    sleep 1
done

RUN_DIR_2=$(find .orchestra/runs/archive -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
[ -n "$RUN_DIR_2" ] || { echo "parcel-mode: no archived run found"; exit 1; }

# In parcel-mode, 3/4/5 must NOT be created
for f in 3-TODO.md 4-DECISIONS.md 5-CHANGELOG.md; do
    if [ -f "$RUN_DIR_2/$f" ]; then
        echo "parcel-mode: $f should NOT exist (governance is in Governance/pending/<hex>.md)"
        exit 1
    fi
done

# But the rest of the layout should exist
for f in 1-INBOX.md 2-OBJECTIVE.md 6-HANDOVER.md 7-SUMMARY.md; do
    [ -f "$RUN_DIR_2/$f" ] || { echo "parcel-mode: missing $f"; exit 1; }
done

rm -rf "$TMP2"

echo "OK"
