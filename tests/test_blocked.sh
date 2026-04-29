#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; [ -n "${RUN_TS:-}" ] && tmux kill-session -t "orch-bl-$RUN_TS" 2>/dev/null || tmux kill-server 2>/dev/null || true' EXIT

# Fake claude: write a HANDOVER, emit BLOCKED. No need to commit because
# spec Section 11 explicitly allows BLOCKED to leave dirty state.
mkdir -p "$TMP/fake-bin"
cat > "$TMP/fake-bin/claude" <<'EOF'
#!/bin/bash
prompt=$(cat)
# Extract the run dir from the prompt — it's referenced as
# "$WORKTREE_DIR/.orchestra/runs/$RUN_TS/" in build_session_prompt.
rd=$(echo "$prompt" | grep -oE '/[a-zA-Z0-9_/.-]*\.orchestra/runs/[^/ ]+' | head -1)
echo "Cannot proceed without API key" > "$rd/6-HANDOVER.md"
echo "stuck"
echo "BLOCKED"
exit 0
EOF
chmod +x "$TMP/fake-bin/claude"

cd "$TMP"
git init -q --initial-branch=master
git -c user.email=t@t -c user.name=t commit --allow-empty -q -m "init"
"$REPO/bin/orchestra" init . 2>&1

cat > .orchestra/CONFIG.md <<EOF
- \`MAX_SESSIONS\`: 5
- \`MAX_CONSECUTIVE_CRASHES\`: 2
- \`MODEL\`: opus
- \`WORKTREE_BASE\`: $TMP/wt
- \`BASE_BRANCH\`: master
- \`TMUX_PREFIX\`: orch-bl
- \`QUOTA_PACING\`: false
- \`COOLDOWN_SECONDS\`: 0
- \`CRASH_COOLDOWN_SECONDS\`: 0
EOF
echo "stub" > .orchestra/OBJECTIVE.md
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "config"

PATH="$TMP/fake-bin:$PATH" .orchestra/runtime/bin/orchestra run 2>&1

WORKTREE=""
for _ in $(seq 1 60); do
    WORKTREE=$(ls -d "$TMP/wt"/run-* 2>/dev/null | head -1 || true)
    if [ -n "$WORKTREE" ]; then
        RUN_TS="${WORKTREE##*/run-}"
        tmux has-session -t "orch-bl-$RUN_TS" 2>/dev/null || break
    fi
    sleep 1
done

WORKTREE=$(ls -d "$TMP/wt"/run-* | head -1)
RUN=$(ls -d "$WORKTREE"/.orchestra/runs/2*/ | head -1)

[ -f "${RUN}BLOCKED" ] || { echo "no BLOCKED marker"; exit 1; }
grep -q "Cannot proceed" "${RUN}BLOCKED" || { echo "missing handover content in BLOCKED"; exit 1; }
grep -q "Blocked at:" "${RUN}BLOCKED" || { echo "missing timestamp"; exit 1; }
grep -q "Session: 1" "${RUN}BLOCKED" || { echo "missing session number"; exit 1; }

# Run NOT archived
[ ! -d "$WORKTREE/.orchestra/runs/archive/$(basename "$RUN")" ] || { echo "BLOCKED runs must not auto-archive"; exit 1; }

# Only one session was run (BLOCKED halts immediately)
n=$(ls "${RUN}9-sessions/"*.json 2>/dev/null | wc -l)
[ "$n" -eq 1 ] || { echo "expected exactly 1 session, got $n"; exit 1; }

# Session JSON should record exit_signal=BLOCKED
sig=$(jq -r '.exit_signal' "${RUN}9-sessions/001.json")
[ "$sig" = "BLOCKED" ] || { echo "expected exit_signal=BLOCKED, got '$sig'"; exit 1; }

echo "OK"
