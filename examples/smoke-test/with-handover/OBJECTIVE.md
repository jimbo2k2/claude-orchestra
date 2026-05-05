# Run Objective

This objective is split into two **phases**, each meant for a different
session. The split is deliberate — it forces a HANDOVER between sessions
to verify the multi-session pickup path.

## Phase 1 (Session 1 only)

1. Create `file-a.txt` containing the literal text `alpha`. Commit it.
2. Add `[smoke-todo] Phase 1 done — Phase 2 work remains.` to `3-TODO.md`.
3. Add `[smoke-decision] Used alpha as Phase 1 content per smoke spec.` to `4-DECISIONS.md`.
4. Add `[smoke-changelog] Added file-a.txt (alpha).` to `5-CHANGELOG.md`.

## Phase 1 → 2 transition (CRITICAL — read carefully)

After completing Phase 1, you **MUST**:

1. Write `6-HANDOVER.md` with a brief (3–8 line) handover briefing for
   the next session. The briefing must explicitly state:
   - Phase 1 is complete (file-a.txt exists, governance entries recorded).
   - Phase 2 remains: create `file-b.txt` with content `beta`, commit it,
     add the matching governance entries.
2. Emit `HANDOVER` (not `COMPLETE`) as the LAST line of your output, on
   its own line.

**Do NOT do Phase 2 in Session 1.** Even if you have time. The smoke
test is verifying that the multi-session HANDOVER path works — collapsing
both phases into one session defeats the test and will cause assertion
failure. The whole point is to land mid-run, hand off, and resume.

## Phase 2 (Session 2 only)

A second session will pick up the work. Read `6-HANDOVER.md` for the
briefing.

1. Create `file-b.txt` containing the literal text `beta`. Commit it.
2. Add `[smoke-todo] Phase 2 done.` to `3-TODO.md`.
3. Add `[smoke-decision] Used beta as Phase 2 content per smoke spec.` to `4-DECISIONS.md`.
4. Add `[smoke-changelog] Added file-b.txt (beta).` to `5-CHANGELOG.md`.

## Phase 2 completion

When BOTH `file-a.txt` AND `file-b.txt` exist with the right content,
emit `COMPLETE`.

## Run governance markers

- In `3-TODO.md`, prefix every entry with `[smoke-todo]`.
- In `4-DECISIONS.md`, prefix every entry with `[smoke-decision]`.
- In `5-CHANGELOG.md`, prefix every entry with `[smoke-changelog]`.

These are required by the smoke test. Do NOT use any of these markers in
the wrong file.
