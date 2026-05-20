#!/bin/bash
# Executor BLOCKED on one task, slice completes — spec §§ 3.7.3, 8.1.
#
# N-task brief where task K returns Executor BLOCKED. Assert: Organiser takes
# K inline; if K remains stuck, captures K as deferred in the parcel; the
# session COMPLETEs (assuming the remaining tasks succeed) — NOT session BLOCKED.
#
# Opt-in only — invokes real Claude. Run manually:
#   ./bin/orchestra test executor-blocked-slice-completes
echo "  SKIP: opt-in integration test (run manually: ./bin/orchestra test executor-blocked-slice-completes; fixture under examples/smoke-test/ TBD post-Slice-1)"
exit 0
