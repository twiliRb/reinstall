#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_root/tests/smoke-quiet.sh"

success_output=$(run_smoke_check 'checkpoint success' \
    'download=phase one completed' 'configuration=phase two details' -- \
    sh -c 'printf "debug trace that should not be replayed\\n"; printf "phase one completed\\n"; printf "phase two details\\n" >&2')
[[ "$success_output" == $'RUN checkpoint success\nCHECKPOINT checkpoint success/download: phase one completed\nCHECKPOINT checkpoint success/configuration: phase two details\nPASS checkpoint success' ]]
[[ "$success_output" != *'debug trace'* ]]

failure_output=$(run_smoke_check 'visible failure' 'phase=phase passed' -- \
    sh -c 'printf "stdout detail\\n"; printf "stderr detail\\n" >&2; exit 23' 2>&1) && {
    printf 'smoke wrapper accepted a failing command\n' >&2
    exit 1
}
failure_status=$?
[[ "$failure_status" == 23 ]]
[[ "$failure_output" == *'FAIL visible failure (exit 23)'* ]]
[[ "$failure_output" == *'stdout detail'* ]]
[[ "$failure_output" == *'stderr detail'* ]]

missing_output=$(run_smoke_check 'missing phase' 'download=download complete' -- \
    sh -c 'printf "partial output\\n"' 2>&1) && {
    printf 'smoke wrapper accepted a missing checkpoint\n' >&2
    exit 1
}
missing_status=$?
[[ "$missing_status" == 1 ]]
[[ "$missing_output" == *'FAIL missing phase: checkpoint download missing'* ]]
[[ "$missing_output" == *'partial output'* ]]

rejection_output=$(run_smoke_failure_check 'expected preflight rejection' \
    'Invalid --filesystem value: invalid' -- \
    sh -c 'printf "Invalid --filesystem value: invalid\n" >&2; exit 1')
[[ "$rejection_output" == $'RUN expected preflight rejection\nCHECKPOINT expected preflight rejection/rejection: Invalid --filesystem value: invalid\nCHECKPOINT expected preflight rejection/no-disk-operations: no parted, mkfs, wipefs, or Create Part marker observed\nPASS expected preflight rejection' ]]

unexpected_success=$(run_smoke_failure_check 'unexpected success' 'expected error' -- \
    sh -c 'printf "command succeeded unexpectedly\n"' 2>&1) && {
    printf 'failure wrapper accepted a successful command\n' >&2
    exit 1
}
[[ "$unexpected_success" == *'FAIL unexpected success: command unexpectedly succeeded'* ]]
[[ "$unexpected_success" == *'command succeeded unexpectedly'* ]]

unsafe_rejection=$(run_smoke_failure_check 'late rejection' 'expected error' -- \
    sh -c 'printf "Create Part\nexpected error\n" >&2; exit 1' 2>&1) && {
    printf 'failure wrapper accepted a rejection after disk operations began\n' >&2
    exit 1
}
[[ "$unsafe_rejection" == *'FAIL late rejection: disk operation marker appeared before rejection'* ]]
[[ "$unsafe_rejection" == *'Create Part'* ]]

printf 'CHECKPOINT smoke wrapper success: emitted matched phase output and PASS result\n'
printf 'CHECKPOINT smoke wrapper failure: nonzero exit and missing phases include captured output\n'
printf 'CHECKPOINT smoke wrapper rejection: expected errors and preflight boundary are visible\n'
printf 'Quiet smoke output tests passed.\n'
