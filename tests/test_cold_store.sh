#!/bin/bash
# cmd_cold_store: mothball runs/<ts>/ and runs/archive/<ts>/ to
# cold-storage/<ts>-<slug>/ with the slug derived from each run's
# 2-OBJECTIVE.md. Verifies the slugifier, the bulk move, the dest
# layout, and the tmux-active refusal.

set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; tmux kill-session -t "orch-cs-test-20260520-120510" 2>/dev/null || true' EXIT

cd "$TMP"
git init -q
git checkout -b feature/cold-store-test -q 2>/dev/null || git branch -m feature/cold-store-test 2>/dev/null
git -c user.email=t@t -c user.name=t commit --allow-empty -q -m "init"

"$REPO/bin/orchestra" init . 2>&1 >/dev/null

# Set TMUX_PREFIX to a recognisable name so the active-tmux check has something
# specific to look for; substitute WORKTREE_PATH (the auto-init seed used $TMP).
WT_PATH=$(realpath "$TMP")
sed -i "s|^- \`TMUX_PREFIX\`:.*|- \`TMUX_PREFIX\`: orch-cs-test|" .orchestra/CONFIG.md

# Stage three historical run folders with different OBJECTIVE shapes.
mkdir -p .orchestra/runs/20260501-152641
cat > .orchestra/runs/20260501-152641/2-OBJECTIVE.md <<'EOF'
# Run Objective — TODO/TODO.md Cleanup

## Goal
Tidy the TODO file.
EOF

mkdir -p .orchestra/runs/20260507-141954
cat > .orchestra/runs/20260507-141954/2-OBJECTIVE.md <<'EOF'
# Run Objective — Spec B.2b (Refinement FSM + AIT/AIC Fan-out + Optimistic Generalisation)

## Goal
Long objective that should truncate.
EOF

mkdir -p .orchestra/runs/archive/20260508-151257
cat > .orchestra/runs/archive/20260508-151257/2-OBJECTIVE.md <<'EOF'
# Run Objective — Spec B.3 (Engine lift, FSM retry transition, walkthrough residuals)

## Goal
Already archived run.
EOF

# Commit the staged history so `git mv` can move them as tracked files.
git add .orchestra/runs
git -c user.email=t@t -c user.name=t commit -q -m "stage three historical runs"

# Run cmd_cold_store.
"$REPO/bin/orchestra" cold-store 2>&1 | tail -5

# Verify the destination folders exist with expected slugs.
for expected in \
    "20260501-152641-todo-todo-md-cleanup" \
    "20260507-141954-spec-b-2b-refinement-fsm-ait-aic-fan-out-optimistic" \
    "20260508-151257-spec-b-3-engine-lift-fsm-retry-transition-walkthrough"; do
    [ -d ".orchestra/cold-storage/$expected" ] || {
        echo "ASSERT FAIL: expected .orchestra/cold-storage/$expected"
        ls -la .orchestra/cold-storage/ 2>&1
        exit 1
    }
done

# Verify source folders are gone.
[ ! -d ".orchestra/runs/20260501-152641" ] || { echo "ASSERT FAIL: src 20260501-152641 still present"; exit 1; }
[ ! -d ".orchestra/runs/20260507-141954" ] || { echo "ASSERT FAIL: src 20260507-141954 still present"; exit 1; }
[ ! -d ".orchestra/runs/archive/20260508-151257" ] || { echo "ASSERT FAIL: archive src 20260508-151257 still present"; exit 1; }

# Verify archive/ dir was removed (empty).
[ ! -d ".orchestra/runs/archive" ] || { echo "ASSERT FAIL: empty archive/ dir not removed"; exit 1; }

echo "cold-store bulk move: PASS"

# --- tmux-active refusal ---
mkdir -p .orchestra/runs/20260520-120510
cat > .orchestra/runs/20260520-120510/2-OBJECTIVE.md <<'EOF'
# Run Objective — Active Run

## Goal
Should refuse while tmux session alive.
EOF

# Start a fake tmux session matching the orchestra naming convention
# (<TMUX_PREFIX>-<timestamp>) so cmd_cold_store refuses.
tmux new-session -d -s "orch-cs-test-20260520-120510" 'sleep 60' 2>/dev/null

set +e
out=$("$REPO/bin/orchestra" cold-store 2>&1)
code=$?
set -e
tmux kill-session -t "orch-cs-test-20260520-120510" 2>/dev/null || true

[ "$code" -ne 0 ] || { echo "ASSERT FAIL: cold-store should refuse with active tmux; got exit 0. Output: $out"; exit 1; }
echo "$out" | grep -qE "Refusing.*tmux|tmux.*active|active.*tmux" || {
    echo "ASSERT FAIL: refusal message should mention tmux/active; got: $out"
    exit 1
}
echo "cold-store tmux-active refusal: PASS"

echo "test_cold_store: PASS"
