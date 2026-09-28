#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_root/tests/smoke-quiet.sh"

success_output=$(run_smoke_check 'quiet success' sh -c 'printf "@REINSTALL_XTRACE@ top-level trace\\n"; printf "@@REINSTALL_XTRACE@ nested trace\\n"; printf "@@@REINSTALL_XTRACE@ deep trace\\n"; printf "phase one completed\\n"; printf "phase two details\\n" >&2')
[[ "$success_output" == $'PASS quiet success\nOUTPUT quiet success\nphase one completed\nphase two details' ]]
[[ "$success_output" != *'REINSTALL_XTRACE'* ]]

failure_output=$(run_smoke_check 'visible failure' sh -c 'printf "@@REINSTALL_XTRACE@ traced command\\n"; printf "stdout detail\\n"; printf "stderr detail\\n" >&2; exit 23' 2>&1) && {
    printf 'smoke wrapper accepted a failing command\n' >&2
    exit 1
}
failure_status=$?
[[ "$failure_status" == 23 ]]
[[ "$failure_output" == *'FAIL visible failure (exit 23)'* ]]
[[ "$failure_output" == *'@@REINSTALL_XTRACE@ traced command'* ]]
[[ "$failure_output" == *'stdout detail'* ]]
[[ "$failure_output" == *'stderr detail'* ]]

printf 'Quiet smoke output tests passed.\n'
