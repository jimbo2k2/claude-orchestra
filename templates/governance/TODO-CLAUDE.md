# TODO Archiving Protocol

## When to archive
Archive when the active file exceeds **30 current entries** (entries in the "Current Tasks" section).

## How to archive
1. Move all COMPLETE tasks from "Current Tasks" to a new file in `archive/` named `TXXXX-TYYYY.md` (range of T-numbers).
2. For each archived task, add a one-line summary to the "Summary Index" section: `- TXXXX: Task title — COMPLETE`
3. Update the `<!-- Next number: TXXX -->` comment.
4. Archive files are **immutable** once created — never edit them.

## Task entry format
See the main TODO.md for the standard entry format. All fields are mandatory except Parent and Depends (which are omitted when not applicable).

## Task statuses
- **OPEN** — ready for pickup (default for new tasks)
- **IN_PROGRESS** — a session is working on it
- **COMPLETE** — finished and verified
- **BLOCKED** — needs human input (reason in detail)
- **PROPOSED** — awaiting human approval before becoming OPEN
