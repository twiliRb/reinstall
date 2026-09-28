#!/usr/bin/env bash

# Run a smoke case without flooding successful CI output. Keep stdout and
# stderr together so a failing case can replay the complete diagnostic trace.
run_smoke_check() {
    local name=$1 status log
    shift
    log=$(mktemp)

    if "$@" >"$log" 2>&1; then
        printf 'PASS %s\n' "$name"
        rm -f "$log"
        return 0
    else
        status=$?
    fi

    printf 'FAIL %s (exit %s)\n' "$name" "$status" >&2
    cat "$log" >&2
    rm -f "$log"
    return "$status"
}
