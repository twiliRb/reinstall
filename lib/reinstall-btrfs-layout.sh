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

# Emit the ext4 partition plan used by the shared Arch-family installation
# path. Keep the firmware and 2 TiB table decision aligned with the Btrfs plan.
reinstall_ext4_layout_plan() (
    [ "$#" -eq 2 ] || exit 2

    case $1 in
        bios|efi) ;;
        *) exit 2 ;;
    esac

    _reinstall_ext4_layout_table=$(reinstall_btrfs_layout_plan "$1" "$2" |
        awk -F '\t' '$1 == "table" {print $2}') || exit 2
    case $_reinstall_ext4_layout_table in
        gpt|msdos) ;;
        *) exit 2 ;;
    esac

    if [ "$1" = efi ]; then
        printf 'table\tgpt\n'
        printf 'partition\t1\tesp\tvfat\t1MiB\t101MiB\tboot\n'
        printf 'partition\t2\troot\text4\t101MiB\t100%%\t-\n'
    elif [ "$_reinstall_ext4_layout_table" = gpt ]; then
        printf 'table\tgpt\n'
        printf 'partition\t1\tbios_grub\tnone\t1MiB\t2MiB\tbios_grub\n'
        printf 'partition\t2\troot\text4\t2MiB\t100%%\t-\n'
    else
        printf 'table\tmsdos\n'
        printf 'partition\t1\troot\text4\t1MiB\t100%%\tboot\n'
    fi
)

# Format the root partition for the shared Arch-family installer. Alpine's
# extlinux cannot read ext4 with the 64-bit feature enabled.
reinstall_ext4_format_root() {
    [ "$#" -eq 2 ] || return 2

    case $2 in
        alpine) mkfs.ext4 -F -O ^64bit "$1" ;;
        *) mkfs.ext4 -F "$1" ;;
    esac
}

# Apply the planned ext4 partition table, refresh kernel partition nodes, and
# format the root/EFI partitions. The caller supplies its partition refresh
# function so this shared executor remains testable outside trans.sh.
reinstall_ext4_create_partitions() (
    [ "$#" -eq 5 ] || exit 2
    _reinstall_ext4_disk=$1
    _reinstall_ext4_mode=$2
    _reinstall_ext4_size=$3
    _reinstall_ext4_distro=$4
    _reinstall_ext4_refresh=$5
    case $_reinstall_ext4_disk in /dev/*) ;; *) exit 2 ;; esac
    case $_reinstall_ext4_refresh in *[!a-zA-Z0-9_]*) exit 2 ;; esac
    [ -n "$_reinstall_ext4_refresh" ] || exit 2

    _reinstall_ext4_plan=$(reinstall_ext4_layout_plan \
        "$_reinstall_ext4_mode" "$_reinstall_ext4_size") || exit 2
    _reinstall_ext4_table=$(printf '%s\n' "$_reinstall_ext4_plan" |
        awk -F '\t' '$1 == "table" {print $2}')
    case $_reinstall_ext4_table in gpt|msdos) ;; *) exit 2 ;; esac

    parted "$_reinstall_ext4_disk" -s -- mklabel "$_reinstall_ext4_table" || exit 1
    _reinstall_ext4_tab=$(printf '\t')
    _reinstall_ext4_root_number=
    _reinstall_ext4_efi_number=
    while IFS="$_reinstall_ext4_tab" read -r \
        _reinstall_ext4_record _reinstall_ext4_number _reinstall_ext4_role \
        _reinstall_ext4_fs _reinstall_ext4_start _reinstall_ext4_end _reinstall_ext4_flag; do
        [ "$_reinstall_ext4_record" = partition ] || continue
        [ -n "$_reinstall_ext4_number" ] && [ -n "$_reinstall_ext4_fs" ] || exit 2
        case $_reinstall_ext4_role in
            esp)
                parted "$_reinstall_ext4_disk" -s -- mkpart '" "' fat32 \
                    "$_reinstall_ext4_start" "$_reinstall_ext4_end" || exit 1
                parted "$_reinstall_ext4_disk" -s -- set \
                    "$_reinstall_ext4_number" "$_reinstall_ext4_flag" on || exit 1
                _reinstall_ext4_efi_number=$_reinstall_ext4_number
                ;;
            bios_grub)
                parted "$_reinstall_ext4_disk" -s -- mkpart '" "' \
                    "$_reinstall_ext4_start" "$_reinstall_ext4_end" || exit 1
                parted "$_reinstall_ext4_disk" -s -- set \
                    "$_reinstall_ext4_number" "$_reinstall_ext4_flag" on || exit 1
                ;;
            root)
                if [ "$_reinstall_ext4_table" = msdos ]; then
                    parted "$_reinstall_ext4_disk" -s -- mkpart primary ext4 \
                        "$_reinstall_ext4_start" "$_reinstall_ext4_end" || exit 1
                    if [ "$_reinstall_ext4_flag" = boot ]; then
                        parted "$_reinstall_ext4_disk" -s -- set \
                            "$_reinstall_ext4_number" boot on || exit 1
                    fi
                else
                    parted "$_reinstall_ext4_disk" -s -- mkpart '" "' ext4 \
                        "$_reinstall_ext4_start" "$_reinstall_ext4_end" || exit 1
                fi
                _reinstall_ext4_root_number=$_reinstall_ext4_number
                ;;
            *) exit 2 ;;
        esac
    done <<EOF
$_reinstall_ext4_plan
EOF

    [ -n "$_reinstall_ext4_root_number" ] || exit 2
    "$_reinstall_ext4_refresh" || exit 1
    if [ -n "$_reinstall_ext4_efi_number" ]; then
        _reinstall_ext4_efi_device=$_reinstall_ext4_disk
        case $_reinstall_ext4_disk in *[0-9]) _reinstall_ext4_efi_device=${_reinstall_ext4_disk}p ;; esac
        mkfs.fat "${_reinstall_ext4_efi_device}${_reinstall_ext4_efi_number}" || exit 1
    fi
    _reinstall_ext4_root_device=$_reinstall_ext4_disk
    case $_reinstall_ext4_disk in *[0-9]) _reinstall_ext4_root_device=${_reinstall_ext4_disk}p ;; esac
    reinstall_ext4_format_root \
        "${_reinstall_ext4_root_device}${_reinstall_ext4_root_number}" \
        "$_reinstall_ext4_distro"
)

# Refresh kernel partition nodes after parted has changed the table. Every
# required step returns an error explicitly because callers may run this from
# an `if`/`||` condition where `set -e` does not apply inside nested functions.
reinstall_refresh_partitions() (
    [ "$#" -eq 1 ] || return 2
    _reinstall_refresh_disk=$1

    sleep 1 || return 1
    sync || return 1
    sleep 1 || return 1

    if command -v partprobe >/dev/null 2>&1; then
        partprobe "$_reinstall_refresh_disk" 2>/dev/null || true
        sleep 1 || return 1
    fi

    if command -v partx >/dev/null 2>&1; then
        partx -u "$_reinstall_refresh_disk" || return 1
        sleep 1 || return 1
    fi

    ensure_service_stopped mdev || return 1
    sleep 1 || return 1
    retry 5 rm -rf /dev/disk/* || return 1
    mdev -sf 2>/dev/null || return 1
    sleep 1 || return 1
    ensure_service_started mdev 2>/dev/null || return 1
    sleep 1 || return 1
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

    : >"$_reinstall_btrfs_filtered_fstab" || exit 1
    if [ -f "$_reinstall_btrfs_fstab_file" ]; then
        _reinstall_btrfs_field_ifs=$(printf ' \t')
        while IFS= read -r _reinstall_btrfs_line || [ -n "$_reinstall_btrfs_line" ]; do
            _reinstall_btrfs_source=
            _reinstall_btrfs_mountpoint=
            _reinstall_btrfs_rest=
            IFS="$_reinstall_btrfs_field_ifs" read -r \
                _reinstall_btrfs_source _reinstall_btrfs_mountpoint _reinstall_btrfs_rest <<EOF
$_reinstall_btrfs_line
EOF
            case $_reinstall_btrfs_source in
            \#*) printf '%s\n' "$_reinstall_btrfs_line" >>"$_reinstall_btrfs_filtered_fstab" || exit 1 ;;
            *)
                case $_reinstall_btrfs_mountpoint in
                /|/boot|/efi) ;;
                *) printf '%s\n' "$_reinstall_btrfs_line" >>"$_reinstall_btrfs_filtered_fstab" || exit 1 ;;
                esac
                ;;
            esac
        done <"$_reinstall_btrfs_fstab_file"
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
