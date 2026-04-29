#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

source lib/config.sh

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

cat > "$TMP/CONFIG.md" <<'EOF'
# Test Config

Some prose to ignore.

## Section
- `MAX_SESSIONS`: 5
- `MODEL`: opus
- `WORKTREE_BASE`: /tmp/orch
- `BASE_BRANCH`: main
- `MAX_CONSECUTIVE_CRASHES`: 3
EOF

declare -gA ORCHESTRA_CONFIG
parse_config_md "$TMP/CONFIG.md"

[ "${ORCHESTRA_CONFIG[MAX_SESSIONS]}" = "5" ] || { echo "MAX_SESSIONS"; exit 1; }
[ "${ORCHESTRA_CONFIG[MODEL]}" = "opus" ] || { echo "MODEL"; exit 1; }
[ "${ORCHESTRA_CONFIG[WORKTREE_BASE]}" = "/tmp/orch" ] || { echo "WORKTREE_BASE"; exit 1; }
[ "${ORCHESTRA_CONFIG[BASE_BRANCH]}" = "main" ] || { echo "BASE_BRANCH"; exit 1; }

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
cat > "$TMP/bad2.md" <<'EOF'
- `MAX_SESSIONS`: 5
- `MAX_CONSECUTIVE_CRASHES`: 3
- `MODEL`: gpt4
- `WORKTREE_BASE`: /tmp/orch
- `BASE_BRANCH`: main
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

echo "OK"
