#!/bin/bash
# Regression test for code-review Important #1: trailing blank line in
# claude --print output should not misclassify a clean COMPLETE as Cat B.
# Fake claude emits "COMPLETE\n\n" and exits 0; expect exit_signal=COMPLETE,
# crash_category=null, and orchestrator exits cleanly after one session.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; [ -n "${RUN_TS:-}" ] && tmux kill-session -t "orch-complete-test-$RUN_TS" 2>/dev/null || tmux kill-server 2>/dev/null || true' EXIT

mkdir -p "$TMP/fake-bin"
# Final line is whitespace-only (spaces) after COMPLETE. Bash's $(...) strips
# trailing *newlines* but preserves a trailing whitespace-only line, so this
# reproduces the bug where the old `tail -n1` returned the blank/whitespace
# line instead of the real signal line.
cat > "$TMP/fake-bin/claude" <<'EOF'
#!/bin/bash
cat >/dev/null
# Phase 6: COMPLETE requires a clean worktree (Cat D check). The orchestrator
# initialises .orchestra/runs/<ts>/ before invoking claude, so a real agent
# would commit those state files during their session. Mirror that here.
git add -A 2>/dev/null && git -c user.email=test@x -c user.name=test commit -q -m "session work" 2>/dev/null || true
printf 'doing some work...\nCOMPLETE\n   \n'
exit 0
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
- \`TMUX_PREFIX\`: orch-complete-test
- \`QUOTA_PACING\`: false
- \`COOLDOWN_SECONDS\`: 0
- \`CRASH_COOLDOWN_SECONDS\`: 0
EOF
echo "stub" > .orchestra/OBJECTIVE.md
git add -A
git commit -q -m "config"

PATH="$TMP/fake-bin:$PATH" .orchestra/runtime/bin/orchestra run 2>&1

# Wait for orchestrator session to terminate.
for _ in $(seq 1 30); do
    WT=$(ls -d "$TMP/wt"/run-* 2>/dev/null | head -1 || true)
    if [ -z "$WT" ]; then
        sleep 1
        continue
    fi
    RUN_TS="${WT##*/run-}"
    tmux has-session -t "orch-complete-test-$RUN_TS" 2>/dev/null || break
    sleep 1
done

WORKTREE=$(ls -d "$TMP/wt"/run-* | head -1)
# Phase 8: COMPLETE now triggers wind-down + archive. The run dir is moved
# into <worktree>/.orchestra/runs/archive/<ts>/, so look there.
RUN_DIR=$(ls -d "$WORKTREE"/.orchestra/runs/archive/*/ | head -1)

# Should have exactly one session JSON (MAX_SESSIONS=1, COMPLETE on first).
n=$(ls "${RUN_DIR}9-sessions/"*.json 2>/dev/null | wc -l)
[ "$n" -eq 1 ] || { echo "expected 1 session JSON, got $n"; exit 1; }

f="${RUN_DIR}9-sessions/001.json"
signal=$(jq -r '.exit_signal' "$f")
category=$(jq -r '.crash_category' "$f")
code=$(jq -r '.exit_code' "$f")

[ "$signal" = "COMPLETE" ] || { echo "expected exit_signal=COMPLETE, got '$signal'"; exit 1; }
[ "$category" = "null" ] || { echo "expected crash_category=null, got '$category'"; exit 1; }
[ "$code" = "0" ] || { echo "expected exit_code=0, got '$code'"; exit 1; }

echo "OK"
