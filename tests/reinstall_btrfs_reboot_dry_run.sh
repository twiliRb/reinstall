#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo_root/lib/reinstall-btrfs-layout.sh"

usage() {
    echo "Usage: $0 prepare-all|verify-all <artifact-directory>" >&2
    exit 2
}

fail() {
    echo "Btrfs reboot dry-run: $*" >&2
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

make_state() {
    _distro=$1
    _boot_mode=$2
    _state_dir=$3
    _work_dir=$4
    _image="$_state_dir/btrfs.img"
    _esp_image="$_state_dir/esp.img"
    _top="$_work_dir/top"
    _target="$_work_dir/target"
    _efi_uuid=

    mkdir -p "$_state_dir" "$_top" "$_target"
    truncate -s 256M "$_image"
    mkfs.btrfs --quiet --force -L reinstall-ci "$_image" || fail "mkfs.btrfs failed"

    mount -t btrfs -o loop,subvolid=5,compress=zstd "$_image" "$_top" ||
        fail "could not mount the Btrfs top-level subvolume"
    btrfs subvolume create "$_top/@" >/dev/null
    btrfs subvolume create "$_top/@boot" >/dev/null
    chattr +m "$_top/@boot" || fail "could not set no-compression on @boot"
    _root_subvolume_id=$(btrfs inspect-internal rootid "$_top/@")
    btrfs subvolume set-default "$_root_subvolume_id" "$_top" >/dev/null
    umount "$_top"

    if [ "$_boot_mode" = efi ]; then
        truncate -s 64M "$_esp_image"
        mkfs.vfat -n EFI "$_esp_image" >/dev/null || fail "mkfs.vfat failed"
        _efi_uuid=$(blkid -s UUID -o value "$_esp_image")
        [ -n "$_efi_uuid" ] || fail "could not read the ESP UUID"
    fi

    mount -t btrfs -o loop,subvol=@,compress=zstd "$_image" "$_target" ||
        fail "could not mount the target root subvolume"
    mkdir -p "$_target/boot" "$_target/etc" "$_target/efi" "$_target/etc/default"
    mount -t btrfs -o loop,subvol=@boot "$_image" "$_target/boot" ||
        fail "could not mount the target boot subvolume"
    if [ "$_boot_mode" = efi ]; then
        mount -t vfat -o loop,umask=077 "$_esp_image" "$_target/efi" ||
            fail "could not mount the target EFI system partition"
    fi

    _root_uuid=$(blkid -s UUID -o value "$_image")
    [ -n "$_root_uuid" ] || fail "could not read the Btrfs UUID"
    printf 'target-tree=%s\nboot-mode=%s\n' "$_distro" "$_boot_mode" \
        >"$_target/etc/reinstall-ci-state"
    printf 'kernel fixture\n' >"$_target/boot/vmlinuz-reinstall-ci"

    if [ "$_distro" = nixos ]; then
        mkdir -p "$_target/etc/nixos"
        {
            printf 'fileSystems."/" = { device = "UUID=%s"; fsType = "btrfs"; };\n' "$_root_uuid"
            printf 'fileSystems."/boot" = { device = "UUID=%s"; fsType = "btrfs"; };\n' "$_root_uuid"
            if [ -n "$_efi_uuid" ]; then
                printf 'fileSystems."/efi" = { device = "UUID=%s"; fsType = "vfat"; };\n' "$_efi_uuid"
            fi
            reinstall_btrfs_nixos_config_snippet @ @boot compress=zstd
            printf 'boot.kernelParams = [ "%s" ];\n' \
                "$(reinstall_btrfs_kernel_rootflags @ compress=zstd)"
        } >"$_target/etc/nixos/reinstall-ci.nix"
        printf '%s\n' "$(reinstall_btrfs_nixos_add_initrd_module 'virtio_pci virtio_blk')" \
            >"$_target/etc/nixos/reinstall-ci-initrd-modules"
    else
        {
            printf '# Existing target-specific mount survives the simulated install.\n'
            printf 'UUID=33333333-3333-4333-8333-333333333333 /home btrfs defaults,subvol=@home 0 0\n'
            printf 'UUID=44444444-4444-4444-8444-444444444444 / btrfs defaults,subvol=@old 0 0\n'
        } >"$_target/etc/fstab"
        if [ -n "$_efi_uuid" ]; then
            reinstall_btrfs_write_fstab "$_target" "$_root_uuid" @ @boot compress=zstd "$_efi_uuid"
        else
            reinstall_btrfs_write_fstab "$_target" "$_root_uuid" @ @boot compress=zstd
        fi
        printf 'GRUB_CMDLINE_LINUX="%s"\n' \
            "$(reinstall_btrfs_kernel_rootflags @ compress=zstd)" \
            >"$_target/etc/default/grub.dry-run"
    fi

    if [ -n "$_efi_uuid" ]; then
        mkdir -p "$_target/efi/EFI/reinstall-ci"
        printf 'EFI fixture\n' >"$_target/efi/EFI/reinstall-ci/bootx64.efi"
    fi

    sync
    if [ "$_boot_mode" = efi ]; then
        umount "$_target/efi"
    fi
    umount "$_target/boot"
    umount "$_target"
    {
        printf 'distro=%s\n' "$_distro"
        printf 'boot_mode=%s\n' "$_boot_mode"
        printf 'root_uuid=%s\n' "$_root_uuid"
        printf 'efi_uuid=%s\n' "$_efi_uuid"
    } >"$_state_dir/state.env"
}

verify_state() {
    _distro=$1
    _boot_mode=$2
    _state_dir=$3
    _work_dir=$4
    _image="$_state_dir/btrfs.img"
    _esp_image="$_state_dir/esp.img"
    _target="$_work_dir/target"

    [ -s "$_image" ] || fail "missing persisted Btrfs image for $_distro/$_boot_mode"
    . "$_state_dir/state.env"
    [ "$distro" = "$_distro" ] && [ "$boot_mode" = "$_boot_mode" ] ||
        fail "persisted test state does not match $_distro/$_boot_mode"

    mkdir -p "$_target"
    mount -t btrfs -o loop,subvol=@,compress=zstd "$_image" "$_target" ||
        fail "fresh-container root remount failed for $_distro/$_boot_mode"
    mkdir -p "$_target/boot" "$_target/efi"
    mount -t btrfs -o loop,subvol=@boot "$_image" "$_target/boot" ||
        fail "fresh-container /boot remount failed for $_distro/$_boot_mode"
    if [ "$_boot_mode" = efi ]; then
        [ -s "$_esp_image" ] || fail "missing persisted EFI image"
        mount -t vfat -o loop,umask=077 "$_esp_image" "$_target/efi" ||
            fail "fresh-container EFI remount failed"
    fi

    _root_fs=$(findmnt -rn -o FSTYPE --target "$_target")
    _root_options=$(findmnt -rn -o OPTIONS --target "$_target")
    _boot_subvolume=$(btrfs subvolume show "$_target/boot" | awk -F ': ' '$1 == "Name" { print $2 }')
    _boot_attributes=$(lsattr -d "$_target/boot" | awk '{ print $1 }')
    _boot_file_attributes=$(lsattr -d "$_target/boot/vmlinuz-reinstall-ci" | awk '{ print $1 }')
    [ "$_root_fs" = btrfs ] || fail "root is not mounted as Btrfs after simulated reboot"
    case $_root_options in *compress=zstd*) ;; *) fail "root mount lost compress=zstd" ;; esac
    case ",$_root_options," in
    *,subvol=@,*|*,subvol=/@,*) ;;
    *) fail "root mount lost subvol=@ (findmnt reported: $_root_options)" ;;
    esac
    [ "$_boot_subvolume" = @boot ] || fail "/boot is not mounted from @boot"
    case $_boot_attributes in *m*) ;; *) fail "/boot lost its no-compression attribute" ;; esac
    case $_boot_file_attributes in *m*) ;; *) fail "/boot files did not inherit no-compression" ;; esac
    [ -s "$_target/etc/reinstall-ci-state" ] || fail "root target files did not persist"
    [ -s "$_target/boot/vmlinuz-reinstall-ci" ] || fail "boot target files did not persist"

    if [ "$_distro" = nixos ]; then
        _nixos_config="$_target/etc/nixos/reinstall-ci.nix"
        grep -Fq 'fileSystems."/".options = lib.mkForce [ "subvol=@" "compress=zstd" ];' "$_nixos_config" ||
            fail "NixOS root mount configuration did not persist"
        grep -Fq 'fileSystems."/boot".options = lib.mkForce [ "subvol=@boot" "compress=zstd" ];' "$_nixos_config" ||
            fail "NixOS /boot mount configuration did not persist"
        grep -Fq 'rootflags=subvol=@,compress=zstd' "$_nixos_config" ||
            fail "NixOS rootflags did not persist"
        if [ "$_boot_mode" = efi ]; then
            grep -Fq "device = \"UUID=$efi_uuid\"; fsType = \"vfat\";" "$_nixos_config" ||
                fail "NixOS ESP configuration did not persist"
        fi
        grep -Fq 'virtio_pci virtio_blk btrfs' \
            "$_target/etc/nixos/reinstall-ci-initrd-modules" ||
            fail "NixOS initrd Btrfs module did not persist"
    else
        grep -Fq "UUID=$root_uuid / btrfs defaults,compress=zstd,subvol=@ 0 0" \
            "$_target/etc/fstab" || fail "root fstab entry did not persist"
        grep -Fq "UUID=$root_uuid /boot btrfs defaults,compress=zstd,subvol=@boot 0 0" \
            "$_target/etc/fstab" || fail "/boot fstab entry did not persist"
        grep -Fq 'GRUB_CMDLINE_LINUX="rootflags=subvol=@,compress=zstd"' \
            "$_target/etc/default/grub.dry-run" || fail "GRUB rootflags did not persist"
        grep -Fq '/home btrfs defaults,subvol=@home' "$_target/etc/fstab" ||
            fail "an unrelated fstab entry was lost"
    fi

    if [ "$_boot_mode" = efi ]; then
        _efi_fs=$(findmnt -rn -o FSTYPE --target "$_target/efi")
        [ "$_efi_fs" = vfat ] || fail "ESP did not remount as vfat"
        [ -s "$_target/efi/EFI/reinstall-ci/bootx64.efi" ] || fail "ESP files did not persist"
        if [ "$_distro" != nixos ]; then
            grep -Fq "UUID=$efi_uuid /efi vfat umask=077 0 2" \
                "$_target/etc/fstab" || fail "EFI fstab entry did not persist"
        fi
    fi

    sync
    if [ "$_boot_mode" = efi ]; then
        umount "$_target/efi"
    fi
    umount "$_target/boot"
    umount "$_target"
}

run_all() {
    _operation=$1
    _artifact_dir=$2
    [ "$(id -u)" -eq 0 ] || fail "must run as root in a privileged Linux container"
    ensure_loop_devices
    for _required in awk blkid btrfs chattr findmnt grep lsattr mkfs.btrfs mkfs.vfat mount sync truncate umount; do
        require_command "$_required"
    done
    mkdir -p "$_artifact_dir"
    _work_dir=$(mktemp -d "${TMPDIR:-/tmp}/reinstall-btrfs-reboot.XXXXXX") || exit 1
    trap 'umount -R "$_work_dir/target" 2>/dev/null || true; umount "$_work_dir/top" 2>/dev/null || true; rm -rf "$_work_dir"' 0 HUP INT TERM

    for _distro in arch gentoo aosc nixos; do
        for _boot_mode in bios efi; do
            _state_dir="$_artifact_dir/$_distro-$_boot_mode"
            case $_operation in
            prepare-all) make_state "$_distro" "$_boot_mode" "$_state_dir" "$_work_dir" ;;
            verify-all) verify_state "$_distro" "$_boot_mode" "$_state_dir" "$_work_dir" ;;
            esac
            echo "$_operation: $_distro/$_boot_mode passed"
        done
    done
}

[ "$#" -eq 2 ] || usage
case $1 in prepare-all | verify-all) ;; *) usage ;; esac
run_all "$1" "$2"
