#!/bin/bash
# run.sh — Test runner for test-orchestrator project (v2: utility toolkit)
#
# Runs assertions against all scripts. Prints PASS/FAIL for each test.
# Exits non-zero if any test fails.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "PASS: $1"
    ((PASS_COUNT++))
}

fail() {
    echo "FAIL: $1"
    ((FAIL_COUNT++))
}

# ─── greet.sh ────────────────────────────────────────────────────────────────

echo "--- greet.sh ---"

if [ ! -f "$SCRIPT_DIR/scripts/greet.sh" ]; then
    fail "scripts/greet.sh does not exist"
else
    # Test with a name argument
    OUTPUT=$(bash "$SCRIPT_DIR/scripts/greet.sh" Alice 2>&1)
    EXIT_CODE=$?
    if [ $EXIT_CODE -ne 0 ]; then
        fail "greet.sh Alice exited with code $EXIT_CODE"
    elif echo "$OUTPUT" | grep -qi "Alice"; then
        pass "greet.sh Alice: output contains 'Alice'"
    else
        fail "greet.sh Alice: output '$OUTPUT' does not contain 'Alice'"
    fi

    # Test with no argument — should exit non-zero
    OUTPUT=$(bash "$SCRIPT_DIR/scripts/greet.sh" 2>&1)
    EXIT_CODE=$?
    if [ $EXIT_CODE -ne 0 ]; then
        pass "greet.sh (no args): exits non-zero"
    else
        fail "greet.sh (no args): should exit non-zero but got exit 0"
    fi
fi

# ─── password.sh ─────────────────────────────────────────────────────────────

echo "--- password.sh ---"

if [ ! -f "$SCRIPT_DIR/scripts/password.sh" ]; then
    fail "scripts/password.sh does not exist"
else
    # Test default length — should produce non-empty output
    OUTPUT=$(bash "$SCRIPT_DIR/scripts/password.sh" 2>&1)
    EXIT_CODE=$?
    if [ $EXIT_CODE -ne 0 ]; then
        fail "password.sh (default): exited with code $EXIT_CODE"
    elif [ -z "$OUTPUT" ]; then
        fail "password.sh (default): output is empty"
    else
        pass "password.sh (default): produces output"
    fi

    # Test that default output contains only valid characters (alphanum + symbols OK)
    OUTPUT=$(bash "$SCRIPT_DIR/scripts/password.sh" 2>&1)
    if echo "$OUTPUT" | grep -qE '[a-z]' && echo "$OUTPUT" | grep -qE '[A-Z]' || echo "$OUTPUT" | grep -qE '[0-9]'; then
        pass "password.sh (default): contains mix of character types"
    else
        fail "password.sh (default): output '$OUTPUT' doesn't appear to have mixed character types"
    fi

    # Test explicit length
    OUTPUT=$(bash "$SCRIPT_DIR/scripts/password.sh" 20 2>&1)
    EXIT_CODE=$?
    LEN=${#OUTPUT}
    if [ $EXIT_CODE -ne 0 ]; then
        fail "password.sh 20: exited with code $EXIT_CODE"
    elif [ "$LEN" -eq 20 ]; then
        pass "password.sh 20: output is exactly 20 characters"
    else
        fail "password.sh 20: output is $LEN characters (expected 20)"
    fi

    # Test that two invocations produce different output (randomness check)
    OUTPUT1=$(bash "$SCRIPT_DIR/scripts/password.sh" 2>&1)
    OUTPUT2=$(bash "$SCRIPT_DIR/scripts/password.sh" 2>&1)
    if [ "$OUTPUT1" != "$OUTPUT2" ]; then
        pass "password.sh: two invocations produce different output"
    else
        fail "password.sh: two invocations produced identical output ('$OUTPUT1')"
    fi
fi

# ─── sysinfo.sh ──────────────────────────────────────────────────────────────

echo "--- sysinfo.sh ---"

if [ ! -f "$SCRIPT_DIR/scripts/sysinfo.sh" ]; then
    fail "scripts/sysinfo.sh does not exist"
else
    OUTPUT=$(bash "$SCRIPT_DIR/scripts/sysinfo.sh" 2>&1)
    EXIT_CODE=$?
    if [ $EXIT_CODE -ne 0 ]; then
        fail "sysinfo.sh exited with code $EXIT_CODE"
    else
        LINE_COUNT=$(echo "$OUTPUT" | wc -l | tr -d ' ')
        if [ "$LINE_COUNT" -ge 4 ]; then
            pass "sysinfo.sh: outputs at least 4 lines ($LINE_COUNT lines)"
        else
            fail "sysinfo.sh: only $LINE_COUNT lines (expected at least 4)"
        fi
    fi
fi

# ─── README.md ───────────────────────────────────────────────────────────────

echo "--- README.md ---"

if [ ! -f "$SCRIPT_DIR/README.md" ]; then
    fail "README.md does not exist"
elif [ ! -s "$SCRIPT_DIR/README.md" ]; then
    fail "README.md is empty"
else
    pass "README.md exists and is non-empty"
fi

# ─── DECISIONS.md ────────────────────────────────────────────────────────────

echo "--- DECISIONS.md ---"

if [ ! -f "$SCRIPT_DIR/.orchestra/DECISIONS.md" ]; then
    fail ".orchestra/DECISIONS.md does not exist"
else
    # Count decision entries (lines starting with ###)
    DECISION_COUNT=$(grep -c '^### ' "$SCRIPT_DIR/.orchestra/DECISIONS.md" 2>/dev/null) || DECISION_COUNT=0
    if [ "$DECISION_COUNT" -ge 2 ]; then
        pass ".orchestra/DECISIONS.md has at least 2 entries ($DECISION_COUNT found)"
    else
        fail ".orchestra/DECISIONS.md has only $DECISION_COUNT entries (expected at least 2)"
    fi
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "================================"
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
echo "================================"

if [ $FAIL_COUNT -gt 0 ]; then
    exit 1
fi

exit 0
