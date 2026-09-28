#!/usr/bin/env bash

# Capture verbose smoke output, then print only the named checkpoints on
# success. Failures replay the full command output to retain debugging context.
run_smoke_check() {
    local name=$1 status=0 log spec stage pattern matched
    shift
    local -a checkpoints=()

    while [[ $# -gt 0 && $1 != -- ]]; do
        checkpoints+=("$1")
        shift
    done
    if [[ $# -eq 0 ]]; then
        printf 'FAIL %s: missing -- before smoke command\n' "$name" >&2
        return 2
    fi
    shift
    if [[ $# -eq 0 ]]; then
        printf 'FAIL %s: missing smoke command\n' "$name" >&2
        return 2
    fi

    log=$(mktemp) || return 1
    printf 'RUN %s\n' "$name"
    if "$@" >"$log" 2>&1; then
        for spec in "${checkpoints[@]}"; do
            if [[ "$spec" != *=* ]]; then
                printf 'FAIL %s: malformed checkpoint %s\n' "$name" "$spec" >&2
                status=2
                break
            fi
            stage=${spec%%=*}
            pattern=${spec#*=}
            if matched=$(grep -F -m1 -- "$pattern" "$log"); then
                printf 'CHECKPOINT %s/%s: %s\n' "$name" "$stage" "$matched"
            else
                printf 'FAIL %s: checkpoint %s missing (%s)\n' \
                    "$name" "$stage" "$pattern" >&2
                status=1
                break
            fi
        done
    else
        status=$?
    fi

    if [[ $status -ne 0 ]]; then
        printf 'FAIL %s (exit %s)\n' "$name" "$status" >&2
        cat "$log" >&2
        rm -f "$log"
        return "$status"
    fi

    printf 'PASS %s\n' "$name"
    rm -f "$log"
}
