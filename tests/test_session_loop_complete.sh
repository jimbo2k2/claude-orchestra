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
cat > "$TMP/fake-bin/claude" <<EOF
#!/bin/bash
# Capture every prompt this fake-claude is invoked with (working session
# AND wind-down) so the test can assert the working-session prompt was
# built from the Organiser template. Append with a boundary marker —
# overwriting would lose the working-session prompt when wind-down runs.
{ echo "----PROMPT-BOUNDARY----"; cat; echo; } >> "$TMP/captured-prompt"
# Phase 6: COMPLETE requires a clean worktree (Cat D check). The orchestrator
# initialises .orchestra/runs/<ts>/ before invoking claude, so a real agent
# would commit those state files during their session. Mirror that here.
git add -A 2>/dev/null && git -c user.email=test@x -c user.name=test commit -q -m "session work" 2>/dev/null || true
# Phase 20: orchestrator now uses --output-format stream-json. Fake a result
# event whose .result text ends with COMPLETE plus trailing whitespace —
# regression test for the trailing-blank-line bug (extract_signal must take
# the last NON-EMPTY line of .result).
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"doing some work...\nCOMPLETE\n   "}'
exit 0
EOF
chmod +x "$TMP/fake-bin/claude"

cd "$TMP"
git init -q && git checkout -b feature/test-rip -q 2>/dev/null || git branch -m feature/test-rip 2>/dev/null
git -C . commit --allow-empty -q -m "init"
"$REPO/bin/orchestra" init . 2>&1

cat > .orchestra/CONFIG.md <<EOF
- \`MAX_SESSIONS\`: 1
- \`MAX_CONSECUTIVE_CRASHES\`: 2
- \`MODEL\`: opus
- \`WORKTREE_PATH\`: $(realpath "$TMP")
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
    WT=$(find "$TMP/.orchestra/runs" -mindepth 1 -maxdepth 1 -type d -not -name archive 2>/dev/null | head -1 || true)
    if [ -z "$WT" ]; then
        # Maybe already archived
        WT=$(find "$TMP/.orchestra/runs/archive" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 || true)
    fi
    if [ -z "$WT" ]; then
        sleep 1
        continue
    fi
    RUN_TS="$(basename "$WT")"
    tmux has-session -t "orch-complete-test-$RUN_TS" 2>/dev/null || break
    sleep 1
done

# Run-in-place: COMPLETE triggers wind-down + archive. The run dir is moved
# into <worktree>/.orchestra/runs/archive/<ts>/, so look there.
RUN_DIR="$(find "$TMP/.orchestra/runs/archive" -mindepth 1 -maxdepth 1 -type d | head -1)/"

# Should have exactly one session transcript (MAX_SESSIONS=1, COMPLETE on first).
# Match [0-9]*.json so summary.json doesn't inflate the count.
n=$(ls "${RUN_DIR}9-sessions/"[0-9]*.json 2>/dev/null | wc -l)
[ "$n" -eq 1 ] || { echo "expected 1 session transcript, got $n"; exit 1; }

# Transcript must be the raw stream-json NDJSON (always archived now).
[ -s "${RUN_DIR}9-sessions/001.json" ] || { echo "expected non-empty transcript at 001.json"; exit 1; }
grep -q '"type":"result"' "${RUN_DIR}9-sessions/001.json" || { echo "expected result event in transcript"; exit 1; }

# Metadata stub now lives in summary.json as a JSON array (one entry per session).
f="${RUN_DIR}9-sessions/summary.json"
signal=$(jq -r '.[0].exit_signal' "$f")
category=$(jq -r '.[0].crash_category' "$f")
code=$(jq -r '.[0].exit_code' "$f")

[ "$signal" = "COMPLETE" ] || { echo "expected exit_signal=COMPLETE, got '$signal'"; exit 1; }
[ "$category" = "null" ] || { echo "expected crash_category=null, got '$category'"; exit 1; }
[ "$code" = "0" ] || { echo "expected exit_code=0, got '$code'"; exit 1; }

# Session prompt was built from the Organiser template — confirm by grepping
# for a literal phrase unique to lib/organiser-prompt.txt that wouldn't appear
# in the legacy heredoc.
[ -s "$TMP/captured-prompt" ] || { echo "expected captured prompt file to exist and be non-empty"; exit 1; }
grep -q "You are the Organiser" "$TMP/captured-prompt" || { echo "expected Organiser prompt marker in captured prompt; got first 5 lines:"; head -5 "$TMP/captured-prompt"; exit 1; }
grep -q "Agent tool" "$TMP/captured-prompt" || { echo "expected Agent-tool reference in captured prompt"; exit 1; }
# Placeholders must be substituted, not left literal.
! grep -q "__RUN_DIR__\|__SESSION_NUM__\|__ORGANISER_CONTEXT_THRESHOLD__" "$TMP/captured-prompt" || { echo "expected all __PLACEHOLDERS__ to be substituted"; exit 1; }

# Activity log file must be created at run start (touch in cmd_run).
[ -f "${RUN_DIR}9-sessions/executor-activity.log" ] || { echo "expected 9-sessions/executor-activity.log to exist"; exit 1; }

echo "OK"
