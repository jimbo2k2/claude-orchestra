#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; [ -n "${RUN_TS:-}" ] && tmux kill-session -t "orch-wf-$RUN_TS" 2>/dev/null || tmux kill-server 2>/dev/null || true' EXIT

# Fake claude: working session commits then COMPLETE; wind-down session
# pretends a merge conflict and emits BLOCKED with a HANDOVER.
mkdir -p "$TMP/fake-bin"
cat > "$TMP/fake-bin/claude" <<'EOF'
#!/bin/bash
prompt=$(cat)
if echo "$prompt" | grep -q "wind-down session"; then
    # Spec Section 6.3 wind-down BLOCKED shape: files in conflict, git status
    # excerpt, manual resolution.
    rd=$(echo "$prompt" | grep "Run dir:" | grep -oE '/[^ ]+\.orchestra/runs/[^ ]+' | head -1)
    cat > "$rd/6-HANDOVER.md" <<HOEOF
# Wind-down BLOCKED

Files in conflict: src/foo.c

Manual resolution: edit src/foo.c, git add, git commit, git push.
HOEOF
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"I am stuck on a conflict\nBLOCKED"}'
else
    git add -A
    git -c user.email=t@t -c user.name=t commit --allow-empty -q -m "session" 2>/dev/null || true
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"all good\nCOMPLETE"}'
fi
exit 0
EOF
chmod +x "$TMP/fake-bin/claude"

cd "$TMP"
git init -q --initial-branch=master
git -c user.email=t@t -c user.name=t commit --allow-empty -q -m "init"
"$REPO/bin/orchestra" init . 2>&1

cat > .orchestra/CONFIG.md <<EOF
- \`MAX_SESSIONS\`: 1
- \`MAX_CONSECUTIVE_CRASHES\`: 1
- \`MODEL\`: opus
- \`WORKTREE_BASE\`: $TMP/wt
- \`BASE_BRANCH\`: master
- \`TMUX_PREFIX\`: orch-wf
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
        tmux has-session -t "orch-wf-$RUN_TS" 2>/dev/null || break
    fi
    sleep 1
done

WORKTREE=$(ls -d "$TMP/wt"/run-* | head -1)
RUN=$(ls -d "$WORKTREE"/.orchestra/runs/2*/ | head -1)

[ -f "${RUN}WIND-DOWN-FAILED" ] || { echo "no WIND-DOWN-FAILED marker"; exit 1; }
grep -q "Category: BLOCKED" "${RUN}WIND-DOWN-FAILED" || { echo "wrong category"; exit 1; }
grep -q "Files in conflict" "${RUN}WIND-DOWN-FAILED" || { echo "missing handover content"; exit 1; }
grep -q "Failed at: " "${RUN}WIND-DOWN-FAILED" || { echo "missing timestamp"; exit 1; }

# Run NOT archived (spec line 182)
[ ! -d "$WORKTREE/.orchestra/runs/archive/$(basename "$RUN")" ] || { echo "should not archive failed wind-down"; exit 1; }

echo "OK"
