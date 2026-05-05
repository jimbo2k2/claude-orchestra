# With-handover smoke-test fixture

Exercises the multi-session **HANDOVER → next-session pickup → COMPLETE**
lifecycle.

The OBJECTIVE.md is structured into two phases that the agent is
explicitly instructed to split across two sessions: Session 1 does
Phase 1 and emits `HANDOVER`; Session 2 reads the briefing and does
Phase 2 to `COMPLETE`. This is the only way to deterministically force
the handover path — otherwise the agent might choose to finish the work
in one session.

`smoke_assert_with_handover()` in `bin/orchestra` verifies:

- `9-sessions/` contains exactly 2 session JSON files.
- The archived `6-HANDOVER.md` is non-empty (Session 1 wrote a briefing).
- Both work products land on the merged base (`file-a.txt` = `alpha`,
  `file-b.txt` = `beta`).
- Run governance shows entries for both Phase 1 and Phase 2 markers.
- Wind-down ingestion ran (legacy mode — same path as `with-governance`).

Note: `MAX_SESSIONS=2` from the harness is exactly enough — a third
session would indicate an unexpected second HANDOVER.
