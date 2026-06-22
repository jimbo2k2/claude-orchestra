# Plan — `lr-tmux` Executor swap

Executes `spec.md` in this folder. Task-by-task, dependency order. Each task names its files, the change, the verification, and the commit boundary. Two repos are touched: **CO** = `~/projects/claude-orchestra/` (its own git repo), **LR** = `~/projects/logrings/logrings-main/` (LogRings git repo). The two `.orchestra/runtime/` installs under `~/projects/logrings/{logrings-main,20260505-alpha}/` are NON-authoring copies fed from CO via `propagate.sh`.

## Operator decisions (2026-06-22)

- **O1** — The pre-existing uncommitted `lr-*` harness edits (codewriter/reviewers/planwriter/SKILL) are committed FIRST, as their own commit on a new LR feature branch, before any retooling edit. Their content is not altered.
- **O2** — Branching: **LR gets a feature branch** (`feature/lr-tmux-executor`); **claude-orchestra commits on main** (no stated no-main rule there).
- **O3** — Both installs updated, byte-identical: `logrings-main` (on the LR feature branch) and `20260505-alpha` (on the `alpha` branch — a separate commit).

## Plan-review disposition (folded below)

B1 (review-channel clarity), B2 (headless signal reality), B3 (reattachment narrowing + safe reconcile), S1 (real model extraction), S2 (grep parity), S3 (cross-branch choreography), S4 (orphan the template), S5 (authoring-site invariant), N1 (max-wait bump), N2 (err-path comment), N3 (inline stray-commit as fast path), N4 (stubbed wrapper self-test), N5 (test-suite grep) all folded.

## Inflight (live execution log — tick as we go)

- [ ] T-pre  Create LR feature branch; commit pre-existing `lr-*` WIP (O1)
- [ ] T0  Back-port inotify tuning to canonical + `propagate.sh`
- [ ] T1  §6.4 no-self-delegation + review-is-external clarity in `lr-codewriter-o.md`
- [ ] T2  §6.3 headless guard (skill) + `LR_HEADLESS` export in `lr-dispatch.sh`
- [ ] T3  `dispatch-and-wait` wrapper in `lr-tmux`
- [ ] T4  §6.1 rewrite `organiser-prompt.txt` (keystone) — folds §6.2 + §6.5
- [ ] T5  Propagate changed CO files into both installs (cross-branch)
- [ ] T6  §8.6 smoke fixture + wrapper self-test + orphan-template + test-suite grep
- [ ] T7  Code-review gate (fresh-eyes subagent) + fold
- [ ] T8  Commit both repos (per O2/O3)

---

## T0 — Back-port inotify tuning + propagation helper (CO)

**Why first:** makes canonical a true superset of the installs so every later feed-down is safe (spec §3).

**Files:**
- `CO/bin/orchestrator.sh` — apply the two install-only tunings to canonical:
  - line ~332: `inotifywait -mr` → add `--exclude '(node_modules|\.git)'`.
  - line ~339: startup deadline `+ 5` → `+ 30`.
  - line ~354: error message `within 5s` → `within 30s`.
- `CO/build-history/lr-tmux-executor/propagate.sh` (new, `chmod +x`, `set -euo pipefail`):
  - Takes a list of runtime-relative file paths (e.g. `lib/organiser-prompt.txt`).
  - For each, copies `CO/<path>` → `<install>/.orchestra/runtime/<path>` for both installs.
  - After copying, `diff -q` each install copy against canonical and FAIL loudly if any differ.
  - Prints a one-line summary per file per install (COPIED / IDENTICAL-SKIPPED).
  - Hardcode the two install roots as an array; easy to extend.

**Verification:** `diff -q CO/bin/orchestrator.sh <main-install>/bin/orchestrator.sh` → identical after back-port. `bash -n propagate.sh` parses. Dry-run `propagate.sh` against a no-op file shows IDENTICAL.

**Commit (CO):** `back-port inotify tuning to canonical orchestrator.sh; add propagate.sh helper`.

---

## T1 — §6.4 no-self-delegation + review-is-external clarity (LR) — folds B1

**File:** `LR/.claude/agents/lr-codewriter-o.md`.

**Change:** add one directive (the file currently has zero delegation language), AND clarify the review channel (B1). The file currently states (lines 23/30/51) that the codewriter's work is gated by `lr-code-reviewer-o` reviewing each commit's diff at protocol step 9. A tmux-dispatched worker cannot self-fire a reviewer — and never could; in tmux dispatch the review has always been fired externally (by the skill's orchestrator, now by the Organiser). The new line must not leave the codewriter believing it must self-dispatch a per-commit reviewer (which would silently no-op). Wording:
> You ARE the codewriter. Write the code yourself, inline, sequentially. Never dispatch sub-codewriters — no `Agent`/`Task` self-delegation; to continue across a context boundary you are *resumed* (same session), you do not spawn a successor. Parallelism is reserved for decoupled mechanical sweeps only, never a feature's coupled code. **Review is fired externally:** when you run as a dispatched tmux worker, the per-commit/step-9 review is performed by a *separately dispatched* `lr-code-reviewer-o` (the orchestrator's or Organiser's job), not by you — commit at protocol points and your diffs will be reviewed out-of-band. Do not attempt to dispatch your own reviewer.

Place near the existing role block (~line 23). Do NOT touch its commit cadence (D1: commit behaviour stays identical; only the *who fires review* is clarified, and that was already external in tmux). The per-commit-vs-slice review-cadence question is a pre-existing property of tmux dispatch and is out of scope here.

**Verification:** `grep -n 'Never dispatch sub-codewriters' lr-codewriter-o.md` hits; the diff shows only the inserted directive (no change to commit lines).

**Commit (LR):** retooling commit on the feature branch (T8).

---

## T2 — §6.3 headless guard (LR) — folds B2

**Scope reality (B2):** the Organiser path does NOT invoke this skill — it dispatches workers directly via the wrapper. So this guard is purely defensive for the *observed* failure: a human/process invoking `/lr-feature-dev-tmux` directly under headless `claude -p`. The deterministic signal is set by the actual headless launcher in this ecosystem — `lr-dispatch.sh` (and any future headless skill launcher) — NOT by `orchestrator.sh` (which never runs this skill).

**Files:**
- `LR/Development/scripts/lr-tmux/lr-dispatch.sh` — in `run_streaming()`, export `LR_HEADLESS=1` into the `claude -p` environment (one line, next to the existing `CLAUDE_CONFIG_DIR=`). Deterministic marker that any dispatched session is headless.
- `LR/.claude/skills/lr-feature-dev-tmux/SKILL.md` — the "First action — choose the cycle mode" block (~lines 62–68). Prepend:
  > **Headless guard.** If you are running non-interactively — `LR_HEADLESS=1` is set in the environment, or you otherwise have no interactive client to answer an `AskUserQuestion` (e.g. launched under `claude -p`/`--print`) — do NOT call `AskUserQuestion`; it errors with no interactive client. Default to **Standard** mode, state the default in your output, and route any genuinely blocking decision to a `BLOCKED` signal / `1-INBOX.md` rather than an interactive prompt.

**Verification:** `grep -n LR_HEADLESS lr-dispatch.sh` hits inside `run_streaming`; skill guard text present before the `AskUserQuestion` instruction; `bash -n lr-dispatch.sh`.

**Commit (LR):** retooling commit on the feature branch (T8).

---

## T3 — `dispatch-and-wait` wrapper (LR)

**File (new):** `LR/Development/scripts/lr-tmux/lr-dispatch-wait.sh`, `chmod +x`, `set -euo pipefail`.

**Contract:**
```
lr-dispatch-wait.sh init   <role> <worktree> <taskfile> <label>   # launch fresh, block, print result
lr-dispatch-wait.sh resume <label> <taskfile>                     # resume, block, print result
```

**Behaviour:**
1. Resolve `LR_STATE` / `LEDGER` exactly as `lr-dispatch.sh` does (same env defaults).
2. **tmux collision guard:** if `tmux has-session -t lr-<label>` succeeds, FAIL (a worker with that label is already in flight) — never clobber.
3. Launch detached: `tmux new-session -d -s lr-<label> "bash <dir>/lr-dispatch.sh <mode> <args...>"`.
4. **Poll** the ledger until the row for `<label>` has `status==done` or `status==error`. Sleep interval ~10s. Add a **max-wait backstop** (env `LR_DISPATCH_MAX_WAIT`, default **14400s / 4h** — N1: a deep codewriter pushed to ~750–800k tokens per principle 6 can exceed 2h; a too-short cap turns a healthy worker into a spurious `error`). On exceed, FAIL with a clear message naming the still-running label (do not hang forever). Rely on `lr-dispatch.sh:finalize()` to always write a terminal status (its `|| true` guarantees this even on worker crash).
5. On `done`: extract the result with the **same filter `lr-dispatch.sh:finalize()` uses** (S2 — parity, tolerant of a space after the colon): `O=$(ledger .out); grep -E '"type": *"result"' "$O" | tail -1 | jq -r '.result'` — print to **stdout**, exit 0. If the result is empty despite `done` status, exit non-zero with a diagnostic (guards the "success treated as no-op" trap).
6. On `error`: print the result line if any, then the tail of `STATE/out/<label>.err` to **stderr**, exit non-zero. The Organiser treats a non-zero wrapper exit like an Executor ESCALATE/failure. (N2: the err path is `${out%.json}.err` per `lr-dispatch.sh` — derive it the same way and comment the tie so a future `OUTDIR` change can't silently break it.)

**Why a separate script, not a new mode in `lr-dispatch.sh`:** keeps the proven, e2e-smoke-tested dispatcher untouched; the wrapper is pure orchestration around it.

**Verification:** `bash -n`. A stubbed dry-run (fake ledger row pre-seeded to `done` with a hand-written out-file) returns the result text and exit 0; a pre-seeded `error` row returns non-zero and prints the err tail. Collision guard trips when a dummy `lr-x` session exists.

**Commit (LR):** with T1/T2 at T8, or standalone (it is independently useful).

---

## T4 — §6.1 rewrite `organiser-prompt.txt` (CO) — KEYSTONE; folds §6.2 + §6.5

**File:** `CO/lib/organiser-prompt.txt`.

This is a prose rewrite of a binding contract. Preserve structure and the surrounding discipline; swap only what the channel-change requires. Section-by-section:

**Header / role (lines 5–11):** keep "your job is NOT primarily to write code." Replace "brief subagent **Executors** via the Agent tool" with "dispatch **workers** through the `lr-tmux` harness (`lr-dispatch-wait.sh`)". Note workers are visible on `lr-dashboard` and resumable by label.

**§2b Dispatch protocol (lines 82–120):** rewrite:
- Replace "Compose a briefing using `executor-prompt-template.txt`" with "Write a lean task file to `STATE/<label>-task.md`" where `STATE = ~/projects/logrings/.lr-sessions` (or the harness's `LR_STATE`). Task-file shape (spec §5): job statement; plan excerpt; files in scope; acceptance condition; for a `resume`, the specific review findings to address. **No** protocol-folder pointer, **no** "you are an Executor" preamble — the `lr-*` agent supplies its own framing and reads the cascade itself.
- Replace step 4 ("Use the Agent tool … subagent_type general-purpose") with: dispatch via `bash <lr-tmux>/lr-dispatch-wait.sh init <role> <worktree> <taskfile> <label>` (fresh) or `resume <label> <taskfile>` (warm). The wrapper **blocks** until the worker returns and prints the worker's result to stdout — same blocking shape the Agent tool had (preserves the "no concurrent workspace edits while a worker is in flight" invariant, lines 100–104, verbatim in intent).
- **Worker-plan default:** ONE `lr-codewriter-o` for a feature's coupled code (label `codewriter`, `init` once then `resume`), with FRESH `lr-code-reviewer-o` each review round (label `code-review-<n>`, `init` each round). State principle 2 (no worker spawns a worker) and principle 3 (parallelism only for decoupled mechanical sweeps).
- **Model selection:** drop the per-task Sonnet/Opus choice prose — model is fixed by the agent's `-s`/`-o` suffix (spec §7 conscious trade). Keep a one-line note that this is deliberate.

**§2b.6 activity log (lines 106–120) — §6.2 BRIDGE + S1:** KEEP verbatim in intent. After every `lr-dispatch-wait` call, append one CSV line to `9-sessions/executor-activity.log` in the unchanged schema `<iso8601-ts>,<session-num>,<task-id>,<model>,<outcome>,<duration-seconds>`. `<task-id>` = the worker `<label>`. **`<model>` (S1):** do NOT fabricate it from the `-s`/`-o` suffix (that is a naming convention, not a model flag — `lr-dispatch.sh` passes `--agent` with no `--model`). Read the REAL model from the worker's out-file: `grep -E '"type": *"assistant"' "$O" | head -1 | jq -r '.message.model'`, then map the model id to the `sonnet|opus|haiku` family so wind-down's Step 1.5 model-mix math stays meaningful. If no model field is present, write `unknown` (wind-down tolerates it; better an honest `unknown` than a fabricated tier). `<duration>` from wall-clock around the wrapper call. This keeps wind-down unchanged (spec §2 D2).

**§2c iteration model:** "same task-id on retry" becomes "the label IS the task-id; to iterate, `resume <label>` (warm)." The review-fix loop: dispatch `code-review-<n>` fresh → if REVISE, `resume codewriter` with a task file naming the findings → re-review with `code-review-<n+1>`. Keep the two-attempt cap and the verification-gate-then-iterate logic (lines 122–281) — they are channel-agnostic.

**§2c.0 / §2c.1 announcement & status blocks (lines 135–165):** keep — they print to the Organiser's tmux pane (operator-watching). Add: the worker also shows live on `lr-dashboard` and via `tmux attach -t lr-<label>`.

**§2c.4 commit handling — D1:** where verification passes, the Organiser updates governance (parcel) and moves on. It does NOT commit the worker's code — the codewriter already committed it. Make explicit: **codewriter owns code commits; Organiser owns only the parcel commit.**

**Step 3 self-monitor / Step 4 exit (lines 283–355) — §6.5 + D1 + principle 4:**
- Principle 4: checkpoint only BETWEEN workers — never HANDOVER while a worker is in flight (the blocking wrapper makes this the natural shape: the Organiser cannot reach the threshold-check mid-wrapper).
- COMPLETE (D1 + N3): ensure the **parcel** is committed. Then `git status`: the codewriter committed its own code during its run, so the tree should be clean apart from the parcel. **If stray code remains, the Organiser commits it inline as the exceptional cleanup fast-path** (N3 — do NOT `resume codewriter` just to commit at the most context-exhausted moment; resume is the exception, not the default). Orchestra's Cat-D clean-worktree check (orchestrator.sh) + wind-down damage-assessment commit remain the final safety net. D1 holds: the Organiser does not *routinely* commit code; the codewriter does, during its run.
- HANDOVER (§6.5): when writing `6-HANDOVER.md`, if (exceptionally) a worker is in flight, record its `label` + `session_id` (from the ledger) so the next Organiser can reconcile it.
- **Cold-start ledger scan (§6.5 ungraceful backstop — B3, narrowed + made safe):** add to Step 1 (Read run state). A `running` ledger row can ONLY persist if `lr-dispatch.sh` itself was killed before `finalize()` ran (OOM-kill of the tmux session, reboot, manual `tmux kill-session`) — the blocking wrapper + principle 4 mean this is a rare double-fault, not routine recovery. State that. On cold-start, scan `.lr-sessions/ledger.json` for `status=="running"` rows and reconcile each:
  - tmux session `lr-<label>` still alive → the worker is genuinely running (parent Organiser died but child survived); wait on it via the wrapper's poll, then proceed.
  - tmux session gone AND a `type:"result"` event exists in the out-file → the worker actually finished; treat as done, read the result.
  - tmux session gone AND no result event → genuine orphan. **Do NOT autonomously `resume`** (the worktree may hold a half-written, uncommitted edit and the transcript may be truncated — resuming can fail or compound damage). Instead: if the worktree is dirty, record the orphan in `6-HANDOVER.md` and surface it (HANDOVER, or BLOCKED if it blocks all progress) for operator/next-session judgement; only `resume` when the tree is clean and resuming is plainly safe.

**§5.6 cache note — D6:** add one sentence: resume-warmth pays within a single review-fix loop (sub-cache-TTL); it is lost across a human gate (the run ends at BLOCKED there anyway). Observable post-hoc in the ledger cache columns; not a pre-dispatch gate.

**§5 governance authoring (lines 357–446):** the parcel-authoring contract is unchanged. REMOVE the §5.6 "PROTOCOL_FOLDER mirror substitution for executor briefs" block (lines 422–439) — it described filling `executor-prompt-template.txt`, which the `lr-tmux` path no longer uses. Replace with a one-line note that worker task files carry no protocol pointer (the agent reads the cascade itself).

**Verification:** read the rewritten file end-to-end; confirm no remaining reference to "Agent tool", `subagent_type`, or `executor-prompt-template.txt` except where deliberately explaining the change; confirm the CSV schema line is intact; confirm the two-attempt cap and verification gates survive.

**Commit (CO):** `rewrite Organiser contract: dispatch via lr-tmux harness (visible, resumable workers)`.

---

## T5 — Propagate changed CO files into both installs (cross-branch) — folds S3, resolved by O2/O3

**Confirmed:** `.orchestra/runtime/{bin,lib}/…` is git-TRACKED in both worktrees — `logrings-main` (on the LR feature branch after T-pre) and `20260505-alpha` (on `alpha`). So propagation is two distinct version-control acts (S3), not one filesystem copy.

**Files propagated:** the canonical CO files T4/T0 changed: `lib/organiser-prompt.txt` (always), and `bin/orchestrator.sh` (now that T0 back-ported the inotify tuning, canonical ⊇ install, so copying it down is safe and re-converges the two installs onto canonical).

**Run:** `bash CO/build-history/lr-tmux-executor/propagate.sh lib/organiser-prompt.txt bin/orchestrator.sh`. The helper copies CO→both installs and `diff -q`-verifies byte-identity.

**Commit choreography (O2/O3):**
- `logrings-main` install copies are staged on the **LR feature branch** and committed with the rest of the LR retooling (T8). Never on `main` directly (LR rule).
- `20260505-alpha` install copies are a **separate commit on the `alpha` branch** (its own worktree). `alpha` is not `main`, so a direct commit there is allowed — but SURFACE it to the operator before/at T8 since it touches the long-lived release channel.

**Verification:** `propagate.sh`'s built-in `diff -q` passes for every file × both installs; `git -C logrings-main status` and `git -C 20260505-alpha status` each show exactly the propagated runtime files changed.

---

## T6 — Smoke fixture + wrapper self-test + orphan-template + test grep (CO/LR) — folds S4, N4, N5

**6a — `with-organiser` fixture (CO, §8.6).** Extend (or add a sibling `with-lr-dispatch/`) under `CO/examples/smoke-test/` so the fixture documents an Organiser that dispatches via `lr-dispatch-wait.sh`. A live run invokes `claude -p` (cost + needs the LR harness present), so scope this to the fixture + a documented invocation; mark the live end-to-end run operator-gated (spec §7). Update its `README.md`.

**6b — Wrapper self-test (LR, N4).** Add `LR/Development/scripts/lr-tmux/test-dispatch-wait.sh` (`set -euo pipefail`): pre-seed a fake `ledger.json` + out-file in a temp `LR_STATE`, then assert the wrapper (i) returns the result text + exit 0 on a `done` row, (ii) exits non-zero + prints the err tail on an `error` row, (iii) trips the tmux-collision guard when `lr-<label>` exists, (iv) exits non-zero on empty-result-despite-done. Pure-bash, no live `claude`. This gives wrapper-regression coverage without the live-run gate.

**6c — Orphan the executor template (CO, S4).** `lib/executor-prompt-template.txt` is unused on the `lr-tmux` path after T4. Add a one-line `ORPHANED — the lr-tmux dispatch path does not use this; retained for the legacy Agent-tool path only.` header so a future reader doesn't mistake it for live contract. (Spec §7 keeps `bin/orchestra`'s `cp` of it untouched — harmless dead weight; note the contradiction is accepted, not resolved here.)

**6d — Test-suite grep (CO, N5).** Before T4 commit, grep `CO/tests/` for content-assertions on strings T4 removes (`Agent tool`, `subagent_type`, `executor-prompt-template`, `general-purpose`). If any test asserts on the old contract, update it. Confirm `tests/run-tests.sh --fast` passes.

**Commit (CO):** `smoke: lr-dispatch worker fixture; orphan executor template; test parity`. **(LR):** self-test rides the feature-branch retooling commit.

---

## T7 — Code-review gate (fresh-eyes subagent)

Dispatch a fresh general-purpose subagent (clean eyes, NOT lr-* — this is cross-repo orchestra work, not LogRings feature-dev) to review the full diff across both repos against this plan + spec. Focus: contract coherence (no dangling Agent-tool references), wrapper robustness (hang-safety, collision guard, error surfacing), the D1 commit-ownership nuance (stray-code path), the §6.5 cold-start ledger scan, and bash correctness (`set -euo pipefail`, quoting, `jq` filters). Fold findings; re-review only if substantive.

## T8 — Commit both repos

Commit CO (orchestrator back-port + propagate + organiser-prompt + smoke) and LR (codewriter line + skill guard + wrapper [+ propagated install copies if tracked]) at logical boundaries. Follow each repo's commit conventions. Per CO/LR rules: feature branch where required. **Surface to operator before any merge to main** — this is infra; the operator decides integration.

---

## Sequencing notes

- T0 → (T1, T2, T3 independent) → T4 → T5 → T6 → T7 → T8.
- T1/T2/T3 are LR-side and independent of the CO keystone; can be done in any order.
- T4 depends on T3 (the contract references the wrapper) and T0 (clean propagation pipeline).
- The live smoke run (T6) and any main merge (T8) are operator-gated.
