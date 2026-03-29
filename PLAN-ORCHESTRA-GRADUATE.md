# Plan: Add `orchestra graduate` Command to claude-orchestra

## Context

The claude-orchestra tool (`/home/james/projects/claude-orchestra`) manages autonomous multi-session Claude Code workflows. After a build completes, there's currently no structured way to transition from "orchestra finished" to "project ready for next build". The `reset --archive` command archives state files but doesn't help consolidate knowledge into long-lived documentation.

This plan adds an `orchestra graduate` command that codifies a "graduation protocol" — archiving orchestra state, creating a docs skeleton, restructuring changelogs, and printing a consolidation checklist. This makes the protocol reusable across any project that uses orchestra.

**Prerequisite**: All 6 improvements from `IMPROVEMENTS.md` have already been implemented and committed (multi-task sessions, model self-selection, descriptive commits, reduced plugins, focused context, debug passes). That file is now stale and should be deleted.

## Current Codebase State

- **`bin/orchestra`**: CLI dispatcher with `init`, `run`, `reset`, `status` commands
- **`lib/orchestrator.sh`**: Session loop runner
- **`lib/commit-and-update.sh`**: Post-session git commit hook
- **`lib/stage-changes.sh`**: Auto-stage modified files hook
- **`lib/verify-completion.sh`**: Verify state files updated before stop
- **`templates/`**: State file templates (PLAN.md, TODO.md, CHANGELOG.md, HANDOVER.md, INBOX.md, DECISIONS.md, CLAUDE.md, CLAUDE-workflow.md, settings.json, settings-autonomous.json)
- **`README.md`**: User-facing documentation
- **`IMPROVEMENTS.md`**: Stale planning artifact (all items implemented)

The existing `cmd_reset()` function in `bin/orchestra` (lines 153-235) handles archiving and resetting. The `graduate` command will reuse the archive logic and add docs scaffolding on top.

---

## Step 1: Add `cmd_graduate()` to `bin/orchestra`

Add a new function and dispatch entry. The function should:

1. Accept `--label NAME` flag (default: extract from PLAN.md objective, same as reset)
2. Validate `.orchestra/` exists and has content
3. Run the archive step (reuse logic from `cmd_reset`)
4. Create `docs/` skeleton in the project root (if it doesn't already exist):
   ```
   docs/
   ├── architecture/
   │   └── current.md
   ├── business-logic/       # Empty dir — user creates domain-specific files
   ├── design/
   │   ├── tokens.md
   │   └── patterns.md
   ├── decisions/
   │   ├── current.md
   │   └── [label].md        # Copy from template, named after the build label
   └── known-issues.md
   ```
5. Create `changelogs/` directory if it doesn't exist
6. If root `CHANGELOG.md` exists, move it to `changelogs/[label].md`
7. Create fresh `CHANGELOG.md` from template
8. Reset orchestra state files (same as `cmd_reset`)
9. Print the consolidation checklist to stdout

**Dispatch entry** (add to the case statement around line 301):
```
graduate) cmd_graduate "$@" ;;
```

**Usage entry** (add to the usage function):
```
echo "  graduate [--label NAME]  Archive, create docs skeleton, reset for next build"
```

## Step 2: Create Doc Templates

**New directory: `templates/docs/`**

These are minimal files (~10-20 lines each) with section headings and the "no code" rule.

**`templates/docs/architecture/current.md`**:
```markdown
<!-- Last verified: YYYY-MM-DD -->
<!-- RULE: No code blocks that mirror implementation. Reference source files instead. -->

# Architecture

## Tech Stack

## Database

## Auth Model

## Key Conventions

## Source Files
```

**`templates/docs/design/tokens.md`**:
```markdown
<!-- Last verified: YYYY-MM-DD -->
<!-- RULE: Use value tables, not CSS. Mark any illustrative snippets with <!-- VERIFY --> -->

# Design Tokens

## Colour Palette

## Person/Entity Colours

## State Colours

## Typography

## Spacing & Shadows
```

**`templates/docs/design/patterns.md`**:
```markdown
<!-- Last verified: YYYY-MM-DD -->
<!-- RULE: Describe patterns in prose. Reference source files for implementation. -->

# Design Patterns

## Card Pattern

## Grid/Table Pattern

## Badge/Tag Pattern
```

**`templates/docs/decisions/current.md`**:
```markdown
# Decisions — Current

Append new decisions here as they're made. When a major version ships, rename this file descriptively and start a fresh current.md.

| Date | Decision | Choice | Rationale |
|------|----------|--------|-----------|
```

**`templates/docs/known-issues.md`**:
```markdown
<!-- Keep this file pruned — remove issues as they're resolved -->

# Known Issues & Caveats

| Issue | Detail | Affects | Added |
|-------|--------|---------|-------|
```

**`templates/CHANGELOG-fresh.md`** (used when creating a fresh changelog after graduation):
```markdown
# Changelog

| Date | Type | Summary | Files | Details |
|------|------|---------|-------|---------|
```

## Step 3: Checklist Output

The `cmd_graduate()` function should print this checklist after completing all automated steps:

```
Orchestra graduated! Archive: .orchestra/archive/NNN-label/

Created docs/ skeleton. Now consolidate your project knowledge:

  [ ] docs/architecture/current.md
      Extract from: CLAUDE.md, your plan files
      Include: tech stack, DB schema, auth model, key conventions

  [ ] docs/business-logic/
      Extract from: your plan files, orchestra PLAN.md
      Create one file per domain (e.g. gate-logic.md, pocket-money.md)
      Include: rules, formulas, worked examples — NOT code blocks

  [ ] docs/design/tokens.md
      Extract from: any design reference files
      Include: colour values, typography, spacing as tables — NOT CSS

  [ ] docs/decisions/[label].md
      Extract from: plan files, orchestra DECISIONS.md
      Freeze all decisions from this build phase

  [ ] docs/known-issues.md
      Extract from: orchestra HANDOVER.md, CHANGELOG.md
      Include: current caveats, gotchas, sharp edges

  [ ] CLAUDE.md — rewrite as compact index (<100 lines)
      Keep: overview, tech stack, rules, docs/ pointers, orchestra workflow
      Remove: content that moved to docs/

  [ ] Delete graduated source files (plan files, design refs, etc.)

Rules for docs/:
  - NO code blocks that mirror implementation — they go stale silently
  - Describe rules and formulas in prose
  - Reference source files by path for implementation details
  - Mark any illustrative snippets with <!-- VERIFY -->
  - Add "Last verified: YYYY-MM-DD" to each file header
```

## Step 4: Clean Up IMPROVEMENTS.md

Delete `/home/james/projects/claude-orchestra/IMPROVEMENTS.md`. All 6 improvements are implemented. Git history preserves it.

## Step 5: Update README.md

Add `graduate` to the Commands section in `README.md` (after the `reset` entry, around line 90):

```markdown
### `orchestra graduate [--label NAME]`

Completes a build phase: archives state files, creates a `docs/` skeleton for long-lived documentation, restructures changelogs, and resets orchestra for the next build.

The `--label` flag names the archive (e.g. `--label mvp-build`). If omitted, the label is extracted from PLAN.md.

After running, follow the printed checklist to consolidate project knowledge from plan files and orchestra state into the `docs/` structure.
```

Also add `graduate` to the Directory layout section if it shows the docs structure.

## Step 6: Update `templates/CLAUDE-workflow.md`

Add a brief section at the end of the workflow template (before the closing):

```markdown
### Graduation

When a build phase is complete, run `orchestra graduate` to:
- Archive state files and session logs
- Create a `docs/` skeleton for long-lived documentation
- Reset orchestra for the next build

See the graduation checklist output for consolidation steps.
```

---

## Files Changed

| Action | File |
|--------|------|
| Modify | `bin/orchestra` — add `cmd_graduate()` function + dispatch entry + usage line |
| Create | `templates/docs/architecture/current.md` |
| Create | `templates/docs/design/tokens.md` |
| Create | `templates/docs/design/patterns.md` |
| Create | `templates/docs/decisions/current.md` |
| Create | `templates/docs/known-issues.md` |
| Create | `templates/CHANGELOG-fresh.md` |
| Modify | `README.md` — document `graduate` command |
| Modify | `templates/CLAUDE-workflow.md` — add graduation section |
| Delete | `IMPROVEMENTS.md` — all improvements already implemented |

## Verification

1. `cd /home/james/projects/claude-orchestra/examples/test-orchestrator && orchestra graduate --label test-build`
   - Should create `docs/` skeleton, `changelogs/`, archive, and reset state
   - Checklist should print to stdout
2. `orchestra status` in that directory shows clean slate with archive
3. `docs/` contains all expected template files
4. `changelogs/test-build.md` exists (if there was a CHANGELOG.md)
5. Fresh `CHANGELOG.md` has the table header format
6. README.md documents the new command
