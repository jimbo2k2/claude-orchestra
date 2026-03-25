# Orchestra v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the orchestra v2 design spec — replacing v1's checkbox governance with numbered/archivable T/D/C protocols, adding three-tier planning, a codewriting inner loop, and config-driven project integration.

**Architecture:** The v1 codebase is ~1,300 lines of bash across 5 files plus templates. v2 modifies all 5 files, rewrites 2 (session prompts, init), adds a config reader, updates templates, and removes graduation. Changes are sequenced so each phase produces a working (if incomplete) system.

**Tech Stack:** Bash (POSIX-compatible), jq, git, Claude Code CLI, shellcheck for lint.

**Spec:** `docs/orchestra-v2-spec.md` (authoritative). Visual reference: `docs/orchestra-v2-flow.html`.

---

## File Structure

### Modified files

| File | Responsibility | Key changes |
|---|---|---|
| `bin/orchestra` (~500 lines) | CLI dispatcher: init, run, reset, status | Remove graduate. Rewrite init (governance scanning). Update run (pre-flight, lockfile, config). Update reset (simplified). Update status (config-mapped). |
| `lib/orchestrator.sh` (~550 lines) | Session loop: spawn, crash recovery, exit handling | Read config for governance paths. New session prompt (three-tier, task loop, codewriting loop). New recovery prompt. Model:effort parsing. Lockfile acquire/release. Governance checksum on config paths. Inverted crash recovery logic. |
| `lib/verify-completion.sh` (~144 lines) | Stop hook: verify session did work | Read governance paths from config. Check T-numbered status changes. Check C-numbered changelog entry. Check D-entries if decisions made. |
| `lib/commit-and-update.sh` (~64 lines) | Stop hook: git commit | Read governance paths from config. Single commit (code + governance together). |
| `lib/stage-changes.sh` (~17 lines) | PostToolUse hook: git add | No changes needed. |

### New files

| File | Responsibility |
|---|---|
| `lib/config.sh` (~60 lines) | Config reader: source `.orchestra/config`, export paths, provide defaults. Used by orchestrator and hooks. |
| `templates/config` | Template config file with commented defaults. |
| `templates/toolchain.md` | Template toolchain file (React Native + Expo + Supabase). |
| `templates/standing-ac.md` | Template standing acceptance criteria. |
| `templates/governance/TODO-CLAUDE.md` | Archiving protocol for TODO. |
| `templates/governance/TODO.md` | Empty T-numbered TODO template. |
| `templates/governance/DECISIONS-CLAUDE.md` | Archiving protocol for DECISIONS. |
| `templates/governance/DECISIONS.md` | Empty D-numbered DECISIONS template. |
| `templates/governance/CHANGELOG-CLAUDE.md` | Archiving protocol for CHANGELOG. |
| `templates/governance/CHANGELOG.md` | Empty C-numbered CHANGELOG template. |

### Deleted files

| File | Reason |
|---|---|
| `templates/TODO.md` | Replaced by `templates/governance/TODO.md` |
| `templates/PLAN.md` | Plans live in the project, not `.orchestra/` |
| `templates/DECISIONS.md` | Replaced by `templates/governance/DECISIONS.md` |
| `templates/CHANGELOG.md` | Replaced by `templates/governance/CHANGELOG.md` |
| `templates/CHANGELOG-fresh.md` | Graduation artifact — removed |
| `templates/docs/` | Entire directory — graduation docs scaffolding removed |

---

## Phase 1: Config Reader & Templates (foundation)

Everything else depends on config. Build this first.

### Task 1: Create config reader library

**Files:**
- Create: `lib/config.sh`

- [ ] **Step 1: Write `lib/config.sh`**

```bash
#!/bin/bash
# config.sh — Read .orchestra/config and export governance paths
#
# Source this file from orchestrator.sh and hook scripts.
# Usage: source "$LIB_DIR/config.sh" "$PROJECT_DIR"

load_orchestra_config() {
    local project_dir="$1"
    local config_file="$project_dir/.orchestra/config"

    if [ ! -f "$config_file" ]; then
        echo "ERROR: .orchestra/config not found. Run 'orchestra init' first." >&2
        return 1
    fi

    # Source the config (key=value format)
    set -a
    source "$config_file"
    set +a

    # Resolve relative paths against project dir
    TODO_FILE="${project_dir}/${TODO_FILE}"
    TODO_PROTOCOL="${project_dir}/${TODO_PROTOCOL}"
    DECISIONS_FILE="${project_dir}/${DECISIONS_FILE}"
    DECISIONS_PROTOCOL="${project_dir}/${DECISIONS_PROTOCOL}"
    CHANGELOG_FILE="${project_dir}/${CHANGELOG_FILE}"
    CHANGELOG_PROTOCOL="${project_dir}/${CHANGELOG_PROTOCOL}"
    PLAN_FILE="${project_dir}/${PLAN_FILE:-}"
    TOOLCHAIN_FILE="${project_dir}/${TOOLCHAIN_FILE:-.orchestra/toolchain.md}"
    STANDING_AC_FILE="${project_dir}/${STANDING_AC_FILE:-.orchestra/standing-ac.md}"
}

# Pre-flight validation: check all required files exist and are non-empty
preflight_check() {
    local errors=0

    if [ -z "${PLAN_FILE:-}" ] || [ ! -f "$PLAN_FILE" ] || [ ! -s "$PLAN_FILE" ]; then
        echo "ERROR: No strategic plan. Set PLAN_FILE in .orchestra/config and create the file." >&2
        errors=$((errors + 1))
    fi

    if [ ! -f "$TOOLCHAIN_FILE" ] || [ ! -s "$TOOLCHAIN_FILE" ]; then
        echo "ERROR: Toolchain not configured. Write build/test/capture commands to $TOOLCHAIN_FILE" >&2
        errors=$((errors + 1))
    fi

    if [ ! -f "$STANDING_AC_FILE" ] || [ ! -s "$STANDING_AC_FILE" ]; then
        echo "ERROR: Standing acceptance criteria not defined. Write criteria to $STANDING_AC_FILE" >&2
        errors=$((errors + 1))
    fi

    for label in TODO DECISIONS CHANGELOG; do
        local var_name="${label}_FILE"
        local file_path="${!var_name}"
        if [ ! -f "$file_path" ]; then
            echo "ERROR: Governance file not found: $file_path" >&2
            errors=$((errors + 1))
        fi
    done

    return "$errors"
}

# Coarse check: at least one OPEN task exists.
# Full dependency eligibility (Depends: field) is checked by the session itself
# during the task loop — too complex for a bash pre-flight check.
check_eligible_tasks() {
    local open_count proposed_count
    open_count=$(grep -c 'Status:.*OPEN' "$TODO_FILE" 2>/dev/null) || open_count=0
    proposed_count=$(grep -c 'Status:.*PROPOSED' "$TODO_FILE" 2>/dev/null) || proposed_count=0

    if [ "$open_count" -eq 0 ]; then
        if [ "$proposed_count" -gt 0 ]; then
            echo "ERROR: No OPEN tasks in $TODO_FILE ($proposed_count PROPOSED tasks awaiting human approval)" >&2
        else
            echo "ERROR: No OPEN tasks in $TODO_FILE. Add tasks or unblock existing ones." >&2
        fi
        return 1
    fi
    return 0
}
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n lib/config.sh`
Expected: no output (clean parse)

Run: `shellcheck lib/config.sh`
Expected: no errors (warnings acceptable)

- [ ] **Step 3: Commit**

```bash
git add lib/config.sh
git commit -m "feat: add config reader library for v2 governance paths"
```

### Task 2: Create governance templates

**Files:**
- Create: `templates/governance/TODO.md`
- Create: `templates/governance/TODO-CLAUDE.md`
- Create: `templates/governance/DECISIONS.md`
- Create: `templates/governance/DECISIONS-CLAUDE.md`
- Create: `templates/governance/CHANGELOG.md`
- Create: `templates/governance/CHANGELOG-CLAUDE.md`

- [ ] **Step 1: Create TODO template**

`templates/governance/TODO.md`:
```markdown
# TODO

## Summary Index

<!-- Archived entries appear here as one-liners -->

---

## Current Tasks

<!-- Add tasks below using the format:

### T001: Task title
- **Status:** OPEN
- **Tier:** 1
- **Added:** YYYY-MM-DD
- **Context:**
- **Parent:**
- **Depends:**
- **Detail:** Description of what needs to be done.

-->

<!-- Next number: T001 -->
```

- [ ] **Step 2: Create TODO archiving protocol**

`templates/governance/TODO-CLAUDE.md`:
```markdown
# TODO Archiving Protocol

## When to archive
Archive when the active file exceeds **30 current entries** (entries in the "Current Tasks" section).

## How to archive
1. Move all COMPLETE tasks from "Current Tasks" to a new file in `archive/` named `TXXXX-TYYYY.md` (range of T-numbers).
2. For each archived task, add a one-line summary to the "Summary Index" section: `- TXXXX: Task title — COMPLETE`
3. Update the `<!-- Next number: TXXX -->` comment.
4. Archive files are **immutable** once created — never edit them.

## Task entry format
See the main TODO.md for the standard entry format. All fields are mandatory except Parent and Depends (which are omitted when not applicable).

## Task statuses
- **OPEN** — ready for pickup (default for new tasks)
- **IN_PROGRESS** — a session is working on it
- **COMPLETE** — finished and verified
- **BLOCKED** — needs human input (reason in detail)
- **PROPOSED** — awaiting human approval before becoming OPEN
```

- [ ] **Step 3: Create DECISIONS template**

`templates/governance/DECISIONS.md`:
```markdown
# Decisions

## Summary Index

<!-- Archived entries appear here as one-liners -->

---

## Current Decisions

<!-- Add decisions below using the format:

### D001: Decision title
- **Date:** YYYY-MM-DD
- **Status:** ACTIVE
- **Context:**
- **Detail:** What was decided and why.
- **Alternatives considered:** What else was considered and why it was rejected.

-->

<!-- Next number: D001 -->
```

- [ ] **Step 4: Create DECISIONS archiving protocol**

`templates/governance/DECISIONS-CLAUDE.md`:
```markdown
# Decisions Archiving Protocol

## When to archive
Archive when the active file exceeds **30 current entries**.

## How to archive
1. Move resolved decisions to `archive/DXXXX-DYYYY.md`.
2. Add one-line summary to "Summary Index": `- DXXXX: Decision title — ACTIVE`
3. Update the next-number comment.
4. Archive files are **immutable**.
```

- [ ] **Step 5: Create CHANGELOG template**

`templates/governance/CHANGELOG.md`:
```markdown
# Changelog

## Summary Index

<!-- Archived entries appear here as one-liners -->

---

## Current Entries

<!-- Add entries below using the format:

### C001: Short description of change
- **Date:** YYYY-MM-DD
- **Task:** TXXXX
- **Decision:** DXXXX (if applicable)
- **Type:** FEATURE | FIX | REFACTOR | CONFIG | DOCS
- **Files:** path/to/file1, path/to/file2
- **Summary:** What changed and why.

-->

<!-- Next number: C001 -->
```

- [ ] **Step 6: Create CHANGELOG archiving protocol**

`templates/governance/CHANGELOG-CLAUDE.md`:
```markdown
# Changelog Archiving Protocol

## When to archive
Archive when the active file exceeds **50 current entries**.

## How to archive
1. Move entries to `archive/CXXXX-CYYYY.md`.
2. Add one-line summary to "Summary Index": `- CXXXX: Description — TYPE`
3. Update the next-number comment.
4. Archive files are **immutable**.
```

- [ ] **Step 7: Verify all template files exist and are well-formed**

Run: `ls -la templates/governance/`
Expected: 6 files (3 main + 3 protocol)

Run: `for f in templates/governance/*.md; do echo "--- $f ---"; head -3 "$f"; done`
Expected: each file shows its header

- [ ] **Step 8: Commit**

```bash
git add templates/governance/
git commit -m "feat: add v2 governance templates (T/D/C numbered, archivable)"
```

### Task 3: Create config, toolchain, and standing AC templates

**Files:**
- Create: `templates/config`
- Create: `templates/toolchain.md`
- Create: `templates/standing-ac.md`

- [ ] **Step 1: Create config template**

`templates/config`:
```bash
# .orchestra/config — Orchestra v2 configuration
# Paths are relative to project root.

# Governance file locations
TODO_FILE=TODO/TODO.md
TODO_PROTOCOL=TODO/CLAUDE.md
DECISIONS_FILE=Decisions/DECISIONS.md
DECISIONS_PROTOCOL=Decisions/CLAUDE.md
CHANGELOG_FILE=Changelog/CHANGELOG.md
CHANGELOG_PROTOCOL=Changelog/CLAUDE.md

# Strategic plan for current build (set before orchestra run)
PLAN_FILE=

# Toolchain (stack-specific build/test commands)
TOOLCHAIN_FILE=.orchestra/toolchain.md

# Standing acceptance criteria
STANDING_AC_FILE=.orchestra/standing-ac.md
```

- [ ] **Step 2: Create toolchain template**

`templates/toolchain.md`:
```markdown
# Toolchain — React Native + Expo + Supabase

## Build & Serve
```
npx expo start --web
```

## UI Capture
- Tool: Puppeteer (headless Chrome)
- Viewport: 393x852 (iPhone 15 Pro)
- Navigate via `data-testid` selectors
- Screenshot for visual verification
- DOM query for structural verification

## Data Verification
- Use `supabase-js` to query target tables after mutations
- Verify RLS policies allow/deny as expected for current user role
- Check optimistic updates revert cleanly on simulated failure

## Conventions
- File naming: see project CLAUDE.md and PUBLISHED-LANGUAGE.md
- Component structure: see toolchain-specific conventions in project docs
```

- [ ] **Step 3: Create standing AC template**

`templates/standing-ac.md`:
```markdown
# Standing Acceptance Criteria

These criteria apply to **every UI task**. Claude generates task-specific AC as children under these categories.

## Visual & Layout
- All UI elements render without clipping or overflow
- Layout holds at target viewport dimensions (393x852, 430x932)
- No visual regressions in adjacent screens

## Functional
- All interactive elements respond to tap/press
- Navigation flows complete without dead ends
- Loading, empty, and error states all render correctly

## Data
- Data persists correctly to Supabase
- RLS policies allow/deny as expected for the current user role
- Optimistic updates revert cleanly on failure

## Code Quality
- No console errors or warnings
- No TypeScript compiler errors
- Accessibility labels present on all interactive elements

## Integration
- Component renders within the existing navigation structure
- No regressions in previously passing acceptance criteria
```

- [ ] **Step 4: Verify files**

Run: `bash -n templates/config`
Expected: clean parse (it's sourceable bash)

Run: `ls templates/toolchain.md templates/standing-ac.md templates/config`
Expected: all three exist

- [ ] **Step 5: Commit**

```bash
git add templates/config templates/toolchain.md templates/standing-ac.md
git commit -m "feat: add config, toolchain, and standing AC templates"
```

---

## Phase 2: CLI Overhaul (init, run, reset, status)

### Task 4: Rewrite `orchestra init` with governance scanning

**Files:**
- Modify: `bin/orchestra` (lines 60-131, `cmd_init` function)

This is the most complex CLI change. The new init scans for existing governance structures and either inherits, creates, or warns on conflict.

- [ ] **Step 1: Write the governance scanning helper**

Add above `cmd_init` in `bin/orchestra`:

```bash
# ─── Governance scanning helpers ─────────────────────────────────────────────

# Check if a directory matches the numbered governance pattern:
# - Contains a main .md file with numbered entries (T/D/C-XXX patterns)
# - Contains a CLAUDE.md protocol file
# - Contains an archive/ subdirectory
scan_governance_dir() {
    local dir="$1"
    local prefix="$2"  # T, D, or C
    local main_file="$3"

    if [ ! -d "$dir" ]; then
        echo "NOT_FOUND"
        return
    fi

    local has_main=false has_protocol=false has_archive=false has_numbers=false

    [ -f "$dir/$main_file" ] && has_main=true
    [ -f "$dir/CLAUDE.md" ] && has_protocol=true
    [ -d "$dir/archive" ] && has_archive=true

    if [ "$has_main" = true ] && grep -qE "${prefix}[0-9]{3,}" "$dir/$main_file" 2>/dev/null; then
        has_numbers=true
    fi

    if [ "$has_main" = true ] && [ "$has_protocol" = true ] && [ "$has_archive" = true ] && [ "$has_numbers" = true ]; then
        echo "MATCH"
    elif [ "$has_main" = true ] || compgen -G "$dir/*.md" > /dev/null 2>&1; then
        echo "CONFLICT"
    else
        echo "NOT_FOUND"
    fi
}

# Prompt user for conflict resolution
resolve_conflict() {
    local artifact_name="$1"
    local dir="$2"

    echo ""
    echo "  WARNING: Found existing $artifact_name structure in $dir"
    echo "  but it doesn't match the expected numbered/archivable format."
    echo ""
    echo "  Options:"
    echo "    adopt  — Migrate to numbered format (creates archive/ and CLAUDE.md)"
    echo "    point  — Use as-is (orchestra reads but may not write correctly)"
    echo "    skip   — Don't manage $artifact_name through orchestra"
    echo ""
    read -rp "  Choice [adopt/point/skip]: " choice

    case "${choice,,}" in
        adopt|point|skip) echo "$choice" ;;
        *) echo "skip" ;;
    esac
}
```

- [ ] **Step 2: Rewrite `cmd_init` body**

Replace the existing `cmd_init` function (lines 60-131) with the complete new version:

```bash
cmd_init() {
    local target_dir="${1:-.}"
    target_dir="$(cd "$target_dir" 2>/dev/null && pwd)" || die "Directory '$1' does not exist"

    local orchestra_dir="$target_dir/.orchestra"

    if [ -d "$orchestra_dir" ] && [ -f "$orchestra_dir/config" ]; then
        die ".orchestra/ already exists in $target_dir. Use 'orchestra reset' to start fresh."
    fi

    echo "Initialising orchestra v2 in $target_dir"

    # ─── Governance scanning ────────────────────────────────────────────────
    # For each governance artifact, scan common directory names, inherit if
    # matching, create if missing, prompt on conflict.

    local config_lines=""

    # Define: artifact_name  prefix  search_dirs  main_filename  template_prefix
    local -a ARTIFACTS=(
        "TODO:T:TODO:TODO.md:TODO"
        "DECISIONS:D:Decisions:DECISIONS.md:DECISIONS"
        "CHANGELOG:C:Changelog:CHANGELOG.md:CHANGELOG"
    )

    for artifact_spec in "${ARTIFACTS[@]}"; do
        IFS=: read -r art_name art_prefix search_dir main_file tpl_prefix <<< "$artifact_spec"

        local result="NOT_FOUND"
        local found_dir=""

        # Check the primary expected location
        if [ -d "$target_dir/$search_dir" ]; then
            result=$(scan_governance_dir "$target_dir/$search_dir" "$art_prefix" "$main_file")
            found_dir="$target_dir/$search_dir"
        fi

        case "$result" in
            MATCH)
                echo "   $art_name: inherited from $found_dir"
                config_lines="${config_lines}${art_name}_FILE=${search_dir}/${main_file}\n"
                config_lines="${config_lines}${art_name}_PROTOCOL=${search_dir}/CLAUDE.md\n"
                ;;
            CONFLICT)
                local choice
                choice=$(resolve_conflict "$art_name" "$found_dir")
                case "$choice" in
                    adopt)
                        # Create missing structure around existing file
                        mkdir -p "$found_dir/archive"
                        if [ ! -f "$found_dir/CLAUDE.md" ]; then
                            cp "$TEMPLATE_DIR/governance/${tpl_prefix}-CLAUDE.md" "$found_dir/CLAUDE.md"
                        fi
                        echo "   $art_name: adopted existing structure in $found_dir"
                        config_lines="${config_lines}${art_name}_FILE=${search_dir}/${main_file}\n"
                        config_lines="${config_lines}${art_name}_PROTOCOL=${search_dir}/CLAUDE.md\n"
                        ;;
                    point)
                        echo "   $art_name: pointing to existing file (manual compatibility)"
                        config_lines="${config_lines}${art_name}_FILE=${search_dir}/${main_file}\n"
                        config_lines="${config_lines}${art_name}_PROTOCOL=\n"
                        ;;
                    skip)
                        echo "   $art_name: skipped (not managed by orchestra)"
                        config_lines="${config_lines}${art_name}_FILE=\n"
                        config_lines="${config_lines}${art_name}_PROTOCOL=\n"
                        ;;
                esac
                ;;
            NOT_FOUND)
                # Create fresh governance structure
                local new_dir="$target_dir/$search_dir"
                mkdir -p "$new_dir/archive"
                cp "$TEMPLATE_DIR/governance/${tpl_prefix}.md" "$new_dir/$main_file"
                cp "$TEMPLATE_DIR/governance/${tpl_prefix}-CLAUDE.md" "$new_dir/CLAUDE.md"
                echo "   $art_name: created $search_dir/ with templates"
                config_lines="${config_lines}${art_name}_FILE=${search_dir}/${main_file}\n"
                config_lines="${config_lines}${art_name}_PROTOCOL=${search_dir}/CLAUDE.md\n"
                ;;
        esac
    done

    # ─── Create .orchestra/ ─────────────────────────────────────────────────
    mkdir -p "$orchestra_dir/session-logs" "$orchestra_dir/archive"

    # Write config file
    cat > "$orchestra_dir/config" << CONFIGEOF
# .orchestra/config — Orchestra v2 configuration
# Paths are relative to project root.

# Governance file locations
$(echo -e "$config_lines")
# Strategic plan for current build (set before orchestra run)
PLAN_FILE=

# Toolchain (stack-specific build/test commands)
TOOLCHAIN_FILE=.orchestra/toolchain.md

# Standing acceptance criteria
STANDING_AC_FILE=.orchestra/standing-ac.md
CONFIGEOF
    echo "   Created .orchestra/config"

    # Copy operational files
    for f in HANDOVER.md INBOX.md; do
        if [ -f "$TEMPLATE_DIR/$f" ]; then
            cp "$TEMPLATE_DIR/$f" "$orchestra_dir/$f"
        fi
    done

    # Copy toolchain and standing AC templates
    cp "$TEMPLATE_DIR/toolchain.md" "$orchestra_dir/toolchain.md"
    cp "$TEMPLATE_DIR/standing-ac.md" "$orchestra_dir/standing-ac.md"
    echo "   Created .orchestra/ with operational files, toolchain, standing AC"

    # ─── Handle CLAUDE.md ───────────────────────────────────────────────────
    if [ -f "$target_dir/CLAUDE.md" ]; then
        if grep -q "## Multi-Session Autonomous Workflow" "$target_dir/CLAUDE.md" 2>/dev/null; then
            echo "   CLAUDE.md already has workflow section — skipping"
        else
            if [ -f "$TEMPLATE_DIR/CLAUDE-workflow.md" ]; then
                echo "" >> "$target_dir/CLAUDE.md"
                cat "$TEMPLATE_DIR/CLAUDE-workflow.md" >> "$target_dir/CLAUDE.md"
                echo "   Appended workflow section to existing CLAUDE.md"
            fi
        fi
    else
        if [ -f "$TEMPLATE_DIR/CLAUDE.md" ]; then
            cp "$TEMPLATE_DIR/CLAUDE.md" "$target_dir/CLAUDE.md"
            echo "   Created CLAUDE.md from template"
        fi
    fi

    # ─── Handle .claude/settings.json ───────────────────────────────────────
    local claude_dir="$target_dir/.claude"
    if [ -f "$claude_dir/settings.json" ]; then
        echo "   .claude/settings.json exists — not overwriting (check hooks manually)"
    else
        mkdir -p "$claude_dir"
        if [ -f "$TEMPLATE_DIR/settings.json" ]; then
            cp "$TEMPLATE_DIR/settings.json" "$claude_dir/settings.json"
            echo "   Created .claude/settings.json with hook definitions"
        fi
    fi

    # ─── Git init if needed ─────────────────────────────────────────────────
    if ! git -C "$target_dir" rev-parse --show-toplevel &>/dev/null; then
        git -C "$target_dir" init
        echo "   Initialised git repository"
    fi

    echo ""
    echo "Done! Next steps:"
    echo "  1. Write a strategic plan and set PLAN_FILE in .orchestra/config"
    echo "  2. Add T-numbered tasks to your TODO file"
    echo "  3. Review .orchestra/toolchain.md and .orchestra/standing-ac.md"
    echo "  4. Customise CLAUDE.md for your project"
    echo "  5. Run: orchestra run"
}
```

- [ ] **Step 3: Test init on a fresh directory**

```bash
mkdir /tmp/test-init && cd /tmp/test-init && git init
orchestra init
ls -la .orchestra/
cat .orchestra/config
ls -la TODO/ Decisions/ Changelog/
```

Expected: fresh governance structures created, config populated with paths.

- [ ] **Step 4: Test init on a LogRings-like directory**

```bash
mkdir -p /tmp/test-inherit/TODO/archive /tmp/test-inherit/Decisions/archive
cd /tmp/test-inherit && git init
echo "### T001: Test task" > TODO/TODO.md
echo "# Protocol" > TODO/CLAUDE.md
echo "### D001: Test decision" > Decisions/DECISIONS.md
echo "# Protocol" > Decisions/CLAUDE.md
mkdir -p Decisions/archive
orchestra init
cat .orchestra/config
```

Expected: config points to existing TODO/ and Decisions/ paths. Changelog/ created fresh.

- [ ] **Step 5: Commit**

```bash
git add bin/orchestra
git commit -m "feat: rewrite orchestra init with governance scanning"
```

### Task 5: Update `cmd_run` with pre-flight and lockfile

**Files:**
- Modify: `bin/orchestra` (`cmd_run` function, lines 135-151)

- [ ] **Step 1: Rewrite `cmd_run`**

Replace the existing `cmd_run` with:

```bash
cmd_run() {
    local project_dir
    project_dir="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Not in a git repository"

    if [ ! -d "$project_dir/.orchestra" ]; then
        die ".orchestra/ not found. Run 'orchestra init' first."
    fi

    if [ ! -f "$project_dir/CLAUDE.md" ]; then
        die "CLAUDE.md not found in project root."
    fi

    # Source config reader and load config
    source "$LIB_DIR/config.sh"
    load_orchestra_config "$project_dir" || die "Failed to load .orchestra/config"

    # Pre-flight checks
    preflight_check || die "Pre-flight checks failed. Fix the errors above and retry."
    check_eligible_tasks || die "No eligible tasks. Add OPEN tasks to $TODO_FILE or unblock existing ones."

    # Lockfile is acquired inside orchestrator.sh (after trap is set) to ensure cleanup.
    export STATE_DIR="$project_dir/.orchestra"
    exec bash "$LIB_DIR/orchestrator.sh"
}
```

- [ ] **Step 2: Test pre-flight rejection**

```bash
cd /tmp/test-init
# PLAN_FILE is empty in config — should fail
orchestra run
```

Expected: "No strategic plan" error.

- [ ] **Step 3: Commit**

```bash
git add bin/orchestra
git commit -m "feat: add pre-flight checks and lockfile to orchestra run"
```

### Task 6: Simplify `cmd_reset` and remove `cmd_graduate`

**Files:**
- Modify: `bin/orchestra` (`cmd_reset` lines 155-237, `cmd_graduate` lines 300-480, dispatch, usage)

- [ ] **Step 1: Rewrite `cmd_reset`**

Simplified: only archives HANDOVER + session-logs. Does NOT touch governance files.

```bash
cmd_reset() {
    local label=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --label)
                [ -z "${2:-}" ] && die "--label requires a value"
                label="$2"
                shift 2
                ;;
            --label=*) label="${1#--label=}"; shift ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    local project_dir
    project_dir="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Not in a git repository"
    local orchestra_dir="$project_dir/.orchestra"

    [ -d "$orchestra_dir" ] || die ".orchestra/ not found. Nothing to reset."

    # Archive HANDOVER + session-logs
    local archive_base="$orchestra_dir/archive"
    mkdir -p "$archive_base"

    local last_num=0
    local _old_nullglob=$(shopt -p nullglob 2>/dev/null)
    shopt -s nullglob
    for d in "$archive_base"/[0-9][0-9][0-9]-*/; do
        [ -d "$d" ] || continue
        local name="${d%/}"; name="${name##*/}"
        local num="${name%%-*}"; num=$((10#$num))
        [ "$num" -gt "$last_num" ] && last_num="$num"
    done
    $_old_nullglob
    local next_num=$((last_num + 1))

    [ -z "$label" ] && label="$(date -u +%Y%m%d-%H%M%S)"

    local archive_dir
    archive_dir=$(printf "%s/%03d-%s" "$archive_base" "$next_num" "$label")
    mkdir -p "$archive_dir"

    # Archive handover and session logs
    [ -f "$orchestra_dir/HANDOVER.md" ] && cp "$orchestra_dir/HANDOVER.md" "$archive_dir/"
    if [ -d "$orchestra_dir/session-logs" ] && [ "$(ls -A "$orchestra_dir/session-logs" 2>/dev/null)" ]; then
        cp -r "$orchestra_dir/session-logs" "$archive_dir/"
    fi
    echo "Archived to $archive_dir"

    # Reset HANDOVER to template
    if [ -f "$TEMPLATE_DIR/HANDOVER.md" ]; then
        cp "$TEMPLATE_DIR/HANDOVER.md" "$orchestra_dir/HANDOVER.md"
    fi

    # Clear INBOX processed messages (keep the file, clear processed section)
    if [ -f "$orchestra_dir/INBOX.md" ]; then
        sed -i '/^## Processed/,$d' "$orchestra_dir/INBOX.md"
        echo -e "\n## Processed\n" >> "$orchestra_dir/INBOX.md"
    fi

    # Clear session logs
    rm -f "$orchestra_dir/session-logs/"*.json 2>/dev/null || true

    # Optionally clear PLAN_FILE from config
    echo ""
    echo "Reset complete. Governance files (TODO, DECISIONS, CHANGELOG) untouched."
    echo "To start a new build phase, update PLAN_FILE in .orchestra/config."
}
```

- [ ] **Step 2: Delete `cmd_graduate` function** (lines 300-480)

- [ ] **Step 3: Update dispatch and usage**

Remove `graduate` from the case statement and usage function. Update reset description to show `--label` flag.

- [ ] **Step 4: Verify no syntax errors**

Run: `bash -n bin/orchestra`
Expected: clean parse

- [ ] **Step 5: Commit**

```bash
git add bin/orchestra
git commit -m "feat: simplify reset, remove graduate command"
```

### Task 7: Update `cmd_status` to read from config

**Files:**
- Modify: `bin/orchestra` (`cmd_status` function, lines 241-296)

- [ ] **Step 1: Rewrite `cmd_status`**

Read governance paths from config. Count T-numbered entries by status instead of checkbox format.

```bash
cmd_status() {
    local project_dir
    project_dir="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Not in a git repository"

    [ -d "$project_dir/.orchestra" ] || die ".orchestra/ not found. Run 'orchestra init' first."

    source "$LIB_DIR/config.sh"
    load_orchestra_config "$project_dir" || die "Failed to load .orchestra/config"

    echo "=== Orchestra v2 Status ==="
    echo ""

    # Tasks from config-mapped TODO
    if [ -f "$TODO_FILE" ]; then
        local total open in_progress complete blocked proposed
        total=$(grep -c '^### T[0-9]' "$TODO_FILE" 2>/dev/null) || total=0
        open=$(grep -c 'Status:.*OPEN' "$TODO_FILE" 2>/dev/null) || open=0
        in_progress=$(grep -c 'Status:.*IN_PROGRESS' "$TODO_FILE" 2>/dev/null) || in_progress=0
        complete=$(grep -c 'Status:.*COMPLETE' "$TODO_FILE" 2>/dev/null) || complete=0
        blocked=$(grep -c 'Status:.*BLOCKED' "$TODO_FILE" 2>/dev/null) || blocked=0
        proposed=$(grep -c 'Status:.*PROPOSED' "$TODO_FILE" 2>/dev/null) || proposed=0
        echo "Tasks: $complete/$total complete | $open open | $in_progress in progress | $blocked blocked | $proposed proposed"
    else
        echo "Tasks: (TODO file not found at $TODO_FILE)"
    fi

    # Decisions
    if [ -f "$DECISIONS_FILE" ]; then
        local d_count
        d_count=$(grep -c '^### D[0-9]' "$DECISIONS_FILE" 2>/dev/null) || d_count=0
        echo "Decisions: $d_count current"
    fi

    # Changelog
    if [ -f "$CHANGELOG_FILE" ]; then
        local c_count
        c_count=$(grep -c '^### C[0-9]' "$CHANGELOG_FILE" 2>/dev/null) || c_count=0
        echo "Changelog: $c_count current entries"
    fi

    # Sessions
    local session_count=0
    if [ -d "$project_dir/.orchestra/session-logs" ]; then
        session_count=$(ls "$project_dir/.orchestra/session-logs/"*.json 2>/dev/null | wc -l | tr -d ' ')
    fi
    echo "Sessions: $session_count logged"

    # Plan
    echo ""
    if [ -n "${PLAN_FILE:-}" ] && [ -f "$PLAN_FILE" ]; then
        echo "Plan: $PLAN_FILE"
        head -5 "$PLAN_FILE" | sed 's/^/  /'
    else
        echo "Plan: (not set)"
    fi

    # Last handover
    echo ""
    if [ -f "$project_dir/.orchestra/HANDOVER.md" ]; then
        echo "Last handover:"
        head -15 "$project_dir/.orchestra/HANDOVER.md" | sed 's/^/  /'
    fi
}
```

- [ ] **Step 2: Verify**

Run: `bash -n bin/orchestra`
Expected: clean parse

- [ ] **Step 3: Commit**

```bash
git add bin/orchestra
git commit -m "feat: update status command to read from config-mapped governance"
```

---

## Phase 3: Orchestrator Rewrite (session loop)

### Task 8: Update orchestrator pre-flight and config loading

**Files:**
- Modify: `lib/orchestrator.sh` (lines 43-83)

- [ ] **Step 1: Replace pre-flight section**

Replace the existing pre-flight checks (lines 49-83) with config-based checks:

```bash
# ─── Load config ────────────────────────────────────────────────────────────
SCRIPT_DIR_ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR_ORCH/config.sh"
load_orchestra_config "$PROJECT_DIR" || exit 1

# ─── Pre-flight checks ─────────────────────────────────────────────────────
if ! command -v claude &>/dev/null; then
    echo "ERROR: Claude Code CLI not found." >&2; exit 1
fi
if ! command -v jq &>/dev/null; then
    echo "ERROR: jq not found." >&2; exit 1
fi

preflight_check || exit 1
check_eligible_tasks || exit 1

# ─── Lockfile ───────────────────────────────────────────────────────────────
# Acquired here (after trap setup below) to ensure cleanup on any exit path.
LOCKFILE="$STATE_DIR/orchestra.lock"
cleanup_lock() { rm -f "$LOCKFILE"; }

if [ -f "$LOCKFILE" ]; then
    LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null)
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "ERROR: Another orchestrator is already running (PID $LOCK_PID)." >&2
        echo "If stale, delete $LOCKFILE" >&2
        exit 1
    else
        echo "WARNING: Stale lockfile (PID $LOCK_PID not running). Removing."
        rm -f "$LOCKFILE"
    fi
fi
echo $$ > "$LOCKFILE"
```

- [ ] **Step 2: Update the snapshot function to use config paths**

Replace `snapshot_state_files` to checksum governance files at config paths:

```bash
snapshot_state_files() {
    STATE_SNAPSHOT=""
    # Checksum governance files + HANDOVER (HANDOVER included for stall detection:
    # a session that only updates HANDOVER without touching governance is still progress)
    for f in "$TODO_FILE" "$DECISIONS_FILE" "$CHANGELOG_FILE" "$STATE_DIR/HANDOVER.md"; do
        if [ -f "$f" ]; then
            STATE_SNAPSHOT="$STATE_SNAPSHOT$(md5sum "$f")"
        fi
    done
    echo "$STATE_SNAPSHOT"
}
```

- [ ] **Step 3: Update recovery_commit to use config paths**

Replace the hardcoded `.orchestra/` state file staging with config-driven paths:

```bash
recovery_commit() {
    local session_num="$1"
    git add -u 2>/dev/null || true
    # Stage governance files from config paths
    for f in "$TODO_FILE" "$DECISIONS_FILE" "$CHANGELOG_FILE"; do
        [ -f "$f" ] && git add "$f" 2>/dev/null || true
    done
    # Stage operational files
    for f in HANDOVER.md INBOX.md; do
        [ -f "$STATE_DIR/$f" ] && git add "$STATE_DIR/$f" 2>/dev/null || true
    done
    if ! git diff --cached --quiet 2>/dev/null; then
        # --no-verify is intentional: recovery commits bypass hooks to avoid
        # recursive verification (verify-completion.sh would trigger on the commit)
        git commit -m "auto: recovery commit after session $session_num crash" --no-verify 2>/dev/null || true
        notify "Recovery commit saved work from crashed session $session_num"
        return 0
    fi
    return 1
}
```

- [ ] **Step 4: Update trap to include lockfile cleanup**

```bash
trap 'stop_ram_monitor; restore_settings; cleanup_lock' EXIT
```

- [ ] **Step 5: Verify syntax**

Run: `bash -n lib/orchestrator.sh`
Expected: clean parse

- [ ] **Step 6: Commit**

```bash
git add lib/orchestrator.sh
git commit -m "feat: update orchestrator pre-flight and config loading for v2"
```

### Task 9: Rewrite session prompts

**Files:**
- Modify: `lib/orchestrator.sh` (lines 169-326, SESSION_PROMPT and RECOVERY_PROMPT)

This is the heart of v2. The session prompt encodes the three-tier planning model, task loop, codewriting loop, governance protocols, and ubiquitous language.

- [ ] **Step 1: Write the new SESSION_PROMPT**

Replace the entire `SESSION_PROMPT` variable (lines 175-255) with the v2 prompt. The prompt must include:

1. Identity and governance reading sequence
2. Ubiquitous language (key terms only — the full table is too long; include the 10 most critical terms)
3. Task loop: pick OPEN task → tier check → decompose or execute → governance update → INBOX check → capacity check
4. Codewriting loop: generate AC → write → code review → conditional 2nd pass → UI test → debug (max 3)
5. Quality gates: decomposition review (max 2 retries) + plan coherence check
6. State file update instructions with T/D/C numbering
7. Exit signals: HANDOVER, COMPLETE, BLOCKED
8. Model:effort recommendation (default opus:high)

The prompt should reference `.orchestra/config` paths rather than hardcoded `.orchestra/` files. Include instructions to read the toolchain file and standing AC file.

Full prompt is ~200 lines. Write it completely — no placeholders.

- [ ] **Step 2: Write the new RECOVERY_PROMPT**

Replace the RECOVERY_PROMPT (lines 258-326) with the v2 version that prepends damage assessment:

1. Check build state (run build command from toolchain)
2. Check governance file consistency
3. Check git status for uncommitted work
4. For IN_PROGRESS tasks: inspect actual file state before deciding redo vs continue
5. Then enter the normal task loop

- [ ] **Step 3: Verify the prompts parse cleanly in bash**

Run: `bash -n lib/orchestrator.sh`
Expected: clean parse (watch for unescaped single quotes in heredocs)

- [ ] **Step 4: Commit**

```bash
git add lib/orchestrator.sh
git commit -m "feat: rewrite session prompts for v2 three-tier planning"
```

### Task 10: Update model selection and crash recovery logic

**Files:**
- Modify: `lib/orchestrator.sh` (lines 403-485)

- [ ] **Step 1: Update model selection to parse `model:effort` format**

Replace the model selection block (lines 403-423) with:

```bash
# ─── Model selection ─────────────────────────────────────────────────────
# Read model:effort recommendation from HANDOVER.md
# v2 DEFAULT: opus:high (v1 defaulted to sonnet). Only downgrade for
# explicitly mechanical tasks. See spec section 2, "Model Recommendation".
RECOMMENDED_MODEL="opus"
RECOMMENDED_EFFORT="high"

if [ -f "$STATE_DIR/HANDOVER.md" ]; then
    REC_LINE=$(grep -i 'model recommendation' "$STATE_DIR/HANDOVER.md" | tail -1 || echo "")
    if echo "$REC_LINE" | grep -qi 'sonnet'; then
        RECOMMENDED_MODEL="sonnet"
    fi
    if echo "$REC_LINE" | grep -qi 'standard'; then
        RECOMMENDED_EFFORT="standard"
    fi
fi

# First session override via env var
if [ "$SESSION_COUNT" -eq 1 ] && [ -n "${INITIAL_MODEL:-}" ]; then
    RECOMMENDED_MODEL="${INITIAL_MODEL}"
    notify "   Model: ${INITIAL_MODEL} (INITIAL_MODEL override)"
fi

MODEL_FLAG="--model ${RECOMMENDED_MODEL}"
EFFORT_FLAG="--effort ${RECOMMENDED_EFFORT}"
notify "   Model: ${RECOMMENDED_MODEL}:${RECOMMENDED_EFFORT}"
```

Also update the `claude -p` invocation (around line 430 of orchestrator.sh) to include both flags:

```bash
claude -p "$CURRENT_PROMPT" \
    $MODEL_FLAG \
    $EFFORT_FLAG \
    --output-format stream-json \
    --verbose \
    --dangerously-skip-permissions \
    2>&1 | tee "$SESSION_LOG" \
    ...
```

- [ ] **Step 2: Invert crash recovery logic**

Replace the crash handling block (lines 446-484). Key change: governance files changed → recovery prompt (not normal).

```bash
if [ $EXIT_CODE -ne 0 ]; then
    CONSECUTIVE_CRASHES=$((CONSECUTIVE_CRASHES + 1))
    TOTAL_CRASHES=$((TOTAL_CRASHES + 1))
    notify "Session $SESSION_COUNT crashed (exit $EXIT_CODE). Consecutive: $CONSECUTIVE_CRASHES/$MAX_CONSECUTIVE_CRASHES"

    if state_files_changed "$PRE_STATE"; then
        # v2 INVERSION: v1 treated governance-changed as safe (USE_RECOVERY_PROMPT=false).
        # v2 treats it as needing damage assessment because governance may be
        # half-written (e.g. task set to IN_PROGRESS but not completed). See spec 6.3.
        notify "   Governance files changed — partial state, recovery needed"
        recovery_commit "$SESSION_COUNT"
        USE_RECOVERY_PROMPT=true
    else
        STAGED_COUNT=$(git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
        MODIFIED_COUNT=$(git diff --name-only 2>/dev/null | wc -l | tr -d ' ')
        if [ "$STAGED_COUNT" -gt 0 ] || [ "$MODIFIED_COUNT" -gt 0 ]; then
            notify "   Code files modified without governance update — recovery needed"
            recovery_commit "$SESSION_COUNT"
            USE_RECOVERY_PROMPT=true
        else
            # Nothing changed — session died before acting
            notify "   No work detected — using normal prompt"
            USE_RECOVERY_PROMPT=false
        fi
    fi

    if [ "$CONSECUTIVE_CRASHES" -ge "$MAX_CONSECUTIVE_CRASHES" ]; then
        notify "$MAX_CONSECUTIVE_CRASHES consecutive crashes. Stopping."
        exit 1
    fi

    notify "   Retrying in ${CRASH_COOLDOWN_SECONDS}s..."
    sleep "$CRASH_COOLDOWN_SECONDS"
    continue
fi
```

- [ ] **Step 3: Update the COMPLETE detection to use T-numbers instead of checkboxes**

Replace the `grep -c '^\- \[ \]'` patterns (lines 516, 532, 545) with:

```bash
REMAINING=$(grep -c 'Status:.*OPEN' "$TODO_FILE" 2>/dev/null) || REMAINING=0
```

- [ ] **Step 4: Verify syntax**

Run: `bash -n lib/orchestrator.sh`
Expected: clean parse

- [ ] **Step 5: Commit**

```bash
git add lib/orchestrator.sh
git commit -m "feat: update model selection, crash recovery, and task detection for v2"
```

---

## Phase 4: Hook Updates

### Task 11: Update verify-completion.sh

**Files:**
- Modify: `lib/verify-completion.sh`

- [ ] **Step 1: Update to read config and check T/D/C entries**

Add config loading at the top (after the guard):

```bash
SCRIPT_DIR_HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR_HOOK/config.sh" ]; then
    source "$SCRIPT_DIR_HOOK/config.sh"
    load_orchestra_config "$PROJECT_DIR" 2>/dev/null || true
fi
```

Update the TODO_CONTENT gathering to read from config path:

```bash
if [ -n "${TODO_FILE:-}" ] && [ -f "$TODO_FILE" ]; then
    TODO_CONTENT=$(head -100 "$TODO_FILE")
fi
```

Update the verification prompt to check for T-numbered status changes and C-numbered entries rather than checkbox format.

- [ ] **Step 2: Verify syntax**

Run: `bash -n lib/verify-completion.sh && shellcheck lib/verify-completion.sh`

- [ ] **Step 3: Commit**

```bash
git add lib/verify-completion.sh
git commit -m "feat: update verify-completion to check T/D/C numbered governance"
```

### Task 12: Update commit-and-update.sh

**Files:**
- Modify: `lib/commit-and-update.sh`

- [ ] **Step 1: Rewrite the complete `commit-and-update.sh`**

Replace the entire file. Key change: single commit for code + governance (v1 made two separate commits).

```bash
#!/bin/bash
# commit-and-update.sh — Stop hook (v2)
# Fires when Claude finishes responding. Makes a single commit
# containing both code changes and governance file updates.

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_DIR="${STATE_DIR:-${PROJECT_DIR}/.orchestra}"
SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cd "$PROJECT_DIR"

# Load config for governance file paths
SCRIPT_DIR_HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR_HOOK/config.sh" ]; then
    source "$SCRIPT_DIR_HOOK/config.sh"
    load_orchestra_config "$PROJECT_DIR" 2>/dev/null || true
fi

# Stage governance files from config paths
for gov_file in "${TODO_FILE:-}" "${DECISIONS_FILE:-}" "${CHANGELOG_FILE:-}"; do
    if [ -n "$gov_file" ] && [ -f "$gov_file" ]; then
        git diff --quiet "$gov_file" 2>/dev/null || git add "$gov_file" 2>/dev/null || true
    fi
done

# Stage operational files
for op_file in HANDOVER.md INBOX.md; do
    if [ -f "$STATE_DIR/$op_file" ]; then
        git diff --quiet "$STATE_DIR/$op_file" 2>/dev/null || git add "$STATE_DIR/$op_file" 2>/dev/null || true
    fi
done

# Single commit: code + governance together
if ! git diff --cached --quiet 2>/dev/null; then
    CHANGED_FILES=$(git diff --cached --name-only | head -20)
    FILE_COUNT=$(git diff --cached --name-only | wc -l | tr -d ' ')

    # Read Claude-generated commit message, fall back to generic
    TASK_SUMMARY=""
    if [ -f "$STATE_DIR/COMMIT_MSG" ]; then
        TASK_SUMMARY=$(head -c 68 "$STATE_DIR/COMMIT_MSG" | tr -d '\n')
    fi
    [ -z "$TASK_SUMMARY" ] && TASK_SUMMARY="session update ($FILE_COUNT files)"

    COMMIT_MSG="auto: $TASK_SUMMARY

Session: $SESSION_ID
Time: $TIMESTAMP
Files changed: $FILE_COUNT
$CHANGED_FILES"

    # --no-verify: avoid recursive hook invocation
    git commit -m "$COMMIT_MSG" --no-verify 2>/dev/null || true
fi

# Clean up COMMIT_MSG (per-session, not persistent)
rm -f "$STATE_DIR/COMMIT_MSG"

exit 0
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n lib/commit-and-update.sh`

- [ ] **Step 3: Commit**

```bash
git add lib/commit-and-update.sh
git commit -m "feat: update commit hook to stage governance from config paths"
```

---

## Phase 5: Template Cleanup & Documentation

### Task 13: Remove obsolete templates and update docs

**Files:**
- Delete: `templates/TODO.md`, `templates/PLAN.md`, `templates/DECISIONS.md`, `templates/CHANGELOG.md`, `templates/CHANGELOG-fresh.md`
- Delete: `templates/docs/` (entire directory)
- Modify: `templates/CLAUDE-workflow.md`
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Delete obsolete template files**

```bash
rm templates/TODO.md templates/PLAN.md templates/DECISIONS.md templates/CHANGELOG.md templates/CHANGELOG-fresh.md
rm -rf templates/docs/
```

- [ ] **Step 2: Rewrite `templates/CLAUDE-workflow.md`**

Replace with the v2 workflow section covering: three-tier planning, governance protocols (T/D/C), task loop, codewriting loop, ubiquitous language reference, and exit signals.

- [ ] **Step 3: Update `README.md`**

Remove graduate documentation. Update init/run/reset/status descriptions. Add v2 overview. Reference the spec and visual flow docs.

- [ ] **Step 4: Update `CLAUDE.md`**

Rewrite with v2 ubiquitous language, updated file structure, and v2 workflow reference.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "docs: remove obsolete templates, update README and CLAUDE.md for v2"
```

---

## Phase 6: Integration Test

### Task 14: End-to-end smoke test

- [ ] **Step 1: Test greenfield init**

```bash
mkdir /tmp/e2e-test && cd /tmp/e2e-test && git init
orchestra init
# Verify: .orchestra/config exists, governance dirs created, templates populated
cat .orchestra/config
ls TODO/ Decisions/ Changelog/
```

- [ ] **Step 2: Set up a plan and run pre-flight**

```bash
echo "# Test Plan" > .claude/plans/test.md
echo "## Goal\nSmoke test" >> .claude/plans/test.md
# Update config
sed -i 's|^PLAN_FILE=.*|PLAN_FILE=.claude/plans/test.md|' .orchestra/config

# Add a task
cat >> TODO/TODO.md << 'EOF'

### T001: Smoke test task
- **Status:** OPEN
- **Tier:** 1
- **Added:** 2026-03-25
- **Detail:** Verify orchestra v2 runs end-to-end.
EOF

orchestra status
```

Expected: status shows 1 task, 0 complete, plan path displayed.

- [ ] **Step 3: Verify pre-flight catches missing toolchain/AC**

```bash
# toolchain.md and standing-ac.md are templates — should have content
orchestra run
```

Expected: either passes pre-flight (templates have content) or fails with specific error.

- [ ] **Step 4: Clean up**

```bash
rm -rf /tmp/e2e-test /tmp/test-init /tmp/test-inherit
```

- [ ] **Step 5: Commit any fixes discovered during testing**

```bash
git add -A
git commit -m "fix: address issues found during end-to-end smoke test"
```

---

## Summary

| Phase | Tasks | Description |
|---|---|---|
| 1 | 1-3 | Config reader, governance templates, toolchain/AC templates |
| 2 | 4-7 | CLI: init (governance scanning), run (pre-flight), reset (simplified), status (config-mapped) |
| 3 | 8-10 | Orchestrator: config loading, session prompts, model selection, crash recovery |
| 4 | 11-12 | Hooks: verify-completion, commit-and-update |
| 5 | 13 | Template cleanup, README, CLAUDE.md |
| 6 | 14 | End-to-end smoke test |

Total: 14 tasks. Estimated: 4-6 sessions at opus:high.
