#!/bin/bash
# orchestrator.sh — invoked inside the run worktree's tmux session.
# Phase 4: stub — touches a marker file and exits. Phases 5+ replace this.
set -euo pipefail

: "${RUN_DIR:?RUN_DIR not set}"
: "${WORKTREE_DIR:?WORKTREE_DIR not set}"

mkdir -p "$RUN_DIR/9-sessions"
touch "$RUN_DIR/9-sessions/000-stub.json"
echo "stub orchestrator: ran at $(date -u +%Y%m%d-%H%M%S)" >> "$RUN_DIR/7-SUMMARY.md"
echo "COMPLETE"
exit 0
