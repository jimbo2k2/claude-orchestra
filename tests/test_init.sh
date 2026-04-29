#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="$(pwd)"
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

cd "$TMP"
git init -q

"$REPO/bin/orchestra" init . 2>&1

# Layout assertions
[ -d .orchestra/runtime/bin ] || { echo "missing runtime/bin"; exit 1; }
[ -d .orchestra/runtime/lib ] || { echo "missing runtime/lib"; exit 1; }
[ -d .orchestra/runs/archive ] || { echo "missing runs/archive"; exit 1; }
[ -x .orchestra/runtime/bin/orchestra ] || { echo "orchestra not executable"; exit 1; }
[ -f .orchestra/runtime/lib/config.sh ] || { echo "config.sh missing"; exit 1; }
[ -f .orchestra/CONFIG.md ] || { echo "CONFIG.md missing"; exit 1; }
[ -f .orchestra/OBJECTIVE.md ] || { echo "OBJECTIVE.md missing"; exit 1; }
[ -f .orchestra/CLAUDE.md ] || { echo "CLAUDE.md missing"; exit 1; }

# Init must NOT create governance dirs or settings.json or DEVELOPMENT-PROTOCOL.md
[ ! -d TODO ] || { echo "TODO/ should not be created"; exit 1; }
[ ! -d Decisions ] || { echo "Decisions/ should not be created"; exit 1; }
[ ! -d Changelog ] || { echo "Changelog/ should not be created"; exit 1; }
[ ! -f .claude/settings.json ] || { echo ".claude/settings.json should not be created"; exit 1; }
[ ! -f DEVELOPMENT-PROTOCOL.md ] || { echo "DEVELOPMENT-PROTOCOL.md should not be created"; exit 1; }

# Re-run init: must not overwrite user's edits
echo "USER-MODIFIED" > .orchestra/CONFIG.md
"$REPO/bin/orchestra" init . 2>&1
[ "$(cat .orchestra/CONFIG.md)" = "USER-MODIFIED" ] || { echo "CONFIG.md was overwritten on re-init"; exit 1; }

# Init outside a git repo: must error, not auto-init
TMP2=$(mktemp -d)
cd "$TMP2"
if "$REPO/bin/orchestra" init . 2>/dev/null; then
    rm -rf "$TMP2"
    echo "expected error when target is not a git repo"
    exit 1
fi
rm -rf "$TMP2"

echo "OK"
