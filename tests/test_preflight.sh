#!/bin/bash
# Five refusal preflight fixtures per spec § 3.4:
#   1. Refuses to run on `main`.
#   2. Refuses to run when HEAD matches an entry in PROTECTED_BRANCHES.
#   3. Refuses to run when CONFIG.md contains BASE_BRANCH or WORKTREE_BASE.
#   4. Refuses to run when WORKTREE_PATH is absent or mismatched.
#   5. Refuses to run when a prior non-archive run folder exists under .orchestra/runs/.

set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

setup_repo() {
    local tmp="$1"
    cd "$tmp"
    git init -q
    # Initial branch: feature/test-pf (the test will switch where needed).
    git checkout -b feature/test-pf -q 2>/dev/null || git branch -m feature/test-pf 2>/dev/null
    git -c user.email=t@t -c user.name=t commit --allow-empty -q -m "init"
    "$REPO/bin/orchestra" init . 2>&1 >/dev/null
}

assert_refuses() {
    local label="$1"
    local pattern="$2"
    local output
    set +e
    output=$("$REPO/bin/orchestra" run 2>&1)
    local exit_code=$?
    set -e
    [ "$exit_code" -ne 0 ] || { echo "$label: expected refusal (non-zero exit), got 0. Output: $output"; exit 1; }
    echo "$output" | grep -qiE "$pattern" || { echo "$label: expected message matching '$pattern'; got: $output"; exit 1; }
    echo "$label: PASS"
}

# Fixture 1: Refuses on main
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
setup_repo "$TMP"
git checkout -b main -q 2>/dev/null || git branch -m main 2>/dev/null
assert_refuses "refuses-on-main" "protected|refus"
rm -rf "$TMP"; trap - EXIT

# Fixture 2: Refuses on a PROTECTED_BRANCHES entry
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
setup_repo "$TMP"
git checkout -b develop -q
# Append PROTECTED_BRANCHES to the auto-init'd CONFIG.md
echo "- \`PROTECTED_BRANCHES\`: main,master,develop" >> .orchestra/CONFIG.md
assert_refuses "refuses-on-protected-branches-match" "protected|develop"
rm -rf "$TMP"; trap - EXIT

# Fixture 3: Refuses on obsolete keys
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
setup_repo "$TMP"
echo "- \`BASE_BRANCH\`: main" >> .orchestra/CONFIG.md
assert_refuses "refuses-on-obsolete-keys" "BASE_BRANCH|obsolete"
rm -rf "$TMP"; trap - EXIT

# Fixture 4: Refuses on WORKTREE_PATH mismatch
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
setup_repo "$TMP"
# Force WORKTREE_PATH to a nonexistent path so realpath comparison fails.
sed -i 's|^- `WORKTREE_PATH`:.*$|- `WORKTREE_PATH`: /nonexistent/path|' .orchestra/CONFIG.md
assert_refuses "refuses-on-WORKTREE_PATH-mismatch" "WORKTREE_PATH|canary|mismatch"
rm -rf "$TMP"; trap - EXIT

# Fixture 5: Refuses on prior non-archive run folder
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
setup_repo "$TMP"
mkdir -p .orchestra/runs/20260101-000000
assert_refuses "refuses-on-prior-run-folder" "previous run|run folder|reset"
rm -rf "$TMP"; trap - EXIT

echo "test_preflight: ALL PASS"
