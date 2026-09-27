#!/bin/sh

# Serialize one value as a single kernel command-line word.
reinstall_cmdline_serialize() {
    _reinstall_name=$1
    _reinstall_value=$2
    case "$_reinstall_name" in extra_* | finalos_*) ;; *) return 2 ;; esac
    case "$_reinstall_name" in *[!A-Za-z0-9_]*) return 2 ;; esac
    printf '%s_b64=%s' "$_reinstall_name" "$(printf '%s' "$_reinstall_value" | base64 | tr -d '\r\n')"
}

# Serialize one value as a POSIX shell single-quoted word for generated scripts.
reinstall_shell_quote() {
    printf "'"
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}

# Return 1 for an unknown filesystem value and 2 when Btrfs is unavailable for
# the selected distro. ext4 remains the default on every existing path.
reinstall_validate_filesystem() {
    local _reinstall_filesystem=$1 _reinstall_distro=$2
    case "$_reinstall_filesystem" in
    ext4) return 0 ;;
    btrfs)
        case "$_reinstall_distro" in
        arch | gentoo | nixos | aosc) return 0 ;;
        *) return 2 ;;
        esac
        ;;
    *) return 1 ;;
    esac
}

# Parse the first line emitted by `mke2fs -V`. The executable name contains a
# digit, so looking for the first number in the line reports `2`, not its
# version. Keep this a pure parser so callers can reject unsupported tools
# before touching disks.
reinstall_e2fsprogs_version_from_mke2fs_output() {
    printf '%s\n' "$1" |
        awk 'NR == 1 && $1 == "mke2fs" && $2 ~ /^[0-9][0-9.]*$/ { print $2 }'
}

# The Btrfs no-compression inode flag is exposed by e2fsprogs chattr since
# 1.46.2. Accept only a plain three-part numeric version string.
reinstall_e2fsprogs_supports_nocompress() {
    local _reinstall_version=$1
    local _reinstall_major _reinstall_minor _reinstall_patch _reinstall_rest

    case "$_reinstall_version" in
    '' | *[!0-9.]* | .* | *..* | *.) return 1 ;;
    esac
    _reinstall_major=${_reinstall_version%%.*}
    [ "$_reinstall_major" != "$_reinstall_version" ] || return 1
    _reinstall_rest=${_reinstall_version#*.}
    _reinstall_minor=${_reinstall_rest%%.*}
    [ "$_reinstall_minor" != "$_reinstall_rest" ] || return 1
    _reinstall_patch=${_reinstall_rest#*.}
    case "$_reinstall_patch" in *.* | '') return 1 ;; esac

    if [ "$_reinstall_major" -gt 1 ]; then
        return 0
    fi
    [ "$_reinstall_major" -eq 1 ] || return 1
    if [ "$_reinstall_minor" -gt 46 ]; then
        return 0
    fi
    [ "$_reinstall_minor" -eq 46 ] || return 1
    [ "$_reinstall_patch" -ge 2 ]
}

# web_path is generated as an HTTP path, then also used beneath a static root.
# Accept only safe path segments so it cannot escape /tmp/web or contain shell
# syntax when supplied through an old or manually edited kernel command line.
reinstall_validate_web_path() {
    local _reinstall_web_path=$1
    case "$_reinstall_web_path" in
    /*) ;;
    *) return 1 ;;
    esac
    case "$_reinstall_web_path" in
    / | */ | *//* | *[!A-Za-z0-9/_-]*) return 1 ;;
    esac
}

# Return a constant script for websocketd; callers pass path and log as argv.
reinstall_websocket_log_script() {
    cat <<'EOF'
if [ "$PATH_INFO" = "$1" ]; then
    tail -fn+0 "$2" | tr '\r' '\n' | grep -Fiv -e password -e token
fi
EOF
}

reinstall_cmdline_apply_token() {
    local _reinstall_token=$1 _reinstall_prefix_filter=$2
    local _reinstall_key _reinstall_value _reinstall_encoded _reinstall_sha
    case "$_reinstall_token" in *=*) ;; *) return 0 ;; esac
    _reinstall_key=${_reinstall_token%%=*}
    _reinstall_value=${_reinstall_token#*=}
    case "$_reinstall_prefix_filter:$_reinstall_key" in
    all:finalos_* | all:extra_* | extra:extra_*) ;;
    *) return 0 ;;
    esac
    _reinstall_encoded=0
    case "$_reinstall_key" in
    *_b64) _reinstall_key=${_reinstall_key%_b64}; _reinstall_encoded=1 ;;
    esac
    case "$_reinstall_key" in
    finalos_a | finalos_boot_wim | finalos_codename | finalos_confirmed_no_efi | \
        finalos_deb_mirror | finalos_distro | finalos_efi | finalos_firmware | \
        finalos_fnos_part_size | finalos_image_name | finalos_img | finalos_img_type | \
        finalos_img_type_warp | finalos_initrd | finalos_iso | finalos_kernel | \
        finalos_ks | finalos_minimal | finalos_mirror | finalos_mirrorlist | \
        finalos_modloop | finalos_releasever | finalos_repo | finalos_squashfs | \
        finalos_udeb_mirror | finalos_vmlinuz | \
        extra_addrs | extra_allow_ping | extra_cloud_image | extra_confhome | extra_deb_mirror | \
        extra_elts | extra_force_boot_mode | extra_force_cn | extra_force_old_windows_setup | \
        extra_hold | extra_kernel | extra_link_grub_dir | extra_localtest | extra_main_disk | \
        extra_filesystem | extra_mirrorlist | extra_no_auto_drivers | extra_no_cloud_kernel | extra_rdp_port | \
        extra_source_id | extra_ssh_port | extra_username | extra_web_path | extra_web_port) ;;
    *) return 0 ;;
    esac
    if [ "$_reinstall_encoded" -eq 1 ]; then
        _reinstall_value=$(printf '%s' "$_reinstall_value" | base64 -d 2>/dev/null) || return 1
    fi
    case "$_reinstall_key" in
    extra_confhome)
        case "$_reinstall_value" in https://raw.githubusercontent.com/twiliRb/reinstall/*) ;; *) return 1 ;; esac
        _reinstall_sha=${_reinstall_value#https://raw.githubusercontent.com/twiliRb/reinstall/}
        case "$_reinstall_sha" in *[!0-9a-f]* | '') return 1 ;; esac
        [ "${#_reinstall_sha}" -eq 40 ] || return 1
        confhome=$_reinstall_value
        ;;
    extra_addrs) addrs=$_reinstall_value ;;
    extra_allow_ping) allow_ping=$_reinstall_value ;;
    extra_cloud_image) cloud_image=$_reinstall_value ;;
    extra_deb_mirror) deb_mirror=$_reinstall_value ;;
    extra_elts) elts=$_reinstall_value ;;
    extra_force_boot_mode) force_boot_mode=$_reinstall_value ;;
    extra_force_cn) force_cn=$_reinstall_value ;;
    extra_force_old_windows_setup) force_old_windows_setup=$_reinstall_value ;;
    extra_filesystem) filesystem=$_reinstall_value ;;
    extra_hold) hold=$_reinstall_value ;;
    extra_kernel) kernel=$_reinstall_value ;;
    extra_link_grub_dir) link_grub_dir=$_reinstall_value ;;
    extra_localtest) localtest=$_reinstall_value ;;
    extra_main_disk) main_disk=$_reinstall_value ;;
    extra_mirrorlist) mirrorlist=$_reinstall_value ;;
    extra_no_auto_drivers) no_auto_drivers=$_reinstall_value ;;
    extra_no_cloud_kernel) no_cloud_kernel=$_reinstall_value ;;
    extra_rdp_port) rdp_port=$_reinstall_value ;;
    extra_source_id) source_id=$_reinstall_value ;;
    extra_ssh_port) ssh_port=$_reinstall_value ;;
    extra_username) username=$_reinstall_value ;;
    extra_web_path) web_path=$_reinstall_value ;;
    extra_web_port) web_port=$_reinstall_value ;;
    finalos_a) a=$_reinstall_value ;;
    finalos_boot_wim) boot_wim=$_reinstall_value ;;
    finalos_codename) codename=$_reinstall_value ;;
    finalos_confirmed_no_efi) confirmed_no_efi=$_reinstall_value ;;
    finalos_deb_mirror) deb_mirror=$_reinstall_value ;;
    finalos_distro) distro=$_reinstall_value ;;
    finalos_efi) efi=$_reinstall_value ;;
    finalos_firmware) firmware=$_reinstall_value ;;
    finalos_fnos_part_size) fnos_part_size=$_reinstall_value ;;
    finalos_image_name) image_name=$_reinstall_value ;;
    finalos_img) img=$_reinstall_value ;;
    finalos_img_type) img_type=$_reinstall_value ;;
    finalos_img_type_warp) img_type_warp=$_reinstall_value ;;
    finalos_initrd) initrd=$_reinstall_value ;;
    finalos_iso) iso=$_reinstall_value ;;
    finalos_kernel) kernel=$_reinstall_value ;;
    finalos_ks) ks=$_reinstall_value ;;
    finalos_minimal) minimal=$_reinstall_value ;;
    finalos_mirror) mirror=$_reinstall_value ;;
    finalos_mirrorlist) mirrorlist=$_reinstall_value ;;
    finalos_modloop) modloop=$_reinstall_value ;;
    finalos_releasever) releasever=$_reinstall_value ;;
    finalos_repo) repo=$_reinstall_value ;;
    finalos_squashfs) squashfs=$_reinstall_value ;;
    finalos_udeb_mirror) udeb_mirror=$_reinstall_value ;;
    finalos_vmlinuz) vmlinuz=$_reinstall_value ;;
    esac
}

reinstall_cmdline_load_file() {
    local _reinstall_file=$1
    local _reinstall_prefix_filter=${2:-all}
    local _reinstall_tokens _reinstall_token _reinstall_old_ifs
    local _reinstall_restore_globbing=0

    [ -r "$_reinstall_file" ] || return 1
    case "$_reinstall_prefix_filter" in all | extra) ;; *) return 2 ;; esac

    if command -v xargs >/dev/null 2>&1; then
        _reinstall_tokens=$(xargs -n1 <"$_reinstall_file") || return 1
        while IFS= read -r _reinstall_token; do
            reinstall_cmdline_apply_token "$_reinstall_token" "$_reinstall_prefix_filter" || return 1
        done <<EOF
$_reinstall_tokens
EOF
    else
        # Some Debian installer initrds omit xargs. Serialized values have no
        # whitespace, so splitting is safe; disable globbing while reading them.
        case $- in *f*) ;; *) set -f; _reinstall_restore_globbing=1 ;; esac
        _reinstall_old_ifs=$IFS
        IFS=' '
        _reinstall_tokens=$(cat "$_reinstall_file") || return 1
        for _reinstall_token in $_reinstall_tokens; do
            if ! reinstall_cmdline_apply_token "$_reinstall_token" "$_reinstall_prefix_filter"; then
                IFS=$_reinstall_old_ifs
                [ "$_reinstall_restore_globbing" -eq 0 ] || set +f
                return 1
            fi
        done
        IFS=$_reinstall_old_ifs
        [ "$_reinstall_restore_globbing" -eq 0 ] || set +f
    fi
}

reinstall_cmdline_reencode_file() {
    local _reinstall_file=$1
    local _reinstall_prefix=$2
    local _reinstall_skip_key=${3:-}
    local _reinstall_tokens _reinstall_token _reinstall_key _reinstall_value

    [ -r "$_reinstall_file" ] || return 1
    case "$_reinstall_prefix" in extra | finalos) ;; *) return 2 ;; esac
    command -v xargs >/dev/null 2>&1 || return 1
    _reinstall_tokens=$(xargs -n1 <"$_reinstall_file") || return 1
    while IFS= read -r _reinstall_token; do
        case "$_reinstall_token" in
        "${_reinstall_prefix}_"*'='*)
            _reinstall_key=${_reinstall_token%%=*}
            _reinstall_value=${_reinstall_token#*=}
            [ "$_reinstall_key" = "$_reinstall_skip_key" ] && continue
            case "$_reinstall_key" in
            *_b64)
                _reinstall_key=${_reinstall_key%_b64}
                _reinstall_value=$(printf '%s' "$_reinstall_value" | base64 -d 2>/dev/null) || return 1
                ;;
            esac
            printf ' %s' "$(reinstall_cmdline_serialize "$_reinstall_key" "$_reinstall_value")" || return 1
            ;;
        esac
    done <<EOF
$_reinstall_tokens
EOF
}
