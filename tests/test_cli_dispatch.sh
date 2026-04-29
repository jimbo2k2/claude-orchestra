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

# Each known subcommand should be routed by the dispatcher and not be flagged
# as unknown. `init` has a real side-effecting implementation, so target a
# throwaway temp dir. `test` invokes a real smoke run against Claude (5-15
# min, burns tokens) — its dispatching is already covered by the usage-grep
# above, so skip the actual invocation here.
REPO="$(pwd)"
for cmd in init run status reset; do
    if [ "$cmd" = "init" ]; then
        # Use init's target-dir argument instead of cd+capture-via-tempfile —
        # avoids any fixed-name temp-file race between parallel test runs.
        TMP_DISPATCH=$(mktemp -d)
        ( cd "$TMP_DISPATCH" && git init -q )
        out=$("$REPO/bin/orchestra" init "$TMP_DISPATCH" 2>&1) || true
        rm -rf "$TMP_DISPATCH"
    else
        # Stubs may exit 0 (help-like behaviour) or non-zero — both fine,
        # we only check that the dispatcher didn't classify it as unknown.
        out=$(./bin/orchestra "$cmd" 2>&1) || true
    fi
    if echo "$out" | grep -q "Unknown command"; then
        echo "subcommand '$cmd' was treated as unknown"
        exit 1
    fi
done

echo "OK"
