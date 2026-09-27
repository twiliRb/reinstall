#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_root/lib/reinstall-btrfs-layout.sh"

# The live preflight needs full e2fsprogs chattr/lsattr support for Btrfs +m;
# BusyBox's applets do not implement that inode attribute.
[[ "$(reinstall_btrfs_preflight_packages)" == "e2fsprogs e2fsprogs-extra btrfs-progs" ]]

preflight_kernel_calls=
ensure_service_started() {
    preflight_kernel_calls="${preflight_kernel_calls}service:$1 "
}
modprobe() {
    preflight_kernel_calls="${preflight_kernel_calls}module:$1 "
}
reinstall_btrfs_activate_kernel_support
[[ "$preflight_kernel_calls" == 'service:modloop module:btrfs ' ]]

two_tib=2199023255552

expect_plan() {
    local firmware=$1
    local disk_size=$2
    local expected=$3
    local actual

    actual=$(reinstall_btrfs_layout_plan "$firmware" "$disk_size")
    if [[ "$actual" != "$expected" ]]; then
        printf 'unexpected %s plan for %s bytes\nexpected:\n%s\nactual:\n%s\n' \
            "$firmware" "$disk_size" "$expected" "$actual" >&2
        exit 1
    fi
}

expect_rejected() {
    local actual

    if actual=$(reinstall_btrfs_layout_plan "$@"); then
        printf 'accepted invalid planner input: %s\n' "$*" >&2
        exit 1
    fi
    if [[ -n "$actual" ]]; then
        printf 'emitted a plan for invalid planner input: %s\n%s\n' "$*" "$actual" >&2
        exit 1
    fi
}

gpt_uefi=$'table\tgpt\npartition\t1\tesp\tvfat\t1MiB\t101MiB\tesp\npartition\t2\troot\tbtrfs\t101MiB\t100%\t-\nsubvolume\t@\t/\tcompress=zstd\nsubvolume\t@boot\t/boot\tno-compression'
expect_plan efi 1 "$gpt_uefi"
expect_plan efi 999999999999999999999999999999 "$gpt_uefi"

msdos_bios=$'table\tmsdos\npartition\t1\troot\tbtrfs\t1MiB\t100%\tboot\nsubvolume\t@\t/\tcompress=zstd\nsubvolume\t@boot\t/boot\tno-compression'
expect_plan bios "$two_tib" "$msdos_bios"
expect_plan bios 2199023255551 "$msdos_bios"
expect_plan bios 0002199023255552 "$msdos_bios"

gpt_bios=$'table\tgpt\npartition\t1\tbios_grub\tnone\t1MiB\t2MiB\tbios_grub\npartition\t2\troot\tbtrfs\t2MiB\t100%\t-\nsubvolume\t@\t/\tcompress=zstd\nsubvolume\t@boot\t/boot\tno-compression'
expect_plan bios 2199023255553 "$gpt_bios"

for invalid_firmware in '' biosx EFI uefi; do
    expect_rejected "$invalid_firmware" 1
done
for invalid_size in '' 0 000 -1 +1 1.0 1x ' 1' '1 '; do
    expect_rejected bios "$invalid_size"
done
expect_rejected bios
expect_rejected bios 1 extra

printf 'Btrfs layout planner tests passed\n'
