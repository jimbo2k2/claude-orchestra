# Orchestra Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite claude-orchestra as a session-orchestration runtime per spec `2026-04-29-orchestra-cleanup-design.md`, dropping all opinions on parent-project governance/protocol/toolchain while introducing canonical per-run governance, agent-driven wind-down, and a markdown-format CONFIG parser.

**Architecture:** Bash-based runtime, project-local install (no global). Each `orchestra run` creates a worktree + run-branch + tmux session. Sessions write to numbered files under `<worktree>/.orchestra/runs/<run>/`. On `COMPLETE`, a wind-down session ingests run governance into parent project intelligently and merges to the base branch.

**Tech Stack:** Bash (POSIX-leaning), git, tmux, jq, inotify-tools (Linux-only).

---

## Phase 0 — Pre-flight setup

**Goal:** Establish a clean working branch and confirm dependencies.

**Files:** none (environment only)

- [ ] **Step 1: Create feature branch from main**

```bash
cd /home/james/projects/claude-orchestra
git checkout main
git pull origin main
git checkout -b orchestra-cleanup-rewrite
```

- [ ] **Step 2: Verify required dependencies are installed**

Run:
```bash
which bash git tmux jq inotifywait
```
Expected: all five paths printed. If `inotifywait` is missing:
```bash
sudo apt-get install inotify-tools
```

- [ ] **Step 3: Create `tests/` directory at repo root**

Run:
```bash
mkdir -p tests
```

- [ ] **Step 4: Write a minimal test runner script**

Create `tests/run-tests.sh`:
```bash
#!/bin/bash
# Run all test_*.sh files in tests/, report pass/fail counts, exit non-zero on any failure.
set -u
cd "$(dirname "$0")"

passed=0
failed=0
failed_names=()

for test in test_*.sh; do
    [ -f "$test" ] || continue
    if bash "$test" >/dev/null 2>&1; then
        passed=$((passed + 1))
        echo "  PASS: $test"
    else
        failed=$((failed + 1))
        failed_names+=("$test")
        echo "  FAIL: $test"
    fi
done

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
```

```bash
chmod +x tests/run-tests.sh
```

- [ ] **Step 5: Commit**

```bash
git add tests/
git commit -m "test: add minimal bash test runner"
```

---

## Phase 1 — CONFIG.md parser (foundation)

**Goal:** Implement a markdown-format config parser per spec Section 10. This is foundational for everything else.

**Files:**
- Create: `lib/config.sh`
- Create: `tests/test_config_parser.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_config_parser.sh`:
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Test: parser extracts KEY: VALUE pairs from markdown bullets, ignoring prose.

source lib/config.sh

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

cat > "$TMP/CONFIG.md" <<'EOF'
# Test Config

Some prose to ignore.

## Section
- `MAX_SESSIONS`: 5
- `MODEL`: opus
- `WORKTREE_BASE`: /tmp/orch
- `BASE_BRANCH`: main
- `MAX_CONSECUTIVE_CRASHES`: 3
EOF

declare -gA ORCHESTRA_CONFIG
parse_config_md "$TMP/CONFIG.md"

[ "${ORCHESTRA_CONFIG[MAX_SESSIONS]}" = "5" ] || { echo "MAX_SESSIONS"; exit 1; }
[ "${ORCHESTRA_CONFIG[MODEL]}" = "opus" ] || { echo "MODEL"; exit 1; }
[ "${ORCHESTRA_CONFIG[WORKTREE_BASE]}" = "/tmp/orch" ] || { echo "WORKTREE_BASE"; exit 1; }
[ "${ORCHESTRA_CONFIG[BASE_BRANCH]}" = "main" ] || { echo "BASE_BRANCH"; exit 1; }

echo "OK"
```

```bash
chmod +x tests/test_config_parser.sh
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bash tests/test_config_parser.sh
```
Expected: FAIL (`lib/config.sh` doesn't exist).

- [ ] **Step 3: Write minimal `lib/config.sh` parser**

Create `lib/config.sh`:
```bash
#!/bin/bash
# CONFIG.md parser — extracts KEY: VALUE bullets from markdown.
# Spec: docs/superpowers/specs/2026-04-29-orchestra-cleanup-design.md Section 10.
# Values are stored verbatim in ORCHESTRA_CONFIG associative array; never eval'd.

# Parse markdown bullet lines of the form `- \`KEY\`: VALUE` into ORCHESTRA_CONFIG.
# Caller MUST declare `declare -gA ORCHESTRA_CONFIG` before calling.
# Errors abort with non-zero exit and a message to stderr.
parse_config_md() {
    local file="$1"
    [ -f "$file" ] || { echo "ERROR: config file not found: $file" >&2; return 1; }

    local line key value
    local -A seen=()
    local re='^[[:space:]]*-[[:space:]]+`([A-Z_][A-Z0-9_]*)`:[[:space:]]*(.+)$'

    while IFS= read -r line; do
        if [[ "$line" =~ $re ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            # Trim trailing whitespace
            value="${value%"${value##*[![:space:]]}"}"

            if [ -n "${seen[$key]:-}" ]; then
                echo "ERROR: duplicate key '$key' in $file" >&2
                return 1
            fi
            seen[$key]=1
            ORCHESTRA_CONFIG[$key]="$value"
        fi
    done < "$file"

    return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/test_config_parser.sh
```
Expected: prints `OK`, exit 0.

- [ ] **Step 5: Add validation tests for required keys, types, and constraints**

Append to `tests/test_config_parser.sh`:
```bash
# Test: missing required key fails
cat > "$TMP/bad1.md" <<'EOF'
- `MODEL`: opus
EOF
unset ORCHESTRA_CONFIG
declare -gA ORCHESTRA_CONFIG
if validate_config "$TMP/bad1.md" 2>/dev/null; then
    echo "expected validation failure for missing required keys"
    exit 1
fi

# Test: invalid model enum fails
cat > "$TMP/bad2.md" <<'EOF'
- `MAX_SESSIONS`: 5
- `MAX_CONSECUTIVE_CRASHES`: 3
- `MODEL`: gpt4
- `WORKTREE_BASE`: /tmp/orch
- `BASE_BRANCH`: main
EOF
unset ORCHESTRA_CONFIG
declare -gA ORCHESTRA_CONFIG
parse_config_md "$TMP/bad2.md"
if validate_config 2>/dev/null; then
    echo "expected validation failure for invalid MODEL"
    exit 1
fi

# Test: duplicate key fails
cat > "$TMP/bad3.md" <<'EOF'
- `MAX_SESSIONS`: 5
- `MAX_SESSIONS`: 7
EOF
unset ORCHESTRA_CONFIG
declare -gA ORCHESTRA_CONFIG
if parse_config_md "$TMP/bad3.md" 2>/dev/null; then
    echo "expected duplicate-key failure"
    exit 1
fi

echo "OK"
```

- [ ] **Step 6: Add `validate_config()` to `lib/config.sh`**

Append to `lib/config.sh`:
```bash
# Validate ORCHESTRA_CONFIG has required keys with correct types per spec Section 10.
# Apply defaults for optional keys if not set.
# Returns non-zero on any validation failure with a message to stderr.
validate_config() {
    local required=(MAX_SESSIONS MAX_CONSECUTIVE_CRASHES MODEL WORKTREE_BASE BASE_BRANCH)
    local k
    for k in "${required[@]}"; do
        if [ -z "${ORCHESTRA_CONFIG[$k]:-}" ]; then
            echo "ERROR: required config key '$k' is missing" >&2
            return 1
        fi
    done

    # Type checks per spec table
    _check_int_min MAX_SESSIONS 1 || return 1
    _check_int_min MAX_CONSECUTIVE_CRASHES 1 || return 1
    _check_int_min MAX_HANG_SECONDS 60 || return 1
    _check_enum MODEL opus sonnet haiku || return 1
    _check_enum EFFORT low medium high || return 1
    _check_abspath WORKTREE_BASE || return 1
    _check_nonempty BASE_BRANCH || return 1
    _check_pattern TMUX_PREFIX '^[a-z][a-z0-9-]*$' || return 1
    _check_bool QUOTA_PACING || return 1
    _check_int_range QUOTA_THRESHOLD 1 100 || return 1
    _check_int_min QUOTA_POLL_INTERVAL 30 || return 1
    _check_int_min COOLDOWN_SECONDS 0 || return 1
    _check_int_min CRASH_COOLDOWN_SECONDS 0 || return 1
    _check_int_min SMOKE_TEST_TIMEOUT 60 || return 1

    return 0
}

# Apply defaults for optional keys (call after parse, before validate).
apply_config_defaults() {
    : "${ORCHESTRA_CONFIG[MAX_HANG_SECONDS]:=1200}"
    : "${ORCHESTRA_CONFIG[EFFORT]:=high}"
    : "${ORCHESTRA_CONFIG[TMUX_PREFIX]:=orchestra}"
    : "${ORCHESTRA_CONFIG[QUOTA_PACING]:=true}"
    : "${ORCHESTRA_CONFIG[QUOTA_THRESHOLD]:=80}"
    : "${ORCHESTRA_CONFIG[QUOTA_POLL_INTERVAL]:=120}"
    : "${ORCHESTRA_CONFIG[COOLDOWN_SECONDS]:=15}"
    : "${ORCHESTRA_CONFIG[CRASH_COOLDOWN_SECONDS]:=30}"
    : "${ORCHESTRA_CONFIG[SMOKE_TEST_TIMEOUT]:=900}"
}

# --- internal validation helpers ---
_check_int_min() {
    local k="$1" min="$2" v="${ORCHESTRA_CONFIG[$1]:-}"
    [ -z "$v" ] && return 0  # optional key not set, skip
    if ! [[ "$v" =~ ^[0-9]+$ ]] || [ "$v" -lt "$min" ]; then
        echo "ERROR: config key '$k'=$v must be an integer >= $min" >&2
        return 1
    fi
}

_check_int_range() {
    local k="$1" lo="$2" hi="$3" v="${ORCHESTRA_CONFIG[$1]:-}"
    [ -z "$v" ] && return 0
    if ! [[ "$v" =~ ^[0-9]+$ ]] || [ "$v" -lt "$lo" ] || [ "$v" -gt "$hi" ]; then
        echo "ERROR: config key '$k'=$v must be an integer in [$lo,$hi]" >&2
        return 1
    fi
}

_check_enum() {
    local k="$1"; shift
    local v="${ORCHESTRA_CONFIG[$k]:-}"
    [ -z "$v" ] && return 0
    local opt
    for opt in "$@"; do
        [ "$v" = "$opt" ] && return 0
    done
    echo "ERROR: config key '$k'=$v must be one of: $*" >&2
    return 1
}

_check_abspath() {
    local k="$1" v="${ORCHESTRA_CONFIG[$1]:-}"
    [ -z "$v" ] && return 0
    if [[ "$v" != /* ]]; then
        echo "ERROR: config key '$k'=$v must be an absolute path" >&2
        return 1
    fi
}

_check_nonempty() {
    local k="$1" v="${ORCHESTRA_CONFIG[$1]:-}"
    if [ -z "$v" ]; then
        echo "ERROR: config key '$k' must not be empty" >&2
        return 1
    fi
}

_check_pattern() {
    local k="$1" pat="$2" v="${ORCHESTRA_CONFIG[$1]:-}"
    [ -z "$v" ] && return 0
    if ! [[ "$v" =~ $pat ]]; then
        echo "ERROR: config key '$k'=$v must match pattern $pat" >&2
        return 1
    fi
}

_check_bool() {
    local k="$1" v="${ORCHESTRA_CONFIG[$1]:-}"
    [ -z "$v" ] && return 0
    if [ "$v" != "true" ] && [ "$v" != "false" ]; then
        echo "ERROR: config key '$k'=$v must be 'true' or 'false'" >&2
        return 1
    fi
}
```

- [ ] **Step 7: Update test to call `apply_config_defaults` between parse and validate, run, verify pass**

Edit the validation test block in `tests/test_config_parser.sh` to call `apply_config_defaults` before `validate_config`.

```bash
bash tests/test_config_parser.sh
```
Expected: `OK`, exit 0.

- [ ] **Step 8: Commit**

```bash
git add lib/config.sh tests/test_config_parser.sh
git commit -m "feat(config): markdown CONFIG.md parser with type validation"
```

---

## Phase 2 — CLI dispatcher skeleton

**Goal:** A working `orchestra` CLI that dispatches to subcommand stubs.

**Files:**
- Create: `bin/orchestra` (rewrite — current ~28KB version stays in git history; new file is a fresh CLI)
- Create: `tests/test_cli_dispatch.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_cli_dispatch.sh`:
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Test: orchestra prints usage on no args; dispatches to known subcommands.

out=$(./bin/orchestra 2>&1) || true
echo "$out" | grep -q "Usage:" || { echo "missing Usage"; exit 1; }
echo "$out" | grep -q "init" || { echo "missing init in usage"; exit 1; }
echo "$out" | grep -q "run" || { echo "missing run in usage"; exit 1; }
echo "$out" | grep -q "status" || { echo "missing status in usage"; exit 1; }
echo "$out" | grep -q "test" || { echo "missing test in usage"; exit 1; }
echo "$out" | grep -q "reset" || { echo "missing reset in usage"; exit 1; }

# Unknown subcommand should error
if ./bin/orchestra bogus 2>/dev/null; then
    echo "expected error on unknown subcommand"
    exit 1
fi

echo "OK"
```

```bash
chmod +x tests/test_cli_dispatch.sh
```

- [ ] **Step 2: Run test, verify it fails**

```bash
bash tests/test_cli_dispatch.sh
```
Expected: FAIL (`bin/orchestra` doesn't exist or is the old version).

- [ ] **Step 3: Rewrite `bin/orchestra` as a minimal dispatcher**

Overwrite `bin/orchestra`:
```bash
#!/bin/bash
# orchestra — CLI for managing autonomous Claude Code workflows.
# Spec: docs/superpowers/specs/2026-04-29-orchestra-cleanup-design.md
#
# Subcommands:
#   init     — Scaffold .orchestra/ in current dir
#   run      — Start an orchestra run
#   status   — Show current run state
#   test     — Run smoke test
#   reset    — Archive in-progress run state and reset
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

usage() {
    cat <<EOF
Usage: orchestra <command> [args]

Commands:
  init [dir]   Scaffold .orchestra/ state files in target directory
  run          Start an orchestra run (uses .orchestra/CONFIG.md + OBJECTIVE.md)
  status       Show current run state
  test         Run end-to-end smoke test
  reset        Archive current run state, reset for next

All run parameters live in .orchestra/CONFIG.md — no env vars, no CLI args.
EOF
}

die() { echo "ERROR: $1" >&2; exit 1; }

cmd_init()   { die "init not yet implemented (Phase 3)"; }
cmd_run()    { die "run not yet implemented (Phase 4)"; }
cmd_status() { die "status not yet implemented (Phase 16)"; }
cmd_test()   { die "test not yet implemented (Phase 11)"; }
cmd_reset()  { die "reset not yet implemented (Phase 16)"; }

cmd="${1:-}"
shift 2>/dev/null || true
case "$cmd" in
    init)   cmd_init "$@" ;;
    run|start) cmd_run "$@" ;;
    status) cmd_status "$@" ;;
    test)   cmd_test "$@" ;;
    reset)  cmd_reset "$@" ;;
    -h|--help|help|"") usage; exit 0 ;;
    *) echo "Unknown command: $cmd" >&2; usage >&2; exit 1 ;;
esac
```

```bash
chmod +x bin/orchestra
```

- [ ] **Step 4: Run test, verify pass**

```bash
bash tests/test_cli_dispatch.sh
```
Expected: `OK`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add bin/orchestra tests/test_cli_dispatch.sh
git commit -m "feat(cli): rewrite orchestra dispatcher with subcommand stubs"
```

---

## Phase 3 — `orchestra init`

**Goal:** Implement the simplified init per spec Section 12.

**Files:**
- Modify: `bin/orchestra`
- Create: `templates/CONFIG.md`
- Create: `templates/OBJECTIVE.md`
- Create: `templates/orchestra-CLAUDE.md`
- Create: `tests/test_init.sh`

- [ ] **Step 1: Write `templates/CONFIG.md`** (per spec Section 10 example, with prose explaining each section)

Create `templates/CONFIG.md` with the literal example from spec Section 10 plus header text noting that values can be edited but the bullet format must be preserved.

- [ ] **Step 2: Write `templates/OBJECTIVE.md`** (placeholder run brief)

Create `templates/OBJECTIVE.md`:
```markdown
# Run Objective

Replace this file's contents with a clear brief for the next orchestra run.

A good objective:
- States the goal in one paragraph
- References any specs, plans, or design docs the agent should read
- Calls out non-goals or out-of-scope items if any
- Notes any constraints (time, scope, dependencies)

Commit this file to your `BASE_BRANCH` before running `orchestra run`.
```

- [ ] **Step 3: Write `templates/orchestra-CLAUDE.md`** (agent-facing setup/invocation guidance per spec Section 9)

Create `templates/orchestra-CLAUDE.md` with sections:
- One-paragraph orchestra overview + run/session vocabulary
- Invocation: `.orchestra/runtime/bin/orchestra run|status|test`, alias suggestion
- How to prepare `OBJECTIVE.md`: free-form markdown referencing specs/plans, must be committed before run
- Reading run output: pointer to `<worktree>/.orchestra/runs/<run>/` numbered files and what each contains
- Wind-down behaviour summary: ingestion, archive, `WIND-DOWN-FAILED`/`BLOCKED` markers
- Migration: pointer to `MIGRATION.md` in orchestra source repo

- [ ] **Step 4: Write the failing test**

Create `tests/test_init.sh`:
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="$(pwd)"
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

cd "$TMP"
git init -q

# Run init
"$REPO/bin/orchestra" init . 2>&1

# Assertions
[ -d .orchestra/runtime/bin ] || { echo "missing runtime/bin"; exit 1; }
[ -d .orchestra/runtime/lib ] || { echo "missing runtime/lib"; exit 1; }
[ -d .orchestra/runs/archive ] || { echo "missing runs/archive"; exit 1; }
[ -x .orchestra/runtime/bin/orchestra ] || { echo "orchestra not executable"; exit 1; }
[ -x .orchestra/runtime/bin/orchestrator.sh ] || { echo "orchestrator.sh not executable (skipped if not yet created)"; }
[ -f .orchestra/runtime/lib/config.sh ] || { echo "config.sh missing"; exit 1; }
[ -f .orchestra/CONFIG.md ] || { echo "CONFIG.md missing"; exit 1; }
[ -f .orchestra/OBJECTIVE.md ] || { echo "OBJECTIVE.md missing"; exit 1; }
[ -f .orchestra/CLAUDE.md ] || { echo "CLAUDE.md missing"; exit 1; }

# Init must NOT create governance dirs or settings.json
[ ! -d TODO ] || { echo "TODO/ should not be created"; exit 1; }
[ ! -d Decisions ] || { echo "Decisions/ should not be created"; exit 1; }
[ ! -d Changelog ] || { echo "Changelog/ should not be created"; exit 1; }
[ ! -f .claude/settings.json ] || { echo ".claude/settings.json should not be created"; exit 1; }
[ ! -f DEVELOPMENT-PROTOCOL.md ] || { echo "DEVELOPMENT-PROTOCOL.md should not be created"; exit 1; }

# Re-run init: should not overwrite existing files
echo "MODIFIED" > .orchestra/CONFIG.md
"$REPO/bin/orchestra" init . 2>&1
[ "$(cat .orchestra/CONFIG.md)" = "MODIFIED" ] || { echo "CONFIG.md was overwritten"; exit 1; }

# Init outside a git repo: must error, not silently git init
TMP2=$(mktemp -d)
trap "rm -rf $TMP $TMP2" EXIT
cd "$TMP2"
if "$REPO/bin/orchestra" init . 2>/dev/null; then
    echo "expected error when target is not a git repo"
    exit 1
fi

# inotify-tools preflight: skip in test if installed; orchestra init should error if not.
# (Cannot easily test the missing-dep path without uninstalling. Defer to integration manual check.)

echo "OK"
```

```bash
chmod +x tests/test_init.sh
```

- [ ] **Step 5: Run test, verify it fails**

```bash
bash tests/test_init.sh
```
Expected: FAIL (init not implemented).

- [ ] **Step 6: Implement `cmd_init` in `bin/orchestra`**

Replace `cmd_init() { die "init not yet implemented..."; }` with:
```bash
cmd_init() {
    local target="${1:-.}"
    target="$(cd "$target" 2>/dev/null && pwd)" || die "Directory does not exist: ${1:-.}"

    # Must be a git repo (no auto-init per spec Section 12 step 2)
    git -C "$target" rev-parse --show-toplevel >/dev/null 2>&1 \
        || die "$target is not a git repository. If this is intentional, run 'git init' first then retry."

    # inotify-tools preflight (Linux-only target per spec)
    command -v inotifywait >/dev/null 2>&1 \
        || die "inotify-tools not installed — run 'apt-get install inotify-tools' (Ubuntu/Debian) or your distro's equivalent"

    local orch="$target/.orchestra"
    mkdir -p "$orch/runtime/bin" "$orch/runtime/lib" "$orch/runs/archive"

    # Copy runtime
    cp "$SCRIPT_DIR/orchestra"          "$orch/runtime/bin/orchestra"
    [ -f "$SCRIPT_DIR/orchestrator.sh" ] && cp "$SCRIPT_DIR/orchestrator.sh" "$orch/runtime/bin/orchestrator.sh"
    cp "$LIB_DIR/config.sh"             "$orch/runtime/lib/config.sh"
    chmod +x "$orch/runtime/bin/orchestra"
    [ -f "$orch/runtime/bin/orchestrator.sh" ] && chmod +x "$orch/runtime/bin/orchestrator.sh"

    # Copy templates only if missing — do not overwrite
    local TEMPLATE_DIR="$SCRIPT_DIR/../templates"
    for pair in "CONFIG.md:CONFIG.md" "OBJECTIVE.md:OBJECTIVE.md" "orchestra-CLAUDE.md:CLAUDE.md"; do
        local src="${pair%:*}" dst="${pair#*:}"
        if [ ! -f "$orch/$dst" ]; then
            cp "$TEMPLATE_DIR/$src" "$orch/$dst"
            echo "  Created .orchestra/$dst"
        else
            echo "  Skipped .orchestra/$dst (already exists)"
        fi
    done

    cat <<EOF

Done. Next steps:
  1. Edit .orchestra/CONFIG.md — set MAX_SESSIONS, MODEL, WORKTREE_BASE, BASE_BRANCH
  2. Edit .orchestra/OBJECTIVE.md with the brief for your first run
  3. Commit .orchestra/CONFIG.md and .orchestra/OBJECTIVE.md to your base branch
  4. Run: .orchestra/runtime/bin/orchestra run
EOF
}
```

- [ ] **Step 7: Run test, verify pass**

```bash
bash tests/test_init.sh
```
Expected: `OK`, exit 0.

- [ ] **Step 8: Commit**

```bash
git add bin/orchestra templates/ tests/test_init.sh
git commit -m "feat(init): minimal scaffold without governance opinions"
```

---

## Phase 4 — Run lifecycle scaffold (atomic mkdir + worktree + tmux)

**Goal:** `orchestra run` reaches the point of launching a tmux session in a worktree, but with a no-op orchestrator session that exits immediately.

**Files:**
- Create: `bin/orchestrator.sh`
- Modify: `bin/orchestra` (`cmd_run` body)
- Create: `tests/test_run_lifecycle.sh`

- [ ] **Step 1: Write `bin/orchestrator.sh` as a no-op stub**

Create `bin/orchestrator.sh`:
```bash
#!/bin/bash
# orchestrator.sh — invoked inside the run worktree's tmux session.
# Reads run state from $RUN_DIR (set by parent orchestra invocation).
# Phase 4: just touches a marker file and exits cleanly.
set -euo pipefail

: "${RUN_DIR:?RUN_DIR not set}"
: "${WORKTREE_DIR:?WORKTREE_DIR not set}"

mkdir -p "$RUN_DIR/9-sessions"
touch "$RUN_DIR/9-sessions/000-stub.json"
echo "stub orchestrator: ran at $(date -u +%Y%m%d-%H%M%S)" >> "$RUN_DIR/7-SUMMARY.md"
echo "COMPLETE"
exit 0
```

```bash
chmod +x bin/orchestrator.sh
```

- [ ] **Step 2: Write the failing test**

Create `tests/test_run_lifecycle.sh`:
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="$(pwd)"
TMP=$(mktemp -d)
trap "rm -rf $TMP; tmux kill-server 2>/dev/null || true" EXIT

# Set up a fixture project
cd "$TMP"
git init -q
git -C . commit --allow-empty -q -m "init"

"$REPO/bin/orchestra" init . 2>&1

# Replace CONFIG.md with workable test config
cat > .orchestra/CONFIG.md <<EOF
- \`MAX_SESSIONS\`: 1
- \`MAX_CONSECUTIVE_CRASHES\`: 1
- \`MODEL\`: opus
- \`WORKTREE_BASE\`: $TMP/wt
- \`BASE_BRANCH\`: master
- \`TMUX_PREFIX\`: orch-test
EOF

cat > .orchestra/OBJECTIVE.md <<'EOF'
Stub objective.
EOF

git add -A
git commit -q -m "config + objective"

# Run
.orchestra/runtime/bin/orchestra run 2>&1

# Wait briefly for tmux session to finish (stub orchestrator exits fast)
sleep 2

# Assertions
ls "$TMP/wt"/run-* >/dev/null 2>&1 || { echo "no worktree created"; exit 1; }
WORKTREE=$(ls -d "$TMP/wt"/run-* | head -1)
[ -d "$WORKTREE/.orchestra/runs" ] || { echo "no runs dir in worktree"; exit 1; }
RUN_DIR=$(ls -d "$WORKTREE"/.orchestra/runs/*/ | head -1)
[ -d "${RUN_DIR}9-sessions" ] || { echo "no 9-sessions in run dir"; exit 1; }

echo "OK"
```

```bash
chmod +x tests/test_run_lifecycle.sh
```

- [ ] **Step 3: Run test, verify it fails**

```bash
bash tests/test_run_lifecycle.sh
```
Expected: FAIL (`cmd_run` not implemented).

- [ ] **Step 4: Implement `cmd_run` in `bin/orchestra`**

Replace `cmd_run() { die "run not yet implemented..."; }` with the run lifecycle. Cherry-pick from existing `bin/orchestra:317` (tmux conflict check) and `bin/orchestra:327` (tmux launch), and from `bin/orchestrator.sh:535` (`git worktree add`).

```bash
cmd_run() {
    local project_dir
    project_dir="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Not in a git repository"
    local orch="$project_dir/.orchestra"
    [ -d "$orch" ] || die ".orchestra/ not found. Run 'orchestra init' first."

    # Load + validate config
    declare -gA ORCHESTRA_CONFIG
    source "$orch/runtime/lib/config.sh"
    parse_config_md "$orch/CONFIG.md" || die "CONFIG.md parse failed"
    apply_config_defaults
    validate_config || die "CONFIG.md validation failed"

    local base_branch="${ORCHESTRA_CONFIG[BASE_BRANCH]}"
    local worktree_base="${ORCHESTRA_CONFIG[WORKTREE_BASE]}"
    local tmux_prefix="${ORCHESTRA_CONFIG[TMUX_PREFIX]}"

    mkdir -p "$worktree_base"

    # Atomic mkdir gate (spec Section 7) — retry up to 3x with fresh timestamp
    local run_ts run_dir worktree_dir tmux_name attempt=0
    local run_folder_root="$orch/runs"
    while [ $attempt -lt 3 ]; do
        run_ts="$(date -u +%Y%m%d-%H%M%S)"
        run_dir="$run_folder_root/$run_ts"
        if mkdir "$run_dir" 2>/dev/null; then
            break
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    [ $attempt -lt 3 ] || die "Could not allocate a unique run timestamp after 3 attempts"

    worktree_dir="$worktree_base/run-$run_ts"
    tmux_name="$tmux_prefix-$run_ts"
    local run_branch="orchestra/run-$run_ts"

    # Set up cleanup trap — fires on any setup failure before session loop is live
    trap "rm -rf '$run_dir'" ERR

    # Worktree creation (cherry-pick from bin/orchestrator.sh:535)
    git -C "$project_dir" worktree add "$worktree_dir" -b "$run_branch" "$base_branch" \
        || die "git worktree add failed"

    # Preflight: OBJECTIVE.md must exist in worktree
    [ -f "$worktree_dir/.orchestra/OBJECTIVE.md" ] \
        || die "OBJECTIVE.md not found in worktree — commit it to $base_branch and retry."

    # Snapshot OBJECTIVE.md into the run folder
    # (run_dir lives in the project's main tree; we need the worktree's run-folder copy too)
    local wt_run_dir="$worktree_dir/.orchestra/runs/$run_ts"
    mkdir -p "$wt_run_dir/9-sessions"
    cp "$worktree_dir/.orchestra/OBJECTIVE.md" "$wt_run_dir/2-OBJECTIVE.md"
    : > "$wt_run_dir/1-INBOX.md"
    : > "$wt_run_dir/3-TODO.md"
    : > "$wt_run_dir/4-DECISIONS.md"
    : > "$wt_run_dir/5-CHANGELOG.md"
    : > "$wt_run_dir/6-HANDOVER.md"
    : > "$wt_run_dir/7-SUMMARY.md"

    # Tmux conflict check (cherry-pick from bin/orchestra:317)
    if tmux has-session -t "$tmux_name" 2>/dev/null; then
        die "tmux session '$tmux_name' already exists — kill it or wait"
    fi

    # Clear setup trap before launching session loop (spec Section 7)
    trap - ERR

    # Launch (cherry-pick from bin/orchestra:327)
    echo "Starting orchestra run in tmux session '$tmux_name'..."
    echo "  Worktree: $worktree_dir"
    echo "  Run dir:  $wt_run_dir"
    echo "  Attach:   tmux attach -t $tmux_name"

    tmux new-session -d -s "$tmux_name" \
        "cd '$worktree_dir' && \
         RUN_DIR='$wt_run_dir' \
         WORKTREE_DIR='$worktree_dir' \
         RUN_TS='$run_ts' \
         RUN_BRANCH='$run_branch' \
         BASE_BRANCH='$base_branch' \
         bash '$orch/runtime/bin/orchestrator.sh'"
}
```

- [ ] **Step 5: Run test, verify pass**

```bash
bash tests/test_run_lifecycle.sh
```
Expected: `OK`, exit 0.

- [ ] **Step 6: Add a setup-failure cleanup test**

Append to `tests/test_run_lifecycle.sh`:
```bash
# Test: setup failure cleans up the run folder
TMP3=$(mktemp -d)
cd "$TMP3"
git init -q
git -C . commit --allow-empty -q -m "init"
"$REPO/bin/orchestra" init . 2>&1
# Bad CONFIG: WORKTREE_BASE points to read-only path so worktree creation fails
cat > .orchestra/CONFIG.md <<EOF
- \`MAX_SESSIONS\`: 1
- \`MAX_CONSECUTIVE_CRASHES\`: 1
- \`MODEL\`: opus
- \`WORKTREE_BASE\`: /proc/orchestra-cant-write
- \`BASE_BRANCH\`: master
EOF
echo "stub" > .orchestra/OBJECTIVE.md
git add -A
git commit -q -m "bad config"

if .orchestra/runtime/bin/orchestra run 2>/dev/null; then
    echo "expected run to fail"; exit 1
fi

# After failure, no orphan run folder should remain
if ls .orchestra/runs/2*/ 2>/dev/null | grep -q .; then
    echo "orphan run folder not cleaned up"; exit 1
fi

cd "$REPO"
rm -rf "$TMP3"

echo "OK"
```

Run: `bash tests/test_run_lifecycle.sh` → expect `OK`.

- [ ] **Step 7: Commit**

```bash
git add bin/orchestra bin/orchestrator.sh tests/test_run_lifecycle.sh
git commit -m "feat(run): worktree + tmux lifecycle with atomic mkdir gate"
```

---

## Phase 5 — Single-session loop + Category A (hard exit)

**Goal:** Orchestrator runs a real Claude session, captures exit signal, increments crash counter on hard exit, writes session JSON.

**Files:**
- Modify: `bin/orchestrator.sh` (rewrite from stub)
- Create: `tests/test_session_loop_hard_exit.sh`

- [ ] **Step 1: Define session JSON schema**

Document at top of `bin/orchestrator.sh`:
```
# 9-sessions/NNN.json schema:
# {
#   "session_num": 1,
#   "started_at": "2026-04-29T15:30:22Z",
#   "ended_at": "2026-04-29T15:35:10Z",
#   "exit_code": 0,
#   "exit_signal": "COMPLETE" | "HANDOVER" | "BLOCKED" | null,
#   "crash_category": null | "A" | "B" | "C" | "D",
#   "rate_limit_events": []
# }
```

- [ ] **Step 2: Write the failing test**

Create `tests/test_session_loop_hard_exit.sh`:
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

# Use a fake Claude binary that exits 1 immediately
TMP=$(mktemp -d)
trap "rm -rf $TMP; tmux kill-server 2>/dev/null || true" EXIT

mkdir -p "$TMP/fake-bin"
cat > "$TMP/fake-bin/claude" <<'EOF'
#!/bin/bash
echo "simulated crash" >&2
exit 1
EOF
chmod +x "$TMP/fake-bin/claude"

cd "$TMP"
git init -q
git -C . commit --allow-empty -q -m "init"
"$REPO/bin/orchestra" init . 2>&1

cat > .orchestra/CONFIG.md <<EOF
- \`MAX_SESSIONS\`: 5
- \`MAX_CONSECUTIVE_CRASHES\`: 2
- \`MODEL\`: opus
- \`WORKTREE_BASE\`: $TMP/wt
- \`BASE_BRANCH\`: master
- \`TMUX_PREFIX\`: orch-test
- \`COOLDOWN_SECONDS\`: 0
- \`CRASH_COOLDOWN_SECONDS\`: 0
EOF
echo "stub" > .orchestra/OBJECTIVE.md
git add -A
git commit -q -m "config"

# Inject fake claude onto PATH for the orchestrator
PATH="$TMP/fake-bin:$PATH" .orchestra/runtime/bin/orchestra run 2>&1

# Wait for orchestrator to bail
for i in $(seq 1 30); do
    tmux has-session -t orch-test-$(ls .orchestra/runs/ | tail -1 | cut -d/ -f1) 2>/dev/null || break
    sleep 1
done

WORKTREE=$(ls -d "$TMP/wt"/run-* | head -1)
RUN_DIR=$(ls -d "$WORKTREE"/.orchestra/runs/*/ | head -1)

# Should have written 2 session JSONs (MAX_CONSECUTIVE_CRASHES=2)
n=$(ls "${RUN_DIR}9-sessions/"*.json 2>/dev/null | wc -l)
[ "$n" -eq 2 ] || { echo "expected 2 session JSONs, got $n"; exit 1; }

# Each should have crash_category=A and exit_code != 0
for f in "${RUN_DIR}9-sessions/"*.json; do
    cat=$(jq -r '.crash_category' "$f")
    code=$(jq -r '.exit_code' "$f")
    [ "$cat" = "A" ] || { echo "$f: expected category A, got $cat"; exit 1; }
    [ "$code" != "0" ] || { echo "$f: expected non-zero exit"; exit 1; }
done

echo "OK"
```

```bash
chmod +x tests/test_session_loop_hard_exit.sh
```

- [ ] **Step 3: Run test, verify it fails**

```bash
bash tests/test_session_loop_hard_exit.sh
```
Expected: FAIL.

- [ ] **Step 4: Rewrite `bin/orchestrator.sh` with single-session-loop + Category A**

Replace stub with:
```bash
#!/bin/bash
# orchestrator.sh — session loop running inside the run worktree's tmux.
# Spec: docs/superpowers/specs/2026-04-29-orchestra-cleanup-design.md Sections 6, 11.
set -euo pipefail

: "${RUN_DIR:?RUN_DIR not set}"
: "${WORKTREE_DIR:?WORKTREE_DIR not set}"
: "${RUN_TS:?RUN_TS not set}"
: "${RUN_BRANCH:?RUN_BRANCH not set}"
: "${BASE_BRANCH:?BASE_BRANCH not set}"

# Load config from the worktree's CONFIG.md
declare -gA ORCHESTRA_CONFIG
source "$WORKTREE_DIR/.orchestra/runtime/lib/config.sh"
parse_config_md "$WORKTREE_DIR/.orchestra/CONFIG.md"
apply_config_defaults

MAX_SESSIONS="${ORCHESTRA_CONFIG[MAX_SESSIONS]}"
MAX_CRASHES="${ORCHESTRA_CONFIG[MAX_CONSECUTIVE_CRASHES]}"
MODEL="${ORCHESTRA_CONFIG[MODEL]}"
EFFORT="${ORCHESTRA_CONFIG[EFFORT]}"
COOLDOWN="${ORCHESTRA_CONFIG[COOLDOWN_SECONDS]}"
CRASH_COOLDOWN="${ORCHESTRA_CONFIG[CRASH_COOLDOWN_SECONDS]}"

session_num=0
crash_count=0

write_session_json() {
    local n="$1" started="$2" ended="$3" code="$4" signal="$5" cat="$6"
    local fname
    fname="$RUN_DIR/9-sessions/$(printf '%03d' "$n").json"
    jq -n \
        --argjson n "$n" \
        --arg s "$started" \
        --arg e "$ended" \
        --argjson c "$code" \
        --arg sig "$signal" \
        --arg cat "$cat" \
        '{session_num: $n, started_at: $s, ended_at: $e, exit_code: $c,
          exit_signal: ($sig | select(. != "") // null),
          crash_category: ($cat | select(. != "") // null),
          rate_limit_events: []}' \
        > "$fname"
}

build_session_prompt() {
    local n="$1"
    cat <<EOF
You are an autonomous Claude Code session in orchestra run $RUN_TS, session $n.

Read the following files in $WORKTREE_DIR/.orchestra/runs/$RUN_TS/ for context:
- 2-OBJECTIVE.md (the run objective — read first)
- 1-INBOX.md (any human messages — check on cold-start)
- 6-HANDOVER.md (briefing from previous session, if any)
- 3-TODO.md, 4-DECISIONS.md, 5-CHANGELOG.md, 7-SUMMARY.md (rolling state)

Make progress against the objective. Update the rolling files as you work.

When done with this session, exit with EXACTLY one of:
- COMPLETE — objective met, ready for wind-down (worktree must be clean)
- HANDOVER — more work remains, write 6-HANDOVER.md briefing for the next session
- BLOCKED — external dependency missing; write 6-HANDOVER.md with remaining-work and dependency analysis

The signal is the LAST line of your output, on its own line.
EOF
}

while [ $session_num -lt $MAX_SESSIONS ] && [ $crash_count -lt $MAX_CRASHES ]; do
    session_num=$((session_num + 1))
    started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    prompt=$(build_session_prompt "$session_num")

    # Run claude headlessly (per spec Section 9 "Headless invocation")
    set +e
    out=$(echo "$prompt" | claude --print --dangerously-skip-permissions \
        --model "$MODEL" --thinking-effort "$EFFORT" 2>&1)
    code=$?
    set -e

    ended_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Determine exit signal and crash category
    last_line=$(printf '%s' "$out" | tail -n1 | tr -d '[:space:]')
    signal=""
    category=""

    if [ $code -ne 0 ]; then
        category="A"
    else
        case "$last_line" in
            COMPLETE|HANDOVER|BLOCKED) signal="$last_line" ;;
            *) category="B" ;;  # Phase 6 will refine this
        esac
    fi

    write_session_json "$session_num" "$started_at" "$ended_at" "$code" "$signal" "$category"

    if [ -n "$category" ]; then
        crash_count=$((crash_count + 1))
        sleep "$CRASH_COOLDOWN"
    else
        crash_count=0
        sleep "$COOLDOWN"

        case "$signal" in
            COMPLETE) echo "Run complete (wind-down deferred to Phase 9)"; exit 0 ;;
            HANDOVER) continue ;;
            BLOCKED)  echo "BLOCKED — Phase 12 will handle this"; exit 0 ;;
        esac
    fi
done

if [ $crash_count -ge $MAX_CRASHES ]; then
    echo "Bailing: MAX_CONSECUTIVE_CRASHES reached"
    exit 1
fi

echo "MAX_SESSIONS reached without COMPLETE"
exit 0
```

- [ ] **Step 5: Run test, verify pass**

```bash
bash tests/test_session_loop_hard_exit.sh
```
Expected: `OK`.

- [ ] **Step 6: Commit**

```bash
git add bin/orchestrator.sh tests/test_session_loop_hard_exit.sh
git commit -m "feat(orchestrator): single-session loop with Category A crash detection"
```

---

## Phase 6 — Categories B (silent exit), D (inconsistent finish), HANDOVER continuity

**Goal:** Refine the loop to handle silent exits, multi-session HANDOVER, and clean-state invariant on COMPLETE.

**Files:**
- Modify: `bin/orchestrator.sh`
- Create: `tests/test_categories_bd.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_categories_bd.sh`:
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"
TMP=$(mktemp -d)
trap "rm -rf $TMP; tmux kill-server 2>/dev/null || true" EXIT

# Fake claude that exits 0 with no recognised signal (Category B)
mkdir -p "$TMP/fake-bin"
cat > "$TMP/fake-bin/claude" <<'EOF'
#!/bin/bash
echo "I did some thinking but forgot the signal"
exit 0
EOF
chmod +x "$TMP/fake-bin/claude"

cd "$TMP"
git init -q
git -C . commit --allow-empty -q -m "init"
"$REPO/bin/orchestra" init . 2>&1

cat > .orchestra/CONFIG.md <<EOF
- \`MAX_SESSIONS\`: 5
- \`MAX_CONSECUTIVE_CRASHES\`: 2
- \`MODEL\`: opus
- \`WORKTREE_BASE\`: $TMP/wt
- \`BASE_BRANCH\`: master
- \`TMUX_PREFIX\`: orch-bd
- \`COOLDOWN_SECONDS\`: 0
- \`CRASH_COOLDOWN_SECONDS\`: 0
EOF
echo "stub" > .orchestra/OBJECTIVE.md
git add -A
git commit -q -m "config"

PATH="$TMP/fake-bin:$PATH" .orchestra/runtime/bin/orchestra run 2>&1

# Wait
for i in $(seq 1 30); do
    tmux ls 2>/dev/null | grep -q orch-bd || break
    sleep 1
done

WORKTREE=$(ls -d "$TMP/wt"/run-* | head -1)
RUN_DIR=$(ls -d "$WORKTREE"/.orchestra/runs/*/ | head -1)

# Should have 2 session JSONs both with crash_category=B
for f in "${RUN_DIR}9-sessions/"*.json; do
    cat=$(jq -r '.crash_category' "$f")
    [ "$cat" = "B" ] || { echo "$f: expected B, got $cat"; exit 1; }
done

echo "OK"
```

```bash
chmod +x tests/test_categories_bd.sh
```

- [ ] **Step 2: Run test, verify it fails or passes-by-accident, then refine**

```bash
bash tests/test_categories_bd.sh
```
Expected: PASS (Phase 5's `B` placeholder already covers this case). If it passes, the test still serves as a regression guard.

- [ ] **Step 3: Add Category D detection — clean-state invariant on COMPLETE**

Modify `bin/orchestrator.sh` `case "$last_line"` block:
```bash
COMPLETE)
    # Category D check: COMPLETE requires clean worktree (spec Section 11.D)
    cd "$WORKTREE_DIR"
    if [ -n "$(git status --porcelain)" ]; then
        category="D"
        signal=""
        # Don't increment crash_count for D (spec Section 11)
        write_session_json "$session_num" "$started_at" "$ended_at" "$code" "" "D"
        # Damage assessment will run at next session — but if D came from
        # the last session and MAX_SESSIONS exhausted, we still bail.
        # Phase 9 wind-down's recovery prompt handles dirty COMPLETE.
        echo "Category D: COMPLETE with dirty worktree — deferring to wind-down (Phase 9)"
        exit 0
    fi
    signal="COMPLETE"
    ;;
```

Reorder the write_session_json call so D is written BEFORE the loop's normal write (move the D-write inside the case D handling, then `continue` the outer loop pre-write to avoid double-write).

Cleaner restructure: replace the `case "$last_line"` at end of loop with:
```bash
elif [ "$last_line" = "COMPLETE" ]; then
    cd "$WORKTREE_DIR"
    if [ -n "$(git status --porcelain)" ]; then
        signal="COMPLETE"
        category="D"
    else
        signal="COMPLETE"
    fi
elif [ "$last_line" = "HANDOVER" ] || [ "$last_line" = "BLOCKED" ]; then
    signal="$last_line"
else
    category="B"
fi
```

Then in the action dispatch:
```bash
if [ -n "$category" ] && [ "$category" != "D" ]; then
    crash_count=$((crash_count + 1))
elif [ "$category" = "D" ]; then
    # No counter increment; signal still treated as COMPLETE for next-session damage assessment
    :
else
    crash_count=0
fi
```

(Refer to spec Section 11 — D doesn't increment counter.)

- [ ] **Step 4: Add HANDOVER recovery-prompt prepending**

Cherry-pick from `bin/orchestrator.sh:~383` (existing `RECOVERY_PROMPT` heredoc).

In the new orchestrator, before the next session's `claude --print` call, if the previous session was Category D OR Category A/B/C, prepend a damage-assessment preamble:

```bash
if [ -n "${prev_category:-}" ]; then
    prompt=$(cat <<EOF
RECOVERY PREAMBLE — the previous session ended with category $prev_category.

$(case "$prev_category" in
    A|B|C) echo "The previous session crashed or hung. Inspect git status and any work-in-progress files before continuing the main task." ;;
    D) echo "The previous session emitted COMPLETE but left uncommitted changes. Assess each modification, decide whether to keep or discard, commit deliberately on the run-branch, then either re-emit COMPLETE (if objective met) or continue with HANDOVER." ;;
esac)

---

$(build_session_prompt "$session_num")
EOF
)
fi
```

Track `prev_category` across loop iterations.

- [ ] **Step 5: Run all tests, verify pass**

```bash
bash tests/run-tests.sh
```
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add bin/orchestrator.sh tests/test_categories_bd.sh
git commit -m "feat(orchestrator): Category B/D detection + recovery prompt"
```

---

## Phase 7 — Hang detection (Category C)

**Goal:** Detect a hung session via inotifywait + stdout silence and force-terminate it.

**Files:**
- Modify: `bin/orchestrator.sh`
- Create: `tests/test_hang_detection.sh`

- [ ] **Step 1: Implement watchdog using `inotifywait` + stdout tail**

In `bin/orchestrator.sh`, replace the direct `claude --print` invocation with a wrapper that:
1. Spawns `inotifywait -mr --format '.' "$WORKTREE_DIR"` to a temp log
2. Spawns `claude --print` to a separate log
3. Polls every 30s: if BOTH logs haven't grown in `MAX_HANG_SECONDS`, treat as hang — kill claude with SIGTERM, wait 30s, SIGKILL

```bash
run_session_with_watchdog() {
    local prompt="$1"
    local stdout_log="$2"
    local stderr_log="$3"

    local inotify_log
    inotify_log=$(mktemp)
    inotifywait -mr --format '.' "$WORKTREE_DIR" >> "$inotify_log" 2>/dev/null &
    local inotify_pid=$!

    echo "$prompt" | claude --print --dangerously-skip-permissions \
        --model "$MODEL" --thinking-effort "$EFFORT" \
        > "$stdout_log" 2> "$stderr_log" &
    local claude_pid=$!

    local last_inotify_size=0
    local last_stdout_size=0
    local quiet_seconds=0

    while kill -0 "$claude_pid" 2>/dev/null; do
        sleep 30

        local i_size s_size
        i_size=$(stat -c %s "$inotify_log" 2>/dev/null || echo 0)
        s_size=$(stat -c %s "$stdout_log" 2>/dev/null || echo 0)

        if [ "$i_size" -eq "$last_inotify_size" ] && [ "$s_size" -eq "$last_stdout_size" ]; then
            quiet_seconds=$((quiet_seconds + 30))
            if [ "$quiet_seconds" -ge "${ORCHESTRA_CONFIG[MAX_HANG_SECONDS]}" ]; then
                kill -TERM "$claude_pid" 2>/dev/null || true
                sleep 30
                kill -KILL "$claude_pid" 2>/dev/null || true
                kill -TERM "$inotify_pid" 2>/dev/null || true
                wait "$claude_pid" 2>/dev/null
                rm -f "$inotify_log"
                return 124  # standard timeout exit code
            fi
        else
            quiet_seconds=0
            last_inotify_size=$i_size
            last_stdout_size=$s_size
        fi
    done

    wait "$claude_pid"
    local code=$?
    kill -TERM "$inotify_pid" 2>/dev/null || true
    rm -f "$inotify_log"
    return "$code"
}
```

In the main loop, replace the direct claude invocation with:
```bash
stdout_log=$(mktemp)
stderr_log=$(mktemp)
set +e
run_session_with_watchdog "$prompt" "$stdout_log" "$stderr_log"
code=$?
set -e
out=$(cat "$stdout_log")
rm -f "$stdout_log" "$stderr_log"

# Detect hang from exit code
if [ "$code" -eq 124 ]; then
    category="C"
    signal=""
fi
```

- [ ] **Step 2: Write the test**

Create `tests/test_hang_detection.sh`:
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"
TMP=$(mktemp -d)
trap "rm -rf $TMP; tmux kill-server 2>/dev/null || true" EXIT

# Fake claude that sleeps forever (hang)
mkdir -p "$TMP/fake-bin"
cat > "$TMP/fake-bin/claude" <<'EOF'
#!/bin/bash
sleep 9999
EOF
chmod +x "$TMP/fake-bin/claude"

cd "$TMP"
git init -q
git -C . commit --allow-empty -q -m "init"
"$REPO/bin/orchestra" init . 2>&1

cat > .orchestra/CONFIG.md <<EOF
- \`MAX_SESSIONS\`: 1
- \`MAX_CONSECUTIVE_CRASHES\`: 1
- \`MAX_HANG_SECONDS\`: 60
- \`MODEL\`: opus
- \`WORKTREE_BASE\`: $TMP/wt
- \`BASE_BRANCH\`: master
- \`TMUX_PREFIX\`: orch-c
EOF
echo "stub" > .orchestra/OBJECTIVE.md
git add -A
git commit -q -m "config"

PATH="$TMP/fake-bin:$PATH" .orchestra/runtime/bin/orchestra run 2>&1

# Wait — should bail in ~90s (MAX_HANG_SECONDS=60 + 30s grace)
for i in $(seq 1 12); do
    tmux ls 2>/dev/null | grep -q orch-c || break
    sleep 10
done

WORKTREE=$(ls -d "$TMP/wt"/run-* | head -1)
RUN_DIR=$(ls -d "$WORKTREE"/.orchestra/runs/*/ | head -1)

cat=$(jq -r '.crash_category' "${RUN_DIR}9-sessions/001.json")
[ "$cat" = "C" ] || { echo "expected C, got $cat"; exit 1; }

echo "OK"
```

```bash
chmod +x tests/test_hang_detection.sh
```

- [ ] **Step 3: Run test, verify pass**

```bash
bash tests/test_hang_detection.sh
```
Expected: `OK` (allow ~2 minutes).

- [ ] **Step 4: Commit**

```bash
git add bin/orchestrator.sh tests/test_hang_detection.sh
git commit -m "feat(orchestrator): Category C hang detection with inotifywait"
```

---

## Phase 8 — Wind-down lock + simple wind-down spawn

**Goal:** On `COMPLETE`, acquire the wind-down lock, spawn a simple wind-down session that does only the merge sequence (no ingestion yet), release lock.

**Files:**
- Modify: `bin/orchestrator.sh`
- Create: `lib/winddown-prompt-simple.txt` (placeholder prompt — no ingestion, just merge)
- Create: `tests/test_winddown_lock.sh`

- [ ] **Step 1: Implement lock acquire/release in orchestrator**

Add to `bin/orchestrator.sh`:
```bash
WINDDOWN_LOCK="$WORKTREE_DIR/.orchestra/runs/.wind-down.lock"

acquire_winddown_lock() {
    local backoff=30
    while true; do
        if (set -C; printf '%d\n%s\n' $$ "$(awk '{print $22}' /proc/self/stat)" > "$WINDDOWN_LOCK") 2>/dev/null; then
            return 0
        fi

        # Lock exists — check liveness
        local lock_pid lock_starttime live_starttime
        lock_pid=$(sed -n '1p' "$WINDDOWN_LOCK" 2>/dev/null) || lock_pid=""
        lock_starttime=$(sed -n '2p' "$WINDDOWN_LOCK" 2>/dev/null) || lock_starttime=""

        if [ -z "$lock_pid" ] || ! kill -0 "$lock_pid" 2>/dev/null; then
            # PID gone — stale, remove
            rm -f "$WINDDOWN_LOCK"
            continue
        fi

        # PID alive — verify start-time matches (defends against PID recycling)
        if [ -e "/proc/$lock_pid/stat" ]; then
            live_starttime=$(awk '{print $22}' "/proc/$lock_pid/stat" 2>/dev/null)
            if [ "$live_starttime" != "$lock_starttime" ]; then
                rm -f "$WINDDOWN_LOCK"
                continue
            fi
        fi

        # Genuinely held by live orchestrator — backoff
        sleep "$backoff"
        backoff=$((backoff * 2))
        [ $backoff -gt 300 ] && backoff=300
    done
}
```

- [ ] **Step 2: Add wind-down spawn to the COMPLETE branch**

Modify the `COMPLETE` handler in the main loop:
```bash
if [ "$signal" = "COMPLETE" ] && [ -z "$category" ]; then
    echo "Run COMPLETE — entering wind-down"

    acquire_winddown_lock

    # Trap discipline (spec Section 6.1) — reserved EXIT INT TERM for lock
    trap 'rm -f "$WINDDOWN_LOCK"' EXIT INT TERM

    # Build wind-down prompt from template
    wd_prompt=$(cat "$WORKTREE_DIR/.orchestra/runtime/lib/winddown-prompt.txt" \
        | sed "s|__RUN_DIR__|$RUN_DIR|g" \
        | sed "s|__BASE_BRANCH__|$BASE_BRANCH|g" \
        | sed "s|__RUN_BRANCH__|$RUN_BRANCH|g")

    set +e
    wd_out=$(echo "$wd_prompt" | claude --print --dangerously-skip-permissions \
        --model "$MODEL" --thinking-effort "$EFFORT" 2>&1)
    wd_code=$?
    set -e

    wd_last=$(printf '%s' "$wd_out" | tail -n1 | tr -d '[:space:]')

    if [ $wd_code -ne 0 ] || [ "$wd_last" != "COMPLETE" ]; then
        # Phase 10 will fully implement wind-down failure path; for now, mark and exit
        touch "$RUN_DIR/WIND-DOWN-FAILED"
        echo "Wind-down failed — see Phase 10 for full failure handling"
        exit 1
    fi

    # Successful wind-down — archive (spec Section 6.3 last sentence)
    local archive_dir="$WORKTREE_DIR/.orchestra/runs/archive"
    mkdir -p "$archive_dir"
    mv "$RUN_DIR" "$archive_dir/$RUN_TS"
    echo "Run archived at $archive_dir/$RUN_TS"
    exit 0
fi
```

- [ ] **Step 3: Write a minimal wind-down prompt**

Create `lib/winddown-prompt.txt`:
```
You are the wind-down session for orchestra run.

Run dir:    __RUN_DIR__
Run branch: __RUN_BRANCH__
Base:       __BASE_BRANCH__

This is the simple wind-down — for Phase 8 only, do only the merge sequence
(Phase 13 adds ingestion):

1. cd into the worktree (you are already there).
2. git checkout __BASE_BRANCH__
3. git pull origin __BASE_BRANCH__
4. If __BASE_BRANCH__ is an ancestor of __RUN_BRANCH__:
     git merge --ff-only __RUN_BRANCH__
   Else:
     git checkout __RUN_BRANCH__
     git rebase __BASE_BRANCH__   (resolve conflicts inline if any)
     git checkout __BASE_BRANCH__
     git merge --ff-only __RUN_BRANCH__
5. git push origin __BASE_BRANCH__
   On rejection: re-pull, re-merge, retry up to 3 times. On 3rd rejection
   or non-conflict push failure: emit BLOCKED with details in 6-HANDOVER.md.

If unresolvable conflict: emit BLOCKED with conflict details in 6-HANDOVER.md
following the wind-down BLOCKED shape (files in conflict, git status excerpt,
manual resolution instructions).

On success: print exactly "COMPLETE" as the final line.
```

- [ ] **Step 4: Update init/run paths to copy `lib/winddown-prompt.txt`**

In `bin/orchestra` `cmd_init`, add:
```bash
cp "$LIB_DIR/winddown-prompt.txt" "$orch/runtime/lib/winddown-prompt.txt"
```

- [ ] **Step 5: Write the test**

Create `tests/test_winddown_lock.sh`:
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"
TMP=$(mktemp -d)
trap "rm -rf $TMP; tmux kill-server 2>/dev/null || true" EXIT

# Fake claude: first session emits COMPLETE; wind-down session also emits COMPLETE
mkdir -p "$TMP/fake-bin"
cat > "$TMP/fake-bin/claude" <<'EOF'
#!/bin/bash
# Read prompt from stdin
prompt=$(cat)
if echo "$prompt" | grep -q "wind-down session"; then
    # Wind-down: do real merge ops
    git checkout master 2>/dev/null
    git pull origin master 2>/dev/null || true
    branch=$(echo "$prompt" | grep "Run branch:" | awk '{print $3}')
    git merge --ff-only "$branch" 2>/dev/null || true
    git push origin master 2>/dev/null || true
    echo "wind-down done"
    echo "COMPLETE"
else
    # Working session: just claim done
    echo "all good"
    echo "COMPLETE"
fi
exit 0
EOF
chmod +x "$TMP/fake-bin/claude"

cd "$TMP"
git init -q --initial-branch=master
git -C . commit --allow-empty -q -m "init"

"$REPO/bin/orchestra" init . 2>&1

cat > .orchestra/CONFIG.md <<EOF
- \`MAX_SESSIONS\`: 1
- \`MAX_CONSECUTIVE_CRASHES\`: 1
- \`MODEL\`: opus
- \`WORKTREE_BASE\`: $TMP/wt
- \`BASE_BRANCH\`: master
- \`TMUX_PREFIX\`: orch-wd
EOF
echo "stub" > .orchestra/OBJECTIVE.md
git add -A
git commit -q -m "config"

PATH="$TMP/fake-bin:$PATH" .orchestra/runtime/bin/orchestra run 2>&1

for i in $(seq 1 30); do
    tmux ls 2>/dev/null | grep -q orch-wd || break
    sleep 1
done

WORKTREE=$(ls -d "$TMP/wt"/run-* | head -1)
ARCHIVE="$WORKTREE/.orchestra/runs/archive"

# Run should be archived
ls -d "$ARCHIVE"/* >/dev/null 2>&1 || { echo "run not archived"; exit 1; }

# Lock file should be released
[ ! -f "$WORKTREE/.orchestra/runs/.wind-down.lock" ] || { echo "lock not released"; exit 1; }

echo "OK"
```

```bash
chmod +x tests/test_winddown_lock.sh
```

- [ ] **Step 6: Run test, verify pass**

```bash
bash tests/test_winddown_lock.sh
```
Expected: `OK`.

- [ ] **Step 7: Commit**

```bash
git add bin/orchestrator.sh bin/orchestra lib/winddown-prompt.txt tests/test_winddown_lock.sh
git commit -m "feat(winddown): orchestrator-owned lock + simple merge-only spawn"
```

---

## Phase 9 — Wind-down failure handling (Section 6.4) + Category E

**Goal:** Implement `WIND-DOWN-FAILED` marker, BLOCKED-during-wind-down handling, recovery commands in user-facing message.

**Files:**
- Modify: `bin/orchestrator.sh`
- Create: `tests/test_winddown_failure.sh`

- [ ] **Step 1: Replace simple wind-down failure path with full Section 6.4**

In `bin/orchestrator.sh`, expand the wind-down failure block:
```bash
if [ $wd_code -ne 0 ] || ! [[ "$wd_last" =~ ^(COMPLETE|BLOCKED)$ ]]; then
    # Wind-down crash (Categories A/B/C during wind-down) — silent exit or hang
    failure_cat="A"
    [ $wd_code -eq 124 ] && failure_cat="C"
    [ $wd_code -eq 0 ] && failure_cat="B"
    write_winddown_failed_marker "$failure_cat" "$wd_out" ""
    print_winddown_recovery "$failure_cat"
    exit 1
fi

if [ "$wd_last" = "BLOCKED" ]; then
    # Wind-down BLOCKED — agent gave up on merge conflict / push failure
    write_winddown_failed_marker "BLOCKED" "$wd_out" "$RUN_DIR/6-HANDOVER.md"
    print_winddown_recovery "BLOCKED"
    exit 1
fi

# wd_last must be COMPLETE — proceed to archive
```

- [ ] **Step 2: Implement helper functions**

```bash
write_winddown_failed_marker() {
    local cat="$1" out="$2" handover="$3"
    {
        echo "Failed at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "Category: $cat"
        echo ""
        echo "--- Last 50 lines of session output ---"
        echo "$out" | tail -50
        if [ "$cat" = "BLOCKED" ] && [ -n "$handover" ] && [ -f "$handover" ]; then
            echo ""
            echo "--- Conflict/push-failure details from 6-HANDOVER.md ---"
            cat "$handover"
        fi
    } > "$RUN_DIR/WIND-DOWN-FAILED"
}

print_winddown_recovery() {
    local cat="$1"
    cat <<EOF >&2

WIND-DOWN FAILED ($cat). Run preserved at:
  $RUN_DIR

Run branch: $RUN_BRANCH

EOF
    case "$cat" in
        A|B|C)
            cat <<EOF >&2
Recovery (the merge step did not complete):
  cd $WORKTREE_DIR
  git checkout $BASE_BRANCH
  git merge --ff-only $RUN_BRANCH
  git push origin $BASE_BRANCH

EOF
            ;;
        BLOCKED)
            cat <<EOF >&2
Recovery (resolve merge/push manually):
  cd $WORKTREE_DIR
  cat $RUN_DIR/6-HANDOVER.md
  # Resolve conflicts following the manual-resolution instructions in HANDOVER, then:
  git add .
  git commit
  git push origin $BASE_BRANCH

EOF
            ;;
    esac
}
```

- [ ] **Step 3: Write the test**

Create `tests/test_winddown_failure.sh`:
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"
TMP=$(mktemp -d)
trap "rm -rf $TMP; tmux kill-server 2>/dev/null || true" EXIT

mkdir -p "$TMP/fake-bin"
cat > "$TMP/fake-bin/claude" <<'EOF'
#!/bin/bash
prompt=$(cat)
if echo "$prompt" | grep -q "wind-down session"; then
    echo "I am stuck on a conflict"
    # Write minimal HANDOVER block expected by spec
    rd=$(echo "$prompt" | grep "Run dir:" | awk '{print $3}')
    cat > "$rd/6-HANDOVER.md" <<HOEOF
# Wind-down BLOCKED

Files in conflict: src/foo.c

Manual resolution: edit src/foo.c, git add, git commit, git push.
HOEOF
    echo "BLOCKED"
else
    echo "all good"
    echo "COMPLETE"
fi
exit 0
EOF
chmod +x "$TMP/fake-bin/claude"

cd "$TMP"
git init -q --initial-branch=master
git -C . commit --allow-empty -q -m "init"
"$REPO/bin/orchestra" init . 2>&1

cat > .orchestra/CONFIG.md <<EOF
- \`MAX_SESSIONS\`: 1
- \`MAX_CONSECUTIVE_CRASHES\`: 1
- \`MODEL\`: opus
- \`WORKTREE_BASE\`: $TMP/wt
- \`BASE_BRANCH\`: master
- \`TMUX_PREFIX\`: orch-wf
EOF
echo "stub" > .orchestra/OBJECTIVE.md
git add -A
git commit -q -m "config"

PATH="$TMP/fake-bin:$PATH" .orchestra/runtime/bin/orchestra run 2>&1 || true

for i in $(seq 1 30); do
    tmux ls 2>/dev/null | grep -q orch-wf || break
    sleep 1
done

WORKTREE=$(ls -d "$TMP/wt"/run-* | head -1)
RUN=$(ls -d "$WORKTREE"/.orchestra/runs/2*/ | head -1)

[ -f "${RUN}WIND-DOWN-FAILED" ] || { echo "no WIND-DOWN-FAILED marker"; exit 1; }
grep -q "Category: BLOCKED" "${RUN}WIND-DOWN-FAILED" || { echo "wrong category"; exit 1; }
grep -q "Files in conflict" "${RUN}WIND-DOWN-FAILED" || { echo "missing handover content"; exit 1; }

# Run NOT archived
[ ! -d "$WORKTREE/.orchestra/runs/archive/$(basename "$RUN")" ] || { echo "should not archive failed wind-down"; exit 1; }

echo "OK"
```

```bash
chmod +x tests/test_winddown_failure.sh
```

- [ ] **Step 4: Run test, verify pass**

```bash
bash tests/test_winddown_failure.sh
```
Expected: `OK`.

- [ ] **Step 5: Commit**

```bash
git add bin/orchestrator.sh tests/test_winddown_failure.sh
git commit -m "feat(winddown): failure handling per Section 6.4 (A/B/C/BLOCKED)"
```

---

## Phase 10 — BLOCKED handling (working-session, not wind-down)

**Goal:** Working session emits BLOCKED → orchestrator writes BLOCKED marker, no further sessions, no wind-down. (Wind-down BLOCKED was handled in Phase 9.)

**Files:**
- Modify: `bin/orchestrator.sh`
- Create: `tests/test_blocked.sh`

- [ ] **Step 1: Add BLOCKED handler to main session loop**

In `bin/orchestrator.sh` after the `signal=COMPLETE` branch:
```bash
if [ "$signal" = "BLOCKED" ]; then
    blocker_text=""
    [ -f "$RUN_DIR/1-INBOX.md" ] && blocker_text+=$'\n\n--- 1-INBOX.md ---\n'$(cat "$RUN_DIR/1-INBOX.md")
    [ -f "$RUN_DIR/6-HANDOVER.md" ] && blocker_text+=$'\n\n--- 6-HANDOVER.md ---\n'$(cat "$RUN_DIR/6-HANDOVER.md")

    {
        echo "Blocked at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "Session: $session_num"
        echo "$blocker_text"
    } > "$RUN_DIR/BLOCKED"

    cat <<EOF >&2

RUN BLOCKED. Run preserved at:
  $RUN_DIR

The agent could not proceed without an external dependency. See:
  $RUN_DIR/BLOCKED
  $RUN_DIR/6-HANDOVER.md (remaining work + dependency analysis)
  $RUN_DIR/1-INBOX.md (any inline blocker text)

After resolving the blocker, prepare a fresh OBJECTIVE.md and run again.
EOF
    exit 0
fi
```

- [ ] **Step 2: Write test**

Create `tests/test_blocked.sh`:
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"
TMP=$(mktemp -d)
trap "rm -rf $TMP; tmux kill-server 2>/dev/null || true" EXIT

mkdir -p "$TMP/fake-bin"
cat > "$TMP/fake-bin/claude" <<'EOF'
#!/bin/bash
prompt=$(cat)
rd=$(echo "$prompt" | grep -oE '/[a-zA-Z0-9_/.-]*\.orchestra/runs/[^/ ]+' | head -1)
echo "Cannot proceed without API key" > "$rd/6-HANDOVER.md"
echo "stuck"
echo "BLOCKED"
exit 0
EOF
chmod +x "$TMP/fake-bin/claude"

cd "$TMP"
git init -q --initial-branch=master
git -C . commit --allow-empty -q -m "init"
"$REPO/bin/orchestra" init . 2>&1

cat > .orchestra/CONFIG.md <<EOF
- \`MAX_SESSIONS\`: 5
- \`MAX_CONSECUTIVE_CRASHES\`: 2
- \`MODEL\`: opus
- \`WORKTREE_BASE\`: $TMP/wt
- \`BASE_BRANCH\`: master
- \`TMUX_PREFIX\`: orch-bl
EOF
echo "stub" > .orchestra/OBJECTIVE.md
git add -A
git commit -q -m "config"

PATH="$TMP/fake-bin:$PATH" .orchestra/runtime/bin/orchestra run 2>&1 || true

for i in $(seq 1 30); do
    tmux ls 2>/dev/null | grep -q orch-bl || break
    sleep 1
done

WORKTREE=$(ls -d "$TMP/wt"/run-* | head -1)
RUN=$(ls -d "$WORKTREE"/.orchestra/runs/2*/ | head -1)

[ -f "${RUN}BLOCKED" ] || { echo "no BLOCKED marker"; exit 1; }
grep -q "Cannot proceed" "${RUN}BLOCKED" || { echo "missing handover content in BLOCKED"; exit 1; }

# Run NOT archived
[ ! -d "$WORKTREE/.orchestra/runs/archive/$(basename "$RUN")" ] || { echo "BLOCKED runs must not auto-archive"; exit 1; }

# Only one session was run (BLOCKED halts immediately)
n=$(ls "${RUN}9-sessions/"*.json 2>/dev/null | wc -l)
[ "$n" -eq 1 ] || { echo "expected exactly 1 session, got $n"; exit 1; }

echo "OK"
```

- [ ] **Step 3: Run test, commit**

```bash
bash tests/test_blocked.sh
git add bin/orchestrator.sh tests/test_blocked.sh
git commit -m "feat(orchestrator): BLOCKED handling for working sessions"
```

---

## Phase 11 — Smoke test driver + `empty/` fixture

**Goal:** Implement `orchestra test` against the `empty/` fixture (no parent governance), exercising the full lifecycle with a real Claude session.

**Files:**
- Modify: `bin/orchestra` (`cmd_test`)
- Create: `examples/smoke-test/empty/` directory with starter files
- Create: a smoke-test driver script (can be inline in `cmd_test`)

- [ ] **Step 1: Create `examples/smoke-test/empty/` fixture**

```bash
mkdir -p examples/smoke-test/empty
cat > examples/smoke-test/empty/README.md <<'EOF'
# Empty smoke-test fixture

Minimal git project with NO parent governance files. Used by `orchestra test`
to verify the no-op-ingestion path of wind-down: a project with no TODO/
DECISIONS/CHANGELOG should not have those files created at wind-down.
EOF

cat > examples/smoke-test/empty/CLAUDE.md <<'EOF'
# Smoke-test project

Trivial fixture for orchestra integration testing.

## Tech stack
- Plain text files only.

## Conventions
- No governance.
EOF

cat > examples/smoke-test/empty/OBJECTIVE.md <<'EOF'
# Run Objective

Create two text files in the worktree:

1. `file-a.txt` containing the literal text `alpha`
2. `file-b.txt` containing the literal text `beta`

Commit each on the run branch. When both exist with correct content, emit COMPLETE.
EOF
```

- [ ] **Step 2: Implement `cmd_test` in `bin/orchestra`**

Replace `cmd_test() { die "..."; }` with:
```bash
cmd_test() {
    local variant="${1:-empty}"
    [ "$variant" = "empty" ] || [ "$variant" = "with-governance" ] \
        || die "Unknown smoke-test variant: $variant (use 'empty' or 'with-governance')"

    local fixture="$SCRIPT_DIR/../examples/smoke-test/$variant"
    [ -d "$fixture" ] || die "Fixture not found: $fixture"

    local tmp tmp_root tmpdir
    tmp_root="${TMPDIR:-/tmp}"
    tmpdir="$tmp_root/orchestra-smoke-$(date -u +%H%M%S)-$variant"
    rm -rf "$tmpdir"
    mkdir -p "$tmpdir"
    cp -r "$fixture/." "$tmpdir/"

    cd "$tmpdir"
    git init -q --initial-branch=master
    git add -A
    git commit -q -m "smoke-test fixture init"

    "$SCRIPT_DIR/orchestra" init . >/dev/null

    # Generate a working CONFIG.md
    cat > .orchestra/CONFIG.md <<EOF
- \`MAX_SESSIONS\`: 2
- \`MAX_CONSECUTIVE_CRASHES\`: 1
- \`MODEL\`: opus
- \`WORKTREE_BASE\`: $tmpdir/wt
- \`BASE_BRANCH\`: master
- \`TMUX_PREFIX\`: orch-smoke
- \`SMOKE_TEST_TIMEOUT\`: 900
EOF

    # Promote fixture's OBJECTIVE.md
    cp OBJECTIVE.md .orchestra/OBJECTIVE.md

    git add -A
    git commit -q -m "smoke-test config + objective"

    .orchestra/runtime/bin/orchestra run

    # Wait up to SMOKE_TEST_TIMEOUT
    local elapsed=0 timeout=900
    while tmux ls 2>/dev/null | grep -q orch-smoke; do
        sleep 10
        elapsed=$((elapsed + 10))
        if [ $elapsed -ge $timeout ]; then
            tmux kill-server 2>/dev/null || true
            die "Smoke test timed out after ${timeout}s"
        fi
    done

    # Run assertions
    smoke_assert_common "$tmpdir"
    if [ "$variant" = "empty" ]; then
        smoke_assert_empty "$tmpdir"
    else
        smoke_assert_with_governance "$tmpdir"
    fi

    echo ""
    echo "Smoke test PASSED ($variant). Tempdir: $tmpdir"
}

smoke_assert_common() {
    local tmpdir="$1"
    local archive
    archive=$(ls -d "$tmpdir"/wt/run-*/.orchestra/runs/archive/* 2>/dev/null | head -1)
    [ -n "$archive" ] || die "ASSERT FAIL: no archived run found"

    for f in 1-INBOX.md 2-OBJECTIVE.md 3-TODO.md 4-DECISIONS.md 5-CHANGELOG.md \
             6-HANDOVER.md 7-SUMMARY.md 9-sessions; do
        [ -e "$archive/$f" ] || die "ASSERT FAIL: missing $f in archive"
    done

    # Active run folder must NOT remain
    local active_count
    active_count=$(ls -d "$tmpdir"/wt/run-*/.orchestra/runs/2* 2>/dev/null | wc -l)
    [ "$active_count" -eq 0 ] || die "ASSERT FAIL: active run folder remains (should be archived)"
}

smoke_assert_empty() {
    local tmpdir="$1"
    local wt
    wt=$(ls -d "$tmpdir"/wt/run-* | head -1)

    # No parent governance files created
    local found
    found=$(find "$wt" -maxdepth 1 \( -name 'TODO*' -o -name 'DECISIONS*' -o -name 'CHANGELOG*' \) | wc -l)
    [ "$found" -eq 0 ] || die "ASSERT FAIL: empty fixture should not have parent governance"

    # Expected work products exist
    [ "$(cat "$wt/file-a.txt" 2>/dev/null)" = "alpha" ] || die "ASSERT FAIL: file-a.txt"
    [ "$(cat "$wt/file-b.txt" 2>/dev/null)" = "beta" ] || die "ASSERT FAIL: file-b.txt"
}
```

- [ ] **Step 3: Run smoke test manually**

```bash
./bin/orchestra test empty
```
Expected: passes (creates the two files, archives the run, no parent governance created).

- [ ] **Step 4: Add a CI-style test that calls the smoke driver as a sub-test (optional, may be slow)**

Create `tests/test_smoke_empty.sh` that just calls `./bin/orchestra test empty`. Mark in repo README that this requires real Claude credentials.

- [ ] **Step 5: Commit**

```bash
git add bin/orchestra examples/smoke-test/empty/ tests/test_smoke_empty.sh
git commit -m "feat(test): smoke-test driver + empty/ fixture (no-op ingestion path)"
```

---

## Phase 12 — Wind-down ingestion + `with-governance/` fixture

**Goal:** Replace the simple wind-down prompt with the full ingestion contract (Section 6.3); add `with-governance/` smoke fixture with per-source markers; iterate the prompt against it.

**Files:**
- Modify: `lib/winddown-prompt.txt` (full contract)
- Create: `examples/smoke-test/with-governance/` (fixture)
- Modify: `bin/orchestra` (`cmd_test` — assertions for with-governance)
- Create: `tests/test_smoke_with_governance.sh`

- [ ] **Step 1: Rewrite `lib/winddown-prompt.txt` with Section 6.3 contract**

Replace contents with the full wind-down contract: governance shape discovery (CLAUDE.md hierarchy first, then root + `docs/` filename patterns), per-file commits with `wind-down: ingest <run-file> → <parent-file>` messages, append-only behaviour, merge sequence with rebase fallback and push retries, BLOCKED shape for wind-down. Reference spec Section 6.3 in a comment for the maintainer.

(Prompt content is implementation detail per spec Section 15. Iterate against the with-governance/ fixture in Phase 13.)

- [ ] **Step 2: Create `examples/smoke-test/with-governance/`**

```bash
mkdir -p examples/smoke-test/with-governance
cat > examples/smoke-test/with-governance/README.md <<'EOF'
# With-governance smoke-test fixture

Pre-populated TODO/DECISIONS/CHANGELOG with [fixture-original] markers.
The OBJECTIVE.md instructs the agent to use [smoke-todo]/[smoke-decision]/
[smoke-changelog] markers in its run governance so the test can verify
each marker lands in the correct destination.
EOF

cat > examples/smoke-test/with-governance/CLAUDE.md <<'EOF'
# Smoke-test project (with governance)

## Governance
- TODO entries live in TODO.md at root
- Decisions live in DECISIONS.md at root
- Changelog lives in CHANGELOG.md at root
EOF

cat > examples/smoke-test/with-governance/TODO.md <<'EOF'
# TODO

[fixture-original] T001: Pre-existing entry — must not be modified by wind-down
EOF

cat > examples/smoke-test/with-governance/DECISIONS.md <<'EOF'
# Decisions

[fixture-original] D001: Pre-existing decision — must not be modified by wind-down
EOF

cat > examples/smoke-test/with-governance/CHANGELOG.md <<'EOF'
# Changelog

[fixture-original] C001: Pre-existing changelog entry — must not be modified by wind-down
EOF

cat > examples/smoke-test/with-governance/OBJECTIVE.md <<'EOF'
# Run Objective

Create two text files (`file-a.txt` containing `alpha`; `file-b.txt` containing `beta`)
in the worktree, then record your run-level governance using these EXACT marker
prefixes:

- In your `3-TODO.md`, prefix each entry `[smoke-todo]`
- In your `4-DECISIONS.md`, prefix each entry `[smoke-decision]`
- In your `5-CHANGELOG.md`, prefix each entry `[smoke-changelog]`

These markers are required by the smoke test to verify wind-down ingestion lands
each source-file's content in the CORRECT parent destination. Do not use any of
the other markers in the wrong file.

When both work products exist and the rolling files contain markers, emit COMPLETE.
EOF
```

- [ ] **Step 3: Add `smoke_assert_with_governance` to `bin/orchestra`**

```bash
smoke_assert_with_governance() {
    local tmpdir="$1"
    local wt
    wt=$(ls -d "$tmpdir"/wt/run-* | head -1)

    # Each parent file: original [fixture-original] entry preserved + correct marker present
    grep -q '\[fixture-original\] T001' "$wt/TODO.md" || die "ASSERT FAIL: TODO.md original lost"
    grep -q '\[smoke-todo\]'              "$wt/TODO.md" || die "ASSERT FAIL: TODO.md missing smoke-todo"

    grep -q '\[fixture-original\] D001' "$wt/DECISIONS.md" || die "ASSERT FAIL: DECISIONS.md original lost"
    grep -q '\[smoke-decision\]'         "$wt/DECISIONS.md" || die "ASSERT FAIL: DECISIONS.md missing smoke-decision"

    grep -q '\[fixture-original\] C001' "$wt/CHANGELOG.md" || die "ASSERT FAIL: CHANGELOG.md original lost"
    grep -q '\[smoke-changelog\]'        "$wt/CHANGELOG.md" || die "ASSERT FAIL: CHANGELOG.md missing smoke-changelog"

    # No marker leaked into the wrong file
    ! grep -q '\[smoke-decision\]' "$wt/TODO.md"      || die "ASSERT FAIL: smoke-decision leaked into TODO.md"
    ! grep -q '\[smoke-changelog\]' "$wt/TODO.md"     || die "ASSERT FAIL: smoke-changelog leaked into TODO.md"
    ! grep -q '\[smoke-todo\]'      "$wt/DECISIONS.md" || die "ASSERT FAIL: smoke-todo leaked into DECISIONS.md"
    ! grep -q '\[smoke-changelog\]' "$wt/DECISIONS.md" || die "ASSERT FAIL: smoke-changelog leaked into DECISIONS.md"
    ! grep -q '\[smoke-todo\]'      "$wt/CHANGELOG.md" || die "ASSERT FAIL: smoke-todo leaked into CHANGELOG.md"
    ! grep -q '\[smoke-decision\]'  "$wt/CHANGELOG.md" || die "ASSERT FAIL: smoke-decision leaked into CHANGELOG.md"

    # Wind-down per-file commits visible
    cd "$wt"
    git log --grep "wind-down: ingest 3-TODO.md → "      | grep -q . || die "ASSERT FAIL: missing TODO commit"
    git log --grep "wind-down: ingest 4-DECISIONS.md → " | grep -q . || die "ASSERT FAIL: missing DECISIONS commit"
    git log --grep "wind-down: ingest 5-CHANGELOG.md → " | grep -q . || die "ASSERT FAIL: missing CHANGELOG commit"
}
```

- [ ] **Step 4: Iterate prompt**

Run `./bin/orchestra test with-governance` repeatedly, refining `lib/winddown-prompt.txt` until assertions pass. Expect 3-5 iterations of:
1. Run smoke test
2. If failure, inspect the run's `7-SUMMARY.md` and the parent files in the worktree
3. Adjust prompt to clarify the failing instruction
4. Re-run

This phase's deliverable is a working prompt that passes the assertions. Commit each substantive prompt change.

- [ ] **Step 5: Final commit**

```bash
git add lib/winddown-prompt.txt examples/smoke-test/with-governance/ bin/orchestra
git commit -m "feat(winddown): full ingestion contract + with-governance smoke fixture"
```

---

## Phase 13 — Conflict surfacing (Section 6.3 step 4a)

**Goal:** Wind-down agent surfaces semantic conflicts in `7-SUMMARY.md` per the schema in Section 6.3 step 4a.

**Files:**
- Modify: `lib/winddown-prompt.txt`
- Create: `examples/smoke-test/with-conflict/` (third fixture for conflict detection)
- Modify: `bin/orchestra` (`cmd_test` — variant + assertions)

- [ ] **Step 1: Add conflict-flagging instructions to wind-down prompt**

Add a section in `lib/winddown-prompt.txt`:
```
## Step 4a — Surface conflicts

Before appending each new entry to a parent file, scan the existing parent
content for entries that may semantically conflict (same key/topic but
contradictory status, decision reversal, superseded TODO entries).

Append-only is preserved: do NOT modify existing entries.

Record each potential conflict in 7-SUMMARY.md under a "Potential governance
conflicts" subsection using EXACTLY this format:

### Conflict <N>
- **Source:** `<run-file>:<entry-id-or-line>` — `<one-line summary>`
- **Target:** `<parent-file>:<entry-id-or-line>` — `<one-line summary>`
- **Reading:** <1-3 sentences explaining the conflict>
- **Recommended resolution:** <supersede / merge / clarify / no action>

If you detect no conflicts, the subsection contains exactly the line:
_No potential conflicts detected._
```

- [ ] **Step 2: Create `with-conflict/` fixture**

```bash
mkdir -p examples/smoke-test/with-conflict
cat > examples/smoke-test/with-conflict/CLAUDE.md <<'EOF'
# Smoke-test project (conflict detection)
## Governance
- DECISIONS.md at root.
EOF

cat > examples/smoke-test/with-conflict/DECISIONS.md <<'EOF'
# Decisions

[fixture-original] D001: We will use SQLite for the database.
EOF

cat > examples/smoke-test/with-conflict/OBJECTIVE.md <<'EOF'
# Run Objective

Record an executive decision in your `4-DECISIONS.md`:
"We will use Postgres for the database (SQLite was insufficient for our needs)."

Prefix with [smoke-decision].

This decision contradicts an existing [fixture-original] decision in DECISIONS.md.
The wind-down agent should detect this and surface it as a Potential Governance
Conflict in 7-SUMMARY.md.

Emit COMPLETE when the decision is recorded.
EOF
```

- [ ] **Step 3: Add `smoke_assert_with_conflict` and a third variant**

```bash
smoke_assert_with_conflict() {
    local tmpdir="$1"
    local archive
    archive=$(ls -d "$tmpdir"/wt/run-*/.orchestra/runs/archive/* | head -1)

    # Conflict surfaced in 7-SUMMARY.md per the schema
    grep -q "Potential governance conflicts" "$archive/7-SUMMARY.md" \
        || die "ASSERT FAIL: no conflicts subsection"

    grep -q "### Conflict" "$archive/7-SUMMARY.md" \
        || die "ASSERT FAIL: no conflict entry"

    grep -qE 'Source:.*4-DECISIONS' "$archive/7-SUMMARY.md" \
        || die "ASSERT FAIL: conflict source not labelled 4-DECISIONS"

    grep -qE 'Target:.*DECISIONS\.md' "$archive/7-SUMMARY.md" \
        || die "ASSERT FAIL: conflict target not labelled DECISIONS.md"

    # Both decisions present in parent (append-only preserved)
    grep -q '\[fixture-original\] D001.*SQLite' "$tmpdir"/wt/run-*/DECISIONS.md \
        || die "ASSERT FAIL: original decision lost"
    grep -q '\[smoke-decision\].*Postgres' "$tmpdir"/wt/run-*/DECISIONS.md \
        || die "ASSERT FAIL: new decision missing"
}
```

In `cmd_test`, accept third variant `with-conflict`. Run.

- [ ] **Step 4: Iterate prompt against fixture, commit**

```bash
git add lib/winddown-prompt.txt examples/smoke-test/with-conflict/ bin/orchestra
git commit -m "feat(winddown): conflict surfacing per spec Section 6.3 step 4a"
```

---

## Phase 14 — Quota pacing

**Goal:** Cherry-pick existing quota pacing from `bin/orchestrator.sh` and integrate.

**Files:**
- Modify: `bin/orchestrator.sh`

- [ ] **Step 1: Cherry-pick quota pacing implementation**

```bash
git show main:bin/orchestrator.sh | grep -B2 -A40 "QUOTA_PACING"
```

Adapt the loop into the new orchestrator before `claude --print` invocations:
- If `QUOTA_PACING=true`, query Claude API for current quota usage (via `ccusage` or whatever the existing impl uses)
- If above `QUOTA_THRESHOLD`%, sleep `QUOTA_POLL_INTERVAL` and re-check
- Once below, proceed

- [ ] **Step 2: Manual smoke-test step**

Run `orchestra test empty` with `QUOTA_PACING: true` set in CONFIG.md. Confirm normal completion (quota check should return well under threshold immediately).

- [ ] **Step 3: Commit**

```bash
git add bin/orchestrator.sh
git commit -m "feat(orchestrator): quota pacing (cherry-picked from v3)"
```

---

## Phase 15 — `orchestra status` and `orchestra reset`

**Goal:** Implement the remaining CLI commands.

**Files:**
- Modify: `bin/orchestra`
- Create: `tests/test_status_reset.sh`

- [ ] **Step 1: Implement `cmd_status`**

```bash
cmd_status() {
    local project_dir orch
    project_dir="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Not in a git repository"
    orch="$project_dir/.orchestra"
    [ -d "$orch" ] || die ".orchestra/ not found. Run 'orchestra init'."

    echo "=== Orchestra status ==="
    echo ""

    # Active runs (under runs/ but not archive/) — also check worktree run dirs
    local found_active=0
    for run in "$orch"/runs/*/ ; do
        [ -d "$run" ] || continue
        [ "$(basename "$run")" = "archive" ] && continue
        local ts
        ts=$(basename "$run")

        local state="active?"
        if [ -f "$run/BLOCKED" ]; then
            state="BLOCKED"
        elif [ -f "$run/WIND-DOWN-FAILED" ]; then
            state="WIND-DOWN-FAILED"
        else
            local tmux_name="${ORCHESTRA_CONFIG[TMUX_PREFIX]:-orchestra}-$ts"
            if tmux has-session -t "$tmux_name" 2>/dev/null; then
                state="active (tmux: $tmux_name)"
            else
                state="stale"
            fi
        fi

        echo "  $ts: $state"
        found_active=1
    done
    [ $found_active -eq 0 ] && echo "  (no active runs)"

    echo ""
    local archive_count
    archive_count=$(ls -d "$orch"/runs/archive/*/ 2>/dev/null | wc -l)
    echo "Archived runs: $archive_count"
}
```

- [ ] **Step 2: Implement `cmd_reset`**

```bash
cmd_reset() {
    local project_dir orch
    project_dir="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Not in a git repository"
    orch="$project_dir/.orchestra"
    [ -d "$orch" ] || die ".orchestra/ not found."

    # Move every non-archive run folder into archive
    local moved=0
    for run in "$orch"/runs/*/ ; do
        [ -d "$run" ] || continue
        [ "$(basename "$run")" = "archive" ] && continue
        mv "$run" "$orch/runs/archive/"
        moved=$((moved + 1))
    done

    # Cleanup .wind-down.lock if no live tmux holds it
    [ -f "$orch/runs/.wind-down.lock" ] && rm -f "$orch/runs/.wind-down.lock"

    echo "Reset: $moved run folder(s) moved to archive."
}
```

- [ ] **Step 3: Test, commit**

```bash
bash tests/test_status_reset.sh
git add bin/orchestra tests/test_status_reset.sh
git commit -m "feat(cli): orchestra status and orchestra reset"
```

---

## Phase 16 — Repo-root `CLAUDE.md` rewrite

**Goal:** Replace the stale repo-root `CLAUDE.md` with one matching the new layout.

**Files:**
- Modify: `CLAUDE.md` (full rewrite)

- [ ] **Step 1: Read the existing stale `CLAUDE.md`** (for any salvageable narrative)

```bash
cat CLAUDE.md
```

- [ ] **Step 2: Rewrite per spec Section 8 scope**

Replace `CLAUDE.md` with sections:
- **Project:** claude-orchestra — autonomous multi-session orchestration runtime for Claude Code
- **Tech stack:** bash, git, tmux, jq, inotify-tools (Linux-only)
- **Layout:** match the actual `bin/`, `lib/`, `templates/`, `examples/`, `docs/`, `tests/` directories
- **Conventions:** `set -euo pipefail`, `chmod +x` on shipped scripts, project-local install (no global `~/`)
- **Vocabulary:** run-vs-session per spec Section 2
- **Where things live:** spec at `docs/superpowers/specs/`; plan at `docs/superpowers/plans/`; smoke fixtures at `examples/smoke-test/{empty,with-governance,with-conflict}/`; migration prompt at `MIGRATION.md`
- NO governance/protocol section (orchestra has no opinion on parent project's)

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: rewrite repo-root CLAUDE.md for new architecture"
```

---

## Phase 17 — `MIGRATION.md` content

**Goal:** Author the Claude-readable migration prompt at orchestra repo root per spec Section 14.

**Files:**
- Create: `MIGRATION.md`

- [ ] **Step 1: Write `MIGRATION.md`**

Sections:
- One-paragraph context: orchestra has been re-architected; this prompt walks through the migration of an existing v3 install
- Steps for Claude (numbered):
  1. Read the existing `.orchestra/` layout (`ls -la .orchestra/`)
  2. Confirm with user no runs are in flight (`tmux ls | grep orchestra` should be empty; `git worktree list` shouldn't show orchestra worktrees)
  3. Move `.orchestra/{bin,lib,hooks}/` → `.orchestra/runtime/{bin,lib}/`
  4. Delete `.orchestra/runtime/hooks/` (stage-changes hook gone)
  5. Edit `.claude/settings.json` to remove orchestra `PostToolUse` hook (preserve user's other hooks)
  6. Rename `.orchestra/sessions/` → `.orchestra/runs/`
  7. Convert `.orchestra/config` (bash) → `.orchestra/CONFIG.md` (markdown). Mapping table (state explicitly, with each old key → new key or "dropped"):
     - `MAX_SESSIONS` → `MAX_SESSIONS`
     - `MAX_CONSECUTIVE_CRASHES` → `MAX_CONSECUTIVE_CRASHES`
     - `QUOTA_PACING` → `QUOTA_PACING`
     - `QUOTA_THRESHOLD` → `QUOTA_THRESHOLD`
     - `QUOTA_POLL_INTERVAL` → `QUOTA_POLL_INTERVAL`
     - `COOLDOWN_SECONDS` → `COOLDOWN_SECONDS`
     - `CRASH_COOLDOWN_SECONDS` → `CRASH_COOLDOWN_SECONDS`
     - `MODEL` → `MODEL`
     - `EFFORT` → `EFFORT`
     - `WORKTREE_BASE` → `WORKTREE_BASE` (must be absolute path; convert if relative)
     - `BASE_BRANCH` → `BASE_BRANCH`
     - `TMUX_SESSION` → `TMUX_PREFIX` (renamed; old was full name, new is prefix only)
     - `TASKS` → DROPPED (no replacement; new model uses OBJECTIVE.md)
     - `TODO_FILE` → DROPPED (no replacement)
     - `DECISIONS_FILE` → DROPPED
     - `CHANGELOG_FILE` → DROPPED
     - `DEVELOPMENT_PROTOCOL` → DROPPED (parent project's CLAUDE.md hierarchy now)
     - `TOOLCHAIN_FILE` → DROPPED (parent project's concern)
  8. Move `.orchestra/HANDOVER.md` and `.orchestra/INBOX.md` (project-level) to `.orchestra/_legacy_backup/`
  9. Per-run file renames in any in-flight or recent-run folders: `tasks.md` → `3-TODO.md`; split `log.md` content (decisions → `4-DECISIONS.md`, changelog entries → `5-CHANGELOG.md`, narrative/findings → `7-SUMMARY.md`); leave archived runs under `runs/archive/<NNN-label>/` untouched
  10. Install `.orchestra/CLAUDE.md` (detection rule for old: references to `DEVELOPMENT-PROTOCOL.md`, `tasks.md`, `log.md`, "autonomous session rules", "Multi-Session Autonomous Workflow" → back up to `.bak`, install new agent-facing version; if no old signatures, prompt before overwriting)
  11. Update orchestra runtime files by re-running `orchestra init .` from new repo (it will skip user-owned files and only refresh runtime + missing templates)
  12. Inform user: parent project files installed by old orchestra (`DEVELOPMENT-PROTOCOL.md`, "Multi-Session Autonomous Workflow" CLAUDE.md sections, `TODO/`/`Decisions/`/`Changelog/` directories) are no longer orchestra's; user decides keep/modify/remove
- Verification at end: `orchestra status` shows expected state

- [ ] **Step 2: Manual test against logrings (optional)**

Have a Claude session in logrings-main read MIGRATION.md and execute it. Verify result.

- [ ] **Step 3: Commit**

```bash
git add MIGRATION.md
git commit -m "docs: MIGRATION.md interactive prompt for v3 → cleanup migration"
```

---

## Phase 18 — Deletions cleanup

**Goal:** Remove all spec Section 8 deletions in one tidy commit.

**Files:** (all deletions)

- [ ] **Step 1: Delete dropped templates and directories**

```bash
git rm -r examples/test-orchestrator/
git rm -r templates/governance/
git rm -r templates/test/
git rm -rf .orchestra/test/  # if present at repo root
git rm templates/CLAUDE.md
git rm templates/CLAUDE-workflow.md
git rm templates/DEVELOPMENT-PROTOCOL.md
git rm templates/standing-ac.md
git rm templates/toolchain.md
git rm templates/HANDOVER.md
git rm templates/INBOX.md
git rm templates/README.md
git rm templates/config.test
git rm templates/settings.json
git rm templates/config        # bash version (replaced by CONFIG.md)
git rm hooks/stage-changes.sh
rmdir hooks 2>/dev/null
git rm install.sh              # replaced by `orchestra init`
```

- [ ] **Step 2: Sanity check no lingering references**

```bash
grep -rn "DEVELOPMENT-PROTOCOL\|TOOLCHAIN_FILE\|stage-changes\|standing-ac\|orchestra-CLAUDE\.md.*old" \
    bin/ lib/ tests/ templates/ examples/ docs/superpowers/ \
    | grep -v "spec/" | grep -v "plan/" | grep -v "MIGRATION"
```
Expected: no matches outside spec/plan/MIGRATION.md.

- [ ] **Step 3: Commit**

```bash
git commit -m "refactor: remove dropped templates, examples, hooks, install.sh"
```

---

## Phase 19 — Branch wrap-up

- [ ] **Step 1: Run all tests**

```bash
bash tests/run-tests.sh
./bin/orchestra test empty
./bin/orchestra test with-governance
./bin/orchestra test with-conflict
```
Expected: all pass.

- [ ] **Step 2: Push branch**

```bash
git push -u origin orchestra-cleanup-rewrite
```

- [ ] **Step 3: Open PR or merge**

User decides. PR-driven if collaborating, direct merge if solo. Spec is at `8bbdefe`/`90bb0bb`; plan tracks all spec sections.

---

## Cross-cutting concerns

### Testing approach

- **Unit-ish:** `tests/test_*.sh` files run in isolation against tempdirs with stubbed `claude` binaries on `$PATH`. Use stub binaries to simulate exit codes / signals / hangs without burning real Claude quota.
- **Integration:** `orchestra test {empty,with-governance,with-conflict}` against real Claude (requires credentials, costs quota). Runs end-to-end. Not in CI; on-demand only.
- **Run all tests:** `bash tests/run-tests.sh`. Runs every `tests/test_*.sh` in sequence. Smoke tests excluded (they're invoked separately).
- **Bash hygiene:** `set -euo pipefail` at the top of every script. Quote variables defensively.

### Dependency installation

- `bash` (default)
- `git` (default)
- `tmux` (`apt-get install tmux`)
- `jq` (`apt-get install jq`)
- `inotify-tools` (`apt-get install inotify-tools` — Linux-only, hard requirement, preflight-checked at `orchestra init`)

### Git branching strategy

- Feature branch: `orchestra-cleanup-rewrite` (created in Phase 0)
- All work on this branch
- `main` stays at `8bbdefe` until the rewrite is verified end-to-end, then merge or PR
- Old runtime is preserved on main's history; the cherry-pick mechanic (`git show main:bin/orchestrator.sh`) lets you pull forward known-good idioms during the rewrite without conflicting with the new fresh-write files

### Cherry-pick reference index (consolidated from spec Section 14a)

| Idiom | Source path | Phase |
|---|---|---|
| Tmux launch | `bin/orchestra:327` | Phase 4 |
| Tmux conflict pre-flight | `bin/orchestra:317` | Phase 4 |
| `git worktree add` flow | `bin/orchestrator.sh:535` | Phase 4 |
| Quota pacing | `bin/orchestrator.sh` (search `QUOTA_PACING`) | Phase 14 |
| Recovery prompt heredoc | `bin/orchestrator.sh:~383` | Phase 6 |
| Session JSON schema | `bin/orchestrator.sh` (search session_log) | Phase 5 |
| Crash counter mechanics | `bin/orchestrator.sh` (existing single-category) | Phase 5+6 |

### What is deliberately NOT cherry-picked (per spec Section 14a)

- `TODO_FILE`/`DECISIONS_FILE`/`CHANGELOG_FILE` config keys — dropped
- TODO scanning / T-numbered task parsing — dropped
- Per-task branching (`orchestra/<t-number>-<slug>`) — dropped
- `cmd_init` governance directory scaffolding — dropped
- `cmd_init` `.claude/settings.json` setup — dropped
- `cmd_init` DEVELOPMENT-PROTOCOL.md scaffolding — dropped
- `stage-changes.sh` hook — dropped
- BLOCKED-via-task-dependency logic — dropped
- The old in-session prompt heredoc structure — replaced; new prompt referenced via Phase 5/6/8/12/13

### Implementation risk forecast (from final review)

1. **Highest risk:** Wind-down prompt fidelity (Phases 12, 13). Iterate against `with-governance` and `with-conflict` smoke fixtures. Budget multiple iterations.
2. **Medium risk:** Hang detection tuning (Phase 7). False-positive avoidance under long Opus thinking may need threshold adjustment after manual observation.
3. **Medium risk:** Conflict surfacing consistency (Phase 13). The agent's "may semantically conflict" judgement is the looseness in the contract.

Lower-risk: CONFIG.md parser, smoke driver, init/migration. Mechanical work.
