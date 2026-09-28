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

# Apply the network-related long CLI options. Values remain data and are
# validated as a whole after getopt has parsed every option.
reinstall_network_set_cli_option() {
    case "$1" in
    --ip-mode) ip_mode=$2 ;;
    --dns-mode) dns_mode=$2 ;;
    --dns-servers)
        if [ -n "${dns_servers:-}" ]; then
            dns_servers="$dns_servers,$2"
        else
            dns_servers=$2
        fi
        ;;
    *) return 2 ;;
    esac
}

# Validate comma-separated IPv4/IPv6 DNS literals. This intentionally rejects
# hostnames, zones, whitespace, and shell/config syntax so the values can be
# used in Linux and Windows target configuration without interpreting them.
reinstall_network_validate_dns_servers() {
    case "$1" in
    '' | ,* | *, | *,,*) return 1 ;;
    esac

    printf '%s\n' "$1" | awk '
        function ipv4(value, octets, count, i, number) {
            count = split(value, octets, ".")
            if (count != 4) return 0
            for (i = 1; i <= count; i++) {
                if (octets[i] !~ /^[0-9]+$/ || length(octets[i]) > 3) return 0
                number = octets[i] + 0
                if (number > 255) return 0
            }
            return 1
        }
        function valid_groups(value, groups, count, i) {
            count = split(value, groups, ":")
            for (i = 1; i <= count; i++) {
                if (groups[i] !~ /^[0-9A-Fa-f]+$/ || length(groups[i]) > 4) return 0
            }
            return count
        }
        function ipv6(value, groups, halves, count, compressed, group_count, i, part_count) {
            if (value !~ /:/ || value !~ /^[0-9A-Fa-f:]+$/ || value ~ /:::/) return 0
            compressed = (value ~ /::/)
            if (compressed && value ~ /::.*::/) return 0
            if (substr(value, 1, 1) == ":" && substr(value, 1, 2) != "::") return 0
            if (substr(value, length(value), 1) == ":" && substr(value, length(value) - 1, 2) != "::") return 0
            if (compressed) {
                split(value, halves, "::")
                group_count = 0
                for (i = 1; i <= 2; i++) {
                    if (halves[i] == "") continue
                    part_count = valid_groups(halves[i], groups)
                    if (!part_count) return 0
                    group_count += part_count
                }
                return group_count < 8
            }
            return valid_groups(value, groups) == 8
        }
        {
            count = split($0, servers, ",")
            if (count < 1) exit 1
            for (i = 1; i <= count; i++) {
                if (!ipv4(servers[i]) && !ipv6(servers[i])) exit 1
            }
        }
    '
}

reinstall_network_validate_cli_options() {
    case "${ip_mode:-auto}" in auto | dhcp | static) ;; *) return 1 ;; esac
    case "${dns_mode:-auto}" in auto | dhcp | static) ;; *) return 2 ;; esac

    if [ "${dns_mode:-auto}" = static ]; then
        [ -n "${dns_servers:-}" ] || return 3
        reinstall_network_validate_dns_servers "$dns_servers" || return 4
    elif [ -n "${dns_servers:-}" ]; then
        return 5
    fi
}

# Resolve the nameservers to write to a target. `auto` keeps the old behavior,
# DHCP remains managed by the target for dynamic IPs, and static IPs pin the
# servers observed during installer DHCP/RA when DNS mode is `dhcp`.
reinstall_network_target_dns_servers() {
    case "$1" in
    auto) printf '%s' "$5" ;;
    static) printf '%s' "$3" ;;
    dhcp)
        if [ "$2" = true ]; then
            printf '%s' "$4"
        fi
        ;;
    *) return 2 ;;
    esac
}

reinstall_network_should_persist_dns() {
    case "$1" in
    auto) return 1 ;;
    static) return 0 ;;
    dhcp) [ "$2" = true ] ;;
    *) return 2 ;;
    esac
}

reinstall_network_require_target_dns() {
    if reinstall_network_should_persist_dns "$1" "$2"; then
        [ -n "$3" ]
    else
        return 0
    fi
}

# Decide whether the target should obtain IPv4 through DHCP. `static` always
# disables target DHCP; `dhcp` forces it when the installer has working IPv4;
# `auto` preserves the detected mode unless DHCP was explicitly disabled.
reinstall_network_use_dhcp() {
    case "$1" in
    auto) [ "$2" = true ] && [ "$3" = false ] && [ "$4" = true ] ;;
    dhcp) [ "$4" = true ] ;;
    static) return 1 ;;
    *) return 2 ;;
    esac
}

reinstall_network_filter_dns_servers() {
    case "$2" in 4 | 6) ;; *) return 2 ;; esac
    (
        IFS=,
        set -f
        for _reinstall_dns_server in $1; do
            case "$2:$_reinstall_dns_server" in
            4:*.*) printf '%s\n' "$_reinstall_dns_server" ;;
            6:*:*) printf '%s\n' "$_reinstall_dns_server" ;;
            esac
        done
    )
}

# Convert rdisc6 output fragments (possibly separated by whitespace or
# commas) into a validated comma-separated DNS list. IPv6 colons are retained.
reinstall_network_parse_dns_candidates() (
    local _reinstall_candidates=$1 _reinstall_invalid _reinstall_server
    local _reinstall_result= _reinstall_separator=

    _reinstall_invalid=$(printf '%s' "$_reinstall_candidates" |
        tr -d '0123456789abcdefABCDEF:.,[:space:]')
    [ -z "$_reinstall_invalid" ] || exit 1

    _reinstall_candidates=$(printf '%s' "$_reinstall_candidates" | tr ',\t\n' '   ')
    IFS=' '
    set -f
    for _reinstall_server in $_reinstall_candidates; do
        reinstall_network_validate_dns_servers "$_reinstall_server" || exit 1
        _reinstall_result="$_reinstall_result$_reinstall_separator$_reinstall_server"
        _reinstall_separator=,
    done
    printf '%s' "$_reinstall_result"
)

reinstall_network_extract_rdnss() {
    local _reinstall_output
    _reinstall_output=$(printf '%s\n' "$1" | awk '
        /Recursive DNS server/ {
            sub(/^.*Recursive DNS server[[:space:]]*:?[[:space:]]*/, "")
            for (i = 1; i <= NF; i++) {
                gsub(/[^[:xdigit:]:]/, "", $i)
                if (index($i, ":") > 0) print $i
            }
        }
    ')
    reinstall_network_parse_dns_candidates "$_reinstall_output"
}

reinstall_network_render_dns_config() {
    local _reinstall_format=$1 _reinstall_servers=$2
    reinstall_network_validate_dns_servers "$_reinstall_servers" || return 1

    case "$_reinstall_format" in
    ifupdown)
        (
            IFS=,
            set -f
            for server in $_reinstall_servers; do
                printf '    dns-nameservers %s\n' "$server"
            done
        )
        ;;
    resolv-conf)
        (
            IFS=,
            set -f
            for server in $_reinstall_servers; do
                printf 'nameserver %s\n' "$server"
            done
        )
        ;;
    alpine-dhcpcd)
        printf 'nohook resolv.conf\n'
        ;;
    nixos)
        printf '  nameservers = [\n'
        (
            IFS=,
            set -f
            for server in $_reinstall_servers; do
                printf '    "%s"\n' "$server"
            done
        )
        printf '  ];\n'
        ;;
    *) return 2 ;;
    esac
}

reinstall_network_write_alpine_dns_config() {
    local _reinstall_dhcpcd_conf=$1 _reinstall_resolv_conf=$2 _reinstall_servers=$3
    local _reinstall_dhcpcd_tmp _reinstall_resolv_tmp

    reinstall_network_validate_dns_servers "$_reinstall_servers" || return 1
    [ -f "$_reinstall_dhcpcd_conf" ] || return 1

    _reinstall_dhcpcd_tmp=$(mktemp "${_reinstall_dhcpcd_conf}.XXXXXX") || return 1
    _reinstall_resolv_tmp=$(mktemp "${_reinstall_resolv_conf}.XXXXXX") || {
        rm -f "$_reinstall_dhcpcd_tmp"
        return 1
    }

    if grep -Eq '^[[:space:]]*nohook[[:space:]].*resolv\.conf([[:space:]]|$)' \
        "$_reinstall_dhcpcd_conf"; then
        cat "$_reinstall_dhcpcd_conf" >"$_reinstall_dhcpcd_tmp" || {
            rm -f "$_reinstall_dhcpcd_tmp" "$_reinstall_resolv_tmp"
            return 1
        }
    else
        {
            reinstall_network_render_dns_config alpine-dhcpcd "$_reinstall_servers"
            cat "$_reinstall_dhcpcd_conf"
        } >"$_reinstall_dhcpcd_tmp" || {
            rm -f "$_reinstall_dhcpcd_tmp" "$_reinstall_resolv_tmp"
            return 1
        }
    fi

    reinstall_network_render_dns_config resolv-conf "$_reinstall_servers" >"$_reinstall_resolv_tmp" || {
        rm -f "$_reinstall_dhcpcd_tmp" "$_reinstall_resolv_tmp"
        return 1
    }
    chmod 644 "$_reinstall_dhcpcd_tmp" "$_reinstall_resolv_tmp" || {
        rm -f "$_reinstall_dhcpcd_tmp" "$_reinstall_resolv_tmp"
        return 1
    }
    mv -f "$_reinstall_dhcpcd_tmp" "$_reinstall_dhcpcd_conf" &&
        mv -f "$_reinstall_resolv_tmp" "$_reinstall_resolv_conf"
}

reinstall_network_write_debian_dns_config() {
    local _reinstall_dhcpcd_conf=$1 _reinstall_dhclient_conf=$2
    local _reinstall_resolv_conf=$3 _reinstall_servers=$4
    local _reinstall_dhclient_tmp _reinstall_ipv4_servers _reinstall_ipv6_servers

    reinstall_network_validate_dns_servers "$_reinstall_servers" || return 1

    mkdir -p "$(dirname "$_reinstall_dhcpcd_conf")" || return 1
    [ -f "$_reinstall_dhcpcd_conf" ] || : >"$_reinstall_dhcpcd_conf" || return 1
    reinstall_network_write_alpine_dns_config \
        "$_reinstall_dhcpcd_conf" "$_reinstall_resolv_conf" "$_reinstall_servers" || return 1

    mkdir -p "$(dirname "$_reinstall_dhclient_conf")" || return 1
    _reinstall_dhclient_tmp=$(mktemp "${_reinstall_dhclient_conf}.XXXXXX") || return 1
    _reinstall_ipv4_servers=$(reinstall_network_filter_dns_servers "$_reinstall_servers" 4 |
        tr '\n' ',' | sed 's/,$//')
    _reinstall_ipv6_servers=$(reinstall_network_filter_dns_servers "$_reinstall_servers" 6 |
        tr '\n' ',' | sed 's/,$//')
    {
        if [ -n "$_reinstall_ipv4_servers" ]; then
            _reinstall_ipv4_servers=$(printf '%s' "$_reinstall_ipv4_servers" | sed 's/,/, /g')
            printf 'supersede domain-name-servers %s;\n' "$_reinstall_ipv4_servers"
        fi
        if [ -n "$_reinstall_ipv6_servers" ]; then
            _reinstall_ipv6_servers=$(printf '%s' "$_reinstall_ipv6_servers" | sed 's/,/, /g')
            printf 'supersede dhcp6.name-servers %s;\n' "$_reinstall_ipv6_servers"
        fi
        if [ -f "$_reinstall_dhclient_conf" ]; then
            awk '!/^[[:space:]]*supersede[[:space:]]+(domain-name-servers|dhcp6[.]name-servers)[[:space:]]/' \
                "$_reinstall_dhclient_conf"
        fi
    } >"$_reinstall_dhclient_tmp" || {
        rm -f "$_reinstall_dhclient_tmp"
        return 1
    }
    chmod 644 "$_reinstall_dhclient_tmp" || {
        rm -f "$_reinstall_dhclient_tmp"
        return 1
    }
    mv -f "$_reinstall_dhclient_tmp" "$_reinstall_dhclient_conf"
}

reinstall_network_apply_debian_dns_policy() {
    local _reinstall_mode=$1 _reinstall_target_has_static_ip=$2 _reinstall_dns_list=$3
    local _reinstall_dhcpcd_conf=$4 _reinstall_dhclient_conf=$5
    local _reinstall_resolv_conf=$6 _reinstall_dns_csv

    case "$_reinstall_mode" in auto | dhcp | static) ;; *) return 1 ;; esac
    case "$_reinstall_target_has_static_ip" in true | false) ;; *) return 1 ;; esac

    if ! reinstall_network_should_persist_dns \
        "$_reinstall_mode" "$_reinstall_target_has_static_ip"; then
        printf 'skipped\n'
        return 0
    fi
    if ! reinstall_network_require_target_dns \
        "$_reinstall_mode" "$_reinstall_target_has_static_ip" "$_reinstall_dns_list"; then
        return 2
    fi

    _reinstall_dns_csv=$(printf '%s\n' "$_reinstall_dns_list" | tr '\n' ',' | sed 's/,$//')
    reinstall_network_write_debian_dns_config \
        "$_reinstall_dhcpcd_conf" "$_reinstall_dhclient_conf" \
        "$_reinstall_resolv_conf" "$_reinstall_dns_csv" || return 3
    printf 'persisted\n'
}

reinstall_network_apply_alpine_dns_policy() {
    local _reinstall_mode=$1 _reinstall_target_has_static_ip=$2 _reinstall_dns_list=$3
    local _reinstall_dhcpcd_conf=$4 _reinstall_resolv_conf=$5 _reinstall_dns_csv

    case "$_reinstall_mode" in auto | dhcp | static) ;; *) return 1 ;; esac
    case "$_reinstall_target_has_static_ip" in true | false) ;; *) return 1 ;; esac

    if ! reinstall_network_should_persist_dns \
        "$_reinstall_mode" "$_reinstall_target_has_static_ip"; then
        printf 'skipped\n'
        return 0
    fi
    if ! reinstall_network_require_target_dns \
        "$_reinstall_mode" "$_reinstall_target_has_static_ip" "$_reinstall_dns_list"; then
        return 2
    fi

    _reinstall_dns_csv=$(printf '%s\n' "$_reinstall_dns_list" | tr '\n' ',' | sed 's/,$//')
    reinstall_network_write_alpine_dns_config \
        "$_reinstall_dhcpcd_conf" "$_reinstall_resolv_conf" "$_reinstall_dns_csv" || return 3
    printf 'persisted\n'
}

# Select a CLI target after bootloader discovery, which may have cached the
# running system's disk ID. The next find_main_disk call must resolve this
# selected target instead.
reinstall_cmdline_select_target_disk() {
    xda=${1##*/dev/}
    main_disk=
}

# Return the disk used to inspect the currently running system's BIOS boot
# code. It remains distinct from xda after a CLI target disk is selected.
reinstall_cmdline_bootloader_disk() {
    [ -n "${boot_xda:-}" ] || return 1
    printf '%s\n' "$boot_xda"
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
        extra_dns_mode | extra_dns_servers | extra_elts | extra_force_boot_mode | extra_force_cn | extra_force_old_windows_setup | \
        extra_hold | extra_kernel | extra_link_grub_dir | extra_localtest | extra_main_disk | \
        extra_filesystem | extra_ip_mode | extra_mirrorlist | extra_no_auto_drivers | extra_no_cloud_kernel | extra_rdp_port | \
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
    extra_dns_mode) dns_mode=$_reinstall_value ;;
    extra_dns_servers) dns_servers=$_reinstall_value ;;
    extra_elts) elts=$_reinstall_value ;;
    extra_force_boot_mode) force_boot_mode=$_reinstall_value ;;
    extra_force_cn) force_cn=$_reinstall_value ;;
    extra_force_old_windows_setup) force_old_windows_setup=$_reinstall_value ;;
    extra_filesystem) filesystem=$_reinstall_value ;;
    extra_hold) hold=$_reinstall_value ;;
    extra_ip_mode) ip_mode=$_reinstall_value ;;
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
