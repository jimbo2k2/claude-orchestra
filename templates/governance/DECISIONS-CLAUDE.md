# Decisions Archiving Protocol

## When to archive
Archive when the active file exceeds **30 current entries**.

## How to archive
1. Move resolved decisions to `archive/DXXXX-DYYYY.md`.
2. Add one-line summary to "Summary Index": `- DXXXX: Decision title — ACTIVE`
3. Update the next-number comment.
4. Archive files are **immutable**.
