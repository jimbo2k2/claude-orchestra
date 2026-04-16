#!/bin/bash
# config.sh — Read .orchestra/config and export governance paths
#
# Source this file from orchestrator.sh and hook scripts.
# Usage: source "$PROJECT_DIR/.orchestra/lib/config.sh" && load_orchestra_config "$PROJECT_DIR"

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
    DECISIONS_FILE="${project_dir}/${DECISIONS_FILE}"
    CHANGELOG_FILE="${project_dir}/${CHANGELOG_FILE}"
    TOOLCHAIN_FILE="${project_dir}/${TOOLCHAIN_FILE:-.orchestra/toolchain.md}"
    DEVELOPMENT_PROTOCOL="${project_dir}/${DEVELOPMENT_PROTOCOL:-DEVELOPMENT-PROTOCOL.md}"
}

# Pre-flight validation: check all required config fields and files exist
preflight_check() {
    local errors=0

    if [ -z "${TASKS:-}" ]; then
        echo "ERROR: No tasks assigned. Set TASKS=T315,T325,... in .orchestra/config" >&2
        errors=$((errors + 1))
    fi

    if [ -z "${TMUX_SESSION:-}" ]; then
        echo "ERROR: TMUX_SESSION not set in .orchestra/config" >&2
        errors=$((errors + 1))
    fi

    if [ ! -f "${DEVELOPMENT_PROTOCOL:-}" ]; then
        echo "ERROR: Development protocol not found at ${DEVELOPMENT_PROTOCOL:-DEVELOPMENT-PROTOCOL.md}" >&2
        errors=$((errors + 1))
    fi

    if [ ! -f "$TOOLCHAIN_FILE" ] || [ ! -s "$TOOLCHAIN_FILE" ]; then
        echo "ERROR: Toolchain not configured. Write build/test commands to $TOOLCHAIN_FILE" >&2
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

    # Verify each T-number in TASKS exists in TODO file
    IFS=',' read -ra task_list <<< "$TASKS"
    for tnumber in "${task_list[@]}"; do
        tnumber=$(echo "$tnumber" | xargs)  # trim whitespace
        if ! grep -q "### $tnumber" "$TODO_FILE" 2>/dev/null; then
            echo "WARNING: $tnumber not found in $TODO_FILE — check the task number" >&2
        fi
    done

    return "$errors"
}

# Validate that tools listed in toolchain.md's ## Prerequisites section are installed.
validate_toolchain_prereqs() {
    local toolchain="$TOOLCHAIN_FILE"
    local in_prereqs=false
    local errors=0

    if [ ! -f "$toolchain" ]; then
        return 0
    fi

    while IFS= read -r line; do
        if [[ "$line" =~ ^##[[:space:]]+Prerequisites ]]; then
            in_prereqs=true
            continue
        fi
        if $in_prereqs && [[ "$line" =~ ^## ]]; then
            break
        fi
        if $in_prereqs && [[ "$line" =~ ^-[[:space:]]+([a-zA-Z0-9_-]+) ]]; then
            local tool="${BASH_REMATCH[1]}"
            if ! command -v "$tool" &>/dev/null; then
                echo "ERROR: Toolchain prerequisite '$tool' not found. See $toolchain" >&2
                errors=$((errors + 1))
            fi
        fi
    done < "$toolchain"

    if [ "$errors" -gt 0 ]; then
        echo "HINT: Install missing prerequisites before running orchestra." >&2
        return 1
    fi
    return 0
}
