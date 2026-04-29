# Orchestra Cleanup & Re-architecture Design

**Date:** 2026-04-29
**Status:** Draft (awaiting user review)
**Scope:** Repo cleanup + architectural simplification + smoke test rebuild

---

## 1. Goals

1. Strip orchestra of opinions it shouldn't hold (governance file paths, protocol enforcement, toolchain documentation) — those belong to the parent project's CLAUDE.md hierarchy.
2. Make orchestra's own internal per-run governance prescriptive and consistent.
3. Clean up bloat: stale examples, duplicated test scaffolds, redundant templates.
4. Rebuild the smoke test as a self-contained, end-to-end exercise against a dummy project fixture.
5. Support overlapping (sequential-but-concurrent) runs without changes to the user UX.

## 2. Vocabulary

- **Run** — one `orchestra run` invocation. Owns one git worktree, one run-branch (`orchestra/run-<timestamp>`), one tmux session, one folder under `.orchestra/runs/`.
- **Session** — a single Claude chat (one process / one 1M-context window) within a run. A run typically contains multiple sessions chained by HANDOVER.
- **Subtask** — discrete work unit within a session, tracked in the run's `3-TODO.md`.
- **Wind-down** — the final session of a run that ingests run governance into parent project documentation and merges to main.

## 3. Conceptual Model

**Orchestra is** a session orchestration runtime. Its responsibilities:
1. Set up a worktree + run-branch for an objective
2. Spawn child Claude sessions until the objective is met (or limits hit)
3. Maintain canonical per-run internal governance (TODO / DECISIONS / CHANGELOG / SUMMARY / HANDOVER)
4. Drive a wind-down session that intelligently ingests run governance into parent project docs and merges to main

**Orchestra is not** a protocol enforcer, governance template provider, or toolchain documenter. The parent project's `CLAUDE.md` hierarchy controls Claude's in-session behaviour, build/test commands, and any project-specific protocol. Orchestra trusts it.

### Consequences for config

**Dropped:** `TODO_FILE`, `DECISIONS_FILE`, `CHANGELOG_FILE`, `DEVELOPMENT_PROTOCOL`, `TOOLCHAIN_FILE`, all governance-path config vars.

**Kept:** session limits, model/effort, worktree base, base branch, tmux prefix, quota pacing, cooldowns.

## 4. Run Input

The user prepares `.orchestra/OBJECTIVE.md` interactively with Claude before invocation. Free-form markdown — typically a short brief that points at one or more spec/plan files. Orchestra treats it as opaque text and feeds it into the first session prompt. No schema.

**Snapshot mechanism — git does it.** `OBJECTIVE.md` is tracked in the project repo. When `orchestra run` creates the worktree from `BASE_BRANCH`, git checkout produces `<worktree>/.orchestra/OBJECTIVE.md` containing exactly what was committed to that branch — a natural point-in-time snapshot. No cross-tree copy needed.

Inside the worktree, the orchestrator copies `<worktree>/.orchestra/OBJECTIVE.md` → `<worktree>/.orchestra/runs/<run>/2-OBJECTIVE.md` so the run folder is self-contained (the objective travels with the archived run for later review).

**Preflight check:** if `<worktree>/.orchestra/OBJECTIVE.md` doesn't exist after worktree creation (user forgot to commit), orchestrator errors out with: "OBJECTIVE.md not found in worktree — commit it to `<BASE_BRANCH>` and retry."

User must commit `OBJECTIVE.md` to `BASE_BRANCH` before `orchestra run` to have it picked up. Same applies to `CONFIG.md` — its committed state is what the run uses; uncommitted edits don't take effect. This is desirable: runs are deterministic against branch state.

User workflow is **sequential firing** — one objective file at a time, prepared between runs. Multiple runs may overlap in execution but they are not queued or fired simultaneously.

## 5. Per-Run Internal Governance

The run folder lives **inside the worktree**, at `<worktree>/.orchestra/runs/<run-timestamp>/`. It's tracked on the run-branch and committed alongside source-code changes. The user edits files in this folder via the worktree path (e.g. `1-INBOX.md` for mid-run redirections); the project's main tree never sees these files until wind-down merges to the base branch.

The numbering gap (skipping `8-`) is intentional: a visual separator between user/agent-facing markdown files (1–7) and the machine-output `9-sessions/` directory.

```
<worktree>/.orchestra/runs/<run-timestamp>/
├── 1-INBOX.md         # live human → run channel for mid-run redirection
├── 2-OBJECTIVE.md     # snapshot of OBJECTIVE.md at run start (read-only thereafter)
├── 3-TODO.md          # rolling subtask list — agent owns
├── 4-DECISIONS.md     # rolling exec decisions taken to keep running headless
├── 5-CHANGELOG.md     # rolling changes within this run
├── 6-HANDOVER.md      # next-session briefing (regenerated each session exit)
├── 7-SUMMARY.md       # rolling per-session narrative summaries (one block per session)
└── 9-sessions/        # machine session logs
    ├── 001.json
    └── 002.json
```

### File semantics

- **1-INBOX.md** — user edits at the worktree path during a run to inject redirections. Each session reads it on cold-start and at the gap between subtasks.
- **2-OBJECTIVE.md** — written once at run start; read-only thereafter.
- **3-TODO.md** — agent maintains rolling subtask list across sessions of this run. Subtasks added as discovered; statuses updated.
- **4-DECISIONS.md** — agent records executive decisions made to keep running headless (when otherwise it would have asked a human).
- **5-CHANGELOG.md** — agent records what changed at the file/feature level. Source material for wind-down ingestion into parent CHANGELOG.
- **6-HANDOVER.md** — written by each session before exiting. Triggered when: context >80% used, large unrelated next subtask warrants fresh context, or session has completed 3+ subtasks. Replaced (not appended) each session.
- **7-SUMMARY.md** — append-only narrative; each session adds a block summarising what it accomplished. Preserved verbatim in the archived run folder after wind-down; not ingested into parent governance.
- **9-sessions/NNN.json** — orchestrator-written machine logs (rate limit events, session metadata, exit codes).

### Why split decisions/changelog/summary?

The wind-down agent maps each rolling file to whatever shape the parent project uses (TODO ← 3-TODO, DECISIONS ← 4-DECISIONS, CHANGELOG ← 5-CHANGELOG). Splitting at the source makes that mapping clean. SUMMARY is for humans reviewing run history, not for ingestion.

## 6. Wind-Down

When the agent emits `COMPLETE`, the orchestrator spawns **one additional Claude session** (separate from the working sessions, exempt from `MAX_SESSIONS`) whose purpose is **ingesting run governance into the parent project**. Wind-down does **not** fire on `HANDOVER` (more work remains) or `BLOCKED` (Section 11 "Exit signals" — run is parked for human resolution).

### 6.1 Lock acquisition (orchestrator-owned)

The orchestrator — not the agent — owns the lock's *creation and release*. The agent is the one running inside the locked critical section but doesn't touch the lock file directly. Wrapping the wind-down spawn:

1. Acquire `.orchestra/runs/.wind-down.lock`:
   - Atomic create via `set -C; printf '%d\n%s\n' $$ "$(awk '{print $22}' /proc/$$/stat)" > .wind-down.lock`. PID on line 1, **process start-time in clock ticks since boot** on line 2 (matching `/proc/<pid>/stat` field 22 units). Use `$$` (the parent shell's PID), not `self` — `$(awk ... /proc/self/stat)` resolves to awk's own PID in a command substitution, so `self` would record awk's start-time and break stale-lock detection on contention.
   - On `EEXIST`: read existing lock; if PID is alive (`kill -0 <pid>`), poll with exponential backoff (start 30s, cap 300s, no hard timeout — wind-downs can take a while).
   - If PID is dead: lock is stale (maybe — could be PID recycled). Verify by reading `/proc/<pid>/stat` field 22 for the live PID; if it matches the lock's recorded value, the original orchestrator is somehow alive without responding to `kill -0` (unlikely but defensive — wait); if it doesn't match, this is a recycled PID and the lock is stale → remove and re-acquire. If `/proc/<pid>/stat` doesn't exist, the PID is gone → stale → remove and re-acquire.
2. **Trap discipline.** Immediately after acquiring the lock, install: `trap 'rm -f .orchestra/runs/.wind-down.lock' EXIT INT TERM`. This guarantees release on Ctrl-C, kill, or any exit path. Without this, `rm` at step 4 is unreliable.

   **`EXIT INT TERM` is reserved for the lock trap** — orchestra commits to not installing competing handlers on these signals. Section 7's setup-cleanup trap uses `ERR` only, by design (see Section 7).
3. Spawn the wind-down Claude session, passing it the run folder path and the wind-down prompt (Section 6.3).
4. On session exit (any reason): trap fires; lock removed.

### 6.2 Merge tactic — agent-driven

The wind-down session is the only Claude process inside the lock, and it runs **all** the git operations itself — including the merge sequence. Reasons:
- Agent has session context to resolve any conflicts that arise during `git pull` or rebase.
- Agent can read the conflict markers, reason about the right resolution, and commit fixes.
- A mechanical orchestrator-driven merge would just fail on conflict and require human intervention regardless.

The merge sequence is part of the agent contract (Section 6.3 MUST clauses).

### 6.3 Wind-down agent contract

The agent receives a wind-down prompt that constrains it to the following contract. Orchestra's runtime does not enforce these — the prompt does, and the contract sets the boundary the agent operates within:

**MUST (in order):**
1. **Discover parent governance shape.** Read parent project's `CLAUDE.md` hierarchy first — if it names governance file paths (e.g. "decisions live in `docs/decisions/`"), prefer those. Otherwise fall back to filename-pattern matching at the project root and `docs/` top-level only (`TODO*`, `DECISIONS*`, `CHANGELOG*`, `HISTORY*`, `NEWS*`). No deeper recursion. Record the mapping decisions made in `7-SUMMARY.md`'s wind-down block.
2. **Ingest run governance into parent shape:**
   - `3-TODO.md` → parent TODO equivalent (or skip if parent has none)
   - `4-DECISIONS.md` → parent DECISIONS equivalent (or skip if parent has none)
   - `5-CHANGELOG.md` → parent CHANGELOG equivalent (or skip if parent has none)
   - `7-SUMMARY.md` and `2-OBJECTIVE.md` are NOT ingested — they remain in the archived run folder for human review.
3. **Per-file commit on the run-branch** with message `wind-down: ingest <run-file> → <parent-file>`. Separate commits per ingested file make per-file review possible.
4. **Append-only against parent files.** Existing parent content is preserved verbatim — new entries appended at the bottom or the project's documented insertion point.
4a. **Surface conflicts in the run summary.** Before appending each new entry, the agent scans the existing parent file for entries that may semantically conflict with the new one (same key/topic but contradictory status, decision reversal, superseded TODO entries, etc.). Append-only is preserved — agent does NOT modify the existing entry — but each potential conflict is recorded in `7-SUMMARY.md`'s wind-down block under a "Potential governance conflicts" subsection. This avoids silent documentation debt where main accumulates contradictory entries no one notices.

   **Schema for each conflict entry** (consistent format so a future tool can grep / parse):

   ```markdown
   ### Conflict <N>
   - **Source:** `<run-file>:<entry-id-or-line>` — `<one-line summary of the new entry>`
   - **Target:** `<parent-file>:<entry-id-or-line>` — `<one-line summary of the existing entry>`
   - **Reading:** <agent's analysis of why they conflict — 1-3 sentences>
   - **Recommended resolution:** <suggested action for human — supersede / merge / clarify / no action>
   ```

   If no conflicts are detected, the subsection contains the literal line `_No potential conflicts detected._` so absence of the section vs absence of conflicts can be distinguished.
5. **Run the merge sequence** to integrate the run branch into the base branch:
   - `git checkout <BASE_BRANCH>`
   - `git pull origin <BASE_BRANCH>` (resolve any conflicts inline using session context)
   - If `<BASE_BRANCH>` is an ancestor of run-branch → `git merge --ff-only <run-branch>`
   - Otherwise → checkout run-branch, `git rebase <BASE_BRANCH>` (resolve conflicts), checkout base, `git merge --ff-only <run-branch>`. Note: rebase rewrites the per-file ingestion commits onto the new base — they're reparented, not lost; reviewers auditing run-branch history post-rebase see the rewritten commits.
   - `git push origin <BASE_BRANCH>`. **On rejection (non-FF — remote moved between pull and push):** re-pull the base branch, redo the merge/rebase as above, retry push. Up to 3 attempts. On 3rd rejection or any non-conflict push failure (auth, network, pre-push hook), invoke wind-down failure path (Section 6.4) — same recovery shape as conflict-BLOCKED.

**MUST NOT:**
- Delete or rewrite existing parent governance content.
- Create new parent governance files where none exist (no-op ingestion is the correct behaviour for projects without governance).
- Touch any file outside parent governance + the run folder.
- Skip the merge sequence — successful ingestion without merge is a half-completed wind-down.

**Failure handling — ingestion ambiguity:** If the agent cannot determine where to ingest a given run-file (parent shape ambiguous), it logs the skip in `7-SUMMARY.md`'s wind-down block and proceeds with the next file. Skipped ingestion is preferable to wrong ingestion.

**Failure handling — unresolvable merge conflict or push rejection:** Agent emits `BLOCKED` with conflict/push-failure details written to `6-HANDOVER.md`. **Important — the BLOCKED enumeration shape is different in wind-down context.** Section 11 "Exit signals" normally requires a "remaining work and dependency analysis" listing each subtask. During wind-down there are no remaining subtasks — the only "remaining work" is the merge itself. So `6-HANDOVER.md` for wind-down BLOCKED must instead include:
- Files in conflict (paths + a brief description per file)
- The current merge state (`git status` excerpt showing conflict markers)
- What manual resolution looks like (e.g. "after resolving, run `git add . && git commit && git push origin <BASE_BRANCH>`")

Orchestrator handles wind-down BLOCKED via the same path as wind-down crash (Section 6.4), not via Section 11's regular BLOCKED handling — see Section 6.4.

After successful merge sequence: agent exits with `COMPLETE`. Orchestrator (still holding lock until trap fires) moves the run folder to `.orchestra/runs/archive/<run-timestamp>/` as the post-wind-down step.

### 6.4 Wind-down failure handling

Wind-down can fail four ways:
- **Category A** during wind-down (hard exit)
- **Category B** during wind-down (silent exit)
- **Category C** during wind-down (hang)
- **`BLOCKED` exit during wind-down** (agent could not resolve merge conflicts or push rejection — see Section 6.3 failure handling)

All four route through this single failure path (NOT through Section 11's regular `BLOCKED` handling — wind-down BLOCKED's recovery shape is "manual merge needed", which mirrors the crash recovery shape):

1. Orchestrator detects the failure (non-zero exit, hang, silent exit, or `BLOCKED` exit signal during wind-down).
2. Lock-release trap fires; `.wind-down.lock` removed.
3. Write `.orchestra/runs/<run>/WIND-DOWN-FAILED` with: timestamp, failure category (A/B/C/BLOCKED), last 50 lines of session output, and (for BLOCKED) the conflict/push-failure details extracted from `6-HANDOVER.md`.
4. Exit orchestrator with explicit message including the run-branch name, the failure category, and copy-paste-able recovery commands. Recovery shape varies by category:
   - **A/B/C:** `cd <worktree> && git checkout <BASE_BRANCH> && git merge --ff-only <run-branch> && git push origin <BASE_BRANCH>` (the wind-down didn't reach the merge step — base may not even need conflict resolution)
   - **BLOCKED:** `cd <worktree> && cat .orchestra/runs/<run>/6-HANDOVER.md` then resolve conflicts manually using the file/line guidance there, finishing with `git add . && git commit && git push origin <BASE_BRANCH>`
5. The run folder is NOT moved to archive — its presence at `.orchestra/runs/<run>/` with a `WIND-DOWN-FAILED` marker indicates an unfinished wind-down for the user to inspect.

Wind-down failures do NOT auto-retry. The user decides whether to resolve manually, abandon the run-branch, or re-run a fresh `orchestra run` referencing the partial work.

## 7. Concurrency

User fires runs sequentially but they may overlap in execution.

- **Run-folder atomic mkdir is the canonical uniqueness gate.** At run start, `mkdir .orchestra/runs/<run-timestamp>/` runs with no `-p`. On `EEXIST` (two runs starting in the same second), the second run sleeps 1s and retries with a fresh timestamp; bails after 3 retries with an explicit error. This is authoritative — tmux name and worktree path collisions become non-issues because they're derived from the same timestamp that just succeeded the mkdir.
- **Cleanup on downstream failure.** Immediately after the mkdir succeeds, the orchestrator installs `trap 'rm -rf .orchestra/runs/<run-timestamp>/' ERR` covering subsequent setup steps (worktree creation, tmux launch, etc.). If any step fails before the orchestrator hands off to the session loop, the trap removes the orphaned run folder so it doesn't appear as "stale" in `orchestra status`. Once the session loop is live, the trap is cleared via `trap - ERR` (the run folder now legitimately persists). **`ERR` is the only signal the setup trap uses** — the lock trap (Section 6.1) reserves `EXIT INT TERM`, so the two traps are non-overlapping in scope. Setup-cleanup runs at a different orchestrator phase from lock-acquisition; the traps are sequential, not nested.
- **Run timestamp format** — `<YYYYMMDD>-<HHMMSS>` (e.g. `20260429-153022`). Used uniformly across run folder, tmux session name, and worktree path so `orchestra status` can map between them with a single string.
- **Tmux session names** — `<TMUX_PREFIX>-<run-timestamp>` (default prefix `orchestra`, e.g. `orchestra-20260429-153022`). Conflicts handled by the atomic-mkdir gate above.
- **Worktree path** — `<WORKTREE_BASE>/run-<run-timestamp>`. Same: gate is upstream.
- **No project-level lockfile** — dropped. The atomic-mkdir gate is sufficient.
- **Wind-down lock** — `.orchestra/runs/.wind-down.lock` (Section 6.1). The only persistent lock. Serialises merges to base branch without blocking parallel work.
- **`orchestra status`** — enumerates `.orchestra/runs/<run>/`. State derived from markers in the run folder: `BLOCKED` marker → blocked; `WIND-DOWN-FAILED` → wind-down failed; otherwise active (if a tmux session matching `<TMUX_PREFIX>-<run-timestamp>` is alive) or stale (if not). **Markers (`BLOCKED`, `WIND-DOWN-FAILED`) are checked BEFORE tmux liveness** — marker presence is authoritative, in case a marker is written and the tmux is still tearing down (race window). Markers are flag files; their *presence*, not contents, is what classifies the run. Archived runs (under `archive/`) shown as a count only.

## 8. File Layout (Repo)

```
bin/orchestra              # CLI
bin/orchestrator.sh        # session loop
lib/config.sh              # config reader (now parses CONFIG.md)
install.sh                 # bootstrap into a project
templates/
  ├── CONFIG.md            # markdown-formatted runtime config (caps signals editable)
  ├── OBJECTIVE.md         # placeholder run brief
  └── orchestra-CLAUDE.md  # agent-facing guidance (setup, invocation, run prep)
examples/
  └── smoke-test/          # minimal scaffolded project for `orchestra test`
docs/
  ├── superpowers/specs/   # design docs (this file)
  └── archive/             # v2 historical (kept — valid history)
README.md
CLAUDE.md                  # full rewrite — current copy is multiply stale
                           # (lists lib/orchestrator.sh, lib/stage-changes.sh,
                           # lib/commit-and-update.sh, lib/verify-completion.sh —
                           # none of which exist in the current or new layout)
                           # New CLAUDE.md should cover: bash tech-stack, the
                           # bin/ + lib/ + templates/ + examples/ + docs/ layout,
                           # repo-local conventions (set -euo pipefail, exec bits,
                           # Linux-only), the run-vs-session vocabulary, where the
                           # spec/plan live, and pointers to MIGRATION.md and
                           # examples/smoke-test/. NO governance/protocol section
                           # (orchestra has no opinion on those for callers).
MIGRATION.md               # Claude-readable migration prompt (Section 14)
```

### Deletions

- `examples/test-orchestrator/` (predates v3 architecture)
- `templates/governance/` (orchestra no longer scaffolds parent governance)
- `templates/test/` (consolidated into `examples/smoke-test/`)
- `.orchestra/test/` at repo root (consolidated into `examples/smoke-test/`)
- `templates/CLAUDE.md`, `templates/CLAUDE-workflow.md` (project-CLAUDE.md scaffolding — orchestra no longer touches parent project's CLAUDE.md)
- Old `templates/orchestra-CLAUDE.md` content (autonomous-session rules, governance enforcement) — replaced with new agent-facing guidance focused on setup/invocation/run prep (see Section 9)
- `templates/DEVELOPMENT-PROTOCOL.md`
- `templates/standing-ac.md`
- `templates/toolchain.md`
- `templates/HANDOVER.md`, `templates/INBOX.md` (now per-run, generated)
- `templates/README.md` (the `.orchestra/README.md` template — not needed)
- `templates/config.test`
- `templates/settings.json` (no `.claude/settings.json` setup needed)
- `hooks/stage-changes.sh` (vestigial; agent runs git itself)
- `hooks/` (now empty)

## 9. File Layout (After Install in a Project)

```
.orchestra/
├── CLAUDE.md             # agent-facing guidance for orchestra setup/invocation/run prep
├── CONFIG.md             # user-editable runtime config (caps, markdown)
├── OBJECTIVE.md          # user-editable run brief (prepared with Claude pre-run)
├── runs/                 # run data
│   ├── <run-timestamp>/  # active run (per Section 5 layout)
│   └── archive/
│       └── <run-timestamp>/   # completed runs after wind-down
└── runtime/              # orchestra internals — don't edit
    ├── bin/
    │   ├── orchestra
    │   └── orchestrator.sh
    └── lib/
        └── config.sh
```

User sees **three files at `.orchestra/`** (`CLAUDE.md`, `CONFIG.md`, `OBJECTIVE.md`) plus two subfolders (`runs/` for output, `runtime/` for internals).

### What `.orchestra/CLAUDE.md` is for

This file is read by any **interactive** Claude session running in the project — picked up automatically via the standard CLAUDE.md cascading discovery. It's not for autonomous run sessions (those operate inside the worktree under parent CLAUDE.md hierarchy). Audience: a Claude that the user is asking to "set up orchestra", "prepare an objective for the next run", "kick off orchestra", "show me what the last run did", "help me migrate an old install", etc.

Contents (template at `templates/orchestra-CLAUDE.md`):
- One-paragraph overview of what orchestra is and the run/session vocabulary
- How to invoke: `.orchestra/runtime/bin/orchestra run` / `status` / `test`, suggested alias setup
- How to prepare `OBJECTIVE.md` — what makes a good brief, expected shape (free-form markdown referencing specs/plans), commit-before-run requirement
- How to read run output — pointer to numbered files in `.orchestra/runs/<run>/` and what each contains
- Wind-down behaviour summary — what happens at end of run, where output goes, what to do with `WIND-DOWN-FAILED` and `BLOCKED` markers
- Pointer to `MIGRATION.md` for old-orchestra-install handling

This file is orchestra-shipped. Edits by the user persist (init won't overwrite if it exists), but the canonical version lives in the templates.

No `.claude/settings.json` is created or required. No `hooks/` directory.

**Headless invocation.** Orchestrator spawns each session via `claude --print --dangerously-skip-permissions --model <MODEL> --thinking-effort <EFFORT>` (consistent with the existing `bin/orchestrator.sh` invocation pattern). Orchestra does not install or require `.claude/settings.json` — `--dangerously-skip-permissions` is the only permission-bypass needed for headless work. The user's interactive Claude Code config (in `~/.claude/`) is irrelevant to autonomous runs.

User invokes via `.orchestra/runtime/bin/orchestra run`. README suggests an alias.

## 10. CONFIG.md Format and Parser

Markdown with `KEY: VALUE` bullet lines. The parser extracts only the bullets and ignores all surrounding prose. The user's own config file in their own repo — not external input — so the threat model is "user typo or copy-paste error", not "untrusted source". Validation exists to fail loud on parse errors before a session starts, not to defend against shell injection.

### Format

```markdown
# Orchestra Configuration

Edit values below. Lines outside the `KEY: VALUE` bullets are ignored.

## Session Limits
- `MAX_SESSIONS`: 10
- `MAX_CONSECUTIVE_CRASHES`: 3
- `MAX_HANG_SECONDS`: 1200

## Quota Pacing
- `QUOTA_PACING`: true
- `QUOTA_THRESHOLD`: 80
- `QUOTA_POLL_INTERVAL`: 120

## Cooldowns (seconds)
- `COOLDOWN_SECONDS`: 15
- `CRASH_COOLDOWN_SECONDS`: 30

## Model
- `MODEL`: opus
- `EFFORT`: high

## Worktree
- `WORKTREE_BASE`: /tmp/orchestra-myproject
- `BASE_BRANCH`: main

## Tmux
- `TMUX_PREFIX`: orchestra

## Smoke Test
- `SMOKE_TEST_TIMEOUT`: 900
```

### Parser regex

```
^[[:space:]]*-[[:space:]]+`([A-Z_][A-Z0-9_]*)`:[[:space:]]*(.+)$
```

Key (group 1) must be backtick-wrapped, uppercase + underscores; value (group 2) is everything after the colon, trimmed of leading/trailing whitespace.

### Parser behaviour

- Parsed values are stored in a bash associative array (`ORCHESTRA_CONFIG[KEY]=VALUE`). They are **never `eval`'d, never `source`d**. Consumers reference `${ORCHESTRA_CONFIG[KEY]}` as a literal string.
- Bullets that don't match the regex are silently ignored (so prose, sub-bullets, `## headings`, code fences are all fine).
- **Duplicate keys → error.** First occurrence wins is too easy to misread; loud error makes the intent explicit.
- **Type validation per key** (see table below).
- On any validation failure: print offending line and key, abort with non-zero exit before any session starts.
- Implementation: bash function `parse_config_md()` in `runtime/lib/config.sh` (~50 lines).

### Required keys, optional keys, and defaults

| Key | Required? | Type | Default | Constraints |
|---|---|---|---|---|
| `MAX_SESSIONS` | yes | int | — | ≥ 1 |
| `MAX_CONSECUTIVE_CRASHES` | yes | int | — | ≥ 1 |
| `MAX_HANG_SECONDS` | no | int | 1200 | ≥ 60 |
| `MODEL` | yes | enum | — | one of: `opus`, `sonnet`, `haiku` |
| `EFFORT` | no | enum | `high` | one of: `low`, `medium`, `high` |
| `WORKTREE_BASE` | yes | path | — | must be absolute |
| `BASE_BRANCH` | yes | string | — | non-empty |
| `TMUX_PREFIX` | no | string | `orchestra` | matches `[a-z][a-z0-9-]*` |
| `QUOTA_PACING` | no | bool | `true` | `true` / `false` (case-sensitive) |
| `QUOTA_THRESHOLD` | no | int | 80 | 1–100 |
| `QUOTA_POLL_INTERVAL` | no | int | 120 | ≥ 30 |
| `COOLDOWN_SECONDS` | no | int | 15 | ≥ 0 |
| `CRASH_COOLDOWN_SECONDS` | no | int | 30 | ≥ 0 |
| `SMOKE_TEST_TIMEOUT` | no | int | 900 | ≥ 60 |

## 11. Crash Detection and Recovery

A "crash" is broader in the new model than just process death. Detection categories:

### Category A — Hard exit
Claude process exits non-zero (segfault, OOM, killed, network teardown, auth failure mid-session).

**Detection:** `$?` non-zero from the `claude --print` invocation.
**Behaviour:** Increment `CRASH_COUNT`; next session uses recovery prompt with damage-assessment step; bail after `MAX_CONSECUTIVE_CRASHES`.

### Category B — Silent exit
Claude exits zero but final output line is not one of the recognised exit signals (`COMPLETE`, `HANDOVER`, `BLOCKED`).

**Detection:** Parse final non-empty line of stdout; if it's not a recognised signal → silent exit.
**Behaviour:** Treat as Category A. Most likely cause: prompt-comprehension failure where Claude finished its turn without following the exit-signal protocol.

### Category C — Hang
No new output, no file changes in worktree, no active subprocess for `MAX_HANG_SECONDS` (default 1200 = 20 min).

**Detection:** `inotifywait -mr` on the worktree (file changes) AND a tail-position monitor on session stdout (output bytes); if BOTH signals quiet for the threshold → hang. Both must be quiet because Claude can be silently editing for a while or thinking visibly without writing — neither alone indicates a hang.

**Dependency:** Requires `inotify-tools` (provides `inotifywait`). Linux-only (consistent with the Linux-only target stated in Section 6.1). `orchestra init` preflight checks for `inotifywait` on `$PATH` and errors with `"inotify-tools not installed — run 'apt-get install inotify-tools' (Ubuntu/Debian) or your distro's equivalent"` if missing. No polling fallback is provided — the dependency is cheap and the alternative (poll `find <worktree> -newer <marker>` every N seconds) would burn CPU on long runs and miss sub-poll-interval activity.

**Behaviour:** Send SIGTERM to Claude, wait 30s, SIGKILL if needed. Then treat as Category A.

### Category D — Inconsistent finish (COMPLETE only)
**Applies only to sessions exiting with `COMPLETE`.** A `COMPLETE` exit asserts the run's objective is met — which means wind-down is about to merge the run-branch into main. If the worktree has uncommitted work at this point, that work is *not* on the run-branch, and wind-down would silently lose it. This makes `COMPLETE` + dirty state a load-bearing invariant violation.

`HANDOVER` and `BLOCKED` exits may legitimately leave dirty state (work-in-progress for the next session, or work parked for human resolution); Category D does not apply to them.

**Detection:** On `COMPLETE` exit only — `git status --porcelain` (excluding ignored entries); any non-empty output → inconsistent.
**Behaviour:** Do **not** restart. Log a warning to the session JSON. Counter is **not** incremented (agent's intent was clean). Wind-down session's prompt includes a damage-assessment preamble: "previous session emitted COMPLETE but left uncommitted changes — assess each modification, commit it on the run-branch with a sensible message, then proceed with wind-down ingestion." This preserves the work and the wind-down still runs.

### Category E — Wind-down crash
Hard exit, silent exit, or hang during the wind-down session specifically (Section 6.4).

**Behaviour:** No retry. Lock released, marker file written, orchestrator exits with explicit recovery instructions. User decides next steps.

### Crash counter rules

- Single counter `CRASH_COUNT`; A/B/C all increment it. D does not. E (wind-down crash) doesn't increment either — wind-down failures never auto-retry.
- `CRASH_COUNT` resets to 0 on any successful session signal (`COMPLETE` or `HANDOVER`). `BLOCKED` does not reset (no further sessions follow regardless).
- On `CRASH_COUNT >= MAX_CONSECUTIVE_CRASHES`: orchestrator bails with a clear message naming the last crash category. User can purge the worktree and restart, or investigate.
- The counter is irrelevant once any terminal state fires: `COMPLETE` (→ wind-down), `BLOCKED` (run halts), `MAX_SESSIONS` reached (run halts), or `MAX_CONSECUTIVE_CRASHES` reached (run halts). After that point no further working sessions are spawned.

### Exit signals

Three recognised signals: `COMPLETE`, `HANDOVER`, `BLOCKED`.

- **`COMPLETE`** — objective met. Triggers wind-down (Section 6). **Requires clean worktree** (no uncommitted changes, no untracked non-ignored files) — see Category D for the load-bearing reason. This is the only invariant orchestra enforces on agent state; everything else (per-subtask commits, branch hygiene, etc.) is the parent project's CLAUDE.md hierarchy concern.
- **`HANDOVER`** — session done, more work remains, next session continues. May leave dirty state intentionally (work-in-progress for the next session); next session reads `6-HANDOVER.md` for the briefing and picks up from the worktree.
- **`BLOCKED`** — agent has done all work it can do without an external dependency it cannot resolve via exec decision (missing credentials, third-party outage, spec ambiguity that exec authority cannot dispatch). Repurposed from the old per-task BLOCKED — now a run-level signal.

**`BLOCKED` decision rule:** "Can I make any further useful progress on the objective without this dependency? If yes, do that work first and emit `BLOCKED` only when I've genuinely run out of forward motion. If no, emit `BLOCKED` immediately rather than waste sessions."

**Required HANDOVER content on `BLOCKED` exit:** the agent's `6-HANDOVER.md` MUST include a "Remaining work and dependency analysis" section that:
- Enumerates each remaining subtask
- Names the specific external dependency (credential, service, spec clarification, etc.) blocking it
- States whether the dependency blocks the subtask absolutely or only partially

This requirement disambiguates the BLOCKED decision — agent cannot emit `BLOCKED` without demonstrating which work remains and why each piece is blocked. Bounds both failure modes (over-eager BLOCKED leaving easy work undone; under-eager BLOCKED that thrashes through MAX_SESSIONS) by forcing the agent to do the enumeration explicitly.

**`BLOCKED` orchestrator behaviour:**
1. No further sessions. No wind-down.
2. Write `.orchestra/runs/<run>/BLOCKED` marker file with the agent's blocker text (extracted from `1-INBOX.md` and `6-HANDOVER.md`).
3. Run folder stays at `.orchestra/runs/<run>/` (not archived) until the user resolves.
4. Orchestrator exits with explicit message naming the blocker and the run path.

User resolves by inspecting the run, fixing the blocker (creds, outage, spec clarification), then starting a fresh `orchestra run` — typically with an updated `OBJECTIVE.md` that references the partial work on the previous run-branch. The blocked run is not auto-resumable in v1; user can manually merge the run-branch if desired or reference its state in the next objective.

## 12. `orchestra init` (Simplified)

Steps:
1. Verify target dir exists (default: cwd).
2. Verify it's a git repo. **If not, error** with `"<path> is not a git repository. If this is intentional, run 'git init' first then retry."` Do not silently `git init`.
3. Create `.orchestra/runtime/bin/`, `.orchestra/runtime/lib/`, `.orchestra/runs/archive/`.
4. Copy `bin/orchestra` → `.orchestra/runtime/bin/orchestra` (chmod +x).
5. Copy `bin/orchestrator.sh` → `.orchestra/runtime/bin/orchestrator.sh` (chmod +x).
6. Copy `lib/config.sh` → `.orchestra/runtime/lib/config.sh`.
7. Copy `templates/CONFIG.md` → `.orchestra/CONFIG.md` (only if doesn't exist).
8. Copy `templates/OBJECTIVE.md` → `.orchestra/OBJECTIVE.md` (only if doesn't exist).
9. Copy `templates/orchestra-CLAUDE.md` → `.orchestra/CLAUDE.md` (only if doesn't exist). **Note:** the source template filename is `orchestra-CLAUDE.md` to disambiguate within `templates/`; the installed name is `CLAUDE.md`.
10. Print next-steps message.

**Removed:** governance directory creation, settings.json, CLAUDE.md scaffolding, DEVELOPMENT-PROTOCOL, toolchain.md, standing-ac.md, HANDOVER.md, INBOX.md, README.md, auto-`git init`. None of these are orchestra's business.

## 13. Smoke Test

Two fixtures, both run as part of `orchestra test`:

### 13.1 Fixture: `examples/smoke-test/empty/`

Minimal git project with no parent governance. Tests:
- `orchestra init` succeeds in a fresh repo
- A run completes end-to-end through wind-down
- The "no-op ingestion" path is correctly exercised (wind-down agent does NOT create parent TODO/DECISIONS/CHANGELOG files where none exist)

### 13.2 Fixture: `examples/smoke-test/with-governance/`

Same minimal git project, but pre-populated with stub parent governance files:
- `TODO.md` containing one existing entry tagged `[fixture-original]`
- `CHANGELOG.md` containing one existing entry tagged `[fixture-original]`
- `DECISIONS.md` containing one existing entry tagged `[fixture-original]`

Tests the actual ingestion path: wind-down agent appends new run-level entries to existing parent files without overwriting prior content.

**Per-source markers.** The fixture's `OBJECTIVE.md` instructs the agent to use distinguishing markers when populating its run-level governance files:
- `3-TODO.md` entries must be prefixed `[smoke-todo]`
- `4-DECISIONS.md` entries must be prefixed `[smoke-decision]`
- `5-CHANGELOG.md` entries must be prefixed `[smoke-changelog]`

These markers exist solely so the test can assert that each source file's content lands in the *correct* parent destination, not just *some* destination. Catches the wrong-place ingestion failure mode (e.g. agent appending CHANGELOG-shaped content to TODO.md). Markers are smoke-test-only — real projects don't use them and orchestra doesn't know about them.

This is the most failure-prone path so it's a v1 requirement, not a future option.

### 13.3 Test driver behaviour

For each fixture, `orchestra test`:
1. Copy fixture to a tempdir (e.g. `/tmp/orchestra-smoke-<HHMMSS>-<variant>/`).
2. Verify it's a git repo (fixtures are committed git repos in the orchestra repo); if not (cleanly copied without `.git`), `git init` and commit initial state.
3. Run `orchestra init` against the tempdir.
4. Pre-populated `OBJECTIVE.md` in the fixture defines a trivial multi-step brief (e.g. "create file A with content X, then create file B with content Y; record what you did in your run governance").
5. Run `orchestra run` with conservative session limits (`MAX_SESSIONS=2`).
6. Wait for completion (timeout: `SMOKE_TEST_TIMEOUT`, default 900s = 15 min).
7. Common assertions (after wind-down completes; **all run-folder file checks run against the archive path** `<tempdir>/.orchestra/runs/archive/<timestamp>/`, not the live path — by this point the run has been archived):
   - Archive folder exists at `<tempdir>/.orchestra/runs/archive/<timestamp>/`
   - Required files exist inside the archive folder: `1-INBOX.md`, `2-OBJECTIVE.md`, `3-TODO.md`, `4-DECISIONS.md`, `5-CHANGELOG.md`, `6-HANDOVER.md`, `7-SUMMARY.md`, `9-sessions/`
   - Agent emitted `COMPLETE` (visible in last `9-sessions/NNN.json`)
   - Expected files A and B exist in the worktree with expected content
   - No active run folder remains at `<tempdir>/.orchestra/runs/<timestamp>/` (i.e. archival succeeded — folder was moved, not copied)
8. Variant-specific assertions:
   - `empty/`: `find <tempdir> -maxdepth 1 \( -name 'TODO*' -o -name 'DECISIONS*' -o -name 'CHANGELOG*' \)` returns nothing.
   - `with-governance/`: each parent file contains its original `[fixture-original]` entry verbatim, AND its corresponding marker (`[smoke-todo]` in TODO.md, `[smoke-decision]` in DECISIONS.md, `[smoke-changelog]` in CHANGELOG.md), AND none of the OTHER markers (TODO.md must NOT contain `[smoke-decision]` or `[smoke-changelog]`, etc.). The wind-down commits are visible on the base branch with explicit source→destination mapping in messages: `git log --grep 'wind-down: ingest 3-TODO.md → '`, `git log --grep 'wind-down: ingest 4-DECISIONS.md → '`, `git log --grep 'wind-down: ingest 5-CHANGELOG.md → '` each returns exactly one match.
9. Tear down tempdir, remove tmux sessions, prune worktrees, delete run-branches.

### What the smoke test replaces

Single canonical location at `examples/smoke-test/{empty,with-governance}/`. Removes `.orchestra/test/`, `templates/test/`, `templates/config.test`, `examples/test-orchestrator/`.

## 14. Migration

No automated migration. Existing v3 installs (e.g. logrings) diverge enough that scripted migration would be more failure-prone than informed manual work.

Instead: ship `MIGRATION.md` at the **orchestra repo root only** (not installed into user projects — irrelevant for new installs and bloat for everyone else). When an existing v3 install needs upgrading, the user has the orchestra source locally anyway and points Claude at the file path: "follow the migration prompt at `<orchestra-repo>/MIGRATION.md` to migrate this project". The `.orchestra/CLAUDE.md` agent guidance (Section 9) tells interactive Claude sessions where to look. Claude:

1. Reads the existing `.orchestra/` layout and the project's git state.
2. Confirms with the user that no runs are currently in flight (worktrees clean, no live tmux orchestra sessions).
3. Walks the user through the changes interactively, applying each one and confirming before moving on:
   - Move `.orchestra/{bin,lib,hooks}/` → `.orchestra/runtime/{bin,lib}/`
   - Delete `.orchestra/runtime/hooks/` once stage-changes hook is removed
   - Edit `.claude/settings.json` to remove the orchestra `PostToolUse` hook (preserve any user-added hooks)
   - Rename `.orchestra/sessions/` → `.orchestra/runs/`
   - Convert `.orchestra/config` (bash) → `.orchestra/CONFIG.md` (markdown), translating each key. Keys dropped from the new model (TODO_FILE, DECISIONS_FILE, CHANGELOG_FILE, DEVELOPMENT_PROTOCOL, TOOLCHAIN_FILE, TASKS, TMUX_SESSION) are noted to the user but not carried over.
   - Move `.orchestra/HANDOVER.md` and `.orchestra/INBOX.md` (project-level) to a backup location; new model has these per-run only.
   - **Install `.orchestra/CLAUDE.md`** (new file in this version) from the template. **Detection rule for old-style file:** if the existing `.orchestra/CLAUDE.md` references `DEVELOPMENT-PROTOCOL.md`, `tasks.md`, `log.md`, "autonomous session rules", or "Multi-Session Autonomous Workflow" — it's an old orchestra-installed file. Back it up to `<existing>.bak` and install the new agent-facing version. If the file appears to be user-written (no old-orchestra signatures), prompt the user before overwriting.
   - **Per-run file renames inside any in-flight or recent run folders:**
     - `tasks.md` → `3-TODO.md`
     - `log.md` is split by content type when ingesting: decisions go to `4-DECISIONS.md`, changelog entries to `5-CHANGELOG.md`, free-form notes/findings/parked issues to `7-SUMMARY.md`. The new model has no single "log" file — split is done by Claude using judgement.
     - Old archived runs under `runs/archive/<NNN-label>/` retain their original layout (don't migrate historical archives).
   - Update orchestra runtime files to the latest version.
4. Notes to the user that parent project files installed by old orchestra (`DEVELOPMENT-PROTOCOL.md`, the "Multi-Session Autonomous Workflow" section in CLAUDE.md, governance directories like `TODO/`, `Decisions/`, `Changelog/`) are now the user's own — orchestra no longer installs or owns them. User decides whether to keep, modify, or remove them.

The prompt content lives in `MIGRATION.md`. It is detailed enough that Claude can execute it without needing the user's cumulative project history — the prompt instructs Claude to discover state from the filesystem.

## 14a. Implementation Approach: Rewrite + Cherry-Pick

The runtime should be **rewritten cleanly**, not adapted in place. Reasons:
- The architectural shift is large (governance paths gone, per-run numbered layout new, wind-down concept new, BLOCKED semantics rebuilt, crash categories rebuilt).
- Current `bin/orchestra` (28KB) and `bin/orchestrator.sh` (39KB) together carry ~68KB of layered legacy with deeply interleaved concerns (TODO scanning, task branching, governance scaffolding) — most of which we're dropping.
- Adapting in place leaves dead-code paths and risks bugs from incomplete edits.
- The current code is mid-evolution (recent session-scoped governance rewrite); compounding more edits accelerates entropy.

**What to rewrite:**
- `bin/orchestra` — small CLI dispatcher
- `bin/orchestrator.sh` — session loop, crash detection, wind-down spawn, lock management
- `lib/config.sh` — CONFIG.md parser
- `install.sh` — much smaller
- `templates/` — fresh CONFIG.md, OBJECTIVE.md, orchestra-CLAUDE.md

**What to cherry-pick from the existing repo** (proven idioms; reference paths shown for the implementer):
- **Tmux launch pattern** — `bin/orchestra:327` (`tmux new-session -d -s ...` invocation). Reuse the cd-into-project + tmux-detached pattern. Adapt to the new tmux-name format (Section 7).
- **Tmux-name conflict pre-flight** — `bin/orchestra:317` (`tmux has-session -t` check). Reuse the conflict-detect + bail pattern.
- **Worktree creation + branch setup** — `bin/orchestrator.sh:535` (`git worktree add "$WORKTREE_DIR" "$SESSION_BRANCH"`). Reuse the worktree dir creation, branch tracking. Adapt to the new run-folder layout and the atomic-mkdir gate (Section 7).
- **Quota pacing** — `bin/orchestrator.sh` quota polling + threshold + cooldown logic (search for `QUOTA_PACING`). Reuse verbatim (the keys `QUOTA_PACING`, `QUOTA_THRESHOLD`, `QUOTA_POLL_INTERVAL`, `COOLDOWN_SECONDS` survive into new CONFIG.md).
- **Session JSON log structure** — current orchestrator writes `9-sessions/NNN.json` files with rate-limit events, exit signal, session metadata. Reuse the schema; new orchestrator writes them to the new path.
- **Crash counter mechanics** — increment-on-crash, reset-on-success pattern. Adapt to the new categories A/B/C/D/E (current code only has A in effect).
- **Recovery prompt prepending pattern** — `bin/orchestrator.sh` `RECOVERY_PROMPT` heredoc + damage-assessment preamble (around line 383). Directly useful for new Categories D and E. Reshape the preamble for the new (much narrower) damage cases (uncommitted-changes-on-COMPLETE; wind-down crash).
- **Lockfile `set -C` idiom** — not in current codebase; implement fresh per Section 6.1.

**What NOT to cherry-pick** (deliberately dropped):
- Anything reading `TODO_FILE`/`DECISIONS_FILE`/`CHANGELOG_FILE` config keys
- Anything scanning `TODO/TODO.md` for T-numbered tasks
- Per-task branching logic (`orchestra/<t-number>-<slug>` branches)
- The `cmd_init` governance directory scaffolding
- The `cmd_init` `.claude/settings.json` setup
- The `cmd_init` DEVELOPMENT-PROTOCOL.md scaffolding
- The `stage-changes.sh` hook
- BLOCKED-via-task-dependency logic
- The in-session prompt heredoc structure (rewrite for the new model — references to TASKS, TODO.md, task-branching all go away)

**Practical mechanic.** Existing scripts stay in git history on the current branch. The implementation creates new files (or empties old ones and writes fresh) on a new branch. When a known-good idiom is needed, `git show main:bin/orchestrator.sh | grep -A20 'quota'` pulls it forward. Cleaner than incremental editing through 80KB of layered legacy.

## 15. Out of Scope

- Parallel-run UX (firing multiple runs simultaneously). Sequential-with-overlap is supported by the runtime; no CLI surface for parallel.
- Auto-resume of `BLOCKED` runs. User starts a fresh run after resolving the blocker.
- The wind-down agent's full prompt — only the contract (Section 6.3) is in this spec; the prompt itself is implementation detail.
- The contents of `MIGRATION.md` — Section 14 specifies that the file exists and what it should walk Claude through, but the prompt's exact wording is implementation detail. Same treatment as the wind-down prompt.

## 16. Decisions Captured

Key decisions are documented inline in the relevant sections. This index points to them rather than restating:

- Wind-down exempt from `MAX_SESSIONS`; only `COMPLETE` triggers wind-down — Section 6 opening, Section 11 "Exit signals"
- Crash counter rules + reset semantics — Section 11 "Crash counter rules"
- No auto `git init` in `orchestra init` — Section 12 step 2
- No `orchestra migrate` subcommand; replaced by `MIGRATION.md` — Section 14
- Agent (not orchestrator) runs the wind-down merge sequence — Section 6.2, Section 6.3 step 5
- Orchestra enforces only one state invariant (`COMPLETE` → clean worktree) — Section 11 exit signals
- Category D applies to `COMPLETE` only — Section 11.D
- Append-only ingestion + conflict surfacing — Section 6.3 step 4, 4a
- `inotify-tools` is the chosen hang-detection mechanism (no fallback) — Section 11.C
- `--dangerously-skip-permissions` is the headless invocation path — Section 9 "Headless invocation"

## 17. Open Risks

1. **Wind-down agent makes wrong ingestion decision.** Higher impact than a normal session error because it touches parent governance directly. Mitigations: contract in Section 6.3 forbids deletion/rewrite, requires append-only, requires per-file commits (so review is granular and revertible per-file). Wind-down failure exits without archiving so the user can inspect the run folder.
2. **CONFIG.md parser silently ignores malformed bullets.** Mitigations: required-key validation fails loud at run-start; type validation per Section 10 table catches bad values; duplicate keys → loud error. Acceptable residual risk: a typo in an *optional* key with valid syntax could result in a default being used silently. User can inspect parsed config via a `orchestra config` print subcommand (future, optional).
3. **Smoke test flakiness.** Real Claude sessions are non-deterministic. Mitigations: trivial briefs (file creation only); 15-minute timeout; run on demand only, not in CI; both fixtures designed so failures map cleanly to root causes (`empty/` failing means runtime/wind-down issue; `with-governance/` failing means ingestion-prompt issue).
4. **Hang detection false positives.** Long-thinking agent could be killed at 20 min. Mitigations: `MAX_HANG_SECONDS` is configurable; detection requires both no file changes AND no output, so a chatty thinking session wouldn't trigger. Default is generous given Opus thinking modes.
