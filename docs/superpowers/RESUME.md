# Orchestra Cleanup Rewrite — Resume Notes

**Branch:** `orchestra-cleanup-rewrite` in worktree `/home/james/projects/claude-orchestra-cleanup`
**Latest commit:** `002ab0e` (Phase 4 review fixes)
**Workflow:** subagent-driven development per `superpowers:subagent-driven-development`
**Spec:** `docs/superpowers/specs/2026-04-29-orchestra-cleanup-design.md`
**Plan:** `docs/superpowers/plans/2026-04-29-orchestra-cleanup-plan.md`
**Followups (apply at Phase 19):** `docs/superpowers/code-review-followups.md`

---

## Status: 4 / 19 phases complete

| Phase | Status | Commit(s) | Notes |
|---|---|---|---|
| 0 — Pre-flight | ✅ | `97445a0` | Test runner only (branch already created by setup; `inotify-tools` installed via apt) |
| 1 — CONFIG.md parser | ✅ | `086b398` | `lib/config.sh` (~200 lines), `tests/test_config_parser.sh` |
| 2 — CLI dispatcher | ✅ | `8177b6f` | `bin/orchestra` (~50 lines), `tests/test_cli_dispatch.sh` |
| 3 — orchestra init | ✅ | `ba1cb3f` | Templates: CONFIG.md, OBJECTIVE.md, orchestra-CLAUDE.md; `tests/test_init.sh` |
| 4 — Run lifecycle | ✅ | `d6133ce`, `002ab0e` | `bin/orchestrator.sh` stub, `cmd_run` lifecycle, `tests/test_run_lifecycle.sh`. Important fixes: COMPLETE signal restored, tmux `-e` env form |
| 5 — Session loop + Cat A | pending | | Replaces orchestrator.sh stub with real Claude session loop + hard-exit detection |
| 6 — Cat B/D + recovery | pending | | Silent exit + COMPLETE-with-dirty-state + recovery prompt |
| 7 — Cat C hang detection | pending | | inotify-tools-based watchdog; SIGTERM/SIGKILL escalation |
| 8 — Wind-down lock + spawn | pending | | Orchestrator-owned lock with PID + start-time stale check; simple wind-down prompt |
| 9 — Wind-down failure | pending | | Section 6.4 unified A/B/C + BLOCKED-during-wind-down → WIND-DOWN-FAILED marker |
| 10 — BLOCKED handling | pending | | Working-session BLOCKED → marker file; HANDOVER enumeration requirement |
| 11 — Smoke test driver + empty/ | pending | | First fixture with real Claude sessions; `cmd_test` |
| 12 — Wind-down ingestion + with-governance/ | pending | | Highest-risk: wind-down prompt iteration against per-source markers |
| 13 — Conflict surfacing + with-conflict/ | pending | | Section 6.3 step 4a schema; third smoke fixture |
| 14 — Quota pacing | pending | | Cherry-pick from main:bin/orchestrator.sh |
| 15 — status + reset | pending | | `cmd_status` + `cmd_reset` |
| 16 — Repo CLAUDE.md rewrite | pending | | Currently stale (lists `lib/orchestrator.sh` etc. — doesn't match new layout) |
| 17 — MIGRATION.md content | pending | | At repo root; Claude-readable interactive migration prompt |
| 18 — Deletions verify | pending | | Bulk deletions already done early as `3526bbf`; this becomes a "verify no lingering references" pass |
| 19 — Wrap-up + final review | pending | | Apply `code-review-followups.md`, full final code review, push branch |

---

## Repo state

```
.gitignore
CLAUDE.md                  # stale — Phase 16 rewrite
README.md                  # stale — Phase 16 rewrite (or keep as-is, plan doesn't list it explicitly)
bin/
  orchestra                # CLI dispatcher with init+run done; status/test/reset stubbed
  orchestrator.sh          # Phase-4 stub (echo COMPLETE)
docs/
  superpowers/
    specs/
      2026-04-29-orchestra-cleanup-design.md
    plans/
      2026-04-29-orchestra-cleanup-plan.md
    code-review-followups.md
    RESUME.md (this file)
lib/
  config.sh                # CONFIG.md parser (Phase 1)
templates/
  CONFIG.md
  OBJECTIVE.md
  orchestra-CLAUDE.md
tests/
  run-tests.sh             # runs all test_*.sh
  test_cli_dispatch.sh
  test_config_parser.sh
  test_init.sh
  test_run_lifecycle.sh
```

All 4 tests pass: `bash tests/run-tests.sh`.

---

## Cherry-pick reference

The legacy implementation lives on `main` (commit `5beb7a2` and earlier). To pull forward known-good idioms:

```bash
git show main:bin/orchestra              # tmux conflict pre-flight (line 317), launch (line 327)
git show main:bin/orchestrator.sh        # quota pacing, recovery prompt heredoc (~line 383), git worktree add (line 535)
git show main:templates/config           # bash-format old config (for migration prompt reference)
```

Spec Section 14a has the full cherry-pick index and "what NOT to cherry-pick" list.

---

## Resume instructions

In a fresh session:

1. **Read the spec and plan** (in that order):
   - `docs/superpowers/specs/2026-04-29-orchestra-cleanup-design.md`
   - `docs/superpowers/plans/2026-04-29-orchestra-cleanup-plan.md`
   - This RESUME.md

2. **Verify worktree is on the right branch and tests pass:**
   ```bash
   cd /home/james/projects/claude-orchestra-cleanup
   git branch --show-current   # should be: orchestra-cleanup-rewrite
   git log -1 --oneline         # should be: 002ab0e fix(run): address Phase 4 review...
   bash tests/run-tests.sh      # should be: 4 passed, 0 failed
   ```

3. **Invoke the workflow skill:**
   ```
   superpowers:subagent-driven-development
   ```

4. **Set the todo list** with phases 5–19 (copy from the table above).

5. **Start with Phase 5** — single-session loop + Category A hard-exit detection. Plan Phase 5 has the full implementation sketch.

---

## Outstanding decisions / context

These were resolved in conversation but aren't all explicit in the spec — capture for the resume agent:

- **`bin/orchestra`'s dispatch test** (`tests/test_cli_dispatch.sh`) was modified during Phase 3 to invoke `init` against a tmp dir (since `init` is now real and would scaffold the repo root). One of the followups recommends simplifying that branch to use `init`'s target-dir argument directly instead of subshell+/tmp/.orchestra_dispatch_out.

- **`tmux kill-server` in `tests/test_run_lifecycle.sh`** is broad — would clobber other dev tmux sessions. Followup recommends scoping to the test's TMUX_PREFIX.

- **ERR-trap test gap (Phase 4):** the existing setup-failure test triggers `mkdir -p` failure BEFORE the trap is armed, so the trap path is unverified. Followup recommends a test that fails between trap install and tmux launch (e.g. invalid `BASE_BRANCH` makes `git worktree add` fail).

- **Project-tree gate folder vs worktree run folder:** the atomic mkdir at `<project>/.orchestra/runs/<ts>/` is the uniqueness gate (left empty); actual run data lives at `<worktree>/.orchestra/runs/<ts>/`. This is "option (a)" from the Phase 4 dispatch — confirmed in Phase 4 spec review.

- **Wind-down prompt is the highest-risk piece** — Phase 12 will need 3-5 iterations against the `with-governance/` smoke fixture before it converges. Budget time accordingly.

- **MIGRATION.md content out-of-scope for spec** but Phase 17 implements it. Mapping table is in plan Phase 17 step 1.

- **Repo-root `CLAUDE.md` and `README.md`** — currently legacy/stale. User said leave until Phase 16 (full rewrite). README.md isn't explicitly in the plan; decide during Phase 16.

- **`inotify-tools`** is installed at `/usr/bin/inotifywait` — Phase 7 hang detection depends on it.

---

## Code review minor follow-ups (apply at Phase 19)

See `docs/superpowers/code-review-followups.md` — currently 13 items across Phases 1–4. All non-blocking polish (comments, test message clarity, idiom simplification). Walk the list, apply or skip each, single commit at end.

---

## Workflow expectations per phase (from `superpowers:subagent-driven-development`)

For each remaining phase:
1. Dispatch implementer subagent (`general-purpose`) with FULL task text + context (don't make subagent read plan)
2. Implementer reports DONE / DONE_WITH_CONCERNS / BLOCKED / NEEDS_CONTEXT
3. Dispatch spec compliance reviewer subagent
4. If ✅: dispatch code quality reviewer (`superpowers:code-reviewer`)
5. If either reports Critical/Important: implementer (same subagent_type) fixes; reviewer re-reviews
6. Append any Minor findings to `code-review-followups.md`
7. Mark phase complete, move to next

After Phase 19: dispatch a final whole-implementation code review subagent, then `superpowers:finishing-a-development-branch` to wrap up.
