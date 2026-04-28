# Session-Scoped Governance — Design

**Date:** 2026-04-28
**Scope:** Orchestra protocol change. Phases 1 + 2 of a larger plan that also includes (Phase 3) T-number policy and (Phase 4) TODO.md restructure — both deferred to a later spec.

## Problem

Two interlocking issues with the current orchestra protocol:

1. **Parallel writers collide on main governance.** Every session — orchestra or interactive — touches `TODO.md`, `DECISIONS.md`, and `CHANGELOG.md`. When two sessions run concurrently (typical: a couple of interactive Claude chats on unrelated code), they fight over the next-number markers and the file sections, even when their code changes don't conflict.

2. **The current half-mitigation breaks orchestra's completion check.** A rule was added saying "don't flip statuses on main TODO.md from a session branch", but orchestra's loop condition reads the worktree's TODO.md to decide if assigned tasks are done. On a session branch, statuses never flip, so orchestra spawns recovery session after recovery session until `MAX_CONSECUTIVE_STALLS` trips. (Observed live: 4+ Claude sessions in a row reporting COMPLETE while orchestra kept reading OPEN.)

The bug and the parallel-writer problem are the same root cause: **governance writes are mid-run, and shared state.**

## Design

Make the orchestra session **fully self-contained for governance purposes** during the run. Defer all main-governance writes to a single, human-triggered merge step.

### What changes

1. **During an orchestra run**, Claude writes only to:
   - `.orchestra/sessions/run-<timestamp>/tasks.md` — assigned + discovered tasks, session-local numbering
   - `.orchestra/sessions/run-<timestamp>/decisions.md` — proposed decisions, session-local numbering, mirrors main `DECISIONS.md` shape (new)
   - `.orchestra/sessions/run-<timestamp>/changelog.md` — proposed changelog entries, session-local numbering, mirrors main `CHANGELOG.md` shape (new)
   - `.orchestra/sessions/run-<timestamp>/log.md` — free-form session notes, findings, parked issues (existing, narrower scope)
   - Session branch code commits (unchanged)

   The session folder mirrors main's governance structure: three structured files (`tasks.md`, `decisions.md`, `changelog.md`) plus `log.md` for everything that isn't a formal entry.

2. **Session-local numbering, clean from 1.** Each run starts its own counters: `T1, T2, T3...`, `D1, D2, D3...`, `C1, C2, C3...`. Within the session there's only one writer, so sequential numbering is collision-free. The merger translates session-local numbers to main's next-numbers at ingest (e.g. session `T1` becomes main `T392`).

   For tasks **assigned from main's brief**, each session-local task carries a `source:` field pointing back to the originating main T-number. Example:

   ```
   - T1: COMPLETE (source: main:T384) — Title here
       Notes: ...
   - T2: IN_PROGRESS (source: main:T385) — Title here
       Notes: ...
   - T3: PROPOSED — Discovered: tighten error handling in foo
       Notes: ...
   ```

   For **discovered tasks** (not in the original brief), no `source:` field — they're new and the merger will assign a fresh main T-number with PROPOSED status.

   Decisions and changelog entries have no `source:` because they originate in the session.

   This makes the merger nearly mechanical — read three files, translate IDs, ingest into three files.

3. **Main governance files are read-only during the run.** Claude may *read* `TODO.md`, `DECISIONS.md`, `CHANGELOG.md` for context. Claude must not write to them, and the orchestra protocol must not require it.

4. **Orchestra's completion check reads `tasks.md`**, not the worktree's `TODO.md`. The session-of-truth and the check now look at the same surface.

5. **A new merge protocol** — invoked by the human via Claude Code when ready to integrate a session — does a one-shot ingest of session governance files into main governance.

### What stays the same (this phase)

- Main governance file shapes: `TODO.md`, `DECISIONS.md`, `CHANGELOG.md` keep their current format.
- Main T/D/C numbering: still sequential. Main numbers are now only ever assigned by the merger, never mid-session. (Sessions use their own local numbering and the merger translates.)
- The `<!-- Next number: TXXX -->` markers stay — they're now only ever incremented by the merger, which is a single sequential operation against main.
- Worktree + session-branch model: unchanged.
- `.orchestra/config TASKS=` field: unchanged. Pre-existing T-numbers in main TODO.md are still the way orchestra is briefed.

(Number policy and TODO.md restructure are deferred to the Phase 3+4 spec.)

## Components

### 1. Protocol updates

**`templates/orchestra-CLAUDE.md`** — change the Governance section:

> **Governance (during run):** Do not write to main `TODO.md`, `DECISIONS.md`, or `CHANGELOG.md`. The run folder mirrors main's governance structure with **session-local numbering** (T1, T2, ...; D1, D2, ...; C1, C2, ...) — write to those instead:
> - Task progress for each assigned task → `tasks.md` with session-local T-number, status, and `source: main:T<n>` field linking back to the brief
> - Decisions made → `decisions.md` with session-local D-numbers, PROPOSED status, same format as main `DECISIONS.md` (title, alternatives, rationale)
> - Changelog-worthy work → `changelog.md` with session-local C-numbers, same format as main `CHANGELOG.md`
> - New tasks discovered → `tasks.md` with session-local T-numbers, PROPOSED status, no `source:` field
> - Free-form notes, findings, parked issues that aren't formal entries → `log.md`
>
> Cross-references *within the session* use session-local IDs (e.g. a decision can reference T2 of the same run). Cross-references *to main* use real main IDs (e.g. "supersedes main:D0017"). Reading main governance files for context is fine and encouraged.

**`templates/DEVELOPMENT-PROTOCOL.md`** — change steps 15-18 ("Governance: Decisions / New tasks / Changelog / Complete task") to write to the session folder's `decisions.md`, `changelog.md`, and `tasks.md` instead of main files when in Orchestra mode. Interactive mode keeps writing direct to main (interactive sessions don't use a session scratchpad).

**`templates/orchestra-CLAUDE.md` Exit Signals** — clarify that COMPLETE means "all assigned tasks marked complete in `tasks.md`", not in main TODO.md.

### 2. Orchestra completion check (two layers)

The completion check has a mechanical layer (orchestra bash) and a semantic layer (Claude judgement). Both must pass for a run to be COMPLETE.

**Layer A — Claude coverage evaluation (semantic).** Before Claude signals COMPLETE for a session, it must run an explicit coverage check as part of session wrap-up:

1. Read main's `TODO.md` snapshot in the worktree (cloned at run start) for each assigned main T-number from `.orchestra/config TASKS=`. Extract title, acceptance criteria, dependencies.
2. Read the session's `tasks.md`, `decisions.md`, `changelog.md`, and the session branch's commits.
3. For each assigned main T-number, find the matching session-local task via the `source: main:T<n>` field. Evaluate: does the recorded work actually cover what main's TODO entry asks for? Not just "is the session-local task COMPLETE", but "would a human reading the main TODO entry agree this is done"?
4. If a task is partially done, ambiguous, or COMPLETE-marked but undercooked, downgrade the session-local entry back to IN_PROGRESS or BLOCKED with a note. Do not signal COMPLETE for the session.
5. Only signal COMPLETE when every assigned main T-number's session-local counterpart has been honestly covered.

This becomes a new step in `DEVELOPMENT-PROTOCOL.md` Part 2 (session wrap-up), positioned before the existing W5 "Write HANDOVER" step. Call it **W4.5 — Coverage evaluation**.

The reason this needs to be explicit: without it, a Claude session that hits context fatigue can mark things COMPLETE-by-default to exit cleanly, and orchestra will accept that. The evaluation gate forces Claude to compare its work product against the original brief.

**Layer B — Orchestra mechanical check (bash).** `bin/orchestra` and/or `lib/orchestrator.sh` reads `tasks.md` (not main `TODO.md`) and, for each main T-number in `TASKS=`, finds the line whose `source:` field matches and checks its status is `COMPLETE`. Anything missing or not COMPLETE means a recovery session is needed.

Format of `tasks.md`:

```
- T1: COMPLETE (source: main:T384) — Title here
    Notes: ...
- T2: IN_PROGRESS (source: main:T385) — Title here
    Notes: partial: did X, Y still outstanding
- T3: BLOCKED (source: main:T386) — Title here
    Notes: reason in detail (also written to INBOX.md)
- T4: COMPLETE — Discovered: tighten error handling in foo
    Notes: no source field — proposed for promotion to main
```

The grep is slightly more involved than a flat status check (needs to match `source: main:T<n>` and a status on the same entry), but it's still a deterministic bash operation.

Layer B alone is the bug fix from the pasted analysis — it stops the recovery loop. Layer A is the integrity guarantee that prevents the obvious workaround (Claude rubber-stamping COMPLETE to exit).

### 3. Merge protocol (Claude Code, not bash)

A new protocol document — `templates/MERGE-PROTOCOL.md` — that the human invokes by saying something like "we're ready to merge run-20260428-070537". Claude follows it.

The protocol:

1. **Identify the run.** Locate `.orchestra/sessions/run-<timestamp>/` in the worktree. Read `tasks.md`, `decisions.md`, `changelog.md`, and `log.md`.
2. **Read main's current state.** Read main's `TODO.md`, `DECISIONS.md`, `CHANGELOG.md` and their `<!-- Next number -->` markers. Read INBOX.md.
3. **Plan the ingest.** Produce a structured summary for the human, translating session-local IDs to main IDs:
   - Task statuses to flip on main `TODO.md`: walk session `tasks.md` entries that have a `source: main:T<n>` field — flip those main T-numbers to the session-local status
   - Decisions to add to main `DECISIONS.md`: assign main D-numbers starting from main's next-number marker (session D1 → main D<next>, session D2 → main D<next+1>, ...). Rewrite intra-session references (`see D2`) to use the new main numbers.
   - Changelog entries to add to main `CHANGELOG.md`: same pattern, session C-numbers → main C-numbers.
   - Discovered tasks to add to main `TODO.md` as PROPOSED: session tasks with no `source:` field get fresh main T-numbers.
   - Surface anything notable from `log.md` to the human for awareness
   - Flag conflicts: main governance changed since the run started (entries with overlapping topics, decisions touching the same area as a recent main D-entry)
4. **Human checkpoint.** Present the plan. Wait for approval, edits, or rejections. This is the conflict-resolution moment.
5. **Apply.** Write the approved entries to main governance files in main's working tree. Bump the next-number markers. Commit on main with message `governance: ingest run-<timestamp>`.
6. **Merge code.** Merge the session branch into main (fast-forward where possible, otherwise standard merge with conflict resolution). Push.
7. **Mark the run ingested.** Append a `## Ingested` marker to the run's `log.md` with the date, list of assigned numbers, and the resulting commit SHAs. This makes re-running the protocol on an already-ingested run a no-op (idempotency check at step 1).

The merge protocol is **Claude Code, not bash**, because: deduplication across `log.md` entries, picking the right entry type (decision vs changelog vs follow-up task), summarising rationale, and resolving cross-session conflicts (e.g. two parallel runs both touched the same area) all need judgement. Bash would either be brittle or would just shell out to Claude anyway.

### 4. Interactive mode is unchanged this phase

Interactive Claude sessions still write directly to main governance.

**Note:** the dominant parallel-collision pain reported by the user is actually interactive-vs-interactive (two unrelated chats converging on the same governance files), not orchestra-vs-interactive. Phase 1+2 does **not** fix that — it fixes the orchestra completion-check bug and removes orchestra as a contention source, but two interactive sessions both editing main `TODO.md` will still race on the next-number markers. The proper fix for interactive-vs-interactive contention is in Phase 3+4 (dropping or deferring sequential numbering — once each entry has a unique slug-based identity, parallel writers can't collide on a shared sequence). Phase 1+2 is therefore staged as: kill the bug, make orchestra well-behaved, then tackle the interactive collision in the follow-up spec.

## Data flow

```
[orchestra run start]
        |
        v
session writes -> .orchestra/sessions/run-<ts>/tasks.md
                   .orchestra/sessions/run-<ts>/decisions.md
                   .orchestra/sessions/run-<ts>/changelog.md
                   .orchestra/sessions/run-<ts>/log.md
                   (session branch code commits)
        |
        v
[orchestra completion check reads tasks.md]
        |
        v
[run ends — worktree preserved]
        |
        v
[human: "ready to merge run-<ts>"]
        |
        v
[Claude follows MERGE-PROTOCOL.md]
        |
        +--> reads tasks.md + decisions.md + changelog.md + log.md
        +--> reads main governance
        +--> proposes ingest plan
        +--> human reviews
        +--> writes main governance
        +--> merges session branch
        +--> marks run ingested
```

## Error handling

- **Run is already ingested.** Step 1's idempotency check finds the `## Ingested` marker, refuses cleanly, tells human to either skip or explicitly override.
- **Main governance changed during the run.** Detected at step 3 (proposed numbers might collide, or a topic was already decided on main). Surface as a conflict in the plan; human decides.
- **Session branch doesn't merge cleanly.** Standard git merge conflict resolution at step 6. Code merge is independent of governance ingest — if governance is committed but code merge fails, governance is still consistent, human resolves the code separately.
- **Orchestra completion check can't parse tasks.md.** Treat as "work remains" (conservative); surface a warning so the run reports the bad state rather than spinning silently.

## Testing

- **Smoke test (`orchestra test`)** must be updated: it currently presumably touches main governance; switch it to write to `tasks.md` and verify the new completion check.
- **Manual integration test:** run a small orchestra job, confirm main governance is untouched at end-of-run, confirm `tasks.md` reflects status, then walk a human through the merge protocol against a live test run.
- **Bug regression test:** simulate the scenario from the pasted analysis (Claude reports COMPLETE 4+ times, main TODO statuses unchanged). New completion check should terminate the run after 1 confirmation, not loop.

## Out of scope (Phase 3 + 4)

- Whether T-numbers should exist at all (slugs vs sequential)
- Splitting TODO.md into a slim backlog + an append-only ledger
- Per-task files vs single TODO.md
- Any change to interactive mode's governance writes

These will be brainstormed together in a separate session because the answers depend on each other.

## Open questions for Phase 1+2

None blocking. The merge protocol's exact prose can be drafted during implementation; the structure above is sufficient for planning.
