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

- [ ] **`bin/orchestrator.sh` — `--thinking-effort` flag unverified against real CLI.** Both tests stub `claude`, so the flag surface is unverified. Worth a one-line confirmation against the real `claude --print` CLI before Phase 11's smoke test.

- [ ] **`bin/orchestrator.sh:88` — pipefail + pipeline makes `$code` non-deterministic.** With `pipefail`, when fake claude crashes the captured `$code` could be 141 (SIGPIPE on `echo`) instead of 1 (claude's real exit). Use a here-string `claude ... <<<"$prompt"` or capture with `out=$(claude ...) || code=$?` so the exit code is unambiguously claude's.

- [ ] **`tests/test_session_loop_hard_exit.sh` — fake claude doesn't drain stdin.** Triggers the SIGPIPE race above. Adding `cat >/dev/null` before `exit 1` (matching `test_session_loop_complete.sh`) would make it deterministic.

- [ ] **`tests/test_session_loop_hard_exit.sh` and `tests/test_session_loop_complete.sh` — trap quoting nit.** `trap "rm -rf $TMP; tmux kill-server 2>/dev/null || true" EXIT` expands `$TMP` at trap-set time. Idiomatic form is single-quoted body: `trap 'rm -rf "$TMP"; tmux kill-server 2>/dev/null || true' EXIT`. Same nit as Phase-1 followup; the broad `tmux kill-server` concern (existing Phase-4 followup) applies to these new files too.

- [ ] **Tests — unused `i` in busy-wait loops.** `for i in $(seq 1 30); do ...` never references `i`. `for _ in $(seq 1 30); do ...` reads more honestly. Applies to both new session-loop tests.

- [ ] **Tests — `ls -d ...*/ | head -1` is non-deterministic with multiple matches.** If two run folders ever exist (e.g. parallel test runs sharing a TMP), `head -1` picks an arbitrary one. Pin to the latest with `ls -1tr | tail -1`, or assert exactly one match exists before picking.

---

## How to apply

At Phase 19 (branch wrap-up):
1. Walk this list checkbox-by-checkbox
2. Apply or skip each (mark with strikethrough or check)
3. Commit any that were applied as a single `chore: address minor code-review followups` commit
4. Delete this file from the branch (or leave for posterity — your call)
