#!/bin/bash
# verify-completion.sh — Stop hook (prompt-based verification)
#
# Uses claude -p with Haiku to verify that Claude actually completed its
# work before allowing the session to stop. Routes through the Max
# subscription — no ANTHROPIC_API_KEY needed.
#
# If the claude CLI is not available, the hook passes through (non-blocking)
# so the system still works without verification, just without the safety net.

# ─── Guard against recursive invocation ──────────────────────────────────────
# claude -p spawns its own session, which triggers Stop hooks again.
# This env var breaks the loop.

if [ "${VERIFY_HOOK_RUNNING:-}" = "1" ]; then
    exit 0
fi
export VERIFY_HOOK_RUNNING=1

# ─── Skip if claude CLI not available (graceful degradation) ─────────────────

if ! command -v claude &>/dev/null; then
    exit 0
fi

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_DIR="${STATE_DIR:-${PROJECT_DIR}/.orchestra}"

# ─── Gather context for the verifier ─────────────────────────────────────────

TODO_CONTENT=""
HANDOVER_CONTENT=""
ACCEPTANCE_CRITERIA=""
TEST_RESULT=""

if [ -f "$STATE_DIR/TODO.md" ]; then
    TODO_CONTENT=$(head -100 "$STATE_DIR/TODO.md")
fi

if [ -f "$STATE_DIR/HANDOVER.md" ]; then
    HANDOVER_CONTENT=$(head -100 "$STATE_DIR/HANDOVER.md")
fi

# Extract acceptance criteria from PLAN.md if it exists
if [ -f "$STATE_DIR/PLAN.md" ]; then
    ACCEPTANCE_CRITERIA=$(sed -n '/^## Acceptance Criteria/,/^## /p' "$STATE_DIR/PLAN.md" | head -50)
fi

# Check for uncommitted changes that weren't staged
UNSTAGED=$(git diff --name-only 2>/dev/null | head -10)

# Check if tests exist and what their last result was
# Adapt these to your test runner
if [ -f "$PROJECT_DIR/package.json" ] && grep -q '"test"' "$PROJECT_DIR/package.json" 2>/dev/null; then
    TEST_RUNNER="npm test"
elif [ -f "$PROJECT_DIR/pytest.ini" ] || [ -f "$PROJECT_DIR/setup.py" ]; then
    TEST_RUNNER="pytest"
elif [ -f "$PROJECT_DIR/tests/run.sh" ]; then
    TEST_RUNNER="bash tests/run.sh"
else
    TEST_RUNNER="none"
fi

# ─── Build the verification prompt ───────────────────────────────────────────

VERIFY_PROMPT="You are a work verification assistant. Your job is to check whether an AI coding session completed its work properly.

Review the following project state and determine if the session can stop.

TODO.md (current state):
---
$TODO_CONTENT
---

HANDOVER.md (current state):
---
$HANDOVER_CONTENT
---

Acceptance criteria from PLAN.md:
---
${ACCEPTANCE_CRITERIA:-No PLAN.md or no acceptance criteria defined}
---

Unstaged file changes: ${UNSTAGED:-none}
Test runner available: $TEST_RUNNER

Check these criteria:
1. Has at least one TODO item been checked off OR has meaningful progress been made?
2. Does HANDOVER.md contain useful context (not empty or boilerplate)?
3. Are there unstaged changes that should have been committed?
4. If the session claims COMPLETE, are all TODO items actually checked off?
5. If the session claims COMPLETE and acceptance criteria exist, does the work appear to satisfy them?

Respond with ONLY a JSON object, no other text:
{
  \"pass\": true or false,
  \"reason\": \"brief explanation\"
}"

# ─── Call the lightweight model via claude CLI ───────────────────────────────
# Using Haiku for speed — this check should take <2 seconds
# --max-turns 1 prevents tool-use loops; just answers the prompt directly

RESPONSE=$(claude -p "$VERIFY_PROMPT" \
    --model haiku \
    --output-format json \
    --max-turns 1 \
    2>/dev/null)

# ─── Parse the result ─────────────────────────────────────────────────────────

if [ -z "$RESPONSE" ]; then
    # CLI call failed — don't block, let the session end
    exit 0
fi

# Extract the text content from the CLI JSON response
VERIFY_TEXT=$(echo "$RESPONSE" | jq -r '.result // empty' 2>/dev/null)

if [ -z "$VERIFY_TEXT" ]; then
    # Couldn't parse response — don't block
    exit 0
fi

# Try to parse as JSON and check the pass field
PASS=$(echo "$VERIFY_TEXT" | jq -r '.pass // empty' 2>/dev/null)
REASON=$(echo "$VERIFY_TEXT" | jq -r '.reason // "no reason given"' 2>/dev/null)

if [ "$PASS" = "false" ]; then
    # Verification failed — output blocking signal
    # The "decision" block tells Claude Code to keep working
    cat <<EOF
{
    "decision": "block",
    "reason": "Work verification failed: $REASON. Please address this before finishing."
}
EOF
    exit 0
fi

# Verification passed (or was indeterminate) — allow session to end
exit 0
