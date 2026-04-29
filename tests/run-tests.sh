#!/bin/bash
# Run all test_*.sh files in tests/, report pass/fail counts, exit non-zero on any failure.
set -u
cd "$(dirname "$0")"

passed=0
failed=0
failed_names=()

for test in test_*.sh; do
    [ -f "$test" ] || continue
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
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
