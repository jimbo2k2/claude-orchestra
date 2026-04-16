# Development Protocol

All work — interactive and autonomous — follows this sequence. This is the single authoritative protocol for task execution, from intake to governance close-out.

## Mode Toggle

- **Interactive (default):** Gates pause for human input at checkpoints.
- **Orchestra (autonomous):** Gates auto-proceed. Decisions logged as PROPOSED for human ratification.
- Interactive can override to auto-proceed by explicit in-session request.

## Part 1: Task Protocol

| # | Step | Gate (skip if...) | Skill / Tool | On fail | Mode |
|---|------|-------------------|-------------|---------|------|
| 1 | **Receive task(s)** | — | Read T-number(s) from TODO.md. Mark IN_PROGRESS. | — | Same |
| 2 | **Create branch** | — | `git checkout -b <prefix>/<t-number>-<slug>` | — | Same |
| 3 | **Explore context** | — | Read linked plan, relevant docs, source. | — | Same |
| 4 | **Plan exists?** | Plan file referenced and exists -> skip to step 7. | — | Continue to 5. | Same |
| 5 | **Brainstorm & design** | Trivial single-file fix -> skip to step 8. | `superpowers:brainstorming` | — | Interactive: dialogue. Orchestra: auto-proceed. |
| 6 | **Write plan** | Skipped if step 5 skipped. | `superpowers:writing-plans` | — | Same |
| 7 | **Sanity-check plan** | No plan AND trivial -> skip. Always check existing plans. | `feature-dev:code-architect` subagent | **Checkpoint.** Fix before proceeding. | Interactive: present. Orchestra: auto-accept. |
| 8 | **Execute implementation** | — | `superpowers:executing-plans` or direct edit. | — | Same |
| 9 | **Code review** | No code changes -> skip. | `feature-dev:code-reviewer` subagent | **Checkpoint.** | Interactive: present. Orchestra: auto-fix. |
| 10 | **Type check** | No code changes -> skip. | Project type checker | Fix, re-run. | Same |
| 11 | **Run tests** | No code changes -> skip. | Project test runner | Fix, re-run. | Same |
| 12 | **Standing AC check** | No code changes -> skip. | Verify against standing acceptance criteria | Fix violations. | Same |
| 13 | **Simplify** | No code changes -> skip. | `simplify` skill | Apply non-breaking improvements. | Same |
| 14 | **Re-run tests** | No changes from 9-13 -> skip. | Test + type check | Fix regressions. | Same |
| 15 | **Governance: Decisions** | No decisions -> skip. | Write D-entries. | — | Interactive: ratified. Orchestra: PROPOSED. |
| 16 | **Governance: New tasks** | None discovered -> skip. | Write T-entries as PROPOSED. | — | Same |
| 17 | **Governance: Changelog** | No substantive changes -> skip. | Write C-entry. | — | Same |
| 18 | **Governance: Complete task** | — | Mark COMPLETE with note. Flag human-verify items. | — | Same |
| 19 | **Commit & push** | — | Commit on branch. Push. Do not merge to main. | — | Same |
| 20 | **Context check** | Not Orchestra -> stop. | 1. Re-read INBOX.md for new messages. 2. If 3+ tasks completed this session, prefer clean HANDOVER over risking context exhaustion. 3. If continuing, return to step 1. | — | Orchestra only. |

### Gate Logic

- **Steps 5-6** gate together on trivial tasks. **Step 7** always fires if a plan exists.
- **Steps 9-14** gate together on "did we change code?" — docs-only tasks skip to governance.
- **Step 20** is Orchestra's session-grouping logic.

## Part 2: Session Wrap-Up

Runs once before session exit.

| # | Step | Gate (skip if...) |
|---|------|-------------------|
| W1 | **Update learnings** | No new learnings -> skip. |
| W2 | **Propagate to Product docs** | No findings affecting docs -> skip. |
| W3 | **Review learnings for CLAUDE.md promotion** | No candidates -> skip. |
| W4 | **Governance archival** | No file crossed threshold -> skip. |
| W5 | **Write HANDOVER** | Not Orchestra, or last session -> skip. |
| W6 | **Final commit & push** | Nothing to commit -> skip. |
