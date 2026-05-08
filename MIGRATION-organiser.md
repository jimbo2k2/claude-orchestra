# Upgrading an existing orchestra install to the organiser-executor runtime

You are an interactive Claude session helping a user upgrade an
existing orchestra `.orchestra/` install to the organiser-executor
runtime (the version that introduces an Organiser/Executor inner loop
inside each working session). Read this whole file before taking any
action.

You operate from the user's project root — the directory that contains
their `.orchestra/` directory, NOT the orchestra source repo. The user
will tell you the absolute path to a freshly-pulled orchestra source
clone (the one that contains *this* file). Use that path when invoking
the new `bin/orchestra init`.

This upgrade is a refresh, not a rearchitecture. No file moves, no
data migration, no governance changes. The shape of `.orchestra/` is
unchanged; runtime files get newer copies and two new prompt files
appear in `runtime/lib/`. Everything is idempotent — running it twice
is harmless.

## What changes

- `.orchestra/runtime/bin/orchestra` — refreshed (new variants, new
  smoke assertions, copies the new prompt files during init).
- `.orchestra/runtime/bin/orchestrator.sh` — refreshed (working-session
  prompt now built from `lib/organiser-prompt.txt` instead of a
  legacy heredoc; reads `ORGANISER_MODEL` with a permissive fallback
  to `MODEL`; touches a new `9-sessions/executor-activity.log` at run
  start).
- `.orchestra/runtime/lib/config.sh` — refreshed (compat shim that
  accepts either `MODEL` or `ORGANISER_MODEL` with a deprecation
  warning when `MODEL` is used; new `ORGANISER_CONTEXT_THRESHOLD`
  validation).
- `.orchestra/runtime/lib/winddown-prompt.txt` — refreshed (wind-down
  session now reads `executor-activity.log` and writes a per-session
  summary into `7-SUMMARY.md`).
- **NEW** `.orchestra/runtime/lib/organiser-prompt.txt` — the
  Organiser inner-loop contract.
- **NEW** `.orchestra/runtime/lib/executor-prompt-template.txt` — the
  briefing skeleton the Organiser fills at dispatch time.

User-owned files (`.orchestra/CONFIG.md`, `.orchestra/OBJECTIVE.md`,
`.orchestra/CLAUDE.md`) are NOT touched by `orchestra init`. The user
may optionally rename `MODEL` → `ORGANISER_MODEL` in their CONFIG.md
to silence the deprecation warning, and add an
`ORGANISER_CONTEXT_THRESHOLD` line. Both are optional — Step 4.

## Steps

### 1. Survey the existing install

```
ls -la .orchestra/
ls .orchestra/runtime/lib/
cat .orchestra/CONFIG.md | head -40
```

You expect to see:
- `.orchestra/runtime/{bin,lib}/` (post-v3 layout).
- `lib/config.sh` and `lib/winddown-prompt.txt` present.
- `lib/organiser-prompt.txt` and `lib/executor-prompt-template.txt`
  ABSENT (they're what we're adding).
- A `MODEL: <opus|sonnet|haiku>` bullet in `CONFIG.md` under `## Model`.

If `.orchestra/runtime/` does NOT exist, the install is pre-v3. Stop
and direct the user to `MIGRATION.md` (v2→v3 migration) first; do not
attempt to upgrade in place.

If `lib/organiser-prompt.txt` already exists, this upgrade has likely
already been applied. Confirm with the user before proceeding (running
init again is harmless but the user may have wanted a different
operation).

### 2. Confirm no runs are in flight

A refresh during a live run is unsafe — the running orchestrator has
already loaded its current runtime files into memory, but a refresh
would change the on-disk versions mid-run. Verify nothing is live:

```
tmux ls 2>/dev/null | grep -E "orchestra|orch-"
git worktree list | grep orchestra
ls .orchestra/runs/ | grep -v archive
```

All three must come back empty (or only show `archive/`). If any show
live state, stop and ask the user to wait for the run to finish or
deliberately kill it before continuing.

### 3. Run the new orchestra init

Ask the user for the absolute path to their fresh orchestra source
clone (the one containing this file). Verify that path:

```
ls <ORCHESTRA_SOURCE>/bin/orchestra
ls <ORCHESTRA_SOURCE>/lib/organiser-prompt.txt
ls <ORCHESTRA_SOURCE>/lib/executor-prompt-template.txt
```

All three must exist. If any are missing, the source clone is itself
out of date — the user needs `git pull` in that source clone before
proceeding.

Then, from the user's project root:

```
<ORCHESTRA_SOURCE>/bin/orchestra init .
```

Expected output:
- A line for each runtime file copied.
- "Created `.orchestra/CONFIG.md`" — **Skipped** if it already exists.
  (User-owned files are preserved; this is the desired path.)
- Same for `OBJECTIVE.md` and `CLAUDE.md`.

### 4. (Optional) Update CONFIG.md to use the new keys

Show the user this rename:

```diff
-- `MODEL`: opus
++ `ORGANISER_MODEL`: opus
```

And this addition (under the same `## Model` heading):

```
- `ORGANISER_CONTEXT_THRESHOLD`: 75
```

Both are optional. The compat shim accepts the legacy `MODEL` key with
a deprecation warning at config-parse time; the threshold defaults to
75 if absent. Recommend the rename + addition, but do NOT make the
edit without the user's confirmation — `CONFIG.md` is user-owned.

If the user agrees, edit `.orchestra/CONFIG.md`:
- Replace the `MODEL` bullet with the `ORGANISER_MODEL` bullet (same
  value).
- Add the `ORGANISER_CONTEXT_THRESHOLD: 75` bullet immediately after.
- Optionally add a short paragraph below the `## Model` heading
  explaining what the threshold does (matches the explanation in
  `templates/CONFIG.md` in the new orchestra source).

### 5. Verify

```
.orchestra/runtime/bin/orchestra status
```

Expected: prints `(no active runs)` plus the archive count. Any error
here means something mis-pointed — diagnose by reading the error.

Confirm the new prompt files landed:

```
ls .orchestra/runtime/lib/
```

Expected files: `config.sh`, `winddown-prompt.txt`,
`organiser-prompt.txt`, `executor-prompt-template.txt`.

### 6. Tell the user what happens next

The Organiser/Executor pattern is now live. The next time they run
`orchestra run`, the working session will:

- Be prompted with the Organiser contract instead of the legacy
  "execute the next task" framing.
- Be expected to dispatch subagents via the Agent tool when work is
  Sonnet-bounded; do inline edits when dispatching would be wasteful;
  ESCALATE to Opus on the same task-id when a Sonnet attempt fails.
- Append one CSV line to `9-sessions/executor-activity.log` per Agent
  dispatch.

The wind-down session will summarise Executor activity (per-session
dispatches, model mix, ESCALATE rate, tasks-with-retries) into
`7-SUMMARY.md`'s `## Wind-down` block.

If the user wants to dry-run before committing real work, they can:

```
<ORCHESTRA_SOURCE>/bin/orchestra test with-organiser
```

That runs the opt-in smoke fixture against real Claude (5–15 min,
real API tokens) to confirm the dispatch path works end-to-end.

## What you should NOT do

- Don't touch `.orchestra/CONFIG.md`, `.orchestra/OBJECTIVE.md`, or
  `.orchestra/CLAUDE.md` without explicit user confirmation. Step 4 is
  optional and user-driven.
- Don't touch `.orchestra/runs/` or `.orchestra/runs/archive/`. Past
  run state is sacred.
- Don't touch `.orchestra/_legacy_backup/` if it exists — it's the
  v2→v3 migration's preserved old state, separate from this upgrade.
- Don't run `orchestra run` yourself to "test" the upgrade. Let the
  user initiate the first new run on their own terms.
- Don't try to reformat the user's existing CONFIG.md beyond the
  Step 4 changes. Keep the diff minimal.
