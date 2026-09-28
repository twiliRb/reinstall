#!/bin/sh
set -eu

run_contract_tests() {
    sh tests/test_reinstall_btrfs_target_config.sh
    sh tests/test_reinstall_network.sh
}

if command -v awk >/dev/null 2>&1 && command -v diff >/dev/null 2>&1; then
    run_contract_tests
    exit 0
fi

# Minimal base images omit tools that are present in the installed systems.
# Add only the two dependencies needed by the shared helper and its assertions.
if command -v apk >/dev/null 2>&1; then
    apk add --no-cache gawk diffutils
elif command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends gawk diffutils
elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --needed --noconfirm gawk diffutils
elif command -v dnf >/dev/null 2>&1; then
    dnf install --assumeyes gawk diffutils
elif command -v microdnf >/dev/null 2>&1; then
    microdnf install --assumeyes gawk diffutils
elif command -v yum >/dev/null 2>&1; then
    yum install --assumeyes gawk diffutils
elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install gawk diffutils
elif command -v nix-shell >/dev/null 2>&1; then
    exec nix-shell -p gawk diffutils --run \
        'sh tests/test_reinstall_btrfs_target_config.sh && sh tests/test_reinstall_network.sh'
elif command -v nix >/dev/null 2>&1; then
    exec nix --extra-experimental-features 'nix-command flakes' shell \
        nixpkgs#gawk nixpkgs#diffutils --command sh -ec \
        'sh tests/test_reinstall_btrfs_target_config.sh && sh tests/test_reinstall_network.sh'
else
    printf 'Cannot install missing awk and diff contract-test dependencies.\n' >&2
    exit 1
fi

command -v awk >/dev/null 2>&1
command -v diff >/dev/null 2>&1
run_contract_tests
