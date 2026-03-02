#!/bin/bash
# commit-and-update.sh — Stop hook
# Fires when Claude finishes responding. Commits any staged changes.
#
# This runs AFTER verify-completion.sh (hooks execute in order).
# By this point, verification has either passed or forced Claude to
# continue working. If we reach here, the work unit is done.

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_DIR="${STATE_DIR:-${PROJECT_DIR}/.orchestra}"
SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cd "$PROJECT_DIR"

# Only commit if there are staged changes
if ! git diff --cached --quiet 2>/dev/null; then
    CHANGED_FILES=$(git diff --cached --name-only | head -20)
    FILE_COUNT=$(git diff --cached --name-only | wc -l | tr -d ' ')

    # Read Claude-generated commit message, fall back to generic
    TASK_SUMMARY=""
    if [ -f "$STATE_DIR/COMMIT_MSG" ]; then
        TASK_SUMMARY=$(head -c 68 "$STATE_DIR/COMMIT_MSG" | tr -d '\n')
    fi

    if [ -z "$TASK_SUMMARY" ]; then
        TASK_SUMMARY="session update ($FILE_COUNT files)"
    fi

    COMMIT_MSG="auto: $TASK_SUMMARY

Session: $SESSION_ID
Time: $TIMESTAMP
Files changed: $FILE_COUNT
$CHANGED_FILES"

    git commit -m "$COMMIT_MSG" --no-verify 2>/dev/null || true
fi

# Also stage and commit state files if they've changed
# Clean up COMMIT_MSG after use (it's per-session, not a persistent state file)
rm -f "$STATE_DIR/COMMIT_MSG"

for STATE_FILE in TODO.md CHANGELOG.md HANDOVER.md DECISIONS.md INBOX.md; do
    if [ -f "$STATE_DIR/$STATE_FILE" ]; then
        if ! git diff --quiet "$STATE_DIR/$STATE_FILE" 2>/dev/null; then
            git add "$STATE_DIR/$STATE_FILE"
        fi
    fi
done

if ! git diff --cached --quiet 2>/dev/null; then
    git commit -m "auto: state files update

Session: $SESSION_ID
Time: $TIMESTAMP" --no-verify 2>/dev/null || true
fi

# Push to remote if configured (Gitea, GitHub, etc.)
# Uncomment the following line once your remote is set up:
# git push origin HEAD 2>/dev/null || true

exit 0
