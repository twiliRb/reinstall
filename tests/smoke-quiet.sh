#!/usr/bin/env bash

# Hide Bash xtrace lines on successful smoke cases while preserving useful
# stdout/stderr. On failure, replay the complete trace and diagnostics.
run_smoke_check() {
    local name=$1 status log visible_log
    shift
    log=$(mktemp)
    visible_log=$(mktemp)

    if "$@" >"$log" 2>&1; then
        printf 'PASS %s\n' "$name"
        sed '/^__REINSTALL_XTRACE__ /d' "$log" >"$visible_log"
        if [[ -s "$visible_log" ]]; then
            printf 'OUTPUT %s\n' "$name"
            cat "$visible_log"
        fi
        rm -f "$log"
        rm -f "$visible_log"
        return 0
    else
        status=$?
    fi

    printf 'FAIL %s (exit %s)\n' "$name" "$status" >&2
    cat "$log" >&2
    rm -f "$log"
    rm -f "$visible_log"
    return "$status"
}
