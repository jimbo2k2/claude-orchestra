#!/bin/bash
# Autonomy: acceptance command fails, Organiser persists — spec § 8.1.
#
# A task whose acceptance command initially fails. Organiser must NOT emit
# BLOCKED; instead read failure, fix (inline or via fix-Executor), retest,
# succeed, COMPLETE with parcel.
#
# Opt-in only — invokes real Claude. Run manually:
#   ./bin/orchestra test autonomy-persist
echo "  SKIP: opt-in integration test (run manually: ./bin/orchestra test autonomy-persist; fixture under examples/smoke-test/ TBD post-Slice-1)"
exit 0
