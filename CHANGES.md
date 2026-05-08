# Orchestra Changes

User-facing changes between releases. For per-version build artifacts
(specs, plans, transcripts) see `build-history/archive/<version>/`.

## Unreleased

### Deprecations

- `MODEL` config key is deprecated in favour of `ORGANISER_MODEL`.
  During the deprecation window, both keys are accepted; if both are
  set, `ORGANISER_MODEL` wins. A warning is printed to stderr at
  config-parse time when `MODEL` is used. The legacy key will be
  removed in a future release. To migrate, rename `MODEL` to
  `ORGANISER_MODEL` in your project's `CONFIG.md`.

### Added

- `ORGANISER_CONTEXT_THRESHOLD` config key (default `75`, integer
  percent in `[50, 95]`) — controls when the Organiser should wind
  itself down and HANDOVER. Surfaced into the Organiser system prompt
  so the agent self-checks; not externally monitored.
- `lib/organiser-prompt.txt` — Organiser inner-loop contract
  (dispatch / inline / escalate, activity-log append rule, override
  logging, exit signals).
- `lib/executor-prompt-template.txt` — briefing skeleton the Organiser
  fills at dispatch time.
- `bin/orchestrator.sh` now builds the working-session prompt by
  loading and substituting `lib/organiser-prompt.txt` (replaces the
  legacy heredoc).
- `bin/orchestra init` copies the two new prompt files into the
  project's `.orchestra/runtime/lib/` so they are available at run time.
- `bin/orchestra run` touches `9-sessions/executor-activity.log` at
  run start; the Organiser appends one CSV line per Agent dispatch.
- `examples/smoke-test/with-organiser/` — opt-in smoke fixture that
  exercises one Sonnet-Executor dispatch end-to-end. Run with
  `orchestra test with-organiser`.
- `examples/smoke-test/with-escalation/` — opt-in smoke fixture that
  exercises the **Sonnet ESCALATE → re-dispatch on Opus** retry path
  with consistent task-id across attempts. Run with
  `orchestra test with-escalation`.
- `examples/smoke-test/with-verify/` — opt-in smoke fixture that
  exercises the **verification rejection → fix-Executor** retry path.
  Both attempts return DONE; the rejection is recorded in DECISIONS.md
  rather than the activity-log outcome. Run with
  `orchestra test with-verify`.
- `lib/organiser-prompt.txt` step 2c sharpened with explicit retry
  rules: same task-id across attempts, two-attempt cap before
  Organiser takes the task inline on Opus, distinct treatment for
  ESCALATE vs DONE-but-verification-failed.
- `lib/winddown-prompt.txt` step 1.5 added: wind-down session now
  reads `9-sessions/executor-activity.log` and writes a per-session
  Executor activity summary (dispatches, model mix, outcomes,
  wall-clock, tasks-with-retries) plus an aggregate ESCALATE rate
  into `7-SUMMARY.md`'s `## Wind-down` block.

These changes accompany the organiser-executor work (see
`build-history/organiser-executor/PLAN.md`).
