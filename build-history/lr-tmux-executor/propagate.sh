#!/usr/bin/env bash
# propagate.sh — feed canonical claude-orchestra runtime files into the LogRings installs.
#
# D4 (lr-tmux Executor retooling): canonical `~/projects/claude-orchestra/` is the single
# authoring site. The `.orchestra/runtime/` copies inside each LogRings worktree are git-TRACKED
# but non-authoring — they are fed from canonical, PER FILE (never a blanket tree copy, so an
# install's local tuning of a file we are NOT propagating is never clobbered).
#
# After copying, every install copy is `diff -q`-verified byte-identical against canonical; any
# mismatch is a hard failure (we never leave a half-propagated install).
#
# Usage:
#   propagate.sh <runtime-relative-path> [<runtime-relative-path> ...]
# Example:
#   propagate.sh lib/organiser-prompt.txt bin/orchestrator.sh
#
# Paths are relative to the canonical root (CANON) and to each install's `.orchestra/runtime/`.
set -euo pipefail

CANON="${CO_CANON:-$HOME/projects/claude-orchestra}"

# Install roots — each holds `.orchestra/runtime/`. Add new installs here.
INSTALLS=(
  "$HOME/projects/logrings/logrings-main"
  "$HOME/projects/logrings/20260505-alpha"
)

if [[ $# -lt 1 ]]; then
  echo "usage: propagate.sh <runtime-relative-path> [<path> ...]" >&2
  echo "  e.g. propagate.sh lib/organiser-prompt.txt bin/orchestrator.sh" >&2
  exit 2
fi

fail=0
for rel in "$@"; do
  src="$CANON/$rel"
  if [[ ! -f "$src" ]]; then
    echo "FATAL: canonical source missing: $src" >&2
    exit 3
  fi
  for inst in "${INSTALLS[@]}"; do
    dst="$inst/.orchestra/runtime/$rel"
    if [[ ! -d "$(dirname "$dst")" ]]; then
      echo "FATAL: install dir missing: $(dirname "$dst")" >&2
      exit 3
    fi
    if [[ -f "$dst" ]] && diff -q "$src" "$dst" >/dev/null 2>&1; then
      echo "IDENTICAL-SKIPPED  $rel  ->  $inst"
      continue
    fi
    cp -p "$src" "$dst"
    # Preserve the executable bit for shipped scripts (orchestra convention).
    [[ -x "$src" ]] && chmod +x "$dst"
    if diff -q "$src" "$dst" >/dev/null 2>&1; then
      echo "COPIED            $rel  ->  $inst"
    else
      echo "FATAL: post-copy diff still differs: $dst" >&2
      fail=1
    fi
  done
done

if [[ "$fail" -ne 0 ]]; then
  echo "propagate.sh: one or more installs failed byte-identity verification" >&2
  exit 1
fi
echo "propagate.sh: all targets verified byte-identical to canonical."
