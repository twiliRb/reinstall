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
    --network-backend) network_backend=$2 ;;
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

# Validate the explicit target network manager selection. `auto` preserves the
# distro's existing behavior and is valid for every target.
reinstall_network_validate_backend_option() {
    case "$1" in
    auto | systemd-networkd | NetworkManager) return 0 ;;
    *) return 1 ;;
    esac
}

# Return 0 when the selected manager is supported by this distro, 1 for a
# valid but unsupported combination, and 2 for an invalid manager value. This
# is a distro policy check only; callers remain responsible for installing and
# configuring the selected service.
reinstall_network_backend_supported_for_distro() {
    reinstall_network_validate_backend_option "$1" || return 2

    case "$1:$2" in
    auto:*) return 0 ;;
    systemd-networkd:debian | systemd-networkd:kali | systemd-networkd:ubuntu | \
        systemd-networkd:arch | systemd-networkd:gentoo | systemd-networkd:fedora | \
        systemd-networkd:nixos)
        return 0
        ;;
    NetworkManager:alpine | NetworkManager:debian | NetworkManager:kali | \
        NetworkManager:ubuntu | NetworkManager:arch | NetworkManager:gentoo | \
        NetworkManager:aosc | NetworkManager:fedora | NetworkManager:opensuse | \
        NetworkManager:nixos | NetworkManager:anolis | NetworkManager:opencloudos | \
        NetworkManager:centos | NetworkManager:almalinux | NetworkManager:rocky | \
        NetworkManager:oracle | NetworkManager:openeuler | NetworkManager:redhat | \
        NetworkManager:fnos)
        return 0
        ;;
    *) return 1 ;;
    esac
}

# Resolve OpenRC's service script name for an explicitly selected backend.
# Alpine packages NetworkManager with the lowercase `networkmanager` service.
reinstall_network_openrc_service_name() {
    case "$1:$2" in
    alpine:NetworkManager) printf '%s\n' networkmanager ;;
    *) return 1 ;;
    esac
}

# Validate comma-separated IPv4/IPv6 DNS literals. This intentionally rejects
# hostnames, zones, whitespace, and shell/config syntax so the values can be
# used in Linux and Windows target configuration without interpreting them.
reinstall_network_validate_dns_servers() {
    case "$1" in
    '' | ,* | *, | *,,*) return 1 ;;
    esac
    case "$1" in
    *[!0-9A-Fa-f:.,]*) return 1 ;;
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

# Validate an interface identifier before placing it in a network-manager
# profile. Interface-name matching in systemd-networkd supports globs, so keep
# the accepted alphabet literal and portable across both output formats.
reinstall_network_validate_profile_interface() {
    case "$1" in
    '') return 0 ;;
    . | .. | *[!A-Za-z0-9_.:-]*) return 1 ;;
    esac
    [ "${#1}" -le 15 ]
}

reinstall_network_validate_profile_mac() {
    case "$1" in
    '') return 0 ;;
    *:*)
        printf '%s\n' "$1" | awk -F: '
            NF != 6 { exit 1 }
            {
                for (i = 1; i <= NF; i++) {
                    if (length($i) != 2 || $i !~ /^[0123456789abcdefABCDEF]+$/) exit 1
                }
            }
        '
        ;;
    *) return 1 ;;
    esac
}

reinstall_network_validate_profile_ip_literal() {
    local _reinstall_address=$1 _reinstall_family=$2
    case "$_reinstall_family:$_reinstall_address" in
    4:*)
        case "$_reinstall_address" in *.*) ;; *) return 1 ;; esac
        case "$_reinstall_address" in *:*) return 1 ;; esac
        ;;
    6:*)
        case "$_reinstall_address" in *:*) ;; *) return 1 ;; esac
        case "$_reinstall_address" in *.*) return 1 ;; esac
        ;;
    *) return 1 ;;
    esac
    reinstall_network_validate_dns_servers "$_reinstall_address"
}

reinstall_network_validate_profile_address_list() {
    local _reinstall_addresses=$1 _reinstall_family=$2
    local _reinstall_address _reinstall_literal _reinstall_prefix _reinstall_limit
    case "$_reinstall_addresses" in
    '') return 0 ;;
    ,* | *, | *,,*) return 1 ;;
    esac
    case "$_reinstall_family" in
    4) _reinstall_limit=32 ;;
    6) _reinstall_limit=128 ;;
    *) return 1 ;;
    esac

    (
        IFS=,
        set -f
        for _reinstall_address in $_reinstall_addresses; do
            case "$_reinstall_address" in
            */*) ;;
            *) exit 1 ;;
            esac
            case "$_reinstall_address" in
            */*/*) exit 1 ;;
            esac
            _reinstall_literal=${_reinstall_address%/*}
            _reinstall_prefix=${_reinstall_address#*/}
            reinstall_network_validate_profile_ip_literal \
                "$_reinstall_literal" "$_reinstall_family" || exit 1
            printf '%s\n' "$_reinstall_prefix" |
                awk -v limit="$_reinstall_limit" \
                    '$0 ~ /^[0-9]+$/ && $0 + 0 <= limit { valid = 1 } END { exit !valid }' || exit 1
        done
    )
}

reinstall_network_validate_profile_args() {
    [ "$#" -eq 11 ] || return 1
    reinstall_network_validate_profile_interface "$1" || return 1
    reinstall_network_validate_profile_mac "$2" || return 1
    [ -n "$1" ] || [ -n "$2" ] || return 1
    case "$3" in auto | manual | disabled) ;; *) return 1 ;; esac
    case "$6" in auto | dhcp | manual | disabled) ;; *) return 1 ;; esac
    if [ "$3" = manual ]; then
        [ -n "$4" ] || return 1
    fi
    if [ "$6" = manual ]; then
        [ -n "$7" ] || return 1
    fi
    reinstall_network_validate_profile_address_list "$4" 4 || return 1
    reinstall_network_validate_profile_address_list "$7" 6 || return 1
    if [ -n "$5" ]; then
        reinstall_network_validate_profile_ip_literal "$5" 4 || return 1
    fi
    if [ -n "$8" ]; then
        reinstall_network_validate_profile_ip_literal "$8" 6 || return 1
    fi
    if [ -n "$4" ] || [ -n "$5" ]; then
        [ "$3" != disabled ] || return 1
    fi
    if [ -n "$7" ] || [ -n "$8" ]; then
        [ "$6" != disabled ] || return 1
    fi
    if [ -n "$9" ]; then
        reinstall_network_validate_dns_servers "$9" || return 1
    fi
    case "${10}" in true | false) ;; *) return 1 ;; esac
    case "${11}" in true | false) ;; *) return 1 ;; esac
    if [ "$6" = disabled ] && [ "${10}" = true ]; then
        return 1
    fi
}

# Apply the selected backend's final target resolver setup without requiring
# a service manager or package database in the test environment.
reinstall_network_finalize_resolver() {
    [ "$#" -eq 2 ] || return 1
    local _reinstall_root=$1 _reinstall_backend=$2

    case "$_reinstall_backend" in
    auto) return 0 ;;
    systemd-networkd)
        rm -f "$_reinstall_root/etc/resolv.conf" "$_reinstall_root/etc/resolv.conf.orig" || return 1
        ln -s ../run/systemd/resolve/stub-resolv.conf \
            "$_reinstall_root/etc/resolv.conf"
        ;;
    NetworkManager)
        rm -f "$_reinstall_root/etc/resolv.conf" "$_reinstall_root/etc/resolv.conf.orig"
        ;;
    *) return 1 ;;
    esac
}

# Render a persistent systemd-networkd .network profile. All caller-provided
# fields are validated before any profile bytes are written to stdout.
reinstall_network_render_networkd_profile() {
    [ "$#" -eq 11 ] || return 1
    local _reinstall_interface=$1 _reinstall_mac=$2
    local _reinstall_ipv4_method=$3 _reinstall_ipv4_addresses=$4
    local _reinstall_ipv4_gateway=$5 _reinstall_ipv6_method=$6
    local _reinstall_ipv6_addresses=$7 _reinstall_ipv6_gateway=$8
    local _reinstall_dns_servers=$9 _reinstall_accept_ra=${10}
    local _reinstall_ignore_auto_dns=${11} _reinstall_dhcp _reinstall_link_local _reinstall_ra
    local _reinstall_server

    reinstall_network_validate_profile_args "$@" || return 1

    if [ "$_reinstall_ipv4_method" = auto ] && [ "$_reinstall_ipv6_method" = dhcp ]; then
        _reinstall_dhcp=yes
    elif [ "$_reinstall_ipv4_method" = auto ]; then
        _reinstall_dhcp=ipv4
    elif [ "$_reinstall_ipv6_method" = dhcp ]; then
        _reinstall_dhcp=ipv6
    else
        _reinstall_dhcp=no
    fi

    if [ "$_reinstall_ipv4_method" = disabled ] &&
        [ "$_reinstall_ipv6_method" = disabled ]; then
        _reinstall_link_local=no
    elif [ "$_reinstall_ipv4_method" = disabled ]; then
        _reinstall_link_local=ipv6
    elif [ "$_reinstall_ipv6_method" = disabled ]; then
        _reinstall_link_local=ipv4
    else
        _reinstall_link_local=yes
    fi
    case "$_reinstall_accept_ra" in
    true) _reinstall_ra=yes ;;
    false) _reinstall_ra=no ;;
    esac

    printf '[Match]\n'
    if [ -z "$_reinstall_mac" ] && [ -n "$_reinstall_interface" ]; then
        printf 'Name=%s\n' "$_reinstall_interface"
    fi
    [ -z "$_reinstall_mac" ] || printf 'MACAddress=%s\n' "$_reinstall_mac"
    printf '\n[Network]\nDHCP=%s\nLinkLocalAddressing=%s\nIPv6AcceptRA=%s\n' \
        "$_reinstall_dhcp" "$_reinstall_link_local" "$_reinstall_ra"
    (
        IFS=,
        set -f
        for _reinstall_server in $_reinstall_ipv4_addresses; do
            [ -n "$_reinstall_server" ] || continue
            printf 'Address=%s\n' "$_reinstall_server"
        done
        for _reinstall_server in $_reinstall_ipv6_addresses; do
            [ -n "$_reinstall_server" ] || continue
            printf 'Address=%s\n' "$_reinstall_server"
        done
    )
    (
        IFS=,
        set -f
        for _reinstall_server in $_reinstall_dns_servers; do
            [ -n "$_reinstall_server" ] || continue
            printf 'DNS=%s\n' "$_reinstall_server"
        done
    )
    [ -z "$_reinstall_ipv4_gateway" ] ||
        printf '\n[Route]\nGateway=%s\nGatewayOnLink=yes\n' "$_reinstall_ipv4_gateway"
    [ -z "$_reinstall_ipv6_gateway" ] ||
        printf '\n[Route]\nGateway=%s\nGatewayOnLink=yes\n' "$_reinstall_ipv6_gateway"

    if [ "$_reinstall_ignore_auto_dns" = true ]; then
        # Older systemd releases (including Debian 10's systemd 241) only
        # understand the shared [DHCP] section. Keep it alongside the newer
        # protocol-specific sections below.
        printf '\n[DHCP]\nUseDNS=no\n'
        if [ "$_reinstall_ipv4_method" = auto ]; then
            printf '\n[DHCPv4]\nUseDNS=no\n'
        fi
        # Router advertisements can trigger DHCPv6 even without DHCP=ipv6.
        if [ "$_reinstall_ipv6_method" = dhcp ] || [ "$_reinstall_accept_ra" = true ]; then
            printf '\n[DHCPv6]\nUseDNS=no\n'
        fi
        if [ "$_reinstall_accept_ra" = true ]; then
            printf '\n[IPv6AcceptRA]\nUseDNS=no\n'
        fi
    fi
}

# Embed a validated networkd profile as a declarative NixOS /etc file. The
# profile bytes come from reinstall_network_render_networkd_profile; reject
# Nix interpolation and indented-string delimiters before emitting any Nix.
reinstall_network_render_nixos_networkd_profile() {
    [ "$#" -eq 2 ] || return 1
    local _reinstall_index=$1 _reinstall_profile=$2

    case "$_reinstall_index" in
    '' | *[!0-9]*) return 1 ;;
    esac
    [ -n "$_reinstall_profile" ] || return 1
    case "$_reinstall_profile" in
    *'${'* | *"''"*) return 1 ;;
    esac

    printf "environment.etc.\"systemd/network/10-reinstall-%s.network\".text = ''\n" \
        "$_reinstall_index"
    printf '%s\n' "$_reinstall_profile"
    printf "'';\n"
}

# Render a NetworkManager .nmconnection keyfile. The keyfile syntax uses one
# addressN entry per static address and semicolon-delimited DNS lists.
reinstall_network_render_nm_profile() {
    [ "$#" -eq 11 ] || return 1
    local _reinstall_interface=$1 _reinstall_mac=$2
    local _reinstall_ipv4_method=$3 _reinstall_ipv4_addresses=$4
    local _reinstall_ipv4_gateway=$5 _reinstall_ipv6_method=$6
    local _reinstall_ipv6_addresses=$7 _reinstall_ipv6_gateway=$8
    local _reinstall_dns_servers=$9 _reinstall_accept_ra=${10}
    local _reinstall_ignore_auto_dns=${11} _reinstall_identifier _reinstall_nm_ipv6_method
    local _reinstall_dns4 _reinstall_dns6 _reinstall_address

    reinstall_network_validate_profile_args "$@" || return 1

    if [ -n "$_reinstall_interface" ]; then
        _reinstall_identifier=$_reinstall_interface
    else
        _reinstall_identifier=$_reinstall_mac
    fi
    case "$_reinstall_ipv6_method" in
    auto | dhcp) _reinstall_nm_ipv6_method=auto ;;
    manual | disabled) _reinstall_nm_ipv6_method=$_reinstall_ipv6_method ;;
    esac

    printf '[connection]\nid=reinstall-%s\ntype=802-3-ethernet\n' \
        "$_reinstall_identifier"
    [ -n "$_reinstall_mac" ] || [ -z "$_reinstall_interface" ] ||
        printf 'interface-name=%s\n' "$_reinstall_interface"
    printf 'autoconnect=true\n\n'

    if [ -n "$_reinstall_mac" ]; then
        printf '[802-3-ethernet]\nmac-address=%s\n\n' "$_reinstall_mac"
    fi

    _reinstall_dns4=$(reinstall_network_filter_dns_servers "$_reinstall_dns_servers" 4 |
        tr '\n' ';' | sed 's/;$//')
    _reinstall_dns6=$(reinstall_network_filter_dns_servers "$_reinstall_dns_servers" 6 |
        tr '\n' ';' | sed 's/;$//')

    printf '[ipv4]\nmethod=%s\n' "$_reinstall_ipv4_method"
    (
        IFS=,
        set -f
        _reinstall_index=1
        for _reinstall_address in $_reinstall_ipv4_addresses; do
            [ -n "$_reinstall_address" ] || continue
            printf 'address%s=%s\n' "$_reinstall_index" "$_reinstall_address"
            _reinstall_index=$((_reinstall_index + 1))
        done
    )
    [ -z "$_reinstall_ipv4_gateway" ] ||
        printf 'gateway=%s\n' "$_reinstall_ipv4_gateway"
    [ -z "$_reinstall_dns4" ] || printf 'dns=%s;\n' "$_reinstall_dns4"
    if [ "$_reinstall_ignore_auto_dns" = true ] &&
        { [ "$_reinstall_ipv4_method" = auto ] || [ "$_reinstall_ipv4_method" = dhcp ]; }; then
        printf 'ignore-auto-dns=true\n'
    fi

    printf '\n[ipv6]\nmethod=%s\n' "$_reinstall_nm_ipv6_method"
    (
        IFS=,
        set -f
        _reinstall_index=1
        for _reinstall_address in $_reinstall_ipv6_addresses; do
            [ -n "$_reinstall_address" ] || continue
            printf 'address%s=%s\n' "$_reinstall_index" "$_reinstall_address"
            _reinstall_index=$((_reinstall_index + 1))
        done
    )
    [ -z "$_reinstall_ipv6_gateway" ] ||
        printf 'gateway=%s\n' "$_reinstall_ipv6_gateway"
    [ -z "$_reinstall_dns6" ] || printf 'dns=%s;\n' "$_reinstall_dns6"
    if [ "$_reinstall_ignore_auto_dns" = true ] &&
        { [ "$_reinstall_ipv6_method" = auto ] || [ "$_reinstall_ipv6_method" = dhcp ]; }; then
        printf 'ignore-auto-dns=true\n'
    fi
}

# Render sysctl settings that NetworkManager cannot express in a connection
# keyfile. Validate every field before emitting any output.
reinstall_network_render_sysctl_profile() {
    [ "$#" -eq 3 ] || return 1
    local _reinstall_interface=$1 _reinstall_accept_ra=$2 _reinstall_autoconf=$3
    reinstall_network_validate_profile_interface "$_reinstall_interface" || return 1
    [ -n "$_reinstall_interface" ] || return 1
    case "$_reinstall_accept_ra" in true | false) ;; *) return 1 ;; esac
    case "$_reinstall_autoconf" in true | false) ;; *) return 1 ;; esac

    [ "$_reinstall_accept_ra" = false ] &&
        printf 'net.ipv6.conf.%s.accept_ra=0\n' "$_reinstall_interface"
    [ "$_reinstall_autoconf" = false ] &&
        printf 'net.ipv6.conf.%s.autoconf=0\n' "$_reinstall_interface"
    return 0
}

# Preserve NetworkManager IPv6 sysctl policy across interface renames by
# recording the hardware address and applying the per-interface setting once
# the target's actual device name is available.
reinstall_network_render_nm_sysctl_map() {
    [ "$#" -eq 4 ] || return 1
    local _reinstall_interface=$1 _reinstall_mac=$2
    local _reinstall_accept_ra=$3 _reinstall_autoconf=$4
    reinstall_network_validate_profile_interface "$_reinstall_interface" || return 1
    reinstall_network_validate_profile_mac "$_reinstall_mac" || return 1
    [ -n "$_reinstall_interface" ] || [ -n "$_reinstall_mac" ] || return 1
    case "$_reinstall_accept_ra" in true | false) ;; *) return 1 ;; esac
    case "$_reinstall_autoconf" in true | false) ;; *) return 1 ;; esac

    if [ -n "$_reinstall_mac" ]; then
        printf 'mac %s %s %s\n' "$_reinstall_mac" \
            "$_reinstall_accept_ra" "$_reinstall_autoconf"
    else
        printf 'name %s %s %s\n' "$_reinstall_interface" \
        "$_reinstall_accept_ra" "$_reinstall_autoconf"
    fi
}

reinstall_network_validate_cli_options() {
    case "${ip_mode:-auto}" in auto | dhcp | static) ;; *) return 1 ;; esac
    case "${dns_mode:-auto}" in auto | dhcp | static) ;; *) return 2 ;; esac
    reinstall_network_validate_backend_option "${network_backend:-auto}" || return 6

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
        extra_filesystem | extra_ip_mode | extra_mirrorlist | extra_network_backend | extra_no_auto_drivers | extra_no_cloud_kernel | extra_rdp_port | \
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
    extra_network_backend) network_backend=$_reinstall_value ;;
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
