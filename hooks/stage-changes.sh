#!/bin/bash
# stage-changes.sh — PostToolUse hook for Edit|MultiEdit|Write
# Stages modified files so the Stop hook can commit them.
# Runs after every file modification tool use — keep it fast.

# Read JSON from stdin (Claude Code passes tool context)
INPUT=$(cat)

# Extract the file path from the tool input
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)

if [ -n "$FILE_PATH" ] && [ -f "$FILE_PATH" ]; then
    git add "$FILE_PATH" 2>/dev/null || true
fi

# Always exit 0 — staging failure shouldn't block Claude's work
exit 0
