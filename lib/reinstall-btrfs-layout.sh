#!/bin/sh

# Return the tools the live installer needs for the Btrfs preflight.
reinstall_btrfs_preflight_packages() {
    printf '%s\n' 'e2fsprogs e2fsprogs-extra btrfs-progs'
}

# Return a valid top-level mount option string for creating the shared layout.
reinstall_btrfs_top_level_mount_options() {
    [ "$#" -eq 1 ] || return 2
    case $1 in *[!A-Za-z0-9_,=./:-]* | *compress-force*) return 2 ;; esac
    if [ -n "$1" ]; then
        printf 'subvolid=5,%s\n' "$1"
    else
        printf '%s\n' subvolid=5
    fi
}

# Debian Installer may not ship a chattr with Btrfs no-compression support.
# Its Btrfs path bundles a private, compatible e2fsprogs chattr in the initrd;
# all other paths use the system utility after the live preflight.
reinstall_btrfs_set_nocompress_flag() {
    [ "$#" -eq 1 ] || return 2
    if [ -x /usr/local/lib/reinstall-btrfs/chattr ]; then
        LD_LIBRARY_PATH=/usr/local/lib/reinstall-btrfs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} \
            /usr/local/lib/reinstall-btrfs/chattr +m "$1"
    else
        command -v chattr >/dev/null 2>&1 || return 127
        chattr +m "$1"
    fi
}

# Copy the visible root-directory entries into a newly created root subvolume
# when Debian Installer formatted the filesystem root itself (subvolume ID 5).
# The destination is mounted inside the source top level, so skip the two new
# subvolumes to avoid recursively copying a directory into itself.
reinstall_btrfs_copy_top_level_except_layout_subvolumes() {
    [ "$#" -eq 2 ] || return 2
    local _reinstall_btrfs_copy_source=$1
    local _reinstall_btrfs_copy_destination=$2
    local _reinstall_btrfs_copy_entry
    [ -d "$_reinstall_btrfs_copy_source" ] &&
        [ -d "$_reinstall_btrfs_copy_destination" ] || return 1

    for _reinstall_btrfs_copy_entry in \
        "$_reinstall_btrfs_copy_source"/* \
        "$_reinstall_btrfs_copy_source"/.[!.]* \
        "$_reinstall_btrfs_copy_source"/..?*; do
        [ -e "$_reinstall_btrfs_copy_entry" ] || [ -L "$_reinstall_btrfs_copy_entry" ] || continue
        case ${_reinstall_btrfs_copy_entry##*/} in
        @ | @boot) continue ;;
        esac
        cp -a "$_reinstall_btrfs_copy_entry" "$_reinstall_btrfs_copy_destination/" || return 1
    done
}

# The Alpine live system keeps kernel modules in modloop. Mounting a Btrfs
# probe image fails with EINVAL until modloop is mounted and Btrfs is loaded.
reinstall_btrfs_activate_kernel_support() {
    ensure_service_started modloop
    modprobe btrfs
}

# Emit the installer-neutral Btrfs partition and subvolume plan as TSV.
reinstall_btrfs_layout_plan() (
    [ "$#" -eq 2 ] || [ "$#" -eq 3 ] || exit 2
    _reinstall_btrfs_root_options=${3-compress=zstd}
    case $_reinstall_btrfs_root_options in
        *[!A-Za-z0-9_,=./:-]*|*compress-force*) exit 2 ;;
    esac

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

    printf 'subvolume\t@\t/\t%s\n' "$_reinstall_btrfs_root_options"
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

# Remove mounts in the source image that refer to the source Btrfs volume being
# flattened into the target @ subvolume. Mounts on separate source filesystems
# remain available in fstab.
reinstall_btrfs_remove_fstab_source_volume_mounts() (
    [ "$#" -ge 2 ] && [ "$#" -le 4 ] || exit 2

    _reinstall_btrfs_target_root=$1
    _reinstall_btrfs_source_uuid=$2
    _reinstall_btrfs_source_partuuid=${3-}
    _reinstall_btrfs_source_label=${4-}
    [ -d "$_reinstall_btrfs_target_root" ] || exit 1
    reinstall_btrfs_valid_uuid "$_reinstall_btrfs_source_uuid" || exit 2
    case $_reinstall_btrfs_source_partuuid in
    '') ;;
    *[!A-Za-z0-9-]*) exit 2 ;;
    esac
    case $_reinstall_btrfs_source_label in
    '') ;;
    *[!A-Za-z0-9_.+-]*) exit 2 ;;
    esac

    _reinstall_btrfs_fstab_file="$_reinstall_btrfs_target_root/etc/fstab"
    [ -f "$_reinstall_btrfs_fstab_file" ] || exit 0
    _reinstall_btrfs_temp_file=$(mktemp "$_reinstall_btrfs_target_root/etc/.reinstall-btrfs-fstab.XXXXXX") || exit 1
    trap 'rm -f "$_reinstall_btrfs_temp_file"' 0 HUP INT TERM
    _reinstall_btrfs_field_ifs=$(printf ' \t')
    while IFS= read -r _reinstall_btrfs_line || [ -n "$_reinstall_btrfs_line" ]; do
        _reinstall_btrfs_source=
        _reinstall_btrfs_mountpoint=
        _reinstall_btrfs_fstype=
        _reinstall_btrfs_rest=
        IFS="$_reinstall_btrfs_field_ifs" read -r \
            _reinstall_btrfs_source _reinstall_btrfs_mountpoint \
            _reinstall_btrfs_fstype _reinstall_btrfs_rest <<EOF
$_reinstall_btrfs_line
EOF
        case $_reinstall_btrfs_source in
        \#*) ;;
        *)
            if [ "$_reinstall_btrfs_fstype" = btrfs ]; then
                case $_reinstall_btrfs_source in
                "UUID=$_reinstall_btrfs_source_uuid") continue ;;
                "PARTUUID=$_reinstall_btrfs_source_partuuid")
                    [ -n "$_reinstall_btrfs_source_partuuid" ] && continue
                    ;;
                "LABEL=$_reinstall_btrfs_source_label")
                    [ -n "$_reinstall_btrfs_source_label" ] && continue
                    ;;
                esac
            fi
            ;;
        esac
        printf '%s\n' "$_reinstall_btrfs_line" >>"$_reinstall_btrfs_temp_file" || exit 1
    done <"$_reinstall_btrfs_fstab_file"
    cat "$_reinstall_btrfs_temp_file" >"$_reinstall_btrfs_fstab_file" || exit 1
    rm -f "$_reinstall_btrfs_temp_file" || exit 1
    trap - 0 HUP INT TERM
)

# Write persistent Btrfs mount entries. The optional sixth argument is the EFI
# system partition UUID; a seventh argument selects /efi or /boot/efi.
reinstall_btrfs_write_fstab() (
    [ "$#" -ge 5 ] && [ "$#" -le 7 ] || exit 2

    _reinstall_btrfs_target_root=$1
    _reinstall_btrfs_root_uuid=$2
    _reinstall_btrfs_root_subvolume=$3
    _reinstall_btrfs_boot_subvolume=$4
    _reinstall_btrfs_root_options=$5
    _reinstall_btrfs_efi_uuid=${6-}
    _reinstall_btrfs_efi_mountpoint=${7:-/efi}

    [ -d "$_reinstall_btrfs_target_root" ] || exit 1
    [ "$_reinstall_btrfs_root_subvolume" = @ ] || exit 2
    [ "$_reinstall_btrfs_boot_subvolume" = @boot ] || exit 2
    case $_reinstall_btrfs_root_options in
    *[!A-Za-z0-9_,=./:-]* | *compress-force*) exit 2 ;;
    esac
    reinstall_btrfs_valid_uuid "$_reinstall_btrfs_root_uuid" || exit 2

    if [ -n "$_reinstall_btrfs_efi_uuid" ]; then
        reinstall_btrfs_valid_efi_uuid "$_reinstall_btrfs_efi_uuid" || exit 2
    fi
    if [ "$#" -eq 6 ] && [ -z "$_reinstall_btrfs_efi_uuid" ]; then
        exit 2
    fi
    case $_reinstall_btrfs_efi_mountpoint in /efi | /boot/efi) ;; *) exit 2 ;; esac

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
                /|/boot|/efi|/boot/efi) ;;
                *) printf '%s\n' "$_reinstall_btrfs_line" >>"$_reinstall_btrfs_filtered_fstab" || exit 1 ;;
                esac
                ;;
            esac
        done <"$_reinstall_btrfs_fstab_file"
    fi
    cat "$_reinstall_btrfs_filtered_fstab" >"$_reinstall_btrfs_new_fstab" || exit 1
    {
        _reinstall_btrfs_fstab_options=defaults
        [ -z "$_reinstall_btrfs_root_options" ] ||
            _reinstall_btrfs_fstab_options="$_reinstall_btrfs_fstab_options,$_reinstall_btrfs_root_options"
        printf 'UUID=%s / btrfs %s,subvol=%s 0 0\n' \
            "$_reinstall_btrfs_root_uuid" "$_reinstall_btrfs_fstab_options" \
            "$_reinstall_btrfs_root_subvolume"
        printf 'UUID=%s /boot btrfs %s,subvol=%s 0 0\n' \
            "$_reinstall_btrfs_root_uuid" "$_reinstall_btrfs_fstab_options" \
            "$_reinstall_btrfs_boot_subvolume"
        if [ -n "$_reinstall_btrfs_efi_uuid" ]; then
            printf 'UUID=%s %s vfat umask=077 0 2\n' \
                "$_reinstall_btrfs_efi_uuid" "$_reinstall_btrfs_efi_mountpoint"
        fi
    } >>"$_reinstall_btrfs_new_fstab" || exit 1

    mv "$_reinstall_btrfs_new_fstab" "$_reinstall_btrfs_fstab_file" || exit 1
    rm -rf "$_reinstall_btrfs_temp_dir" || exit 1
    trap - 0 HUP INT TERM
)

# Emit the Debian Installer recipe for a single Btrfs root filesystem. The EFI
# system partition remains separate; all installed root data is later migrated
# into the common @ and @boot subvolumes by debian.cfg's late-command adapter.
reinstall_btrfs_debian_partman_recipe() {
    [ "$#" -eq 1 ] || return 2
    case $1 in
    efi)
        printf '%s\n' 'btrfs-efi :: 106 1 106 free $iflabel{ gpt } method{ efi } format{ } . 1 1 -1 btrfs method{ format } format{ } use_filesystem{ } filesystem{ btrfs } mountpoint{ / } .'
        ;;
    bios)
        printf '%s\n' 'btrfs-bios :: 1 1 1 free $iflabel{ gpt } method{ biosgrub } . 1 1 -1 btrfs method{ format } format{ } use_filesystem{ } filesystem{ btrfs } mountpoint{ / } .'
        ;;
    *) return 2 ;;
    esac
}

# Write Debian's Btrfs mount entries while preserving its /boot/efi mount and
# unrelated filesystems. The common writer uses /efi for direct-install routes.
reinstall_btrfs_debian_write_fstab() (
    [ "$#" -eq 4 ] || exit 2
    _reinstall_debian_btrfs_root=$1
    _reinstall_debian_btrfs_uuid=$2
    _reinstall_debian_btrfs_options=$3
    _reinstall_debian_btrfs_efi_uuid=$4
    [ -d "$_reinstall_debian_btrfs_root" ] || exit 1
    reinstall_btrfs_valid_uuid "$_reinstall_debian_btrfs_uuid" || exit 2
    [ -z "$_reinstall_debian_btrfs_efi_uuid" ] ||
        reinstall_btrfs_valid_efi_uuid "$_reinstall_debian_btrfs_efi_uuid" || exit 2
    case $_reinstall_debian_btrfs_options in
    *[!A-Za-z0-9_,=./:-]* | *compress-force*) exit 2 ;;
    esac

    _reinstall_debian_btrfs_fstab="$_reinstall_debian_btrfs_root/etc/fstab"
    mkdir -p "$_reinstall_debian_btrfs_root/etc" || exit 1
    _reinstall_debian_btrfs_tmp_dir=$(mktemp -d \
        "$_reinstall_debian_btrfs_root/etc/.reinstall-btrfs-debian.XXXXXX") || exit 1
    trap 'rm -rf "$_reinstall_debian_btrfs_tmp_dir"' 0 HUP INT TERM
    _reinstall_debian_btrfs_tmp="$_reinstall_debian_btrfs_tmp_dir/fstab"
    if [ -f "$_reinstall_debian_btrfs_fstab" ]; then
        awk '$0 ~ /^[[:space:]]*#/ || NF < 2 { print; next }
            $2 != "/" && $2 != "/boot" && $2 != "/boot/efi" { print }' \
            "$_reinstall_debian_btrfs_fstab" >"$_reinstall_debian_btrfs_tmp" || exit 1
    else
        : >"$_reinstall_debian_btrfs_tmp" || exit 1
    fi
    _reinstall_debian_btrfs_fstab_options=defaults
    [ -z "$_reinstall_debian_btrfs_options" ] ||
        _reinstall_debian_btrfs_fstab_options="$_reinstall_debian_btrfs_fstab_options,$_reinstall_debian_btrfs_options"
    {
        printf 'UUID=%s / btrfs %s,subvol=@ 0 0\n' \
            "$_reinstall_debian_btrfs_uuid" "$_reinstall_debian_btrfs_fstab_options"
        printf 'UUID=%s /boot btrfs %s,subvol=@boot 0 0\n' \
            "$_reinstall_debian_btrfs_uuid" "$_reinstall_debian_btrfs_fstab_options"
        if [ -n "$_reinstall_debian_btrfs_efi_uuid" ]; then
            printf 'UUID=%s /boot/efi vfat umask=0077 0 1\n' "$_reinstall_debian_btrfs_efi_uuid"
        fi
    } >>"$_reinstall_debian_btrfs_tmp" || exit 1
    mv "$_reinstall_debian_btrfs_tmp" "$_reinstall_debian_btrfs_fstab" || exit 1
    rm -rf "$_reinstall_debian_btrfs_tmp_dir" || exit 1
    trap - 0 HUP INT TERM
)

# Set rootflags in Debian's GRUB defaults without losing other kernel options.
# Repeated runs replace existing rootflags, making this safe for retries.
reinstall_btrfs_debian_set_grub_rootflags() (
    [ "$#" -eq 2 ] || exit 2
    _reinstall_debian_btrfs_root=$1
    _reinstall_debian_btrfs_options=$2
    _reinstall_debian_btrfs_grub="$_reinstall_debian_btrfs_root/etc/default/grub"
    [ -f "$_reinstall_debian_btrfs_grub" ] || exit 1
    _reinstall_debian_btrfs_rootflags=$(reinstall_btrfs_kernel_rootflags \
        @ "$_reinstall_debian_btrfs_options") || exit 2
    _reinstall_debian_btrfs_tmp="$_reinstall_debian_btrfs_grub.tmp.$$"
    awk -v rootflags="$_reinstall_debian_btrfs_rootflags" '
        /^GRUB_CMDLINE_LINUX=/ {
            found = 1
            if ($0 !~ /^GRUB_CMDLINE_LINUX="[^"]*"$/) {
                invalid = 1
                next
            }
            gsub(/rootflags=[^" ]+/, "", $0)
            sub(/^GRUB_CMDLINE_LINUX="[[:space:]]+/, "GRUB_CMDLINE_LINUX=\"", $0)
            sub(/[[:space:]]+"$/, "\"", $0)
            sub(/"$/, "", $0)
            if ($0 !~ /^GRUB_CMDLINE_LINUX="$/) $0 = $0 " "
            $0 = $0 rootflags "\""
            print
            next
        }
        { print }
        END {
            if (!found) printf "GRUB_CMDLINE_LINUX=\"%s\"\n", rootflags
            if (invalid) exit 2
        }
    ' "$_reinstall_debian_btrfs_grub" >"$_reinstall_debian_btrfs_tmp" || {
        rm -f "$_reinstall_debian_btrfs_tmp"
        exit 1
    }
    mv "$_reinstall_debian_btrfs_tmp" "$_reinstall_debian_btrfs_grub"
)

# Emit the NixOS declarations shared by the installer and reboot dry-run.
reinstall_btrfs_nixos_config_snippet() {
    [ "$#" -eq 3 ] || return 2
    [ "$1" = @ ] && [ "$2" = @boot ] || return 2
    case $3 in *[!A-Za-z0-9_,=./:-]* | *compress-force*) return 2 ;; esac
    _reinstall_btrfs_nixos_root_options='"subvol=@"'
    _reinstall_btrfs_nixos_boot_options='"subvol=@boot"'
    if [ -n "$3" ]; then
        _reinstall_btrfs_nixos_old_ifs=$IFS
        IFS=,
        for _reinstall_btrfs_nixos_option in $3; do
            _reinstall_btrfs_nixos_root_options="$_reinstall_btrfs_nixos_root_options \"$_reinstall_btrfs_nixos_option\""
            _reinstall_btrfs_nixos_boot_options="$_reinstall_btrfs_nixos_boot_options \"$_reinstall_btrfs_nixos_option\""
        done
        IFS=$_reinstall_btrfs_nixos_old_ifs
    fi
    cat <<EOF
boot.supportedFilesystems = [ "btrfs" ];
boot.initrd.supportedFilesystems = [ "btrfs" ];
environment.systemPackages = [ pkgs.btrfs-progs ];
fileSystems."/".options = lib.mkForce [ $_reinstall_btrfs_nixos_root_options ];
fileSystems."/boot".options = lib.mkForce [ $_reinstall_btrfs_nixos_boot_options ];
EOF
}

# Return the rootflags argument used by boot loaders and initramfs generators.
reinstall_btrfs_kernel_rootflags() {
    [ "$#" -eq 2 ] || return 2
    [ "$1" = @ ] || return 2
    case $2 in *[!A-Za-z0-9_,=./:-]* | *compress-force*) return 2 ;; esac
    if [ -n "$2" ]; then
        printf 'rootflags=subvol=%s,%s\n' "$1" "$2"
    else
        printf 'rootflags=subvol=%s\n' "$1"
    fi
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
