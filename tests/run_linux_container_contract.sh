#!/bin/sh
set -eu

run_contract_tests() {
    printf 'CHECKPOINT container-contract/btrfs-target-config: start\n'
    sh tests/test_reinstall_btrfs_target_config.sh
    printf 'CHECKPOINT container-contract/network-policy: start\n'
    sh tests/test_reinstall_network.sh
    printf 'CHECKPOINT container-contract/network-probe: start\n'
    sh tests/test_reinstall_network_probe.sh
    printf 'CHECKPOINT container-contract/ext4-layout: start\n'
    sh tests/test_reinstall_ext4_layout.sh
    printf 'CHECKPOINT container-contract/ssh-key-writer: start\n'
    sh tests/test_reinstall_ssh.sh
    printf 'PASS container contract tests\n'
}

container_id=$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | head -n 1 | tr -d '"')
container_version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | head -n 1 | tr -d '"')
printf 'CHECKPOINT container-contract/identity: distro=%s version=%s\n' \
    "${container_id:-unknown}" "${container_version:-unknown}"

if command -v awk >/dev/null 2>&1 && command -v diff >/dev/null 2>&1 &&
    command -v cmp >/dev/null 2>&1 && command -v stat >/dev/null 2>&1 &&
    command -v mktemp >/dev/null 2>&1 && command -v ln >/dev/null 2>&1; then
    printf 'CHECKPOINT container-contract/dependencies: awk=%s diff=%s cmp=%s stat=%s source=base-image\n' \
        "$(command -v awk)" "$(command -v diff)" "$(command -v cmp)" "$(command -v stat)"
    run_contract_tests
    exit 0
fi

# Minimal base images omit tools that are present in the installed systems.
# Add only the tools required by the shared helper and its assertions.
printf 'CHECKPOINT container-contract/dependencies: installing missing awk, diff, coreutils\n'
if command -v apk >/dev/null 2>&1; then
    apk add --no-cache gawk diffutils coreutils
elif command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends gawk diffutils coreutils
elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --needed --noconfirm gawk diffutils coreutils
elif command -v dnf >/dev/null 2>&1; then
    # RHEL-family minimal images ship coreutils-single, which conflicts with
    # the full coreutils package. diffutils supplies the missing cmp command.
    dnf install --assumeyes gawk diffutils
elif command -v microdnf >/dev/null 2>&1; then
    microdnf install --assumeyes gawk diffutils
elif command -v yum >/dev/null 2>&1; then
    yum install --assumeyes gawk diffutils
elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install gawk diffutils coreutils
elif command -v nix-shell >/dev/null 2>&1; then
    printf 'CHECKPOINT container-contract/dependencies: provisioning=nix-shell packages=gawk,diffutils,coreutils\n'
    exec nix-shell -p gawk diffutils coreutils --run \
        'sh tests/run_linux_container_contract.sh'
elif command -v nix >/dev/null 2>&1; then
    printf 'CHECKPOINT container-contract/dependencies: provisioning=nix-command packages=gawk,diffutils,coreutils\n'
    exec nix --extra-experimental-features 'nix-command flakes' shell \
        nixpkgs#gawk nixpkgs#diffutils nixpkgs#coreutils --command sh -ec \
        'sh tests/run_linux_container_contract.sh'
else
    printf 'Cannot install missing container-contract dependencies.\n' >&2
    exit 1
fi

command -v awk >/dev/null 2>&1
command -v diff >/dev/null 2>&1
command -v cmp >/dev/null 2>&1
command -v stat >/dev/null 2>&1
command -v mktemp >/dev/null 2>&1
command -v ln >/dev/null 2>&1
printf 'CHECKPOINT container-contract/dependencies: awk=%s diff=%s cmp=%s stat=%s source=installed\n' \
    "$(command -v awk)" "$(command -v diff)" "$(command -v cmp)" "$(command -v stat)"
run_contract_tests
