#!/bin/bash
# Legacy-mode wind-down compat — spec §§ 3.6.1, 8.1.
#
# Project without Governance/CLAUDE.md + Governance/pending/. Wind-down's
# legacy Step 2 appends 3/4/5 to parent governance files.
#
# Opt-in only — invokes real Claude. Run manually:
#   ./bin/orchestra test legacy-mode-compat
#
# (Existing `./bin/orchestra test with-governance` and `with-conflict`
# variants already exercise the legacy-mode wind-down path against
# parent-file governance shapes; this stub anchors the spec-prescribed
# fixture name for cross-reference.)
echo "  SKIP: opt-in integration test (use existing 'with-governance' or 'with-conflict' variants for legacy-mode coverage)"
exit 0
