#!/bin/bash
# Run test_*.sh files in tests/, report pass/fail counts, exit non-zero on any failure.
#
# Usage:
#   bash tests/run-tests.sh            # all tests (~140s — includes hang test)
#   bash tests/run-tests.sh --fast     # skip slow tests (~40s) for tight iteration
#
# Tests in $SLOW_TESTS exercise real-time waits (e.g. the hang-detection
# watchdog has to wait MAX_HANG_SECONDS to fire). They're skipped under --fast
# so the day-to-day suite stays under a minute. Always run the full suite at
# end-of-phase and pre-merge.
set -u
cd "$(dirname "$0")"

SLOW_TESTS=(test_hang_detection.sh)

skip_slow=0
if [ "${1:-}" = "--fast" ]; then
    skip_slow=1
fi

is_slow() {
    local name="$1"
    local slow
    for slow in "${SLOW_TESTS[@]}"; do
        if [ "$name" = "$slow" ]; then
            return 0
        fi
    done
    return 1
}

passed=0
failed=0
skipped=0
failed_names=()

for test in test_*.sh; do
    [ -f "$test" ] || continue
    if [ "$skip_slow" -eq 1 ] && is_slow "$test"; then
        skipped=$((skipped + 1))
        echo "  SKIP: $test (--fast)"
        continue
    fi
    if bash "$test" >/dev/null 2>&1; then
        passed=$((passed + 1))
        echo "  PASS: $test"
    else
        failed=$((failed + 1))
        failed_names+=("$test")
        echo "  FAIL: $test"
    fi
done

echo ""
if [ "$skipped" -gt 0 ]; then
    echo "Results: $passed passed, $failed failed, $skipped skipped"
else
    echo "Results: $passed passed, $failed failed"
fi
[ "$failed" -eq 0 ]
