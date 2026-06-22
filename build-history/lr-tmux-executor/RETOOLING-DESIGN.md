# Orchestra retooling — visible, resumable tmux Executors (the `lr-tmux` swap)

**Status:** design, ready to implement. Standalone brief — a fresh chat with no prior context can implement from this file alone.
**Author of brief:** captured from a LogRings AIC-rewrite supervision session (2026-06-22) where the pattern was observed live.
**Scope:** changes to the **claude-orchestra** runtime (`~/projects/claude-orchestra/`) and to the **LogRings** `lr-tmux` harness + agents/skill (`~/projects/logrings/logrings-main/`). Cross-repo.

---

## 1. One-sentence summary

Orchestra is already a two-tier **Organiser → Executor** ("conductor → worker") runtime; this change swaps the Executor **dispatch channel** from opaque in-process **Agent-tool subagents** to **visible, resumable `lr-tmux` sessions** (the LogRings harness that shows every agent on a web dashboard and can warm-resume it), and narrows the worker to **one sequential code-writing agent** rather than many parallel ones. Everything else in Orchestra — session chaining, HANDOVER, context-threshold self-wind-down, the external relaunch loop, run folders, parcel governance, hang/crash detection, wind-down — stays.

## 2. Why (the problem this solves)

Observed live during a large LogRings feature build driven through `/lr-feature-dev-tmux`:

- **Zero visibility into sub-work.** Orchestra's Organiser dispatches **Executor subagents via Claude Code's `Agent` tool** (see `~/projects/claude-orchestra/CLAUDE.md` lines 9–18). Those subagents are **in-process and opaque**: no tmux session, no ledger row, no dashboard presence, no resume handle. When a `lr-tmux` codewriter *itself* self-delegated via the Agent tool, we lost all visibility into the real work — defeating the entire point of the `lr-tmux` harness, which exists to make agents **watchable and resumable**.
- **Cost inflation from opaque self-delegation.** In the observed build, a slice done via heavy Agent-tool self-delegation (~8 nested subagents) cost **~$105**, versus **$22–46** for comparable-size slices written **inline by one agent**. Roughly **2× cost** for the fan-out, plus redundant cascade re-reads inside each hidden subagent.
- **No resumability of workers.** Agent-tool Executors are one-shot; you cannot warm-resume one to address a review finding. The `lr-tmux` harness resumes by `label` (reuses the warm cascade prefix + the agent's own reasoning), which is the token-efficiency win.

**Operator's stated architectural preference (the target):** all code for a feature is written **sequentially by ONE code-writing agent**, resumed as needed, rather than a conductor dispatching multiple agents whose independent work must be reconciled. Rationale: single-author coherence beats committee-plus-reconciliation; reconciliation is where subtle integration bugs hide; resume gives the token efficiency without fragmenting the authoring mind. Parallelism is reserved for **embarrassingly-independent mechanical sweeps** (e.g. "apply this lint rule to 50 unrelated files"), never for a feature's coupled code.

## 3. How Orchestra works TODAY (grounded in the actual runtime)

Read these to confirm before changing anything:
- `~/projects/claude-orchestra/CLAUDE.md` — the organiser-executor overview.
- `~/projects/claude-orchestra/bin/orchestrator.sh` — the **session loop** (runs inside the run's tmux; launches working sessions; watches for hangs/crashes).
- `~/projects/claude-orchestra/lib/organiser-prompt.txt` — **the Organiser inner-loop contract** (THE keystone file to rewrite). Injected as the system prompt into every working session.
- `~/projects/claude-orchestra/lib/executor-prompt-template.txt` — the Executor briefing skeleton the Organiser fills at dispatch time.
- `~/projects/claude-orchestra/lib/winddown-prompt.txt` — wind-down contract.
- LogRings project install: `~/projects/logrings/logrings-main/.orchestra/CLAUDE.md` — run-in-place model, run-folder layout, parcel governance.

Today's loop (run-in-place, organiser-executor):
1. `orchestra run` launches `orchestrator.sh` in one tmux session, in the operator-prepared worktree on a feature branch.
2. `orchestrator.sh` launches **working session N** — a `claude -p` instance acting as **Organiser**, with `organiser-prompt.txt` as system prompt + `OBJECTIVE.md` as the brief.
3. The Organiser holds plan + governance in context and **dispatches Executor subagents (Agent tool)** to do task work. It picks the model per-task (Sonnet bounded / Opus ambiguous), runs verification gates, and **escalates on the same task-id** when an Executor returns `ESCALATE` or fails verification.
4. When the Organiser's own context approaches **`ORGANISER_CONTEXT_THRESHOLD`**, it **self-winds-down**: writes `6-HANDOVER.md`, emits its terminal signal.
5. `orchestrator.sh` (the **external loop**) launches working session N+1 (a fresh Organiser) that reads `6-HANDOVER.md`. Repeat until `COMPLETE` / `BLOCKED` / `MAX_SESSIONS` / `MAX_CONSECUTIVE_CRASHES`.
6. A **wind-down session** verifies parcel-coverage and writes the run summary. The operator does the feature → main rollup manually.

**Key insight:** the context-window-limit case the operator worried about is **already solved** — the Organiser self-winds-down at the threshold and the *external* `orchestrator.sh` loop relaunches a fresh Organiser from `6-HANDOVER.md`. This is the robust pattern (survives ungraceful Organiser death, because the loop relaunches regardless) — strictly better than the Organiser self-spawning its own successor.

## 4. The target model

Same loop, same chaining, same threshold/handover/relaunch — but:
- The Organiser dispatches workers by **shelling out to `lr-dispatch.sh`** (the LogRings harness) and **polling `.lr-sessions/ledger.json`**, instead of calling the Agent tool. Workers become **named tmux sessions** that appear on the **`lr-dashboard`** web view and are **resumable by label**.
- The default worker shape is **ONE sequential codewriter** (`lr-codewriter-o`), resumed warm across the plan→review→fix loop, plus **fresh reviewers** (`lr-code-reviewer-o`) each round. No worker spawns a worker.
- The Organiser is lightweight (it accumulates only summaries), so it self-winds-down rarely — and **only between workers** (never mid-dispatch), so there is never an orphaned in-flight worker to reattach to.

LogRings harness files (canonical on `main`):
- `~/projects/logrings/logrings-main/Development/scripts/lr-tmux/lr-dispatch.sh` — `init <role> <worktree> <taskfile> <label>` | `resume <label> <taskfile>`. Writes the ledger, launches a `claude -p --agent <role>` in tmux under the isolated config home.
- `.../lr-tmux/lr-home-setup.sh` — sets up the isolated `CLAUDE_CONFIG_DIR` (shared credentials symlink + plugins incl. Supabase/Playwright MCP).
- `.../lr-tmux/lr-dashboard.py` + `lr-dashboard.sh` — the web dashboard (reads `.lr-sessions/ledger.json` + per-session out-files; has Turns + Tokens in/out/total + Cache columns).
- `.../lr-tmux/DESIGN.md` — harness architecture.
- The skill: `~/projects/logrings/logrings-main/.claude/skills/lr-feature-dev-tmux/SKILL.md` (the dispatch flow: explorer → spec → planwriter → plan-review loop → codewriter → code-review loop).
- The agents: `~/projects/logrings/logrings-main/.claude/agents/lr-{codewriter-o,code-reviewer-o,planwriter-o,plan-reviewer-o,explorer-s}.md`.

## 5. Design principles (carry into implementation)

1. **One sequential authoring thread per feature.** The codewriter writes all of a feature's coupled code itself, inline, resumed across sessions via `handover.md` ONLY when the window forces it. Never dispatch sub-codewriters.
2. **No worker spawns a worker.** Two tiers, flat: Organiser (conductor) and workers. Orchestration lives only at the Organiser tier.
3. **Parallelism only for decoupled mechanical sweeps.** Never for a feature's coupled code.
4. **Checkpoint only between workers.** The Organiser hits `ORGANISER_CONTEXT_THRESHOLD` and winds down at a clean worker boundary — never while a worker tmux session is running. This sidesteps in-flight reattachment entirely.
5. **All durable state in files, never only in context.** Ledger, plan `## Inflight`, `Governance/pending/<hex>.md` parcels, `6-HANDOVER.md`. Re-incarnation must lose nothing even on ungraceful death.
6. **Push each worker deep.** Brief the codewriter that it has a 1M window; push toward ~750–800k before checkpointing (not bailing at ~58%), to minimise handover seams. (Observed: agents self-assess "heavy context" far too conservatively — they plateaued ~575k and stopped.)

## 6. Work items (the implementation)

### 6.1 Rewrite the Organiser contract — `lib/organiser-prompt.txt` (KEYSTONE)
Replace the "dispatch Executor subagents via the Agent tool" instructions with "dispatch workers via the `lr-tmux` harness":
- To dispatch: write a task file to `STATE/<label>-task.md`, then `tmux new-session -d -s lr-<label> "bash <lr-dispatch.sh> init <role> <worktree> <taskfile> <label>"`.
- To poll: loop on `jq -e '.[]|select(.label=="<label>" and (.status=="done" or .status=="error"))' ledger.json`.
- To read the result: the `type:"result"` event in the out-file (`grep '"type":"result"' "$out" | tail -1 | jq -r '.result'`).
- To iterate/escalate: `resume <label>` (warm) for review-fix; this REPLACES Orchestra's "re-dispatch same task-id" — the label IS the task-id.
- Default worker plan: ONE `lr-codewriter-o` for the whole feature (resumed), fresh `lr-code-reviewer-o` each review round.
- Keep: the verification-gate-then-iterate logic, the per-task protocol-commitment, the governance-parcel discipline.
- Add: the checkpoint-between-workers rule (principle 4) and the "push the codewriter deep" briefing (principle 6).

### 6.2 Bridge the two tracking systems
Orchestra logs working sessions to `9-sessions/` + `executor-activity.log` (which hooks **Agent-tool** dispatches); `lr-tmux` tracks workers in `.lr-sessions/ledger.json` + the dashboard. After the swap, `executor-activity.log` goes blind and wind-down's Executor/governance summary misses the tmux workers. Fix one of:
- (a) the Organiser also appends a CSV line to `executor-activity.log` on each `lr-dispatch` (cheapest), OR
- (b) wind-down reads `.lr-sessions/ledger.json` for the Executor summary.
Recommend (a) — keeps wind-down unchanged.

### 6.3 Headless guard on `/lr-feature-dev-tmux`
The skill OPENS with an `AskUserQuestion` (cycle-mode pick) — which **errors in a headless `claude -p` context** (observed). Add a headless-mode entry that **skips the asks and defaults to Standard mode**. More generally: blocking decisions in a headless run must surface via Orchestra's `1-INBOX.md` / `BLOCKED` marker, NOT via `AskUserQuestion`.

### 6.4 One line in `lr-codewriter-o.md`
Add: *"You ARE the codewriter. Write the code yourself, inline, sequentially. Never dispatch sub-codewriters (no `Agent`/`Task` self-delegation); resume yourself instead. Parallelism is reserved for decoupled mechanical sweeps only."* This is the fix-at-source for the self-delegation that started the whole problem — the agent had read "lr-codewriter-o is mandated for code-writing" as "*dispatch* lr-codewriter-o."

### 6.5 In-flight worker reattachment (backstop)
Even with principle 4 (checkpoint between workers), make `6-HANDOVER.md` record any in-flight worker's `label` + `session_id` so a fresh Organiser can rediscover and `resume` it from the ledger. This is the one genuinely new wrinkle vs Orchestra-classic (whose Agent-tool Executors die with the session and never outlive it).

## 7. Edge cases (checklist for the implementer)

- **In-flight reattachment** — §6.5. Mitigated by §5.4 but keep the backstop.
- **Two trackers** — §6.2.
- **Cache-TTL vs human gates** — resumability pays *within* a slice's tight loop (sub-1h); across a human gate (sim test) the warm cache expires and Orchestra ends the run at `BLOCKED` anyway → next run is cold. Don't over-expect resumability across gates.
- **Per-task model selection** — Orchestra picks Sonnet/Opus per task for cost. The single-sequential-Opus-codewriter preference **gives this up** deliberately (more cost, more coherence). Conscious trade; document it.
- **Headless human-interaction** — §6.3. Route through `1-INBOX.md` / `BLOCKED`.
- **Commit channel** — Orchestra run-in-place "commits directly on HEAD"; `lr-codewriter` workers also commit autonomously. Confirm no double-commit / hook collision; pick one committer. (Parcels already align — workers write `Governance/pending/<hex>.md`; wind-down verifies coverage.)
- **MAX_SESSIONS meaning shifts** — each lightweight Organiser session now spans many worker-dispatches before hitting its threshold, so `MAX_SESSIONS` (counting Organiser sessions) may need re-tuning; per-worker runs don't count against it.
- **Two tmux namespaces** — Orchestra owns the run's tmux session; `lr-dispatch` creates `lr-<label>` sessions. Different names, coexist fine; the global tmux rule (named, collision-check, targeted teardown) applies.

## 8. Acceptance / done criteria

1. `orchestra run` against a feature `OBJECTIVE.md` produces **one persistent Organiser tmux session** that dispatches **visible, resumable `lr-tmux` worker sessions** — all appearing on the `lr-dashboard`.
2. A feature's code is written by **one sequential `lr-codewriter-o`**, resumed warm across review rounds; reviewers are fresh each round.
3. The Organiser self-winds-down at the context threshold **between workers**, writes `6-HANDOVER.md` (recording any in-flight worker), and `orchestrator.sh` relaunches a fresh Organiser that continues — with no lost state and no orphaned worker.
4. The run halts cleanly at a human gate (sim test / blocking design decision) via `1-INBOX.md` / `BLOCKED`, never via `AskUserQuestion`.
5. Wind-down's Executor/governance summary correctly reflects the tmux-dispatched workers.
6. A smoke test (extend `examples/smoke-test/with-organiser/`) exercises the `lr-dispatch`-based Organiser end-to-end.

## 9. Suggested implementation order

1. §6.4 (one-line agent fix) + §6.3 (headless skill guard) — cheap, independently useful, unblock visibility immediately.
2. §6.1 (rewrite `organiser-prompt.txt` to `lr-dispatch`) — the keystone.
3. §6.2 (tracker bridge) + §6.5 (reattachment backstop).
4. §8.6 smoke test; tune `MAX_SESSIONS` / `ORGANISER_CONTEXT_THRESHOLD`.

## 10. Provenance / evidence

- Cost: self-delegated slice ~$105 vs inline slices $22–46 (≈2× from fan-out).
- Context: inline codewriter sessions peaked ~575–594k of a 1M window (≈58%) and self-assessed as "heavy" — too conservative; the orchestrator-as-self-delegator plateaued ~394k because it held only summaries (the real tokens were invisible, inside the Agent-tool subagents).
- The whole motivation: `/lr-feature-dev-tmux` exists to make agents watchable + resumable; Agent-tool Executors break both properties. Routing Executors through `lr-dispatch.sh` restores them with minimal change because **Orchestra already is the conductor/worker model** — only the dispatch channel changes.
