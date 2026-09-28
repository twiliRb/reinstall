#!/bin/sh
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
. "$repo_root/lib/reinstall-cmdline.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' 0
marker="$tmpdir/command-ran"

assert_eq() {
    if [ "$1" != "$2" ]; then
        printf 'expected <%s>, got <%s>\n' "$2" "$1" >&2
        exit 1
    fi
}

ip_mode=auto
dns_mode=auto
dns_servers=
reinstall_network_validate_cli_options
assert_eq "$ip_mode/$dns_mode/$dns_servers" auto/auto/
printf 'CHECKPOINT network/cli-defaults: ip-mode=%s dns-mode=%s dns-servers=empty\n' "$ip_mode" "$dns_mode"

reinstall_network_set_cli_option --ip-mode static
reinstall_network_set_cli_option --dns-mode static
reinstall_network_set_cli_option --dns-servers '1.1.1.1,2606:4700:4700::1111'
reinstall_network_validate_cli_options
assert_eq "$ip_mode/$dns_mode" static/static

if reinstall_network_validate_dns_servers "1.1.1.1;touch $marker"; then
    printf 'accepted command syntax as DNS servers\n' >&2
    exit 1
fi
if reinstall_network_validate_dns_servers '256.1.1.1'; then
    printf 'accepted an invalid IPv4 DNS server\n' >&2
    exit 1
fi
if reinstall_network_validate_dns_servers '2001:::1'; then
    printf 'accepted an invalid IPv6 DNS server\n' >&2
    exit 1
fi
[ ! -e "$marker" ]
printf 'CHECKPOINT network/dns-input-validation: rejected shell syntax and invalid IPv4/IPv6; sentinel=absent\n'

ip_mode=autodhcp
if reinstall_network_validate_cli_options; then
    printf 'accepted an invalid IP mode\n' >&2
    exit 1
fi
ip_mode=auto
dns_mode=automatic
if reinstall_network_validate_cli_options; then
    printf 'accepted an invalid DNS mode\n' >&2
    exit 1
fi

ip_mode=auto
dns_mode=static
dns_servers=
if reinstall_network_validate_cli_options; then
    printf 'accepted static DNS without servers\n' >&2
    exit 1
fi

ip_mode=auto
dns_mode=dhcp
dns_servers=1.1.1.1
if reinstall_network_validate_cli_options; then
    printf 'accepted DNS servers outside static DNS mode\n' >&2
    exit 1
fi
printf 'CHECKPOINT network/mode-combinations: accepted auto/auto and static DNS; rejected invalid modes and inconsistent DNS options\n'

explicit_dns='1.1.1.1,2606:4700:4700::1111'
dhcp_dns='192.0.2.53,2001:db8::53'
legacy_dns='8.8.8.8,2001:4860:4860::8888'
auto_target_dns=$(reinstall_network_target_dns_servers auto false "$explicit_dns" "$dhcp_dns" "$legacy_dns")
static_target_dns=$(reinstall_network_target_dns_servers static false "$explicit_dns" "$dhcp_dns" "$legacy_dns")
dhcp_target_dns=$(reinstall_network_target_dns_servers dhcp true "$explicit_dns" "$dhcp_dns" "$legacy_dns")
no_dhcp_target_dns=$(reinstall_network_target_dns_servers dhcp false "$explicit_dns" "$dhcp_dns" "$legacy_dns")
assert_eq "$auto_target_dns" "$legacy_dns"
assert_eq "$static_target_dns" "$explicit_dns"
assert_eq "$dhcp_target_dns" "$dhcp_dns"
[ -z "$no_dhcp_target_dns" ]
reinstall_network_use_dhcp auto true false true
reinstall_network_use_dhcp dhcp false true true
if reinstall_network_use_dhcp auto true false false; then
    printf 'enabled DHCP without working IPv4\n' >&2
    exit 1
fi
if reinstall_network_use_dhcp auto true true true; then
    printf 'ignored the existing DHCP disable policy in auto mode\n' >&2
    exit 1
fi
if reinstall_network_use_dhcp static true false true; then
    printf 'enabled DHCP in static IP mode\n' >&2
    exit 1
fi
reinstall_network_should_persist_dns static false
reinstall_network_should_persist_dns dhcp true
if reinstall_network_should_persist_dns dhcp false; then
    printf 'persisted DHCP DNS for a DHCP target\n' >&2
    exit 1
fi
if reinstall_network_should_persist_dns auto true; then
    printf 'changed legacy automatic DNS persistence behavior\n' >&2
    exit 1
fi
reinstall_network_require_target_dns static false '1.1.1.1'
if reinstall_network_require_target_dns dhcp true ''; then
    printf 'accepted a static target without an acquired DHCP DNS server\n' >&2
    exit 1
fi
reinstall_network_require_target_dns dhcp false ''
printf 'CHECKPOINT network/target-dns-policy: auto=%s static=%s dhcp=%s no-dhcp=empty\n' \
    "$auto_target_dns" "$static_target_dns" "$dhcp_target_dns"

assert_eq "$(reinstall_network_filter_dns_servers "$explicit_dns" 4)" '1.1.1.1'
assert_eq "$(reinstall_network_filter_dns_servers "$explicit_dns" 6)" '2606:4700:4700::1111'
dns_candidates=$(printf ' 2001:db8::53\n1.1.1.1, 2606:4700:4700::1111')
assert_eq "$(reinstall_network_parse_dns_candidates "$dns_candidates")" \
    '2001:db8::53,1.1.1.1,2606:4700:4700::1111'
if reinstall_network_parse_dns_candidates '1.1.1.1;touch /tmp/owned'; then
    printf 'accepted shell syntax in RA DNS candidates\n' >&2
    exit 1
fi
ra_dns_output=$(cat <<'EOF'
Recursive DNS server: 2001:db8::53 (expires in 60s)
Recursive DNS server: 2606:4700:4700::1111
EOF
)
assert_eq "$(reinstall_network_extract_rdnss "$ra_dns_output")" \
    '2001:db8::53,2606:4700:4700::1111'
printf 'CHECKPOINT network/dns-discovery: ipv4=1.1.1.1 ipv6=2606:4700:4700::1111 rdnss=%s\n' \
    "$(reinstall_network_extract_rdnss "$ra_dns_output")"

reinstall_network_render_dns_config ifupdown '1.1.1.1,2606:4700:4700::1111' >"$tmpdir/ifupdown"
cat >"$tmpdir/expected-ifupdown" <<'EOF'
    dns-nameservers 1.1.1.1
    dns-nameservers 2606:4700:4700::1111
EOF
diff -u "$tmpdir/expected-ifupdown" "$tmpdir/ifupdown"
printf 'CHECKPOINT network/ifupdown-render:\n'
sed 's/^/  | /' "$tmpdir/ifupdown"

reinstall_network_render_dns_config nixos '1.1.1.1,2606:4700:4700::1111' >"$tmpdir/nixos"
cat >"$tmpdir/expected-nixos" <<'EOF'
  nameservers = [
    "1.1.1.1"
    "2606:4700:4700::1111"
  ];
EOF
diff -u "$tmpdir/expected-nixos" "$tmpdir/nixos"
printf 'CHECKPOINT network/nixos-render:\n'
sed 's/^/  | /' "$tmpdir/nixos"

if reinstall_network_render_dns_config unknown "$explicit_dns"; then
    printf 'accepted an unknown DNS config renderer\n' >&2
    exit 1
fi

printf 'PASS network option and target DNS policy tests\n'
