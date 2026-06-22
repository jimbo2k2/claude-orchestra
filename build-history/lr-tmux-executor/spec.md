# Spec — visible, resumable `lr-tmux` Executors (the Orchestra dispatch-channel swap)

**Status:** ready to plan. Formalised from `RETOOLING-DESIGN.md` + the supervision-session decisions (2026-06-22).
**Scope:** cross-repo — `~/projects/claude-orchestra/` (the runtime) and `~/projects/logrings/logrings-main/` (the `lr-tmux` harness, the `lr-codewriter-o` agent, the `lr-feature-dev-tmux` skill).
**Source of truth for the design rationale:** `RETOOLING-DESIGN.md` in this folder. This spec records *what we build and the decisions taken*; the design doc records *why*.

---

## 1. Objective

Swap Orchestra's Executor **dispatch channel** from opaque in-process `Agent`-tool subagents to **visible, resumable `lr-tmux` worker sessions**, and narrow the default worker shape to **one sequential code-writing agent** (resumed warm) plus **fresh reviewers each round**. Everything else in Orchestra — the Organiser→Executor two-tier model, session chaining, HANDOVER, context-threshold self-wind-down, the external `orchestrator.sh` relaunch loop, run folders, parcel governance, hang/crash detection, wind-down — is unchanged.

The win: every unit of real work becomes watchable on the `lr-dashboard` and resumable by label, and a feature's coupled code is written by a single coherent author rather than a fan-out of subagents whose independent work must be reconciled.

## 2. Decisions taken (binding)

These were settled in the design conversation and override any contrary reading of `RETOOLING-DESIGN.md`:

- **D1 — Commit ownership.** The **codewriter owns code commits** (it already commits autonomously at protocol points — no change to its behaviour). The **Organiser owns only** the governance-parcel commit and a final clean-worktree *check* — it no longer does a catch-all `git add -A` before `COMPLETE`. This keeps `lr-codewriter-o.md`'s commit behaviour identical.
- **D2 — Tracker bridge = option (a).** The Organiser keeps appending one CSV line per dispatch to `9-sessions/executor-activity.log`, in the existing schema `<iso8601-ts>,<session-num>,<task-id>,<model>,<outcome>,<duration-seconds>`. Wind-down (`lib/winddown-prompt.txt`) is **not modified** — it already reads that file in Step 1.5 and Step 2a.
- **D3 — Blocking via a wrapper.** Add a `dispatch-and-wait` wrapper to the `lr-tmux` harness that launches the worker detached in tmux, blocks on the ledger until the row goes `done`/`error`, then prints the worker's `type:"result"` payload to stdout. This restores the Agent-tool's blocking-call shape so the Organiser contract is a near drop-in verb-swap, not a new polling protocol.
- **D4 — Edit distribution = canonical-source, manual per-file feed-down.** Edits are authored in the canonical `~/projects/claude-orchestra/` tree, then **manually copied per-file** into each install under `~/projects/logrings/*/.orchestra/runtime/`. Per-file (never a blanket tree copy) so the installs' local `orchestrator.sh` inotify tuning is never clobbered. A `propagate.sh` helper makes the feed-down mechanical and diff-verified. Two installs are kept identical: `logrings-main/` and `20260505-alpha/`.
- **D5 — Keep §6.4.** Add the no-self-delegation line to `lr-codewriter-o.md` (the file currently has no delegation language at all). Orthogonal to D1; it is the fix-at-source for the self-delegation that triggered the redesign.
- **D6 — Cache expectation is prose only.** State in the contract that resume-warmth pays *within* a single review-fix loop (sub-cache-TTL) and is lost across a human gate. No logic depends on it; warmth is observable post-hoc in the ledger's cache columns, not predictable pre-dispatch.

## 3. Pre-work — collapse the existing drift (step 0)

Audit finding (2026-06-22): the installed `orchestrator.sh` copies under both LogRings worktrees differ from canonical in exactly two spots — a local hardening of the inotify hang-detector:

- `inotifywait` gains `--exclude '(node_modules|\.git)'`.
- the watch-startup deadline goes `5s → 30s` (two occurrences: the deadline and its error message).

All `lib/` prompt files are byte-identical across canonical and both installs. Before any feed-down:

- **Back-port the two `orchestrator.sh` tunings into canonical**, so canonical becomes a true superset of the installs and is an honest source of truth.
- This makes the per-file feed-down rule (D4) safe even if `orchestrator.sh` is ever propagated.

## 4. Work items

Numbered to match `RETOOLING-DESIGN.md` §6.

- **W0 (step 0).** Back-port inotify tuning to canonical `orchestrator.sh`; add `propagate.sh`.
- **W6.4.** One-line no-self-delegation directive in `lr-codewriter-o.md` (D5).
- **W6.3.** Headless guard on `lr-feature-dev-tmux` SKILL: in a headless (`claude -p`) context, skip the opening `AskUserQuestion` and default to **Standard** mode. Blocking decisions in a headless run route via Orchestra's `1-INBOX.md` / `BLOCKED`, never `AskUserQuestion`.
- **W3 (wrapper).** `dispatch-and-wait` in `lr-tmux` (D3). Subcommands: launch+wait (init) and resume+wait.
- **W6.1 (keystone).** Rewrite `lib/organiser-prompt.txt` so dispatch goes through the wrapper instead of the `Agent` tool. Preserve: verification-gate-then-iterate, the two-attempt cap, per-task protocol commitment, governance-parcel discipline, the operator-watching announcement/status blocks. Change: dispatch verb; the worker-plan default (one resumed `lr-codewriter-o` + fresh `lr-code-reviewer-o` per round); the label-is-the-task-id iteration model (`resume` replaces "re-dispatch same task-id"); D1 commit-ownership; checkpoint-only-between-workers (principle 4); push-the-codewriter-deep briefing (principle 6); the D6 cache note.
- **W6.2.** Keep the executor-activity.log CSV append on each `lr-dispatch` (D2). Wind-down unchanged.
- **W6.5.** `6-HANDOVER.md` records any in-flight worker's `label` + `session_id` so a fresh Organiser can rediscover and `resume` it from the ledger (backstop to principle 4).
- **W8.6.** Extend `examples/smoke-test/with-organiser/` to exercise the `lr-dispatch`-based Organiser end-to-end.

## 5. The task-file format for `lr-tmux` workers

`lr-dispatch.sh` takes a `<taskfile>` whose contents become the worker's stdin prompt. Unlike `executor-prompt-template.txt` (which framed an Agent-tool Executor and injected a protocol-folder pointer), the `lr-*` agents supply their own role framing and read the LogRings cascade themselves. So the Organiser-authored task file is **leaner**: job statement, plan excerpt, files in scope, acceptance condition, and (for a `resume`) the specific review findings to address. The spec does **not** reuse `executor-prompt-template.txt` for the `lr-tmux` path; it defines a minimal task-file shape in the rewritten contract.

## 6. Acceptance criteria

Mirrors `RETOOLING-DESIGN.md` §8.

1. `orchestra run` against a feature `OBJECTIVE.md` produces one persistent Organiser tmux session that dispatches visible, resumable `lr-tmux` workers, all appearing on `lr-dashboard`.
2. A feature's code is written by one sequential `lr-codewriter-o`, resumed warm across review rounds; reviewers are fresh each round.
3. The Organiser self-winds-down at the context threshold **between workers**, writes `6-HANDOVER.md` (recording any in-flight worker), and `orchestrator.sh` relaunches a fresh Organiser that continues — no lost state, no orphaned worker.
4. The run halts cleanly at a human gate via `1-INBOX.md` / `BLOCKED`, never via `AskUserQuestion`.
5. Wind-down's Executor/governance summary correctly reflects the tmux-dispatched workers (because the CSV is still written — D2).
6. A smoke test exercises the `lr-dispatch`-based Organiser end-to-end (live run may be operator-gated for cost — see §7).

## 7. Out of scope / explicitly deferred

- **Per-task model selection.** The single-sequential-Opus-codewriter preference gives up Orchestra's Sonnet/Opus-per-task cost optimisation. Conscious trade (coherence over cost); documented, not litigated here.
- **Live end-to-end smoke run.** Building the smoke fixture/harness is in scope; *running* a full live `claude -p` Orchestra cycle costs money and time and is treated as an operator-gated verification (analogous to the LogRings sim-test gate), not an autonomous step.
- **`MAX_SESSIONS` / `ORGANISER_CONTEXT_THRESHOLD` re-tuning.** Each Organiser session now spans many dispatches before hitting its threshold, so these counters may need adjusting — flagged for tuning after the first real run, not pre-tuned here.
- **The orchestra CLI migrate/install path.** D4 chooses manual per-file feed-down; we do not modify `bin/orchestra`'s install logic in this change.

## 8. Non-negotiables (carry into the plan)

- `set -euo pipefail` in every shipped script (orchestra convention); shipped scripts `chmod +x`.
- The wrapper must be robust to the no-result-event crash case the way `lr-dispatch.sh:finalize` already is (a killed/crashed worker must still terminate the wait, not hang it forever).
- Canonical is the authoring site; installs receive per-file copies; the two installs stay byte-identical.
- No worker spawns a worker (principle 2). Parallelism only for decoupled mechanical sweeps (principle 3).
