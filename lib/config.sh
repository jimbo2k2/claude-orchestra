#!/bin/bash
# config.sh — Read .orchestra/config and export governance paths
#
# Source this file from orchestrator.sh and hook scripts.
# Usage: source "$LIB_DIR/config.sh" && load_orchestra_config "$PROJECT_DIR"

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
