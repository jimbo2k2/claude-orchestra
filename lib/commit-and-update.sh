#!/bin/bash
# commit-and-update.sh — Stop hook (v2)
# Fires when Claude finishes responding. Makes a single commit
# containing both code changes and governance file updates.

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_DIR="${STATE_DIR:-${PROJECT_DIR}/.orchestra}"
SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cd "$PROJECT_DIR"

# Load config for governance file paths
SCRIPT_DIR_HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR_HOOK/config.sh" ]; then
    source "$SCRIPT_DIR_HOOK/config.sh"
    load_orchestra_config "$PROJECT_DIR" 2>/dev/null || true
fi

# Stage governance files from config paths
for gov_file in "${TODO_FILE:-}" "${DECISIONS_FILE:-}" "${CHANGELOG_FILE:-}"; do
    if [ -n "$gov_file" ] && [ -f "$gov_file" ]; then
        git diff --quiet "$gov_file" 2>/dev/null || git add "$gov_file" 2>/dev/null || true
    fi
done

# Stage operational files
for op_file in HANDOVER.md INBOX.md; do
    if [ -f "$STATE_DIR/$op_file" ]; then
        git diff --quiet "$STATE_DIR/$op_file" 2>/dev/null || git add "$STATE_DIR/$op_file" 2>/dev/null || true
    fi
done

# Single commit: code + governance together
if ! git diff --cached --quiet 2>/dev/null; then
    CHANGED_FILES=$(git diff --cached --name-only | head -20)
    FILE_COUNT=$(git diff --cached --name-only | wc -l | tr -d ' ')

    # Read Claude-generated commit message, fall back to generic
    TASK_SUMMARY=""
    if [ -f "$STATE_DIR/COMMIT_MSG" ]; then
        TASK_SUMMARY=$(head -c 68 "$STATE_DIR/COMMIT_MSG" | tr -d '\n')
    fi
    [ -z "$TASK_SUMMARY" ] && TASK_SUMMARY="session update ($FILE_COUNT files)"

    COMMIT_MSG="auto: $TASK_SUMMARY

Session: $SESSION_ID
Time: $TIMESTAMP
Files changed: $FILE_COUNT
$CHANGED_FILES"

    # --no-verify: avoid recursive hook invocation
    git commit -m "$COMMIT_MSG" --no-verify 2>/dev/null || true
fi

# Clean up COMMIT_MSG (per-session, not persistent)
rm -f "$STATE_DIR/COMMIT_MSG"

exit 0
