# Code Review Follow-ups

Minor / non-blocking recommendations from per-phase reviews. Apply at the end of the rewrite (Phase 19) before merge.

Format: each item lists the **phase**, the **file:line** where applicable, and the **change**. Items are independent — apply or skip individually.

---

## From Phase 1 — CONFIG.md parser

- [ ] **`lib/config.sh:1` — explanatory comment for missing `set -euo pipefail`.** Project convention says scripts use `set -euo pipefail`, but `lib/config.sh` is sourced (not executed) and setting those flags would leak into the caller. Add a one-line comment near the top: `# This file is sourced; intentionally does not set 'set -euo pipefail' (would leak into caller's shell).`

- [ ] **`tests/test_config_parser.sh` — replace `unset ORCHESTRA_CONFIG; declare -gA ORCHESTRA_CONFIG` pattern.** Fragile (the unset+redeclare pattern can leave variables in odd states inside functions). At top level it works, but cleaner: `ORCHESTRA_CONFIG=()` between scenarios, OR factor each scenario into a function with `local -A ORCHESTRA_CONFIG=()`.

- [ ] **`tests/test_config_parser.sh` — informative failure messages.** Replace bare `echo "MAX_SESSIONS"; exit 1` with `echo "MAX_SESSIONS expected 5 got '${ORCHESTRA_CONFIG[MAX_SESSIONS]:-<unset>}'"; exit 1`. Saves debugging time later.

- [ ] **`tests/test_config_parser.sh:8` — trap quoting nit.** `trap "rm -rf $TMP" EXIT` expands `$TMP` at trap-set time. Robust idiom: `trap 'rm -rf "$TMP"' EXIT`.

- [ ] **Integration test for validation helpers.** Current unit test only exercises 3 of 7 validation helper paths (missing-required, invalid-enum, duplicate-key). The other helpers (`_check_int_range`, `_check_pattern`, `_check_bool`, `_check_abspath`) are exercised indirectly by spec compliance. When the parser is first wired into `orchestrator.sh`, add a test that loads a representative full CONFIG.md fixture covering every constraint type.

- [ ] **`lib/config.sh:38` — WHY-comment for trim idiom.** The expression `value="${value%"${value##*[![:space:]]}"}"` is correct but cryptic. Add: `# strip trailing whitespace; leading is consumed by the [[:space:]]* in the regex`.

- [ ] **`lib/config.sh:apply_config_defaults` — idempotency comment.** Add a sentence to the function's doc comment noting it's idempotent and side-effect-free on missing keys.

---

## From Phase 2 — CLI dispatcher skeleton

- [ ] **`bin/orchestra:14` — `LIB_DIR` is currently dead code.** Defined but unused at this stage. Two options: (a) drop it now; Phase 3 reintroduces it when first `source "$LIB_DIR/..."` lands. (b) accept it as forward-declared intent and leave. Conscious choice either way.

- [ ] **`bin/orchestra:40` — clearer shift guard.** Replace `shift 2>/dev/null || true` with `[[ $# -gt 0 ]] && shift`. Self-documenting intent.

- [ ] **`tests/test_cli_dispatch.sh:24-27` — no-op `if/then` cleanup.** The current loop:
  ```bash
  if out=$(./bin/orchestra "$cmd" 2>&1); then
      :
  fi
  ```
  Cleaner equivalent: `out=$(./bin/orchestra "$cmd" 2>&1) || true`.

- [ ] **`tests/test_cli_dispatch.sh` (optional) — assert phase tag in stub errors.** Add per-stub: `./bin/orchestra init 2>&1 | grep -q "Phase 3" || { echo "init missing phase ref"; exit 1; }`. Locks in stub traceability if it's considered part of the contract.

- [ ] **`bin/orchestra` usage (optional) — first-time hint.** Add a one-liner after the commands list: `First time? Run 'orchestra init' to scaffold .orchestra/ in your project.` Skip if you'd rather keep usage terse.

---

## From Phase 3 — orchestra init

- [ ] **`bin/orchestra` `for pair in ...` loop — explanatory comment.** The encoding `"<src>:<dst>"` is non-obvious. Add comment above the loop:
  ```
  # Each entry: "<template-filename>:<dest-filename>". Most are identity;
  # orchestra-CLAUDE.md is renamed to CLAUDE.md so the source template
  # filename doesn't collide with the project's own CLAUDE.md template.
  ```

- [ ] **`tests/test_cli_dispatch.sh` init branch — simpler form.** Current implementation rounds `out` through a fixed `/tmp/.orchestra_dispatch_out` filename in a subshell, which is mildly racy if two test runs ever overlap. Cleaner:
  ```bash
  if [ "$cmd" = "init" ]; then
      TMP_DISPATCH=$(mktemp -d)
      ( cd "$TMP_DISPATCH" && git init -q )
      out=$("$REPO/bin/orchestra" init "$TMP_DISPATCH" 2>&1) || true
      rm -rf "$TMP_DISPATCH"
  else
      out=$(./bin/orchestra "$cmd" 2>&1) || true
  fi
  ```
  Uses `init`'s target-dir argument instead of `cd`+capture-via-tempfile. No fixed-name race risk.

- [ ] **`templates/CONFIG.md:24` — `WORKTREE_BASE` placeholder hint.** Currently `/tmp/orchestra-myproject`. Optional: add inline comment or rename placeholder to `/tmp/orchestra-PROJECT_NAME` (uppercase shouts "replace me"). The next-steps echo already prompts to edit, so this is polish only.

- [ ] **`templates/orchestra-CLAUDE.md` size review.** 55 lines is on the edge of bloat. Trim consideration: "Migration from old orchestra" section could be one line pointing at the source repo's MIGRATION.md. Current content is defensible (high info density, no fluff) — leave as-is unless a future review feels it's too long.

---

## From Phase 4 — Run lifecycle scaffold

- [ ] **`tests/test_run_lifecycle.sh` — add a test that actually exercises the ERR-trap cleanup.** Current "setup-failure" test uses `WORKTREE_BASE=/proc/orchestra-cant-write` which fails at `mkdir -p` *before* the gate mkdir or trap install — so the assertion "no orphan run folder" is trivially true regardless of trap correctness. To verify the trap path itself, force a failure between trap install (`bin/orchestra:120`) and trap clear (`bin/orchestra:147`). The cleanest trigger: invalid `BASE_BRANCH` (e.g. `nonexistent-branch`), which makes `git worktree add` fail. Assertion: both project-tree `$orch/runs/<ts>/` is removed AND any partial worktree at `<WORKTREE_BASE>/run-<ts>/` is cleaned up.

- [ ] **`tests/test_run_lifecycle.sh` — `tmux kill-server` in cleanup is too broad.** Would clobber any other tmux sessions on a dev machine. Replace with targeted kill: `tmux ls 2>/dev/null | grep "^orch-test-" | cut -d: -f1 | xargs -I{} tmux kill-session -t {} 2>/dev/null || true`. Or scope by `TMUX_PREFIX` value used in the test fixture.

---

## From Phase 5 — Single-session loop with Category A crash detection

- [ ] **`bin/orchestrator.sh` — config keys read without `validate_config`.** The script re-parses CONFIG.md but does not call `validate_config`. Under `set -u`, a missing required key becomes an "unbound variable" abort with no useful message. Either call `validate_config` here or wrap each required-key read with `${VAR:?missing}`.

- [ ] **`bin/orchestrator.sh` — terminal-exit branches sleep before exit.** COMPLETE and BLOCKED branches `sleep "$COOLDOWN"` *before* `exit` — the cooldown is between-sessions; on terminal exit it's wasted. Move the sleep to fire only when looping back (HANDOVER path).

- [x] **`bin/orchestrator.sh` — `--thinking-effort` flag unverified against real CLI.** ~~Both tests stub `claude`, so the flag surface is unverified.~~ **Resolved in Phase 11:** real flag is `--effort` (not `--thinking-effort`); fixed in `bin/orchestrator.sh` as part of the Phase 11 commit after the smoke test surfaced "error: unknown option '--thinking-effort'".

- [ ] **`bin/orchestrator.sh:88` — pipefail + pipeline makes `$code` non-deterministic.** With `pipefail`, when fake claude crashes the captured `$code` could be 141 (SIGPIPE on `echo`) instead of 1 (claude's real exit). Use a here-string `claude ... <<<"$prompt"` or capture with `out=$(claude ...) || code=$?` so the exit code is unambiguously claude's.

- [ ] **`tests/test_session_loop_hard_exit.sh` — fake claude doesn't drain stdin.** Triggers the SIGPIPE race above. Adding `cat >/dev/null` before `exit 1` (matching `test_session_loop_complete.sh`) would make it deterministic.

- [ ] **`tests/test_session_loop_hard_exit.sh` and `tests/test_session_loop_complete.sh` — trap quoting nit.** `trap "rm -rf $TMP; tmux kill-server 2>/dev/null || true" EXIT` expands `$TMP` at trap-set time. Idiomatic form is single-quoted body: `trap 'rm -rf "$TMP"; tmux kill-server 2>/dev/null || true' EXIT`. Same nit as Phase-1 followup; the broad `tmux kill-server` concern (existing Phase-4 followup) applies to these new files too.

- [ ] **Tests — unused `i` in busy-wait loops.** `for i in $(seq 1 30); do ...` never references `i`. `for _ in $(seq 1 30); do ...` reads more honestly. Applies to both new session-loop tests.

- [ ] **Tests — `ls -d ...*/ | head -1` is non-deterministic with multiple matches.** If two run folders ever exist (e.g. parallel test runs sharing a TMP), `head -1` picks an arbitrary one. Pin to the latest with `ls -1tr | tail -1`, or assert exactly one match exists before picking.

---

## From Phase 6 — Category B/D detection + recovery prompt

- [ ] **`bin/orchestrator.sh:129` — `cd "$WORKTREE_DIR"` inside the COMPLETE branch persists for the rest of the script.** Idempotent today (tmux already starts the orchestrator with cwd=`$WORKTREE_DIR`), but a future refactor that changes the entry cwd could silently break invariants. Prefer subshell scoping: `if [ -n "$(cd "$WORKTREE_DIR" && git status --porcelain)" ]; then`.

- [ ] **`tests/test_categories_bd.sh:40` — wait-loop pattern inconsistent with rest of suite.** Uses server-wide substring match `tmux ls 2>/dev/null | grep -q orch-bd` while other tests use the more precise `tmux has-session -t "<prefix>-$RUN_TS"`. Functional today but invites copy-paste mistakes. Align with the established pattern.

- [ ] **`bin/orchestrator.sh:88-104` — extract `build_recovery_preamble()` helper.** Once Phase 7 (Cat C) and Phase 9 (wind-down) land, the inline preamble construction will grow. A helper alongside `build_session_prompt()` would mirror the symmetry.

- [ ] **`bin/orchestrator.sh:90` — A|B|C share one recovery note.** When Phase 7 introduces hang detection (Cat C), a hung session likely needs different guidance ("the previous session hung — check whether the long-running operation completed"). Pre-staging a single arm is fine for Phase 6, but split when Phase 7 lands.

- [ ] **`bin/orchestrator.sh:156` — Cat D message says "deferring to wind-down (Phase 9)".** Will become misleading once Phase 9 wind-down lands. Update when Phase 9 ships.

---

## From Phase 7 — Category C hang detection with inotifywait

- [ ] **`bin/orchestrator.sh` — `stat -c %s ... || echo 0` masks file-deletion failures.** If either log is deleted mid-run the size collapses to 0 and stays equal across polls, manifesting as a false-positive Cat C hang. Distinguish "file gone" from "file unchanged" rather than swallowing the error.

- [ ] **`bin/orchestrator.sh` — backgrounded pipeline `echo "$prompt" | claude ... &` captures `$!` as claude's pid; the `echo` half is unwaited.** Theoretical leak only (echo exits immediately) but worth tightening (e.g. process-substitution or a heredoc redirected directly into claude).

- [ ] **`bin/orchestrator.sh` — no cleanup trap covers external interruption of the watchdog.** If the orchestrator itself is killed, `inotifywait` and `claude` become orphans and `inotify_log` leaks in `/tmp`. Track alongside Phase 8 wind-down lock work.

- [ ] **`tests/test_hang_detection.sh:6` — `tmux kill-server` in trap is too broad.** Same nit as Phase 4 followup. Prefer `tmux kill-session -t "orch-c-$RUN_TS" 2>/dev/null || true` or kill by `TMUX_PREFIX` glob.

- [ ] **`tests/test_hang_detection.sh:41-48` — small startup race in the wait-loop.** If dispatch hasn't created the tmux session yet, the for-loop's first iteration could `break` prematurely. Add an initial sleep, or only `break` after `has-session` has previously succeeded once.

- [ ] **`bin/orchestrator.sh` — 5s `poll_interval` magic number could be promoted to a named local or config knob in a later phase.** Not actionable now.

- [ ] **`bin/orchestrator.sh` — 5s inotifywait startup-deadline magic number.** Same family as the `poll_interval` followup; the `startup_deadline=$(($(date +%s) + 5))` literal could be promoted alongside the poll interval to named locals or a config knob.

- [ ] **`bin/orchestrator.sh` — redundant post-loop `grep -q "Watches established"` after the startup-poll loop.** If the loop exited via `break`, the grep already matched; if via deadline expiry, the grep will fail anyway. Tightening to an explicit flag (`local established=0; ... established=1; break`) removes one re-read of the file. Cosmetic.

- [ ] **`tests/test_stderr_preservation.sh` — `tmux kill-server` trap is too broad.** Same nit as Phase 4/7 followups; kill-session by `<TMUX_PREFIX>-$RUN_TS` to avoid clobbering other tmux sessions on the dev machine. Likely contributor to the parallel-run flakiness observed during Phase 7 fix-up review.

---

## From Phase 8 — Wind-down lock + simple wind-down spawn

- [ ] **`bin/orchestrator.sh:316-321` — SIGINT/SIGTERM window between `acquire_winddown_lock` return and `trap` install.** Spec Section 6.1 line 101 says "immediately after acquiring the lock". The window is microseconds but non-zero — a signal arriving in that gap orphans the lock. Mitigation: install a placeholder `trap '...' INT TERM` before calling acquire, then add EXIT after.

- [ ] **`bin/orchestrator.sh:325-327` — `sed` template substitution corrupts on `|`/`&`/`\` in path.** `RUN_DIR` includes user-config `WORKTREE_BASE`, which `validate_config` only checks for absoluteness — not metacharacter-free. Theoretical, but cheap to harden via awk-based substitution or escape interpolation.

- [ ] **`bin/orchestrator.sh:342` — `WIND-DOWN-FAILED` marker is empty.** Spec Section 6.4 step 3 specifies contents: timestamp, failure category (A/B/C/BLOCKED), last 50 lines of session output. Phase 9 will populate; track explicitly so it doesn't ship the failure-detection logic without populating the marker.

- [ ] **`bin/orchestrator.sh:56-67` — stale-lock recovery `rm; continue` busy-loops with no rate limit.** If the lock file is being touched by an external thing in tight loop, `acquire_winddown_lock` pins a CPU. Add a short `sleep 1` before `continue` on stale-lock branches, or a max-stale-evict counter.

- [ ] **`bin/orchestrator.sh:53-54` — PID + start-time read is non-atomic against partial writers.** Two separate `sed -n '1p'` / `sed -n '2p'` reads. With `printf` of ~30 bytes essentially atomic on Linux, the practical risk is ~zero, but `mapfile -t lines < "$WINDDOWN_LOCK"` gets it in one read and is clearer.

- [ ] **`tests/test_winddown_lock.sh:64-72` — wait-loop break condition is subtle.** The `tmux has-session ... || break` exits the loop the first iteration WORKTREE is non-empty AND tmux is gone. Add a one-line comment explaining the intent.

- [ ] **`bin/orchestrator.sh:324-327` — wind-down template-load failure surfaces as "command failed".** A `[ -f "$WORKTREE_DIR/.orchestra/runtime/lib/winddown-prompt.txt" ] || die "wind-down prompt template missing"` preflight gives a cleaner error.

- [ ] **`bin/orchestrator.sh:329-340` — wind-down session has no watchdog.** Spec Section 6.4 lists Cat C during wind-down as a failure mode. Currently a hung wind-down session blocks the orchestrator forever. Phase 9 will reuse `run_session_with_watchdog` for the wind-down call site so hang detection covers both.

---

## From Phase 9 — Wind-down failure handling

- [ ] **`bin/orchestrator.sh:90` — `echo "$out" | tail -50` safe under bash.** Reviewer flagged this for a check; under bash with `set -o pipefail`, a SIGPIPE on `echo` could in theory propagate. In practice `tail -50` reads its input fully (no early close) so `echo` never receives SIGPIPE; the pipeline is safe as-written. Recorded so it isn't re-flagged.

- [ ] **`tests/test_winddown_failure.sh` — A/B/C paths are not exercised end-to-end.** The current test covers BLOCKED routing only; A (non-zero exit, non-124), B (clean exit but missing signal), and C (124 watchdog timeout) are exercised indirectly via the working-session path tests but not asserted at the wind-down call site. Reasonable tradeoff for now; revisit when Phase 11's smoke-test driver lands and can drive synthetic wind-down failures.

---

## From Phase 11 — Smoke-test driver + empty/ fixture

- [ ] **`bin/orchestra` `cmd_test` — bare-remote `git init` doesn't pin `--initial-branch=master`.** The bare remote inherits the user's git default-branch config (often `main`); the working repo uses `--initial-branch=master`. Push of `master` succeeds (creates the branch on the remote) but the bare remote's symbolic HEAD ends up pointing at a non-existent `main`. Cosmetic — `git log` (no `--all`) on the bare remote shows "your current branch 'main' does not have any commits yet" until something targets `main`. Pin `--initial-branch=master` on the bare init too.

- [ ] **`bin/orchestra` `cmd_test` wait loop — `tmux has-session` polled every 10s.** Working-session + wind-down completed in ~56s on the first smoke run. A 10s poll is fine here, but if a future test variant has multi-second sub-actions a tighter (e.g. 2s) interval would catch state transitions sooner. Current value not problematic; flagging for awareness.

- [ ] **`bin/orchestra` `cmd_test` — wait-loop only breaks on tmux session ending; no orchestrator-exit-code check.** If the orchestrator exits non-zero (e.g. infrastructure failure 3, BLOCKED 0, MAX_CRASHES 1), the smoke driver still proceeds to the assertion phase and fails there with a generic "no archived run found". A more diagnostic flow would peek at the most recent session JSON's `exit_signal`/`crash_category` before the assertion phase to give a clearer failure message. Quality-of-life only.

---

## How to apply

At Phase 19 (branch wrap-up):
1. Walk this list checkbox-by-checkbox
2. Apply or skip each (mark with strikethrough or check)
3. Commit any that were applied as a single `chore: address minor code-review followups` commit
4. Delete this file from the branch (or leave for posterity — your call)
