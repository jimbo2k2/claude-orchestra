#!/bin/bash
# Orphan COMPLETE detection — spec § 8.1.
#
# Working session signals COMPLETE without writing a parcel despite non-trivial
# Executor activity. Wind-down's Step 2 verification flags the gap in
# 7-SUMMARY.md (### Governance verification, status GAP). Wind-down does NOT
# retroactively create parcels.
#
# Opt-in only — invokes real Claude. Run manually:
#   ./bin/orchestra test orphan-complete
#
# Fixture under examples/smoke-test/orphan-complete/ has the OBJECTIVE that
# instructs the Organiser to dispatch an Executor but skip parcel-writing,
# simulating the bug we're catching.
echo "  SKIP: opt-in integration test (run manually: ./bin/orchestra test orphan-complete; fixture under examples/smoke-test/ TBD post-Slice-1)"
exit 0
