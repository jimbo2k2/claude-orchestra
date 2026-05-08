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

These changes accompany the organiser-executor work (see
`build-history/organiser-executor/PLAN.md`). The wiring into
`bin/orchestrator.sh` lands in a subsequent change.
