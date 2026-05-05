# Orchestra Roadmap

Backlog of non-blocking improvements identified during the cleanup
rewrite (per-phase code reviews). Items here are correctness-adjacent
polish, defensive hardening, or convenience features — none gate the
core run/wind-down lifecycle.

Categorised by area for quick scanning. Original per-phase context (when
the item was first flagged) lives in git history; see commits prior to
and including the Phase 19 quick-win followups commit, where each item
was filed against the phase that surfaced it. The superseded file
`build-history/archive/v0-cleanup/code-review-followups.md` (deleted in
that commit) had the full per-phase narrative.

## Hardening (defensive — no current bug, would prevent edge cases)

- `bin/orchestrator.sh` startup re-parses CONFIG.md but does not call
  `validate_config`. Under `set -u` a missing required key becomes an
  unbound-variable abort with no useful message. Either invoke
  `validate_config` here or wrap each required-key read with
  `${VAR:?missing}`.
- `bin/orchestrator.sh` template substitution for the wind-down prompt
  uses `sed` with `RUN_DIR` etc. as the replacement; a `|`/`&`/`\` in
  `WORKTREE_BASE` (which `validate_config` only checks for absoluteness)
  would corrupt the substitution. Harden via awk-based substitution or
  metachar-escape the interpolated values.
- `bin/orchestrator.sh:90` (`echo "$out" | tail -50`) — pipefail-safe
  under bash today (`tail -50` reads input fully, so `echo` never
  receives SIGPIPE), but recorded so it isn't re-flagged in future
  reviews.
- `bin/orchestrator.sh` Cat-C hang detection: `stat -c %s ... || echo 0`
  masks file-deletion failures. If either log is deleted mid-run the
  size collapses to 0 and stays equal across polls, manifesting as a
  false-positive Cat C. Distinguish "file gone" from "file unchanged".
- `bin/orchestrator.sh` backgrounded `echo "$prompt" | claude ... &`
  captures `$!` as claude's pid; the `echo` half is unwaited.
  Theoretical leak only. Tighten via process-substitution or a heredoc
  redirected directly into claude.
- `bin/orchestrator.sh` has no cleanup trap covering external
  interruption of the watchdog. If the orchestrator itself is killed,
  `inotifywait` and `claude` become orphans and `inotify_log` leaks in
  `/tmp`.
- `acquire_winddown_lock`: SIGINT/SIGTERM window between lock-acquire
  return and `trap` install. Microseconds-wide but non-zero; a signal in
  that gap orphans the lock. Mitigation: install a placeholder
  `trap '...' INT TERM` before calling acquire, then add EXIT after.
- `acquire_winddown_lock` stale-lock recovery `rm; continue` busy-loops
  with no rate limit. Add `sleep 1` before `continue` on stale-lock
  branches, or a max-stale-evict counter.
- `acquire_winddown_lock` PID + start-time read uses two separate
  `sed -n '1p'` / `sed -n '2p'` reads — non-atomic against partial
  writers. Practical risk near zero on Linux for ~30-byte writes;
  `mapfile -t lines < "$WINDDOWN_LOCK"` reads in one syscall and is
  clearer.
- `bin/orchestrator.sh` wind-down template-load failure surfaces as a
  generic "command failed". A preflight check
  (`[ -f "$WORKTREE_DIR/.orchestra/runtime/lib/winddown-prompt.txt" ] \
   || die "wind-down prompt template missing"`) gives a cleaner error.

## Diagnostics & UX

- `bin/orchestra` `cmd_test` wait loop only breaks on tmux session
  ending — no orchestrator-exit-code check. If the orchestrator exits
  non-zero (infrastructure failure 3, BLOCKED 0, MAX_CRASHES 1), the
  smoke driver still proceeds to assertions and fails with a generic
  "no archived run found". Peek at the most recent session JSON's
  `exit_signal`/`crash_category` before assertions to give a clearer
  failure message.
- `bin/orchestra` usage could carry a one-line first-time hint
  (`First time? Run 'orchestra init' to scaffold .orchestra/ in your
  project.`). Skipped during Phase 19 to keep usage terse — revisit if
  feedback arrives.
- `templates/CONFIG.md` `WORKTREE_BASE` placeholder is
  `/tmp/orchestra-myproject`. Rename to `/tmp/orchestra-PROJECT_NAME`
  (or add an inline comment) so the "replace me" intent shouts.

## Refactor / structure

- Extract `build_recovery_preamble()` helper alongside
  `build_session_prompt()` in `bin/orchestrator.sh`. The inline preamble
  construction has grown across phases; a helper would mirror the
  symmetry and centralise per-category language.
- Cat A/B/C currently share one recovery note. Cat C (hang) likely
  wants different guidance ("the previous session hung — check whether
  the long-running operation completed"). Split when the helper above
  lands.
- 5s `poll_interval` and 5s `inotifywait` startup-deadline magic numbers
  in `bin/orchestrator.sh` could be promoted to named locals or a
  config knob (alongside MAX_HANG_SECONDS). Cosmetic.
- Redundant post-loop `grep -q "Watches established"` after the
  startup-poll loop in Cat-C detection — the loop's own break already
  matched. Tightening to an explicit flag (`local established=0; ...
  established=1; break`) removes one re-read of the file. Cosmetic.
- `tests/test_config_parser.sh` `unset ORCHESTRA_CONFIG; declare -gA
  ORCHESTRA_CONFIG` pattern is fragile (the unset+redeclare combo can
  leave variables in odd states inside functions). At top level it
  works, but cleaner: `ORCHESTRA_CONFIG=()` between scenarios, or
  factor each scenario into a function with `local -A
  ORCHESTRA_CONFIG=()`.

## Test coverage

- `tests/test_run_lifecycle.sh` setup-failure test uses
  `WORKTREE_BASE=/proc/orchestra-cant-write` which fails at `mkdir -p`
  *before* the gate mkdir or trap install — the assertion "no orphan
  run folder" is trivially true regardless of trap correctness. To
  verify the trap path itself, force a failure between trap install
  and trap clear (cleanest: invalid `BASE_BRANCH` makes `git worktree
  add` fail). Assert both project-tree and worktree run dirs are gone.
- `tests/test_winddown_failure.sh` only covers the BLOCKED routing
  path. Cat A (non-zero exit, non-124), Cat B (clean exit but missing
  signal), and Cat C (124 watchdog timeout) at the wind-down call site
  are exercised indirectly via the working-session path tests but not
  asserted at the wind-down site. Revisit when `orchestra test` can
  drive synthetic wind-down failures.
- `tests/test_*.sh` `ls -d ...*/ | head -1` is non-deterministic with
  multiple matches. If two run folders ever coexist (parallel test
  runs sharing a TMP) `head -1` picks an arbitrary one. Pin to the
  latest with `ls -1tr | tail -1`, or assert exactly one match exists
  before picking.
- `tests/test_hang_detection.sh:41-48` has a small startup race in the
  wait-loop: if dispatch hasn't created the tmux session yet, the
  for-loop's first iteration could `break` prematurely. Add an initial
  sleep, or only `break` after `has-session` previously succeeded.
- **Add `with-parcel` smoke fixture for parcel-mode wind-down ingestion.**
  The 2026-05-05 wind-down prompt rewrite added a parcel-mode path
  (Step 1a detects `Governance/CLAUDE.md` + `Governance/pending/`) that
  is currently exercised only by the `with-governance` legacy fixture's
  fallback-mode assertions. Author a third fixture `examples/smoke-test/with-parcel/`
  containing a minimal `Governance/CLAUDE.md` (parcel format + ingestion
  algorithm — can be a short version of the logrings-main file) plus
  `Governance/pending/.gitkeep`, and an `OBJECTIVE.md` that instructs
  the working session to make a tiny task/decision/changelog/bug change
  whose governance trail naturally produces parcel content. Add a
  matching `smoke_assert_with_parcel()` in `bin/orchestra` that asserts:
  (a) at least one `Governance/pending/<hex>.md` file exists post-merge,
  (b) the `wind-down: convert run governance to parcels` commit landed,
  (c) `7-SUMMARY.md` contains a `### Parcel conversion` block, and
  (d) the parent project's TODO/DECISIONS/CHANGELOG/bug-log were NOT
  edited (the parcel-mode wind-down's responsibility ends at parcel
  creation; ingestion is the parent project's W4 responsibility).
  Wire into `cmd_test` alongside `empty`/`with-governance`/`with-conflict`.
  Closes the parcel-mode end-to-end gap surfaced by the logrings-main
  parcel-mechanism plan (`Pipeline/executed/process/2026-04-28-todo-cleanup/plan.md`
  Phase 9 Task 25).

## Documentation polish

- `templates/orchestra-CLAUDE.md` is 55 lines (edge of bloat). The
  "Migration from old orchestra" section could collapse to a one-line
  pointer at `MIGRATION.md`. Defensible as-is — leave unless a future
  review finds it noisy.
