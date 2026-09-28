#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo_root/lib/reinstall-btrfs-layout.sh"

usage() {
    echo "Usage: $0 prepare-all|verify-all <artifact-directory>" >&2
    exit 2
}

fail() {
    echo "Ext4 reboot dry-run: $*" >&2
    [ -n "${_observed_root_fs:-}" ] && printf 'Observed root filesystem: %s\n' "$_observed_root_fs" >&2 || true
    [ -n "${_observed_efi_fs:-}" ] && printf 'Observed EFI filesystem: %s\n' "$_observed_efi_fs" >&2 || true
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

ensure_loop_devices() {
    require_command mknod
    require_command losetup
    if [ ! -e /dev/loop-control ]; then
        mknod /dev/loop-control c 10 237 || fail "cannot create /dev/loop-control"
    fi
    if ! losetup -f >/dev/null 2>&1; then
        _loop_number=0
        while [ "$_loop_number" -lt 8 ]; do
            [ -e "/dev/loop$_loop_number" ] ||
                mknod "/dev/loop$_loop_number" b 7 "$_loop_number" ||
                fail "cannot create /dev/loop$_loop_number"
            _loop_number=$((_loop_number + 1))
        done
        losetup -f >/dev/null 2>&1 || fail "no loop device is available"
    fi
}

cleanup() {
    trap - 0 HUP INT TERM
    if [ -n "${_work_dir:-}" ] && [ -d "$_work_dir" ]; then
        if [ "${_efi_mounted:-no}" = yes ]; then
            umount "$_efi_mount" 2>/dev/null || true
        fi
        if [ "${_root_mounted:-no}" = yes ]; then
            umount "$_target" 2>/dev/null || true
        fi
        rm -rf "$_work_dir"
    fi
}

plan_case() {
    _distro=$1
    _boot_mode=$2
    # The layout is selected from a representative sub-2-TiB disk size. The
    # larger BIOS GPT boundary is covered by tests/test_reinstall_ext4_layout.sh.
    if ! _plan=$(reinstall_ext4_layout_plan "$_boot_mode" 1073741824); then
        fail "could not obtain the ext4 layout plan for $_distro/$_boot_mode"
    fi
    _table=$(printf '%s\n' "$_plan" | awk -F '\t' '$1 == "table" { print $2 }')
    _root_partition=$(printf '%s\n' "$_plan" |
        awk -F '\t' '$1 == "partition" && $3 == "root" { print $2 }')
    _efi_partition=$(printf '%s\n' "$_plan" |
        awk -F '\t' '$1 == "partition" && $3 == "esp" { print $2 }')
    case $_table in gpt|msdos) ;; *) fail "layout plan returned an unknown partition table" ;; esac
    case $_root_partition in ''|*[!0123456789]*) fail "layout plan omitted the root partition number" ;; esac
    if [ "$_boot_mode" = efi ]; then
        case $_efi_partition in ''|*[!0123456789]*) fail "layout plan omitted the EFI partition number" ;; esac
    else
        [ -z "$_efi_partition" ] || fail "BIOS layout unexpectedly contains an EFI partition"
        _efi_partition=none
    fi
    printf 'CHECKPOINT ext4-dry-run/plan: distro=%s firmware=%s table=%s root-partition=%s esp-partition=%s\n' \
        "$_distro" "$_boot_mode" "$_table" "$_root_partition" "$_efi_partition"
}

format_image() {
    _mkfs_image=$1
    _mkfs_distro=$2
    _mkfs_log=$3
    if ! reinstall_ext4_format_root "$_mkfs_image" "$_mkfs_distro" >"$_mkfs_log" 2>&1; then
        cat "$_mkfs_log" >&2
        fail "ext4 formatting failed for $_mkfs_distro"
    fi
}

format_efi_image() {
    _efi_mkfs_image=$1
    _efi_mkfs_log=$2
    if ! mkfs.vfat -n EFI "$_efi_mkfs_image" >"$_efi_mkfs_log" 2>&1; then
        cat "$_efi_mkfs_log" >&2
        fail "FAT EFI formatting failed"
    fi
}

prepare_state() {
    _distro=$1
    _boot_mode=$2
    _state_dir=$3
    _work_dir=$4
    _image="$_state_dir/root.ext4.img"
    _efi_image="$_state_dir/esp.fat.img"
    _target="$_work_dir/target"
    _efi_mount="$_target/efi"
    _root_mounted=no
    _efi_mounted=no

    plan_case "$_distro" "$_boot_mode"
    _state_table=$_table
    _state_root_partition=$_root_partition
    _state_efi_partition=$_efi_partition

    [ ! -L "$_state_dir" ] || fail "refusing symlink case directory: $_state_dir"
    mkdir "$_state_dir" || fail "case directory already exists or cannot be created: $_state_dir"
    [ ! -L "$_image" ] || fail "refusing symlink root image: $_image"
    [ ! -L "$_efi_image" ] || fail "refusing symlink EFI image: $_efi_image"
    truncate -s 96M "$_image"
    format_image "$_image" "$_distro" "$_work_dir/mkfs-ext4.log"
    _root_uuid=$(blkid -s UUID -o value "$_image")
    reinstall_btrfs_valid_uuid "$_root_uuid" || fail "could not read the root ext4 UUID"

    _efi_uuid=
    if [ "$_boot_mode" = efi ]; then
        truncate -s 32M "$_efi_image"
        format_efi_image "$_efi_image" "$_work_dir/mkfs-vfat.log"
        _efi_uuid=$(blkid -s UUID -o value "$_efi_image")
        reinstall_btrfs_valid_efi_uuid "$_efi_uuid" || fail "could not read the EFI FAT UUID"
    fi
    printf 'CHECKPOINT ext4-dry-run/prepare-format: distro=%s firmware=%s root=ext4 root-uuid=%s esp=%s esp-uuid=%s\n' \
        "$_distro" "$_boot_mode" "$_root_uuid" \
        "$([ "$_boot_mode" = efi ] && printf vfat || printf not-applicable)" \
        "${_efi_uuid:-not-applicable}"

    mkdir -p "$_target"
    mount -t ext4 -o loop "$_image" "$_target" || fail "could not mount ext4 root image"
    _root_mounted=yes
    mkdir -p "$_target/etc" "$_target/efi"
    _observed_root_fs=$(findmnt -rn -o FSTYPE --target "$_target")
    [ "$_observed_root_fs" = ext4 ] || fail "prepared root is not mounted as ext4"

    if [ "$_boot_mode" = efi ]; then
        mount -t vfat -o loop,umask=077 "$_efi_image" "$_efi_mount" ||
            fail "could not mount EFI FAT image"
        _efi_mounted=yes
        _observed_efi_fs=$(findmnt -rn -o FSTYPE --target "$_efi_mount")
        [ "$_observed_efi_fs" = vfat ] || fail "prepared EFI image is not mounted as vfat"
        printf 'EFI fixture\n' >"$_efi_mount/reinstall-ci-efi-marker"
    else
        _observed_efi_fs=
    fi

    printf 'distro=%s\nfirmware=%s\n' "$_distro" "$_boot_mode" >"$_target/etc/reinstall-ci-state"
    {
        printf '# Reinstall ext4 reboot dry-run fixture.\n'
        printf 'UUID=%s / ext4 defaults 0 1\n' "$_root_uuid"
        if [ -n "$_efi_uuid" ]; then
            printf 'UUID=%s /efi vfat umask=077 0 2\n' "$_efi_uuid"
        fi
    } >"$_target/etc/fstab"
    printf 'CHECKPOINT ext4-dry-run/prepare-mounts: distro=%s firmware=%s root=%s efi=%s\n' \
        "$_distro" "$_boot_mode" "$_observed_root_fs" "${_observed_efi_fs:-not-applicable}"

    sync
    if [ "$_boot_mode" = efi ]; then
        umount "$_efi_mount"
        _efi_mounted=no
    fi
    umount "$_target"
    _root_mounted=no
    {
        printf 'distro=%s\n' "$_distro"
        printf 'firmware=%s\n' "$_boot_mode"
        printf 'table=%s\n' "$_state_table"
        printf 'root_partition=%s\n' "$_state_root_partition"
        printf 'efi_partition=%s\n' "$_state_efi_partition"
        printf 'root_uuid=%s\n' "$_root_uuid"
        printf 'efi_uuid=%s\n' "${_efi_uuid:-none}"
    } >"$_state_dir/state.env"
    printf 'CHECKPOINT ext4-dry-run/prepare-persisted-state: distro=%s firmware=%s root-uuid=%s efi-uuid=%s marker=fstab=present\n' \
        "$_distro" "$_boot_mode" "$_root_uuid" "${_efi_uuid:-not-applicable}"
}

read_state() {
    _state_file=$1
    _state_distro=
    _state_firmware=
    _state_table=
    _state_root_partition=
    _state_efi_partition=
    _root_uuid=
    _efi_uuid=
    while IFS= read -r _state_line || [ -n "$_state_line" ]; do
        case $_state_line in
            distro=*) [ -z "$_state_distro" ] || fail "duplicate distro in state file"; _state_distro=${_state_line#distro=} ;;
            firmware=*) [ -z "$_state_firmware" ] || fail "duplicate firmware in state file"; _state_firmware=${_state_line#firmware=} ;;
            table=*) [ -z "$_state_table" ] || fail "duplicate table in state file"; _state_table=${_state_line#table=} ;;
            root_partition=*) [ -z "$_state_root_partition" ] || fail "duplicate root partition in state file"; _state_root_partition=${_state_line#root_partition=} ;;
            efi_partition=*) [ -z "$_state_efi_partition" ] || fail "duplicate EFI partition in state file"; _state_efi_partition=${_state_line#efi_partition=} ;;
            root_uuid=*) [ -z "$_root_uuid" ] || fail "duplicate root UUID in state file"; _root_uuid=${_state_line#root_uuid=} ;;
            efi_uuid=*) [ -z "$_efi_uuid" ] || fail "duplicate EFI UUID in state file"; _efi_uuid=${_state_line#efi_uuid=} ;;
            *) fail "unexpected line in persisted state file" ;;
        esac
    done <"$_state_file"
    [ "$_state_distro" = "$_expected_distro" ] && [ "$_state_firmware" = "$_expected_firmware" ] ||
        fail "persisted case state does not match $_expected_distro/$_expected_firmware"
    case $_state_table in gpt|msdos) ;; *) fail "invalid partition table in state file" ;; esac
    case $_state_root_partition in ''|*[!0123456789]*) fail "invalid root partition number in state file" ;; esac
    case $_state_efi_partition in
        none) ;;
        ''|*[!0123456789]*) fail "invalid EFI partition number in state file" ;;
    esac
    reinstall_btrfs_valid_uuid "$_root_uuid" || fail "invalid root UUID in state file"
    if [ "$_expected_firmware" = efi ]; then
        reinstall_btrfs_valid_efi_uuid "$_efi_uuid" || fail "invalid EFI UUID in state file"
        case $_state_efi_partition in none) fail "EFI partition number is missing from state file" ;; esac
    else
        [ "$_efi_uuid" = none ] && [ "$_state_efi_partition" = none ] ||
            fail "BIOS state unexpectedly contains EFI data"
    fi
}

verify_state() {
    _expected_distro=$1
    _expected_firmware=$2
    _state_dir=$3
    _work_dir=$4
    _image="$_state_dir/root.ext4.img"
    _efi_image="$_state_dir/esp.fat.img"
    _target="$_work_dir/target"
    _efi_mount="$_target/efi"
    _observed_root_fs=
    _observed_efi_fs=
    _root_mounted=no
    _efi_mounted=no

    [ -s "$_image" ] || fail "missing persisted ext4 image for $_expected_distro/$_expected_firmware"
    [ ! -L "$_state_dir" ] || fail "refusing symlink case directory: $_state_dir"
    [ ! -L "$_image" ] || fail "refusing symlink root image: $_image"
    [ -f "$_state_dir/state.env" ] && [ ! -L "$_state_dir/state.env" ] ||
        fail "missing or unsafe state file for $_expected_distro/$_expected_firmware"
    read_state "$_state_dir/state.env"

    plan_case "$_expected_distro" "$_expected_firmware"
    [ "$_table" = "$_state_table" ] && [ "$_root_partition" = "$_state_root_partition" ] &&
        [ "$_efi_partition" = "$_state_efi_partition" ] || fail "saved partition plan does not match current planner"
    _actual_root_uuid=$(blkid -s UUID -o value "$_image")
    [ "$_actual_root_uuid" = "$_root_uuid" ] || fail "root image UUID differs from persisted state"

    mkdir -p "$_target"
    mount -t ext4 -o loop "$_image" "$_target" ||
        fail "fresh-container ext4 root remount failed for $_expected_distro/$_expected_firmware"
    _root_mounted=yes
    mkdir -p "$_target/efi"
    _observed_root_fs=$(findmnt -rn -o FSTYPE --target "$_target")
    [ "$_observed_root_fs" = ext4 ] || fail "fresh root remount is not ext4"
    if [ "$_expected_firmware" = efi ]; then
        [ -s "$_efi_image" ] && [ ! -L "$_efi_image" ] || fail "missing or unsafe EFI image"
        _actual_efi_uuid=$(blkid -s UUID -o value "$_efi_image")
        [ "$_actual_efi_uuid" = "$_efi_uuid" ] || fail "EFI image UUID differs from persisted state"
        mount -t vfat -o loop,umask=077 "$_efi_image" "$_efi_mount" || fail "fresh-container EFI remount failed"
        _efi_mounted=yes
        _observed_efi_fs=$(findmnt -rn -o FSTYPE --target "$_efi_mount")
        [ "$_observed_efi_fs" = vfat ] || fail "fresh EFI remount is not vfat"
        [ -s "$_efi_mount/reinstall-ci-efi-marker" ] || fail "EFI marker did not persist"
    else
        _observed_efi_fs=not-applicable
    fi

    [ -s "$_target/etc/reinstall-ci-state" ] || fail "root marker did not persist"
    [ -s "$_target/etc/fstab" ] || fail "fstab fixture did not persist"
    grep -Fqx "distro=$_expected_distro" "$_target/etc/reinstall-ci-state" || fail "root marker distro differs"
    grep -Fqx "firmware=$_expected_firmware" "$_target/etc/reinstall-ci-state" || fail "root marker firmware differs"
    grep -Fqx "UUID=$_root_uuid / ext4 defaults 0 1" "$_target/etc/fstab" ||
        fail "root ext4 fstab entry did not persist"
    if [ "$_expected_firmware" = efi ]; then
        grep -Fqx "UUID=$_efi_uuid /efi vfat umask=077 0 2" "$_target/etc/fstab" ||
            fail "EFI fstab entry did not persist"
    else
        if grep -Eq '[[:space:]]/efi[[:space:]]' "$_target/etc/fstab"; then
            fail "BIOS fstab unexpectedly contains an EFI mount"
        fi
    fi
    printf 'CHECKPOINT ext4-dry-run/fresh-remount: distro=%s firmware=%s root=%s efi=%s root-uuid=verified efi-uuid=%s\n' \
        "$_expected_distro" "$_expected_firmware" "$_observed_root_fs" \
        "$_observed_efi_fs" "$([ "$_expected_firmware" = efi ] && printf verified || printf not-applicable)"
    printf 'CHECKPOINT ext4-dry-run/persisted-config: distro=%s firmware=%s root=fstab efi=%s marker=verified\n' \
        "$_expected_distro" "$_expected_firmware" \
        "$([ "$_expected_firmware" = efi ] && printf fstab || printf not-applicable)"
    awk '$2 == "/" || $2 == "/efi" { print "  | " $0 }' "$_target/etc/fstab"
    if [ "$_expected_firmware" = efi ]; then
        umount "$_efi_mount"
        _efi_mounted=no
    fi
    umount "$_target"
    _root_mounted=no
}

run_all() {
    _operation=$1
    _artifact_dir=$2
    [ "$(id -u)" -eq 0 ] || fail "must run as root in a privileged Linux container"
    ensure_loop_devices
    for _required in awk blkid findmnt grep mkfs.ext4 mkfs.vfat mount sync truncate umount; do
        require_command "$_required"
    done

    [ -n "$_artifact_dir" ] || fail "artifact directory must not be empty"
    while [ "$_artifact_dir" != / ] && [ "${_artifact_dir%/}" != "$_artifact_dir" ]; do
        _artifact_dir=${_artifact_dir%/}
    done
    [ ! -L "$_artifact_dir" ] || fail "refusing symlink artifact directory: $_artifact_dir"
    mkdir -p "$_artifact_dir"
    _artifact_dir=$(CDPATH= cd -- "$_artifact_dir" && pwd -P)
    [ "$_artifact_dir" != / ] || fail "refusing to place test images directly under /"
    _work_dir=$(mktemp -d "${TMPDIR:-/tmp}/reinstall-ext4-reboot.XXXXXX") ||
        fail "could not create temporary work directory"
    trap cleanup 0
    trap 'exit 1' HUP INT TERM

    for _distro in alpine arch; do
        for _boot_mode in bios efi; do
            _state_dir="$_artifact_dir/$_distro-$_boot_mode"
            case $_operation in
                prepare-all) prepare_state "$_distro" "$_boot_mode" "$_state_dir" "$_work_dir" ;;
                verify-all) verify_state "$_distro" "$_boot_mode" "$_state_dir" "$_work_dir" ;;
            esac
            printf 'PASS ext4-dry-run/%s: %s/%s\n' "$_operation" "$_distro" "$_boot_mode"
        done
    done
}

[ "$#" -eq 2 ] || usage
case $1 in prepare-all|verify-all) ;; *) usage ;; esac
run_all "$1" "$2"
