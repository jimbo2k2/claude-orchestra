# Migrating an existing `.orchestra/` install

You are an interactive Claude session helping a user migrate an existing
v3 orchestra install to the new layout in this repo. Read this whole
file before taking any action. Operate from the user's project root —
the directory that contains their `.orchestra/` directory, NOT this
orchestra source repo.

The new orchestra is a re-architecture, not a refactor. File names,
directory layout, and the runtime config format all changed. This prompt
walks you through the migration steps. You'll preserve the user's data
and back up anything you remove or rewrite.

## Steps

### 1. Survey the existing install

```
ls -la .orchestra/
cat .orchestra/config 2>/dev/null
ls .orchestra/sessions/ 2>/dev/null   # old layout
ls .orchestra/runs/ 2>/dev/null       # may also exist if partially migrated
```

Tell the user what you see and ask them to confirm before proceeding.

### 2. Confirm no runs are in flight

A migration during a live run will lose state. Verify:

```
tmux ls 2>/dev/null | grep -E "orchestra|orch-"
git worktree list | grep orchestra
```

Both must be empty/no-match. If either shows live state, **stop** and
ask the user to wait for the current run to finish (or kill it
deliberately) before continuing.

### 3. Move the runtime tree

Old layout had `bin/`, `lib/`, and `hooks/` directly under `.orchestra/`.
New layout consolidates these under `.orchestra/runtime/`:

```
mkdir -p .orchestra/runtime
[ -d .orchestra/bin ]   && git mv .orchestra/bin   .orchestra/runtime/bin   2>/dev/null || mv .orchestra/bin   .orchestra/runtime/bin
[ -d .orchestra/lib ]   && git mv .orchestra/lib   .orchestra/runtime/lib   2>/dev/null || mv .orchestra/lib   .orchestra/runtime/lib
[ -d .orchestra/hooks ] && rm -rf .orchestra/hooks    # the staging hook is gone
```

Then re-run `orchestra init .` from the new orchestra source repo (the
one that contains this MIGRATION.md). It will refresh runtime files and
skip user-owned content (CONFIG.md, OBJECTIVE.md, CLAUDE.md) where
present.

### 4. Remove the old PostToolUse hook from `.claude/settings.json`

Old orchestra installed a staging hook in `.claude/settings.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "Edit|Write|MultiEdit", "hooks": [{"type": "command", "command": ".orchestra/hooks/stage-changes.sh"}]}
    ]
  }
}
```

Edit `.claude/settings.json` and remove that single PostToolUse entry.
Preserve any other hooks the user has — they are not orchestra's.

If `.claude/settings.json` only contained that one hook, leave the file
empty rather than deleting it (Claude Code reads it as a permissions
file too).

### 5. Rename `sessions/` → `runs/`

Old: `.orchestra/sessions/`. New: `.orchestra/runs/`.

```
[ -d .orchestra/sessions ] && mv .orchestra/sessions .orchestra/runs
mkdir -p .orchestra/runs/archive
```

If both `sessions/` and `runs/` exist (partial prior migration), ask the
user which is canonical. Don't merge automatically.

### 6. Convert `.orchestra/config` (bash) → `.orchestra/CONFIG.md` (markdown)

Old config was a bash file sourced by the orchestrator. New config is
markdown bullets parsed by `lib/config.sh`. Each bullet line is

```markdown
- `KEY`: VALUE
```

Mapping table — apply each transform; emit one bullet per kept key:

| Old key                  | New key                  | Notes |
|--------------------------|--------------------------|-------|
| `MAX_SESSIONS`           | `MAX_SESSIONS`           | identity |
| `MAX_CONSECUTIVE_CRASHES`| `MAX_CONSECUTIVE_CRASHES`| identity |
| `QUOTA_PACING`           | `QUOTA_PACING`           | identity |
| `QUOTA_THRESHOLD`        | `QUOTA_THRESHOLD`        | identity |
| `QUOTA_POLL_INTERVAL`    | `QUOTA_POLL_INTERVAL`    | identity |
| `COOLDOWN_SECONDS`       | `COOLDOWN_SECONDS`       | identity |
| `CRASH_COOLDOWN_SECONDS` | `CRASH_COOLDOWN_SECONDS` | identity |
| `MODEL`                  | `MODEL`                  | identity |
| `EFFORT`                 | `EFFORT`                 | identity |
| `WORKTREE_BASE`          | `WORKTREE_BASE`          | MUST be absolute. If relative, expand to absolute against project root. |
| `BASE_BRANCH`            | `BASE_BRANCH`            | identity |
| `TMUX_SESSION`           | `TMUX_PREFIX`            | renamed; old held the full tmux name, new holds just the prefix. Strip any `-NNN` suffix. |
| `TASKS`                  | DROPPED                  | new model uses `OBJECTIVE.md` instead — see step 9. |
| `TODO_FILE`              | DROPPED                  | new wind-down agent discovers parent governance from CLAUDE.md hierarchy + filename patterns. |
| `DECISIONS_FILE`         | DROPPED                  | same. |
| `CHANGELOG_FILE`         | DROPPED                  | same. |
| `DEVELOPMENT_PROTOCOL`   | DROPPED                  | parent project's CLAUDE.md hierarchy now drives this; orchestra has no opinion. |
| `TOOLCHAIN_FILE`         | DROPPED                  | same — parent project concern. |

Back up the original bash config before writing the new file:

```
mv .orchestra/config .orchestra/_legacy_backup/config.bak
```

Then write `.orchestra/CONFIG.md` with the kept-key bullets only.

### 7. Move legacy session-state files to `_legacy_backup/`

The old install had project-level `.orchestra/HANDOVER.md` and
`.orchestra/INBOX.md`. These are now per-run files generated inside the
worktree (named `1-INBOX.md` and `6-HANDOVER.md`). Move the project-level
ones aside:

```
mkdir -p .orchestra/_legacy_backup
[ -f .orchestra/HANDOVER.md ] && mv .orchestra/HANDOVER.md .orchestra/_legacy_backup/
[ -f .orchestra/INBOX.md   ] && mv .orchestra/INBOX.md   .orchestra/_legacy_backup/
```

### 8. Rename per-run files in any non-archived run folders

Old per-run filenames vs new (run files are now numbered for sort
order; each run folder also gets a `9-sessions/` directory for session
JSONs):

| Old              | New              |
|------------------|------------------|
| `tasks.md`       | `3-TODO.md`      |
| `log.md`         | split (see below)|
| (no equivalent)  | `1-INBOX.md` (created empty by `cmd_run`) |
| (no equivalent)  | `2-OBJECTIVE.md` (snapshot of `.orchestra/OBJECTIVE.md`) |
| (no equivalent)  | `4-DECISIONS.md` (created empty) |
| (no equivalent)  | `5-CHANGELOG.md` (created empty) |
| (no equivalent)  | `6-HANDOVER.md`  |
| (no equivalent)  | `7-SUMMARY.md`   |

For each non-archived run folder under `.orchestra/runs/<run>/`:

- `tasks.md` → `3-TODO.md` (rename).
- `log.md` → split:
  - Lines that look like decisions (e.g. start with `D###` or contain
    "decided", "chose", "rejected" near the start) → `4-DECISIONS.md`.
  - Lines that look like changelog entries (e.g. start with `C###` or
    contain "added", "fixed", "removed", "changed") → `5-CHANGELOG.md`.
  - Narrative / findings / reasoning → `7-SUMMARY.md`.
  - When in doubt, put in `7-SUMMARY.md` and note the ambiguity at the
    top of the file. Do NOT delete content.

Leave `runs/archive/` folders untouched. Archived runs are historical
record.

### 9. Author `OBJECTIVE.md`

The old `TASKS` config key was a list of task IDs the orchestrator would
walk through. The new model has a single `.orchestra/OBJECTIVE.md` file
that describes what the run should accomplish, in free-form markdown.
The agent reads it during cold-start.

If the user had a TASKS list, propose a draft `OBJECTIVE.md` that
captures those tasks as a numbered list under "## Work products" or
similar. Show the draft and ask for the user's approval before writing.

### 10. Install the new agent-facing `.orchestra/CLAUDE.md`

Detect the OLD `.orchestra/CLAUDE.md` if it exists. Old signatures:
references to `DEVELOPMENT-PROTOCOL.md`, `tasks.md`, `log.md`,
"autonomous session rules", "Multi-Session Autonomous Workflow", or the
old governance-file paths.

If old signatures are found:

```
mv .orchestra/CLAUDE.md .orchestra/CLAUDE.md.bak
```

If `.orchestra/CLAUDE.md` exists but doesn't match old signatures, ask
the user before overwriting.

Then re-run `orchestra init .` (from the new repo) which copies the new
`templates/orchestra-CLAUDE.md` to `.orchestra/CLAUDE.md`.

### 11. Refresh runtime files

```
/path/to/new-orchestra-source/bin/orchestra init .
```

`init` is idempotent: it copies runtime files unconditionally and skips
user-owned files (CONFIG.md, OBJECTIVE.md, CLAUDE.md) if they already
exist. Runtime files (`.orchestra/runtime/bin/`, `.orchestra/runtime/lib/`)
are always refreshed.

### 12. Inform the user about parent-project files orchestra no longer touches

Old orchestra installed and updated parent-project files: a generic
`DEVELOPMENT-PROTOCOL.md`, a "Multi-Session Autonomous Workflow"
section in the parent's `CLAUDE.md`, and `TODO/`/`Decisions/`/`Changelog/`
directories. These are no longer orchestra's business.

Tell the user:
- `DEVELOPMENT-PROTOCOL.md` (in their project root) — still there if
  they want it; orchestra no longer reads or maintains it.
- Their `CLAUDE.md` may have a "Multi-Session Autonomous Workflow"
  section appended by old orchestra. The wind-down agent now reads
  CLAUDE.md hierarchy for governance discovery only — that workflow
  section is no longer interpreted by orchestra. Recommend the user
  remove it (or keep as documentation if they like it).
- `TODO/`, `Decisions/`, `Changelog/` directories — still parent
  governance, still ingested into by wind-down (matched by pattern).
  No action needed unless the user wants to consolidate.

Each of these is the user's call: keep, modify, or remove. Don't touch
them yourself.

## Verification

After the migration, run:

```
.orchestra/runtime/bin/orchestra status
```

Expected: `(no active runs)` and an archive count matching the number of
historical runs that were preserved. Errors here mean something is
mis-pointed — diagnose by reading the error message and the surrounding
state.

The user can do a smoke run when they're ready by editing
`.orchestra/OBJECTIVE.md` and running:

```
.orchestra/runtime/bin/orchestra run
```

## What you should NOT do

- Don't delete archived runs.
- Don't rewrite the user's parent-project files (CLAUDE.md, README.md,
  etc.) — the user opts into those changes themselves.
- Don't mass-delete `.bak` files you create — leave them for the user
  to clean up after they're satisfied with the migration.
- Don't run `orchestra run` to "test" the migration — let the user
  initiate the first new run on their own terms.
