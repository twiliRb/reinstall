#!/bin/sh

# Return the tools the live installer needs for the Btrfs preflight.
reinstall_btrfs_preflight_packages() {
    printf '%s\n' 'e2fsprogs e2fsprogs-extra btrfs-progs'
}

# The Alpine live system keeps kernel modules in modloop. Mounting a Btrfs
# probe image fails with EINVAL until modloop is mounted and Btrfs is loaded.
reinstall_btrfs_activate_kernel_support() {
    ensure_service_started modloop
    modprobe btrfs
}

# Emit the installer-neutral Btrfs partition and subvolume plan as TSV.
reinstall_btrfs_layout_plan() (
    [ "$#" -eq 2 ] || exit 2

    case $1 in
        bios|efi) ;;
        *) exit 2 ;;
    esac

    _reinstall_btrfs_layout_size=$2
    case $_reinstall_btrfs_layout_size in
        ''|*[!0123456789]*) exit 2 ;;
    esac

    # Strip leading zeroes before checking positivity and comparing sizes.
    while [ "$_reinstall_btrfs_layout_size" != "${_reinstall_btrfs_layout_size#0}" ]; do
        _reinstall_btrfs_layout_size=${_reinstall_btrfs_layout_size#0}
    done
    [ -n "$_reinstall_btrfs_layout_size" ] || exit 2

    _reinstall_btrfs_layout_table=msdos
    if [ "$1" = efi ] || [ "${#_reinstall_btrfs_layout_size}" -gt 13 ]; then
        _reinstall_btrfs_layout_table=gpt
    elif [ "${#_reinstall_btrfs_layout_size}" -eq 13 ]; then
        _reinstall_btrfs_layout_candidate=$_reinstall_btrfs_layout_size
        _reinstall_btrfs_layout_boundary=2199023255552
        _reinstall_btrfs_layout_above_boundary=no
        while [ -n "$_reinstall_btrfs_layout_candidate" ]; do
            _reinstall_btrfs_layout_candidate_digit=${_reinstall_btrfs_layout_candidate%"${_reinstall_btrfs_layout_candidate#?}"}
            _reinstall_btrfs_layout_boundary_digit=${_reinstall_btrfs_layout_boundary%"${_reinstall_btrfs_layout_boundary#?}"}
            if [ "$_reinstall_btrfs_layout_candidate_digit" -gt "$_reinstall_btrfs_layout_boundary_digit" ]; then
                _reinstall_btrfs_layout_above_boundary=yes
                break
            fi
            if [ "$_reinstall_btrfs_layout_candidate_digit" -lt "$_reinstall_btrfs_layout_boundary_digit" ]; then
                break
            fi
            _reinstall_btrfs_layout_candidate=${_reinstall_btrfs_layout_candidate#?}
            _reinstall_btrfs_layout_boundary=${_reinstall_btrfs_layout_boundary#?}
        done
        if [ "$_reinstall_btrfs_layout_above_boundary" = yes ]; then
            _reinstall_btrfs_layout_table=gpt
        fi
    fi

    if [ "$_reinstall_btrfs_layout_table" = gpt ]; then
        printf 'table\tgpt\n'
        if [ "$1" = efi ]; then
            printf 'partition\t1\tesp\tvfat\t1MiB\t101MiB\tesp\n'
            printf 'partition\t2\troot\tbtrfs\t101MiB\t100%%\t-\n'
        else
            printf 'partition\t1\tbios_grub\tnone\t1MiB\t2MiB\tbios_grub\n'
            printf 'partition\t2\troot\tbtrfs\t2MiB\t100%%\t-\n'
        fi
    else
        printf 'table\tmsdos\n'
        printf 'partition\t1\troot\tbtrfs\t1MiB\t100%%\tboot\n'
    fi

    printf 'subvolume\t@\t/\tcompress=zstd\n'
    printf 'subvolume\t@boot\t/boot\tno-compression\n'
)

reinstall_btrfs_valid_uuid() {
    [ "$#" -eq 1 ] || return 1
    case $1 in
    ????????-????-????-????-????????????) ;;
    *) return 1 ;;
    esac
    case $1 in
    *[!0123456789abcdefABCDEF-]*) return 1 ;;
    esac
}

reinstall_btrfs_valid_efi_uuid() {
    [ "$#" -eq 1 ] || return 1
    case $1 in
    ????-????) ;;
    *) return 1 ;;
    esac
    case $1 in
    *[!0123456789abcdefABCDEF-]*) return 1 ;;
    esac
}

# Write the persistent mount entries used by Arch, Gentoo, and AOSC.
# The optional sixth argument is the EFI system partition UUID.
reinstall_btrfs_write_fstab() (
    [ "$#" -eq 5 ] || [ "$#" -eq 6 ] || exit 2

    _reinstall_btrfs_target_root=$1
    _reinstall_btrfs_root_uuid=$2
    _reinstall_btrfs_root_subvolume=$3
    _reinstall_btrfs_boot_subvolume=$4
    _reinstall_btrfs_root_options=$5
    _reinstall_btrfs_efi_uuid=${6-}

    [ -d "$_reinstall_btrfs_target_root" ] || exit 1
    [ "$_reinstall_btrfs_root_subvolume" = @ ] || exit 2
    [ "$_reinstall_btrfs_boot_subvolume" = @boot ] || exit 2
    [ "$_reinstall_btrfs_root_options" = compress=zstd ] || exit 2
    reinstall_btrfs_valid_uuid "$_reinstall_btrfs_root_uuid" || exit 2

    if [ -n "$_reinstall_btrfs_efi_uuid" ]; then
        reinstall_btrfs_valid_efi_uuid "$_reinstall_btrfs_efi_uuid" || exit 2
    fi
    if [ "$#" -eq 6 ] && [ -z "$_reinstall_btrfs_efi_uuid" ]; then
        exit 2
    fi

    mkdir -p "$_reinstall_btrfs_target_root/etc" || exit 1
    _reinstall_btrfs_temp_dir=$(mktemp -d "$_reinstall_btrfs_target_root/etc/.reinstall-btrfs-fstab.XXXXXX") || exit 1
    trap 'rm -rf "$_reinstall_btrfs_temp_dir"' 0 HUP INT TERM
    _reinstall_btrfs_fstab_file="$_reinstall_btrfs_target_root/etc/fstab"
    _reinstall_btrfs_filtered_fstab="$_reinstall_btrfs_temp_dir/filtered"
    _reinstall_btrfs_new_fstab="$_reinstall_btrfs_temp_dir/new"

    if [ -f "$_reinstall_btrfs_fstab_file" ]; then
        awk 'NF < 2 || $1 ~ /^#/ || ($2 != "/" && $2 != "/boot" && $2 != "/efi")' \
            "$_reinstall_btrfs_fstab_file" >"$_reinstall_btrfs_filtered_fstab" || exit 1
    else
        : >"$_reinstall_btrfs_filtered_fstab" || exit 1
    fi
    cat "$_reinstall_btrfs_filtered_fstab" >"$_reinstall_btrfs_new_fstab" || exit 1
    {
        printf 'UUID=%s / btrfs defaults,%s,subvol=%s 0 0\n' \
            "$_reinstall_btrfs_root_uuid" "$_reinstall_btrfs_root_options" \
            "$_reinstall_btrfs_root_subvolume"
        printf 'UUID=%s /boot btrfs defaults,%s,subvol=%s 0 0\n' \
            "$_reinstall_btrfs_root_uuid" "$_reinstall_btrfs_root_options" \
            "$_reinstall_btrfs_boot_subvolume"
        if [ -n "$_reinstall_btrfs_efi_uuid" ]; then
            printf 'UUID=%s /efi vfat umask=077 0 2\n' "$_reinstall_btrfs_efi_uuid"
        fi
    } >>"$_reinstall_btrfs_new_fstab" || exit 1

    mv "$_reinstall_btrfs_new_fstab" "$_reinstall_btrfs_fstab_file" || exit 1
    rm -rf "$_reinstall_btrfs_temp_dir" || exit 1
    trap - 0 HUP INT TERM
)

# Emit the NixOS declarations shared by the installer and reboot dry-run.
reinstall_btrfs_nixos_config_snippet() {
    [ "$#" -eq 3 ] || return 2
    [ "$1" = @ ] && [ "$2" = @boot ] && [ "$3" = compress=zstd ] || return 2

    cat <<'EOF'
boot.supportedFilesystems = [ "btrfs" ];
boot.initrd.supportedFilesystems = [ "btrfs" ];
environment.systemPackages = [ pkgs.btrfs-progs ];
fileSystems."/".options = lib.mkForce [ "subvol=@" "compress=zstd" ];
fileSystems."/boot".options = lib.mkForce [ "subvol=@boot" "compress=zstd" ];
EOF
}

# Return the rootflags argument used by boot loaders and initramfs generators.
reinstall_btrfs_kernel_rootflags() {
    [ "$#" -eq 2 ] || return 2
    [ "$1" = @ ] && [ "$2" = compress=zstd ] || return 2
    printf 'rootflags=subvol=%s,%s\n' "$1" "$2"
}

# Add Btrfs to a generated NixOS initrd module list without duplicating it.
reinstall_btrfs_nixos_add_initrd_module() {
    [ "$#" -eq 1 ] || return 2
    case " $1 " in
    *" btrfs "*) printf '%s\n' "$1" ;;
    *)
        if [ -n "$1" ]; then
            printf '%s btrfs\n' "$1"
        else
            printf 'btrfs\n'
        fi
        ;;
    esac
}
