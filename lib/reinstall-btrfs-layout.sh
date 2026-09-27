#!/bin/sh

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
