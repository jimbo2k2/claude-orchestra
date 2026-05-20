#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

source lib/config.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/CONFIG.md" <<EOF
# Test Config

Some prose to ignore.

## Section
- \`MAX_SESSIONS\`: 5
- \`MODEL\`: opus
- \`WORKTREE_PATH\`: $TMP
- \`MAX_CONSECUTIVE_CRASHES\`: 3
EOF

declare -gA ORCHESTRA_CONFIG
parse_config_md "$TMP/CONFIG.md"

[ "${ORCHESTRA_CONFIG[MAX_SESSIONS]}" = "5" ] || { echo "MAX_SESSIONS expected 5 got '${ORCHESTRA_CONFIG[MAX_SESSIONS]:-<unset>}'"; exit 1; }
[ "${ORCHESTRA_CONFIG[MODEL]}" = "opus" ] || { echo "MODEL expected opus got '${ORCHESTRA_CONFIG[MODEL]:-<unset>}'"; exit 1; }
[ "${ORCHESTRA_CONFIG[WORKTREE_PATH]}" = "$TMP" ] || { echo "WORKTREE_PATH expected $TMP got '${ORCHESTRA_CONFIG[WORKTREE_PATH]:-<unset>}'"; exit 1; }

# Test: missing required key fails
cat > "$TMP/bad1.md" <<'EOF'
- `MODEL`: opus
EOF
unset ORCHESTRA_CONFIG
declare -gA ORCHESTRA_CONFIG
parse_config_md "$TMP/bad1.md"
apply_config_defaults
if validate_config 2>/dev/null; then
    echo "expected validation failure for missing required keys"
    exit 1
fi

# Test: invalid model enum fails
cat > "$TMP/bad2.md" <<EOF
- \`MAX_SESSIONS\`: 5
- \`MAX_CONSECUTIVE_CRASHES\`: 3
- \`MODEL\`: gpt4
- \`WORKTREE_PATH\`: $TMP
EOF
unset ORCHESTRA_CONFIG
declare -gA ORCHESTRA_CONFIG
parse_config_md "$TMP/bad2.md"
apply_config_defaults
if validate_config 2>/dev/null; then
    echo "expected validation failure for invalid MODEL"
    exit 1
fi

# Test: duplicate key fails
cat > "$TMP/bad3.md" <<'EOF'
- `MAX_SESSIONS`: 5
- `MAX_SESSIONS`: 7
EOF
unset ORCHESTRA_CONFIG
declare -gA ORCHESTRA_CONFIG
if parse_config_md "$TMP/bad3.md" 2>/dev/null; then
    echo "expected duplicate-key failure"
    exit 1
fi

# --- ORGANISER_MODEL soft-transition tests ---
# These cover Phase 1 of the organiser-executor plan: MODEL is being
# deprecated in favour of ORGANISER_MODEL, with a one-release window where
# either key works. Tests assert that the compat shim populates whichever
# key was missing, fires a deprecation warning when MODEL is used, and
# enforces the same enum validation on the new key.

# Test: ORGANISER_MODEL alone (no MODEL) validates cleanly, no warning
cat > "$TMP/org-only.md" <<EOF
- \`MAX_SESSIONS\`: 5
- \`MAX_CONSECUTIVE_CRASHES\`: 3
- \`ORGANISER_MODEL\`: sonnet
- \`WORKTREE_PATH\`: $TMP
EOF
unset ORCHESTRA_CONFIG
declare -gA ORCHESTRA_CONFIG
parse_config_md "$TMP/org-only.md"
apply_config_defaults
validate_config 2>"$TMP/warn" >/dev/null || { echo "ORGANISER_MODEL alone should validate; got: $(cat "$TMP/warn")"; exit 1; }
warn_output=$(cat "$TMP/warn")
[ "${ORCHESTRA_CONFIG[ORGANISER_MODEL]}" = "sonnet" ] || { echo "ORGANISER_MODEL expected sonnet got '${ORCHESTRA_CONFIG[ORGANISER_MODEL]:-<unset>}'"; exit 1; }
[ "${ORCHESTRA_CONFIG[MODEL]}" = "sonnet" ] || { echo "compat shim should backfill MODEL=sonnet for orchestrator.sh during transition; got '${ORCHESTRA_CONFIG[MODEL]:-<unset>}'"; exit 1; }
case "$warn_output" in
    *deprecated*|*deprecation*|*DEPRECATED*) echo "no MODEL key was set, deprecation warning should NOT fire; got: $warn_output"; exit 1 ;;
esac

# Test: only MODEL set (legacy install) — compat shim populates ORGANISER_MODEL,
# fires deprecation warning to stderr
cat > "$TMP/legacy.md" <<EOF
- \`MAX_SESSIONS\`: 5
- \`MAX_CONSECUTIVE_CRASHES\`: 3
- \`MODEL\`: opus
- \`WORKTREE_PATH\`: $TMP
EOF
unset ORCHESTRA_CONFIG
declare -gA ORCHESTRA_CONFIG
parse_config_md "$TMP/legacy.md"
apply_config_defaults
validate_config 2>"$TMP/warn" >/dev/null || { echo "legacy MODEL alone should validate (with warning); got: $(cat "$TMP/warn")"; exit 1; }
warn_output=$(cat "$TMP/warn")
[ "${ORCHESTRA_CONFIG[ORGANISER_MODEL]}" = "opus" ] || { echo "compat shim should backfill ORGANISER_MODEL from MODEL; got '${ORCHESTRA_CONFIG[ORGANISER_MODEL]:-<unset>}'"; exit 1; }
case "$warn_output" in
    *MODEL*deprecated*|*MODEL*deprecation*|*deprecated*MODEL*) ;;
    *) echo "expected deprecation warning mentioning MODEL on stderr; got: $warn_output"; exit 1 ;;
esac

# Test: both keys set — ORGANISER_MODEL wins, warning fires noting MODEL is ignored
cat > "$TMP/both.md" <<EOF
- \`MAX_SESSIONS\`: 5
- \`MAX_CONSECUTIVE_CRASHES\`: 3
- \`MODEL\`: opus
- \`ORGANISER_MODEL\`: sonnet
- \`WORKTREE_PATH\`: $TMP
EOF
unset ORCHESTRA_CONFIG
declare -gA ORCHESTRA_CONFIG
parse_config_md "$TMP/both.md"
apply_config_defaults
validate_config 2>"$TMP/warn" >/dev/null || { echo "both keys set should validate (with warning); got: $(cat "$TMP/warn")"; exit 1; }
warn_output=$(cat "$TMP/warn")
[ "${ORCHESTRA_CONFIG[ORGANISER_MODEL]}" = "sonnet" ] || { echo "ORGANISER_MODEL should win; got '${ORCHESTRA_CONFIG[ORGANISER_MODEL]:-<unset>}'"; exit 1; }
[ "${ORCHESTRA_CONFIG[MODEL]}" = "sonnet" ] || { echo "compat shim should overwrite MODEL=sonnet to keep orchestrator.sh consistent; got '${ORCHESTRA_CONFIG[MODEL]:-<unset>}'"; exit 1; }
case "$warn_output" in
    *MODEL*ignored*|*MODEL*deprecated*|*deprecated*MODEL*) ;;
    *) echo "expected warning mentioning MODEL ignored/deprecated when both set; got: $warn_output"; exit 1 ;;
esac

# Test: invalid ORGANISER_MODEL enum fails
cat > "$TMP/bad-org.md" <<EOF
- \`MAX_SESSIONS\`: 5
- \`MAX_CONSECUTIVE_CRASHES\`: 3
- \`ORGANISER_MODEL\`: gpt4
- \`WORKTREE_PATH\`: $TMP
EOF
unset ORCHESTRA_CONFIG
declare -gA ORCHESTRA_CONFIG
parse_config_md "$TMP/bad-org.md"
apply_config_defaults
if validate_config 2>/dev/null; then
    echo "expected validation failure for invalid ORGANISER_MODEL"
    exit 1
fi

# --- ORGANISER_CONTEXT_THRESHOLD tests ---

# Test: default is 75 when key absent
cat > "$TMP/threshold-default.md" <<EOF
- \`MAX_SESSIONS\`: 5
- \`MAX_CONSECUTIVE_CRASHES\`: 3
- \`ORGANISER_MODEL\`: opus
- \`WORKTREE_PATH\`: $TMP
EOF
unset ORCHESTRA_CONFIG
declare -gA ORCHESTRA_CONFIG
parse_config_md "$TMP/threshold-default.md"
apply_config_defaults
[ "${ORCHESTRA_CONFIG[ORGANISER_CONTEXT_THRESHOLD]}" = "75" ] || { echo "ORGANISER_CONTEXT_THRESHOLD default expected 75 got '${ORCHESTRA_CONFIG[ORGANISER_CONTEXT_THRESHOLD]:-<unset>}'"; exit 1; }
validate_config 2>/dev/null || { echo "default threshold should validate"; exit 1; }

# Test: out-of-range threshold fails validation
cat > "$TMP/threshold-bad.md" <<EOF
- \`MAX_SESSIONS\`: 5
- \`MAX_CONSECUTIVE_CRASHES\`: 3
- \`ORGANISER_MODEL\`: opus
- \`ORGANISER_CONTEXT_THRESHOLD\`: 99
- \`WORKTREE_PATH\`: $TMP
EOF
unset ORCHESTRA_CONFIG
declare -gA ORCHESTRA_CONFIG
parse_config_md "$TMP/threshold-bad.md"
apply_config_defaults
if validate_config 2>/dev/null; then
    echo "expected validation failure for ORGANISER_CONTEXT_THRESHOLD=99 (out of [50,95])"
    exit 1
fi

# --- run-in-place schema tests ---

# Test: obsolete BASE_BRANCH triggers rejection with cleanup message
cat > "$TMP/obsolete-base-branch.md" <<EOF
- \`MAX_SESSIONS\`: 5
- \`MAX_CONSECUTIVE_CRASHES\`: 3
- \`ORGANISER_MODEL\`: opus
- \`WORKTREE_PATH\`: $TMP
- \`BASE_BRANCH\`: main
EOF
unset ORCHESTRA_CONFIG
declare -gA ORCHESTRA_CONFIG
parse_config_md "$TMP/obsolete-base-branch.md"
apply_config_defaults
if validate_config 2>"$TMP/warn" >/dev/null; then
    echo "expected validation failure for obsolete BASE_BRANCH key"
    exit 1
fi
warn_output=$(cat "$TMP/warn")
case "$warn_output" in
    *BASE_BRANCH*obsolete*|*obsolete*BASE_BRANCH*) ;;
    *) echo "expected obsolete-key message mentioning BASE_BRANCH; got: $warn_output"; exit 1 ;;
esac

# Test: obsolete WORKTREE_BASE triggers rejection with cleanup message
cat > "$TMP/obsolete-worktree-base.md" <<EOF
- \`MAX_SESSIONS\`: 5
- \`MAX_CONSECUTIVE_CRASHES\`: 3
- \`ORGANISER_MODEL\`: opus
- \`WORKTREE_PATH\`: $TMP
- \`WORKTREE_BASE\`: /tmp/orch
EOF
unset ORCHESTRA_CONFIG
declare -gA ORCHESTRA_CONFIG
parse_config_md "$TMP/obsolete-worktree-base.md"
apply_config_defaults
if validate_config 2>"$TMP/warn" >/dev/null; then
    echo "expected validation failure for obsolete WORKTREE_BASE key"
    exit 1
fi
warn_output=$(cat "$TMP/warn")
case "$warn_output" in
    *WORKTREE_BASE*obsolete*|*obsolete*WORKTREE_BASE*) ;;
    *) echo "expected obsolete-key message mentioning WORKTREE_BASE; got: $warn_output"; exit 1 ;;
esac

# Test: missing WORKTREE_PATH triggers required-key failure
cat > "$TMP/missing-worktree-path.md" <<'EOF'
- `MAX_SESSIONS`: 5
- `MAX_CONSECUTIVE_CRASHES`: 3
- `ORGANISER_MODEL`: opus
EOF
unset ORCHESTRA_CONFIG
declare -gA ORCHESTRA_CONFIG
parse_config_md "$TMP/missing-worktree-path.md"
apply_config_defaults
if validate_config 2>"$TMP/warn" >/dev/null; then
    echo "expected validation failure for missing WORKTREE_PATH"
    exit 1
fi
warn_output=$(cat "$TMP/warn")
case "$warn_output" in
    *WORKTREE_PATH*) ;;
    *) echo "expected missing-key message mentioning WORKTREE_PATH; got: $warn_output"; exit 1 ;;
esac

# Test: PROTECTED_BRANCHES defaults to main,master when omitted
cat > "$TMP/protected-default.md" <<EOF
- \`MAX_SESSIONS\`: 5
- \`MAX_CONSECUTIVE_CRASHES\`: 3
- \`ORGANISER_MODEL\`: opus
- \`WORKTREE_PATH\`: $TMP
EOF
unset ORCHESTRA_CONFIG
declare -gA ORCHESTRA_CONFIG
parse_config_md "$TMP/protected-default.md"
apply_config_defaults
[ "${ORCHESTRA_CONFIG[PROTECTED_BRANCHES]}" = "main,master" ] || { echo "PROTECTED_BRANCHES default expected 'main,master' got '${ORCHESTRA_CONFIG[PROTECTED_BRANCHES]:-<unset>}'"; exit 1; }
validate_config 2>/dev/null || { echo "default PROTECTED_BRANCHES should validate"; exit 1; }

# Test: PROTECTED_BRANCHES explicit value is preserved
cat > "$TMP/protected-explicit.md" <<EOF
- \`MAX_SESSIONS\`: 5
- \`MAX_CONSECUTIVE_CRASHES\`: 3
- \`ORGANISER_MODEL\`: opus
- \`WORKTREE_PATH\`: $TMP
- \`PROTECTED_BRANCHES\`: main,master,develop
EOF
unset ORCHESTRA_CONFIG
declare -gA ORCHESTRA_CONFIG
parse_config_md "$TMP/protected-explicit.md"
apply_config_defaults
[ "${ORCHESTRA_CONFIG[PROTECTED_BRANCHES]}" = "main,master,develop" ] || { echo "PROTECTED_BRANCHES explicit expected 'main,master,develop' got '${ORCHESTRA_CONFIG[PROTECTED_BRANCHES]:-<unset>}'"; exit 1; }

# Test: WORKTREE_PATH must be absolute path
cat > "$TMP/relative-path.md" <<'EOF'
- `MAX_SESSIONS`: 5
- `MAX_CONSECUTIVE_CRASHES`: 3
- `ORGANISER_MODEL`: opus
- `WORKTREE_PATH`: relative/path
EOF
unset ORCHESTRA_CONFIG
declare -gA ORCHESTRA_CONFIG
parse_config_md "$TMP/relative-path.md"
apply_config_defaults
if validate_config 2>/dev/null; then
    echo "expected validation failure for relative WORKTREE_PATH"
    exit 1
fi

echo "OK"
