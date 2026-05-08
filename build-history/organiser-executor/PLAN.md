# Organiser / Executor — implementation plan

Status: Phase 0 complete, ready for Phase 1. Authored 2026-05-08 from
a design conversation following the cost audit of run-20260507-141954
(~$960 overnight, 11 sequential Opus-high working sessions, no model
adaptiveness). Code-reviewed 2026-05-08 against current orchestra
codebase; review findings folded in. Phase 0 verification spike run
2026-05-08 (`/tmp/orchestra-phase0-spike`); findings folded in.

Vocabulary in this plan follows spec Section 2: **run**, **working
session**, **wind-down session**. "Outer loop" / "inner loop" are used
only as architecture descriptors — they do not name a new session tier.

## Goal

Replace the current "every working session re-reads everything and
executes sequentially" model with a two-tier loop:

- **Outer loop**: existing orchestra working-session lifecycle, unchanged
  in shape. One headless Claude invocation per working session.
- **Inner loop**: inside each working session, the Claude instance acts
  as an **Organiser**, dispatching subagent **Executors** to do the
  actual task work via Claude Code's `Agent` tool (the headless-mode
  name for what the docs sometimes call the Task tool). The Organiser
  holds the plan + governance state in context; Executors only see the
  slice they need.

The win is Sonnet-priced execution under Opus-quality direction, with
the Organiser free to escalate to Opus on the fly when an Executor hits
ambiguity.

## Operating principles (settled in design)

1. **Organiser autonomy is high.** Plans stay human-readable prose
   (typically a `Pipeline/` folder authored interactively with Opus-high
   beforehand). The Organiser decides per task: which model to dispatch,
   what context to bundle, whether to verify inline or batch, whether to
   do trivial work itself instead of dispatching, when to wind itself
   down and hand off to the next working session.
2. **One run, one branch.** All Executor work lands on the same
   run-branch by default (preserving today's audit shape). The Organiser
   may opt a specific Executor into a separate worktree if the task
   warrants isolation (e.g. exploratory spike, risky refactor); the
   default is shared workspace.
3. **Hybrid Organiser, not pure orchestrator.** The Organiser may edit
   directly when dispatching would be wasteful (one-line fixes, trivial
   renames). Dispatching has token + latency overhead; let the Organiser
   judge. **Constraint:** the Organiser does not begin inline edits
   while an Executor is in flight — it waits for `DONE`/`ESCALATE`/
   `BLOCKED` before touching the workspace itself. The Agent tool blocks
   the parent on subagent return so this is the natural shape, but the
   rule is stated explicitly to kill ambiguity.
4. **Verification is the Organiser's call.** No mandatory post-task
   verification. The Organiser may run acceptance commands inline, batch
   verification at the end of a logical group, or dispatch a dedicated
   validation Executor. Project-level Development/ protocols still
   govern what "done" means.
5. **Full audit trail preserved by the parent transcript alone.** Phase 0
   confirmed that subagent tool-use events (Bash, Write, Edit, Read,
   etc.) appear inline in the parent's stream-json NDJSON at
   `9-sessions/NNN.json`, with full input args. The Agent dispatch
   itself is also captured (subagent_type, briefing prompt, return
   text). No standalone per-Executor files are needed for data
   preservation. Post-hoc analysis is done by reading the NDJSON
   (typically by handing it to Claude for a summary).
6. **Organiser self-monitors context.** When its own working context
   approaches a configurable threshold, it cleanly winds down any
   in-flight Executor work, writes HANDOVER, and exits — same shape as
   today's working-session boundary, just driven by the Organiser's
   judgement.

## Architecture

```
orchestra run
  └─ working session N (Claude headless, ORGANISER_MODEL)  ← outer loop
       │
       ├─ Organiser reads PLAN / Pipeline / .orchestra state
       │
       ├─ inner loop:
       │    pick next ready task(s)
       │    decide: dispatch, do inline, or escalate
       │    if dispatch:
       │      Agent tool call  →  subagent runs (sonnet | opus | haiku)
       │      (briefing prompt + subagent tool-use events
       │       are captured inline in 9-sessions/NNN.json)
       │      append activity entry → 9-sessions/executor-activity.log
       │      apply result: verify-now | defer-verify | escalate
       │    update CHANGELOG / DECISIONS / TODO as work lands
       │
       └─ when context tight or all tasks done:
            commit work, write HANDOVER → exit signal
            (HANDOVER | COMPLETE | BLOCKED)
            (existing orchestrator.sh handles the next-session spawn)
```

The outer-loop contract with `orchestrator.sh` does not change — it
still sees HANDOVER / COMPLETE / BLOCKED exit signals, still does crash
detection, still runs the wind-down session at the end. Orchestra has
no `.claude/settings.json` hooks (removed in v0 cleanup), so there is
no hook-firing question to answer; commits remain the agent's
responsibility, which means the Organiser commits Executor work after
it has decided to accept it.

## Plan format

Plans remain primarily prose under `Pipeline/` (or wherever the project
keeps them). Tasks are structured by dependency and readability, not by
machine-parseable annotations. The Organiser is trusted to read the
prose and make the same model/dispatch calls a human would.

Optional inline hints are allowed where the author wants to steer the
Organiser explicitly — they read like prose, not config. Three worked
examples covering the common cases:

**Example 1 — explicit hint, Organiser follows it:**

> **Task T9c-3 — Wire FSM persistence into recovery path.**
>   This is a mechanical wiring task once T9c-1 and T9c-2 land — should
>   be safe to dispatch on Sonnet with the FSM persistence module, the
>   recovery module, and `Pipeline/FSM.md` as context. Acceptance:
>   `pnpm test src/fsm/recovery.test.ts` passes.

The Organiser extracts: model=sonnet, files=[fsm/persistence.*,
fsm/recovery.*], doc=Pipeline/FSM.md, acceptance=`pnpm test …`. Briefs
and dispatches.

**Example 2 — no hint, Organiser uses defaults:**

> **Task T9c-4 — Add a `--dry-run` flag to the recovery CLI that prints
> what recovery would do without writing.**

No model hint, no acceptance command. Organiser defaults: pick Sonnet
for "add a flag" mechanical work; brief includes the recovery CLI source
file (auto-discovered via grep); acceptance is "the new flag is wired,
existing tests still pass, and a quick smoke run shows the dry-run
output." If those defaults turn out wrong (e.g. the CLI is more
entangled than expected), the Executor returns ESCALATE.

**Example 3 — Organiser overrides an explicit hint:**

> **Task T9c-5 — Refactor the recovery state machine into a
> generator-based stream.** *(Author hint: "Sonnet should be fine here
> with the recovery module as context.")*

On reading the recovery module the Organiser sees three hidden call
sites in unrelated modules and a non-trivial concurrency invariant.
Override: dispatch on Opus instead, with a wider context bundle. Log
the override in `DECISIONS.md`:
> *"T9c-5: overrode plan hint (sonnet → opus). Recovery module has
> three external call sites and a concurrency invariant the plan didn't
> flag; Sonnet would likely have ESCALATEd."*

This logging is mandatory whenever the Organiser overrides an explicit
hint. Defaults applied silently in Example 2 do not need logging.

A formal optional metadata block (YAML fence at task end) can be added
later if we find the Organiser is missing signal — but start without
it. Prose-first keeps the plan editable and reviewable by humans.

## Executor briefing template

Briefings are dynamic — the Organiser composes each one. The shape is
fixed, but every field is filled at dispatch time:

```
# Executor briefing — <task id>

## Your job
<one-paragraph task statement, written by the Organiser>

## Context bundle
### Plan excerpt
<copied relevant section(s) of PLAN / Pipeline doc>

### Files to read
- <path 1>
- <path 2>

### Governance / protocol docs
- <path>

## Acceptance
<how the Organiser will know you're done — test command, behaviour
description, etc.>

## Return signal
End your final message with EXACTLY one of:
- DONE: <one-line summary of what you did>
- ESCALATE: <one-line reason — spec ambiguous, scope wider than briefed,
  test fails repeatedly, etc.>
- BLOCKED: <one-line reason — external dependency missing, etc.>

## Constraints
- Edit only the files listed above unless ESCALATING with reason.
- Run tests / lint as you would normally.
- Do not write to .orchestra/ — that's the Organiser's space.
```

`lib/executor-prompt-template.txt` ships this skeleton. The Organiser
fills it via straightforward string substitution at dispatch time. No
heavy templating engine; bash-or-Claude-side string interpolation.

## Storage layout additions

Phase 0 confirmed that the parent stream-json transcript at
`9-sessions/NNN.json` already captures every Agent dispatch (briefing
prompt + subagent tool-use events + return text) in full. So no
standalone briefing or result files are needed. The only new artefact
is a flat activity log, which lives under `9-sessions/` per the spec's
1–7 / 9 dichotomy:

```
.orchestra/runs/<ts>/
├── (existing 1-INBOX.md … 7-CHANGELOG.md)
└── 9-sessions/
    ├── NNN.json                  (existing parent stream-json transcript;
    │                              now also the canonical record of every
    │                              Executor dispatch inside session N)
    ├── summary.json              (existing per-session metadata array)
    └── executor-activity.log     one line per dispatch (model, task id,
                                  outcome, duration) — fast summary for
                                  the wind-down report and quick eyeballing
```

`executor-activity.log` is appended to per dispatch (one CSV-style line:
timestamp, session-num, task-id, model, outcome, duration_ms). The
wind-down session reads this to produce a per-session Executor summary
in the run report (Phase 4). Going via this dedicated log is much
cheaper than parsing every NDJSON event from `NNN.json` just to count
escalations.

The `runtime/` install path is untouched.

## Config changes

`templates/CONFIG.md` (and the parser in `lib/config.sh`) — soft
transition, not a hard rename:

- Existing `MODEL` key continues to validate. New `ORGANISER_MODEL` key
  added; if both are set, `ORGANISER_MODEL` wins. If only `MODEL` is
  set, it's accepted with a deprecation warning printed to stderr at
  config-parse time. One release later (post-Phase 5), `MODEL` is
  removed and `ORGANISER_MODEL` becomes required.
- Existing 12 test fixtures (every `tests/test_*.sh` referencing
  `MODEL`) stay valid through the transition. New tests added to cover:
  (a) `ORGANISER_MODEL` alone, (b) both set → new wins, (c) only
  `MODEL` set → deprecation warning fires.
- New `ORGANISER_CONTEXT_THRESHOLD` (default `75`, integer percent — to
  match `QUOTA_THRESHOLD`'s convention; existing `_check_int_range`
  validator handles this without a new helper). Range 50–95. The
  Organiser self-checks (no external monitoring). Tunable per run if a
  workload turns out to need a different cut-off.
- No `EXECUTOR_MODEL` config — Executor model is per-task, decided live
  by the Organiser.

`validate_config` enforces `ORGANISER_MODEL ∈ {opus, sonnet, haiku}`
and `ORGANISER_CONTEXT_THRESHOLD` in 50–95.

## Orchestra runtime changes

- `bin/orchestrator.sh`:
  - Read `ORGANISER_MODEL` (falling back to `MODEL` during the
    transition window). Pass to `claude --model`.
  - Inject the new Organiser system prompt instead of today's "execute
    the next task" framing.
  - Touch `9-sessions/executor-activity.log` at run start.
  - Crash detection, wind-down launch — unchanged.
- `lib/organiser-prompt.txt` (new): defines the inner-loop contract,
  dispatch protocol, activity-log append rule, escalation handling,
  override-logging rule, the three exit signals, the
  Organiser-doesn't-edit-while-Executor-in-flight rule, and the
  context-threshold self-check.
- `lib/executor-prompt-template.txt` (new): the briefing skeleton above.
- `lib/winddown-prompt.txt`: minor edits to (a) acknowledge that some
  CHANGELOG / DECISIONS entries originated from Executor results, and
  (b) read `9-sessions/executor-activity.log` to produce a per-session
  Executor summary (model used, tasks dispatched, escalations) in the
  run report. Substantive logic unchanged.

## Implementation phases

Sized in sessions per the global convention.

**Phase 0 — verification spike (DONE 2026-05-08).**
Confirmed via `/tmp/orchestra-phase0-spike` running `claude --print
--dangerously-skip-permissions --model opus --output-format stream-json
--verbose`:
- The subagent dispatch tool is exposed as `Agent` (not `Task`) in
  headless mode. Plan wording updated.
- Subagent tool-use events (Bash, Write, etc.) appear inline in the
  parent's NDJSON transcript with full input args. The Agent tool's own
  call captures the briefing prompt and subagent_type. So the audit
  trail is complete from `9-sessions/NNN.json` alone — no standalone
  briefing/result files needed.
- Subagent runs in the parent's working directory. Shared workspace
  works as principle 2 assumes.
- 28-second wall-clock for one trivial Sonnet-style dispatch (default
  Opus on parent and subagent). Realistic dispatches will be longer.

**Phase 1 — config & prompt scaffolding (one session).**
Add `ORGANISER_MODEL` (with `MODEL` fallback + deprecation warning) and
`ORGANISER_CONTEXT_THRESHOLD` to `lib/config.sh`. Write
`lib/organiser-prompt.txt` and `lib/executor-prompt-template.txt`.
Update `templates/CONFIG.md` to recommend `ORGANISER_MODEL`. Add the
three new config-parser tests (a/b/c above). Note in `CHANGELOG.md`-
equivalent (or a new top-level `CHANGES.md` if there isn't one) that
`MODEL` is deprecated in favour of `ORGANISER_MODEL`. `MIGRATION.md`
not touched at this stage — it's for major v→v migrations, not config
key renames.

**Phase 2 — runtime wiring + smoke fixture (one to two sessions).**
Update `bin/orchestrator.sh` to inject the Organiser prompt and touch
`9-sessions/executor-activity.log` at run start. Implement the
per-dispatch activity-log append from the Organiser prompt (one-line
CSV). Add `examples/smoke-test/with-organiser/` — a smoke fixture that
exercises one trivial Sonnet-Executor dispatch end-to-end and asserts
that (a) the activity log has one entry, (b) `9-sessions/NNN.json`
contains an `Agent` tool-use event, and (c) the work product landed.
Wire into `tests/run-tests.sh` under the slow-test guard.

**Phase 3 — escalation & verification flows (one session).**
End-to-end test of the escalation path: deliberately under-specify a
task so a Sonnet Executor returns `ESCALATE`, and confirm the Organiser
re-dispatches on Opus with a richer brief. End-to-end test of the
verification flow (Organiser runs acceptance command after Executor
DONE; on failure, dispatches a fix Executor or ESCALATEs to inline).
Rate-tracking is deferred to Phase 4 (this phase only confirms the
mechanism works).

**Phase 4 — observability (one session).**
Update `lib/winddown-prompt.txt` to read `9-sessions/executor-activity.
log` and produce a per-session Executor summary in the run report —
including ESCALATE rate, model mix, total Executor wall-clock per
session. Useful for the cost-audit-style retrospectives this plan was
born from.

**Phase 5 — real overnight run (one session, mostly observation).**
Run a real workload using the new system and compare cost / wall-clock
against the May 7 baseline. Capture findings for tuning
`ORGANISER_CONTEXT_THRESHOLD` and the Organiser prompt. Decide whether
to drop the `MODEL` deprecation now or hold it one more release.

External dependency: Phases 1–4 can land before any real workload runs.
Phase 5 needs a suitable real plan ready to execute (typically the next
logrings phase plan).

## Open risks & mitigations

- **Organiser self-monitoring may be unreliable.** Claude doesn't have a
  perfectly accurate view of its own remaining context. The threshold
  is a hint, not a hard limit. Mitigate with conservative default
  (75%) and the existing `MAX_SESSIONS` outer-loop hard wall.
- **Mis-classified Sonnet tasks waste cycles.** ESCALATE path bounds
  this — worst case is two dispatches instead of one, still cheaper
  than always-Opus. Phase 4 surfaces the rate; if it climbs above ~20%
  the Organiser is being over-optimistic and the prompt needs tuning
  toward Opus.
- **Parallel Executors are out of scope for v1.** Single-Executor-at-a-
  time keeps the workspace shared-branch story simple. Parallelism is a
  follow-on (would need worktree-per-Executor and a merge step).
- **Briefings can drift from reality.** If the Organiser packs stale
  context (e.g. a file the Executor edits, then a sibling Executor
  receives the pre-edit version), correctness suffers. v1 mitigates by
  being single-Executor-at-a-time and by principle 3's no-inline-edits-
  while-in-flight rule. Document both constraints in the Organiser
  prompt.
- **`MODEL` deprecation window may surprise users.** Soft transition is
  the chosen mitigation: existing installs keep working on `git pull`,
  with a clear stderr warning that points at the new key. Phase 5
  decides when to flip to hard-required.

## Success criteria

A real overnight run on the new system, comparable in scope to the May
7 baseline, costs meaningfully less (target: 40–60% reduction, driven
by Sonnet-on-execution) without:

- regressing the audit trail (CHANGELOG / DECISIONS / HANDOVER quality
  unchanged or better),
- regressing wall-clock substantially (one working session of Organiser
  overhead per outer-loop session is acceptable),
- introducing crash modes the existing orchestrator can't recover from.
