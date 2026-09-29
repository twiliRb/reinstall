#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_root/lib/reinstall-btrfs-layout.sh"

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/reinstall-btrfs-layout.XXXXXX")
trap 'rm -rf "$tmp_root"' EXIT HUP INT TERM

mkdir -p "$tmp_root/bin"
cat >"$tmp_root/bin/chattr" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$REINSTALL_BTRFS_CHATTR_LOG"
EOF
chmod +x "$tmp_root/bin/chattr"
export PATH="$tmp_root/bin:$PATH"
export REINSTALL_BTRFS_CHATTR_LOG="$tmp_root/chattr.log"
reinstall_btrfs_set_nocompress_flag /mnt/@boot
[[ "$(cat "$REINSTALL_BTRFS_CHATTR_LOG")" == '+m /mnt/@boot' ]]
if reinstall_btrfs_set_nocompress_flag >/dev/null 2>&1; then
    echo "no-compression helper accepted a missing target" >&2
    exit 1
fi
printf 'CHECKPOINT btrfs-layout/nocompress-helper: uses chattr +m and validates arguments\n'

# The live preflight needs full e2fsprogs chattr/lsattr support for Btrfs +m;
# BusyBox's applets do not implement that inode attribute.
[[ "$(reinstall_btrfs_preflight_packages)" == "e2fsprogs e2fsprogs-extra btrfs-progs" ]]
[[ "$(reinstall_btrfs_top_level_mount_options '')" == subvolid=5 ]]
[[ "$(reinstall_btrfs_top_level_mount_options 'compress=zstd:3,noatime')" == \
    subvolid=5,compress=zstd:3,noatime ]]
if reinstall_btrfs_top_level_mount_options 'compress-force=zstd'; then
    echo "top-level mount helper accepted compress-force" >&2
    exit 1
fi

preflight_kernel_calls=
ensure_service_started() {
    preflight_kernel_calls="${preflight_kernel_calls}service:$1 "
}
modprobe() {
    preflight_kernel_calls="${preflight_kernel_calls}module:$1 "
}
reinstall_btrfs_activate_kernel_support
[[ "$preflight_kernel_calls" == 'service:modloop module:btrfs ' ]]
printf 'CHECKPOINT btrfs-layout/preflight: packages=%s kernel-calls=%s\n' \
    "$(reinstall_btrfs_preflight_packages)" "${preflight_kernel_calls% }"

# When Debian Installer leaves the filesystem root at subvolume ID 5, the new
# @ and @boot subvolumes are visible in the source while the target is mounted.
copy_fixture=$tmp_root/top-level
mkdir -p "$copy_fixture/etc" "$copy_fixture/boot" "$copy_fixture/@" "$copy_fixture/@boot"
printf 'root-file\n' >"$copy_fixture/etc/config"
printf 'hidden-file\n' >"$copy_fixture/.root-hidden"
printf 'boot-file\n' >"$copy_fixture/boot/kernel"
printf 'new-root-marker\n' >"$copy_fixture/@/destination-marker"
printf 'new-boot-marker\n' >"$copy_fixture/@boot/destination-marker"
reinstall_btrfs_copy_top_level_except_layout_subvolumes "$copy_fixture" "$copy_fixture/@"
[[ "$(cat "$copy_fixture/@/etc/config")" == root-file ]]
[[ "$(cat "$copy_fixture/@/.root-hidden")" == hidden-file ]]
[[ "$(cat "$copy_fixture/@/boot/kernel")" == boot-file ]]
[[ "$(cat "$copy_fixture/@/destination-marker")" == new-root-marker ]]
[[ ! -e "$copy_fixture/@/@/destination-marker" ]]
[[ ! -e "$copy_fixture/@/@boot/destination-marker" ]]
printf 'CHECKPOINT btrfs-layout/rootid5-copy: preserves hidden/root files and skips newly created @/@boot destinations\n'

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
printf 'CHECKPOINT btrfs-layout/efi-gpt-plan:\n%s\n' "$gpt_uefi"

msdos_bios=$'table\tmsdos\npartition\t1\troot\tbtrfs\t1MiB\t100%\tboot\nsubvolume\t@\t/\tcompress=zstd\nsubvolume\t@boot\t/boot\tno-compression'
expect_plan bios "$two_tib" "$msdos_bios"
expect_plan bios 2199023255551 "$msdos_bios"
expect_plan bios 0002199023255552 "$msdos_bios"
printf 'CHECKPOINT btrfs-layout/bios-at-or-below-2tib-plan:\n%s\n' "$msdos_bios"

gpt_bios=$'table\tgpt\npartition\t1\tbios_grub\tnone\t1MiB\t2MiB\tbios_grub\npartition\t2\troot\tbtrfs\t2MiB\t100%\t-\nsubvolume\t@\t/\tcompress=zstd\nsubvolume\t@boot\t/boot\tno-compression'
expect_plan bios 2199023255553 "$gpt_bios"
printf 'CHECKPOINT btrfs-layout/bios-above-2tib-plan:\n%s\n' "$gpt_bios"

none_plan=$(reinstall_btrfs_layout_plan efi 1 '')
[[ "$none_plan" == $'table\tgpt\npartition\t1\tesp\tvfat\t1MiB\t101MiB\tesp\npartition\t2\troot\tbtrfs\t101MiB\t100%\t-\nsubvolume\t@\t/\t\nsubvolume\t@boot\t/boot\tno-compression' ]]
custom_plan=$(reinstall_btrfs_layout_plan bios "$two_tib" 'compress=zlib:9,noatime')
[[ "$(printf '%s\n' "$custom_plan" | awk -F '\t' '$1 == "subvolume" && $3 == "/" {print $4}')" == 'compress=zlib:9,noatime' ]]
printf 'CHECKPOINT btrfs-layout/options: none omits compression; custom root options preserved; /boot policy remains no-compression\n'

for invalid_firmware in '' biosx EFI uefi; do
    expect_rejected "$invalid_firmware" 1
done
for invalid_size in '' 0 000 -1 +1 1.0 1x ' 1' '1 '; do
    expect_rejected bios "$invalid_size"
done
expect_rejected bios
expect_rejected bios 1 extra more
expect_rejected bios 1 'compress-force=zstd'
printf 'CHECKPOINT btrfs-layout/invalid-inputs: invalid firmware, disk sizes, missing and extra arguments rejected\n'

printf 'PASS Btrfs layout planner tests\n'
