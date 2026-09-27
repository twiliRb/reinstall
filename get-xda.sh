#!/bin/sh
# debian ubuntu redhat 安装模式共用此脚本
# alpine 未用到此脚本

get_all_disks() {
    # shellcheck disable=SC2010
    ls /sys/block/ | grep -Ev '^(loop|sr|nbd)'
}

get_xda() {
    # 如果没找到 main_disk 或 xda
    # 返回假的值，防止意外地格式化全部盘
    main_disk=
    for token in $(grep -oE 'extra_main_disk(_b64)?=[^ ]*' /proc/cmdline); do
        case "$token" in
        extra_main_disk_b64=*)
            main_disk=$(printf '%s' "${token#*=}" | base64 -d 2>/dev/null) || return 1
            ;;
        extra_main_disk=*) main_disk=${token#*=} ;;
        esac
    done

    if [ -z "$main_disk" ]; then
        echo 'MAIN_DISK_NOT_FOUND'
        return 1
    fi

    for disk in $(get_all_disks); do
        if fdisk -l "/dev/$disk" | grep -iq "$main_disk"; then
            echo "$disk"
            return
        fi
    done

    echo 'XDA_NOT_FOUND'
    return 1
}

get_xda
