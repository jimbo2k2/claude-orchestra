#!/bin/bash
# This file is sourced; intentionally does not set 'set -euo pipefail'
# (would leak those options into the caller's shell).
#
# CONFIG.md parser — extracts KEY: VALUE bullets from markdown.
# Spec: build-history/archive/v0-cleanup/2026-04-29-orchestra-cleanup-design.md Section 10.
# Values are stored verbatim in ORCHESTRA_CONFIG associative array; never eval'd.
#
# Usage:
#   declare -gA ORCHESTRA_CONFIG
#   parse_config_md /path/to/CONFIG.md   # populate from markdown bullets
#   apply_config_defaults                # fill in defaults for optional keys
#   validate_config                      # type/range/enum/pattern checks
#
# Why bash regex + literal storage (no eval/source): the threat model is
# "user typo" not "untrusted input", but values still must be treated as
# opaque strings so a stray backtick or $() in the markdown can't ever
# execute. Loud-fail validation runs before any session starts.

# Parse markdown bullet lines of the form `- \`KEY\`: VALUE` into ORCHESTRA_CONFIG.
# Caller MUST `declare -gA ORCHESTRA_CONFIG` before calling.
# Errors abort with non-zero exit and a message to stderr.
parse_config_md() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "ERROR: config file not found: $file" >&2
        return 1
    fi

    local line
    local key
    local value
    local -A seen=()
    local re='^[[:space:]]*-[[:space:]]+`([A-Z_][A-Z0-9_]*)`:[[:space:]]*(.+)$'

    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ $re ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            # Strip trailing whitespace; leading whitespace is already consumed
            # by the [[:space:]]* portion of the regex above.
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

# Apply defaults for optional keys (call after parse, before validate).
# Uses :=, so only keys not already set are filled in. Idempotent and
# side-effect-free on missing keys — calling twice is harmless.
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

# Validate ORCHESTRA_CONFIG has required keys and all values pass type/range
# checks per spec Section 10. Returns non-zero on first failure with a
# message on stderr.
validate_config() {
    local required=(MAX_SESSIONS MAX_CONSECUTIVE_CRASHES MODEL WORKTREE_BASE BASE_BRANCH)
    local key
    for key in "${required[@]}"; do
        if [ -z "${ORCHESTRA_CONFIG[$key]:-}" ]; then
            echo "ERROR: required config key '$key' is missing" >&2
            return 1
        fi
    done

    # Type / range / enum / pattern checks per spec table.
    _check_int_min   MAX_SESSIONS            1   || return 1
    _check_int_min   MAX_CONSECUTIVE_CRASHES 1   || return 1
    _check_int_min   MAX_HANG_SECONDS        60  || return 1
    _check_enum      MODEL  opus sonnet haiku    || return 1
    _check_enum      EFFORT low  medium  high    || return 1
    _check_abspath   WORKTREE_BASE                || return 1
    _check_nonempty  BASE_BRANCH                  || return 1
    _check_pattern   TMUX_PREFIX '^[a-z][a-z0-9-]*$' || return 1
    _check_bool      QUOTA_PACING                 || return 1
    _check_int_range QUOTA_THRESHOLD 1 100        || return 1
    _check_int_min   QUOTA_POLL_INTERVAL    30   || return 1
    _check_int_min   COOLDOWN_SECONDS       0    || return 1
    _check_int_min   CRASH_COOLDOWN_SECONDS 0    || return 1
    _check_int_min   SMOKE_TEST_TIMEOUT     60   || return 1

    return 0
}

# --- internal validation helpers ---
# Each helper:
#   - Skips silently if the key is unset (so optional keys without defaults are OK).
#   - Returns 0 on pass, 1 on fail, with an explanatory message on stderr.

_check_int_min() {
    local key="$1"
    local min="$2"
    local value="${ORCHESTRA_CONFIG[$key]:-}"
    if [ -z "$value" ]; then
        return 0
    fi
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "ERROR: config key '$key'='$value' must be a non-negative integer" >&2
        return 1
    fi
    if [ "$value" -lt "$min" ]; then
        echo "ERROR: config key '$key'=$value must be >= $min" >&2
        return 1
    fi
    return 0
}

_check_int_range() {
    local key="$1"
    local lo="$2"
    local hi="$3"
    local value="${ORCHESTRA_CONFIG[$key]:-}"
    if [ -z "$value" ]; then
        return 0
    fi
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "ERROR: config key '$key'='$value' must be a non-negative integer" >&2
        return 1
    fi
    if [ "$value" -lt "$lo" ] || [ "$value" -gt "$hi" ]; then
        echo "ERROR: config key '$key'=$value must be in [$lo,$hi]" >&2
        return 1
    fi
    return 0
}

_check_enum() {
    local key="$1"
    shift
    local value="${ORCHESTRA_CONFIG[$key]:-}"
    if [ -z "$value" ]; then
        return 0
    fi
    local option
    for option in "$@"; do
        if [ "$value" = "$option" ]; then
            return 0
        fi
    done
    echo "ERROR: config key '$key'='$value' must be one of: $*" >&2
    return 1
}

_check_abspath() {
    local key="$1"
    local value="${ORCHESTRA_CONFIG[$key]:-}"
    if [ -z "$value" ]; then
        return 0
    fi
    if [[ "$value" != /* ]]; then
        echo "ERROR: config key '$key'='$value' must be an absolute path" >&2
        return 1
    fi
    return 0
}

_check_nonempty() {
    local key="$1"
    local value="${ORCHESTRA_CONFIG[$key]:-}"
    if [ -z "$value" ]; then
        echo "ERROR: config key '$key' must not be empty" >&2
        return 1
    fi
    return 0
}

_check_pattern() {
    local key="$1"
    local pattern="$2"
    local value="${ORCHESTRA_CONFIG[$key]:-}"
    if [ -z "$value" ]; then
        return 0
    fi
    if ! [[ "$value" =~ $pattern ]]; then
        echo "ERROR: config key '$key'='$value' must match pattern $pattern" >&2
        return 1
    fi
    return 0
}

_check_bool() {
    local key="$1"
    local value="${ORCHESTRA_CONFIG[$key]:-}"
    if [ -z "$value" ]; then
        return 0
    fi
    if [ "$value" != "true" ] && [ "$value" != "false" ]; then
        echo "ERROR: config key '$key'='$value' must be 'true' or 'false'" >&2
        return 1
    fi
    return 0
}
