#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# orchestra prints usage on no args; dispatches to known subcommands; errors on unknown.

out=$(./bin/orchestra 2>&1) || true
echo "$out" | grep -q "Usage:" || { echo "missing Usage"; exit 1; }
echo "$out" | grep -q "init" || { echo "missing init in usage"; exit 1; }
echo "$out" | grep -q "run" || { echo "missing run in usage"; exit 1; }
echo "$out" | grep -q "status" || { echo "missing status in usage"; exit 1; }
echo "$out" | grep -q "test" || { echo "missing test in usage"; exit 1; }
echo "$out" | grep -q "reset" || { echo "missing reset in usage"; exit 1; }

# Unknown subcommand should error
if ./bin/orchestra bogus 2>/dev/null; then
    echo "expected error on unknown subcommand"
    exit 1
fi

# Each known subcommand should exit non-zero (stubs error out — they're not implemented)
# but should NOT print "Unknown command"
# `init` has a real implementation with side effects, so target a throwaway temp dir.
REPO="$(pwd)"
for cmd in init run status test reset; do
    if [ "$cmd" = "init" ]; then
        TMP_DISPATCH=$(mktemp -d)
        ( cd "$TMP_DISPATCH" && git init -q && out=$("$REPO/bin/orchestra" init . 2>&1) || true; echo "$out" ) >/tmp/.orchestra_dispatch_out 2>&1 || true
        out="$(cat /tmp/.orchestra_dispatch_out)"
        rm -rf "$TMP_DISPATCH" /tmp/.orchestra_dispatch_out
    else
        if out=$(./bin/orchestra "$cmd" 2>&1); then
            # Stubs may exit 0 for help-like behaviour or non-zero — both fine, just check no "Unknown command"
            :
        fi
    fi
    if echo "$out" | grep -q "Unknown command"; then
        echo "subcommand '$cmd' was treated as unknown"
        exit 1
    fi
done

echo "OK"
