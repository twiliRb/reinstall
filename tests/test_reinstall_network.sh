#!/bin/sh
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
. "$repo_root/lib/reinstall-cmdline.sh"

# Debian Installer runs in a separate initrd process; its shell variables do
# not inherit the installer's defaults, so its late command must establish the
# default even when no backend token was passed.
if ! grep -Fq 'network_backend=${network_backend:-auto};' "$repo_root/debian.cfg"; then
    printf 'Debian Installer late command does not default network_backend to auto\n' >&2
    exit 1
fi
printf 'CHECKPOINT network/debian-installer-default: absent backend token resolves to auto\n'

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' 0
marker="$tmpdir/command-ran"

assert_eq() {
    if [ "$1" != "$2" ]; then
        printf 'expected <%s>, got <%s>\n' "$2" "$1" >&2
        exit 1
    fi
}

assert_backend_status() {
    _expected=$3
    if reinstall_network_backend_supported_for_distro "$1" "$2"; then
        _actual=0
    else
        _actual=$?
    fi
    assert_eq "$_actual" "$_expected"
}

assert_profile_rejected() {
    _renderer=$1
    shift
    if "$_renderer" "$@" >"$tmpdir/rejected-profile"; then
        printf '%s accepted invalid profile data\n' "$_renderer" >&2
        exit 1
    fi
    [ ! -s "$tmpdir/rejected-profile" ]
}

assert_sysctl_profile_rejected() {
    if reinstall_network_render_sysctl_profile "$@" >"$tmpdir/rejected-sysctl"; then
        printf 'invalid sysctl profile data was accepted\n' >&2
        exit 1
    fi
    [ ! -s "$tmpdir/rejected-sysctl" ]
}

ip_mode=auto
dns_mode=auto
dns_servers=
network_backend=auto
reinstall_network_validate_cli_options
assert_eq "$ip_mode/$dns_mode/$dns_servers" auto/auto/
printf 'CHECKPOINT network/cli-defaults: ip-mode=%s dns-mode=%s dns-servers=empty\n' "$ip_mode" "$dns_mode"

for backend in auto systemd-networkd NetworkManager; do
    reinstall_network_set_cli_option --network-backend "$backend"
    reinstall_network_validate_cli_options
    assert_eq "$network_backend" "$backend"
done
printf 'CHECKPOINT network/backend-cli-values: accepted auto, systemd-networkd, and NetworkManager\n'

network_backend=auto
backend_cmdline=$(reinstall_cmdline_serialize extra_network_backend NetworkManager)
reinstall_cmdline_apply_token "$backend_cmdline" extra
assert_eq "$network_backend" NetworkManager
printf 'CHECKPOINT network/backend-cmdline: explicit backend survived base64 kernel command-line round trip\n'

network_backend=networkd
reinstall_network_set_cli_option --network-backend "$network_backend"
if reinstall_network_validate_cli_options; then
    printf 'accepted an invalid network backend\n' >&2
    exit 1
else
    assert_eq "$?" 6
fi
if reinstall_network_backend_supported_for_distro "$network_backend" alpine; then
    printf 'accepted an invalid network backend for Alpine\n' >&2
    exit 1
else
    assert_eq "$?" 2
fi
network_backend=auto
printf 'CHECKPOINT network/backend-invalid-value: CLI status=6; distro-policy status=2\n'

known_backend_distros='alpine debian kali ubuntu arch gentoo aosc fedora opensuse nixos anolis opencloudos centos almalinux rocky oracle openeuler redhat fnos'
networkd_supported_distros='debian kali ubuntu arch gentoo fedora nixos'
networkmanager_supported_distros='alpine debian kali ubuntu arch gentoo aosc fedora opensuse nixos anolis opencloudos centos almalinux rocky oracle openeuler redhat fnos'
for distro in $known_backend_distros; do
    case " $networkd_supported_distros " in
    *" $distro "*) expected_status=0 ;;
    *) expected_status=1 ;;
    esac
    assert_backend_status systemd-networkd "$distro" "$expected_status"

    case " $networkmanager_supported_distros " in
    *" $distro "*) expected_status=0 ;;
    *) expected_status=1 ;;
    esac
    assert_backend_status NetworkManager "$distro" "$expected_status"
    assert_backend_status auto "$distro" 0
done
assert_backend_status auto unknown-distro 0
assert_backend_status auto '' 0
assert_backend_status systemd-networkd unknown-distro 1
assert_backend_status NetworkManager unknown-distro 1
assert_backend_status systemd-networkd alpine 1
assert_backend_status NetworkManager aosc 0
assert_backend_status NetworkManager fnos 0
printf 'CHECKPOINT network/backend-distro-policy: networkd=7 supported; NetworkManager=19 supported; auto=all; unsupported and unknown targets rejected\n'

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

reinstall_network_render_dns_config resolv-conf '1.1.1.1,2606:4700:4700::1111' >"$tmpdir/resolv.conf"
cat >"$tmpdir/expected-resolv.conf" <<'EOF'
nameserver 1.1.1.1
nameserver 2606:4700:4700::1111
EOF
diff -u "$tmpdir/expected-resolv.conf" "$tmpdir/resolv.conf"
printf 'CHECKPOINT network/resolv-conf-render:\n'
sed 's/^/  | /' "$tmpdir/resolv.conf"

reinstall_network_render_dns_config alpine-dhcpcd '1.1.1.1,2606:4700:4700::1111' >"$tmpdir/alpine-dhcpcd"
cat >"$tmpdir/expected-alpine-dhcpcd" <<'EOF'
nohook resolv.conf
EOF
diff -u "$tmpdir/expected-alpine-dhcpcd" "$tmpdir/alpine-dhcpcd"
printf 'CHECKPOINT network/alpine-dhcpcd-render: DHCP and RA resolver writes disabled for a persisted DNS policy\n'

mkdir -p "$tmpdir/alpine/etc"
cat >"$tmpdir/alpine/etc/dhcpcd.conf" <<'EOF'
duid
persistent
option domain_name_servers, domain_name, domain_search, host_name
EOF
reinstall_network_write_alpine_dns_config \
    "$tmpdir/alpine/etc/dhcpcd.conf" \
    "$tmpdir/alpine/etc/resolv.conf" \
    '1.1.1.1,2606:4700:4700::1111'
cat >"$tmpdir/expected-dhcpcd.conf" <<'EOF'
nohook resolv.conf
duid
persistent
option domain_name_servers, domain_name, domain_search, host_name
EOF
diff -u "$tmpdir/expected-dhcpcd.conf" "$tmpdir/alpine/etc/dhcpcd.conf"
diff -u "$tmpdir/expected-resolv.conf" "$tmpdir/alpine/etc/resolv.conf"
reinstall_network_write_alpine_dns_config \
    "$tmpdir/alpine/etc/dhcpcd.conf" \
    "$tmpdir/alpine/etc/resolv.conf" \
    '1.1.1.1,2606:4700:4700::1111'
[ "$(grep -cx 'nohook resolv.conf' "$tmpdir/alpine/etc/dhcpcd.conf")" -eq 1 ]
if reinstall_network_write_alpine_dns_config \
    "$tmpdir/alpine/etc/dhcpcd.conf" \
    "$tmpdir/alpine/etc/resolv.conf" \
    '1.1.1.1;touch /tmp/owned'; then
    printf 'accepted shell syntax as persistent Alpine DNS configuration\n' >&2
    exit 1
fi
printf 'CHECKPOINT network/alpine-target-dns: resolver list persisted and dhcpcd hook disabled idempotently\n'

prepare_alpine_dns_fixture() {
    mkdir -p "$1"
    printf 'duid\npersistent\n' >"$1/dhcpcd.conf"
    printf 'nameserver 192.0.2.200\n' >"$1/resolv.conf"
}

prepare_alpine_dns_fixture "$tmpdir/alpine-policy-auto"
assert_eq "$(reinstall_network_apply_alpine_dns_policy auto false '8.8.8.8' \
    "$tmpdir/alpine-policy-auto/dhcpcd.conf" "$tmpdir/alpine-policy-auto/resolv.conf")" skipped
! grep -q '^nohook resolv.conf$' "$tmpdir/alpine-policy-auto/dhcpcd.conf"
assert_eq "$(cat "$tmpdir/alpine-policy-auto/resolv.conf")" 'nameserver 192.0.2.200'

prepare_alpine_dns_fixture "$tmpdir/alpine-policy-static-dns"
assert_eq "$(reinstall_network_apply_alpine_dns_policy static false "$explicit_dns" \
    "$tmpdir/alpine-policy-static-dns/dhcpcd.conf" "$tmpdir/alpine-policy-static-dns/resolv.conf")" persisted
diff -u "$tmpdir/expected-resolv.conf" "$tmpdir/alpine-policy-static-dns/resolv.conf"
grep -qx 'nohook resolv.conf' "$tmpdir/alpine-policy-static-dns/dhcpcd.conf"

prepare_alpine_dns_fixture "$tmpdir/alpine-policy-dhcp-dns"
assert_eq "$(reinstall_network_apply_alpine_dns_policy dhcp true \
    "$(printf '%s\n' 192.0.2.53 2001:db8::53)" \
    "$tmpdir/alpine-policy-dhcp-dns/dhcpcd.conf" "$tmpdir/alpine-policy-dhcp-dns/resolv.conf")" persisted
cat >"$tmpdir/expected-dhcp-resolv.conf" <<'EOF'
nameserver 192.0.2.53
nameserver 2001:db8::53
EOF
diff -u "$tmpdir/expected-dhcp-resolv.conf" "$tmpdir/alpine-policy-dhcp-dns/resolv.conf"

prepare_alpine_dns_fixture "$tmpdir/alpine-policy-dhcp-dynamic"
assert_eq "$(reinstall_network_apply_alpine_dns_policy dhcp false '192.0.2.53' \
    "$tmpdir/alpine-policy-dhcp-dynamic/dhcpcd.conf" "$tmpdir/alpine-policy-dhcp-dynamic/resolv.conf")" skipped
! grep -q '^nohook resolv.conf$' "$tmpdir/alpine-policy-dhcp-dynamic/dhcpcd.conf"
assert_eq "$(cat "$tmpdir/alpine-policy-dhcp-dynamic/resolv.conf")" 'nameserver 192.0.2.200'

if reinstall_network_apply_alpine_dns_policy static false '' \
    "$tmpdir/alpine-policy-dhcp-dynamic/dhcpcd.conf" "$tmpdir/alpine-policy-dhcp-dynamic/resolv.conf"; then
    printf 'accepted missing DNS for a persisted Alpine DNS policy\n' >&2
    exit 1
else
    [ "$?" -eq 2 ]
fi
printf 'CHECKPOINT network/alpine-policy-cases: auto=skip static-dns=write DHCP+static-IP=write DHCP+dynamic-IP=skip missing-required-DNS=error\n'

# NixOS NetworkManager profiles should match captured hardware by MAC where
# available. Interface-name remains the fallback for devices without a MAC.
awk '
    $0 == "create_nixos_networkmanager_config() {" { capture = 1 }
    capture { print }
    capture && $0 == "}" { exit }
' "$repo_root/trans.sh" >"$tmpdir/nixos-networkmanager-config-function"
if ! grep -Fq 'networking.usePredictableInterfaceNames = false;' \
    "$tmpdir/nixos-networkmanager-config-function"; then
    printf 'NixOS NetworkManager config does not preserve name fallback profiles\n' >&2
    exit 1
fi

. "$tmpdir/nixos-networkmanager-config-function"
get_eths() { printf 'eth7\n'; }
is_staticv4() { return 0; }
is_dhcpv4() { return 1; }
is_staticv6() { return 1; }
is_slaac() { return 1; }
is_dhcpv6() { return 1; }
get_netconf_to() {
    case "$1" in
    mac_addr) mac_addr=02:00:5e:10:00:08 ;;
    ipv4_addr) ipv4_addr=192.0.2.10/24 ;;
    ipv4_gateway) ipv4_gateway=192.0.2.1 ;;
    *) return 1 ;;
    esac
}
should_disable_accept_ra() { return 0; }
should_disable_autoconf() { return 0; }
quote_word() { sed -E 's/([^[:space:]]+)/"\1"/g'; }
ip_mode=static
dns_mode=static
dns_servers=1.1.1.1
create_nixos_networkmanager_config "$tmpdir/nixos-nm-generated.nix"
if grep -Fq 'interface-name = "eth7"' "$tmpdir/nixos-nm-generated.nix"; then
    printf 'NixOS NetworkManager profile still pins a captured interface name despite a MAC address\n' >&2
    exit 1
fi
if grep -Fq 'boot.kernel.sysctl."net.ipv6.conf.eth7.' "$tmpdir/nixos-nm-generated.nix"; then
    printf 'NixOS NetworkManager IPv6 sysctl still pins the captured interface name\n' >&2
    exit 1
fi
grep -Fq 'mac-address = "02:00:5e:10:00:08";' "$tmpdir/nixos-nm-generated.nix"
grep -Fq 'reinstall-networkmanager-ipv6-policy-eth7' "$tmpdir/nixos-nm-generated.nix"
grep -Fq '02:00:5e:10:00:08' "$tmpdir/nixos-nm-generated.nix"
{
    printf '{ pkgs, ... }: {\n'
    cat "$tmpdir/nixos-nm-generated.nix"
    printf '}\n'
} >"$tmpdir/nixos-nm-config.nix"
if command -v nix-instantiate >/dev/null 2>&1; then
    nix-instantiate --parse "$tmpdir/nixos-nm-config.nix" >/dev/null
    printf 'CHECKPOINT network/nixos-networkmanager: profile=MAC-matched sysctl=resolved-at-boot nix-parse=passed\n'
else
    printf 'CHECKPOINT network/nixos-networkmanager: profile=MAC-matched sysctl=resolved-at-boot nix-parse=unavailable\n'
fi
printf 'CHECKPOINT network/nixos-networkmanager-interface-names: MAC match preferred; interface-name fallback retained\n'

if ! command -v reinstall_network_render_nixos_networkd_profile >/dev/null 2>&1; then
    printf 'NixOS networkd profile adapter is missing\n' >&2
    exit 1
fi
nixos_networkd_profile=$(reinstall_network_render_networkd_profile \
    eth6 02:00:5e:10:00:07 disabled '' '' auto '' '' "$explicit_dns" true true)
reinstall_network_render_nixos_networkd_profile 0 "$nixos_networkd_profile" \
    >"$tmpdir/nixos-networkd-profile.nix"
cat >"$tmpdir/expected-nixos-networkd-profile.nix" <<'EOF'
environment.etc."systemd/network/10-reinstall-0.network".text = ''
[Match]
MACAddress=02:00:5e:10:00:07

[Network]
DHCP=no
LinkLocalAddressing=ipv6
IPv6AcceptRA=yes
DNS=1.1.1.1
DNS=2606:4700:4700::1111

[DHCP]
UseDNS=no

[DHCPv6]
UseDNS=no

[IPv6AcceptRA]
UseDNS=no
'';
EOF
diff -u "$tmpdir/expected-nixos-networkd-profile.nix" "$tmpdir/nixos-networkd-profile.nix"
if reinstall_network_render_nixos_networkd_profile 0 \
    '[Match]${builtins.abort "injected"}' >"$tmpdir/rejected-nixos-profile"; then
    printf 'accepted Nix interpolation in embedded networkd profile\n' >&2
    exit 1
fi
[ ! -s "$tmpdir/rejected-nixos-profile" ]
printf 'CHECKPOINT network/nixos-networkd-profile-validation: Nix interpolation rejected before output\n'

# Execute the real NixOS networkd branch with a stubbed profile source, keeping
# the test independent from chroots, package managers, and network interfaces.
awk '
    $0 == "create_nixos_network_config() {" { capture = 1 }
    capture && /^    # 头部/ { print "}"; exit }
    capture { print }
' "$repo_root/trans.sh" >"$tmpdir/nixos-network-config-function"
[ -s "$tmpdir/nixos-network-config-function" ]
. "$tmpdir/nixos-network-config-function"
create_network_backend_profiles() {
    _network_root=$1
    mkdir -p "$_network_root/etc/systemd/network"
    printf '%s\n' "$nixos_networkd_profile" \
        >"$_network_root/etc/systemd/network/10-reinstall-0.network"
}
network_backend=systemd-networkd
create_nixos_network_config "$tmpdir/nixos-networkd-generated.nix"
cat >"$tmpdir/expected-nixos-networkd-config.nix" <<'EOF'
networking.useNetworkd = true;
networking.useDHCP = false;
networking.dhcpcd.enable = false;
networking.usePredictableInterfaceNames = false;
systemd.network.enable = true;
services.resolved.enable = true;
EOF
cat "$tmpdir/nixos-networkd-profile.nix" >>"$tmpdir/expected-nixos-networkd-config.nix"
diff -u "$tmpdir/expected-nixos-networkd-config.nix" "$tmpdir/nixos-networkd-generated.nix"
{
    printf '{ pkgs, ... }: {\n'
    cat "$tmpdir/nixos-networkd-generated.nix"
    printf '}\n'
} >"$tmpdir/nixos-networkd-config.nix"
if command -v nix-instantiate >/dev/null 2>&1; then
    nix-instantiate --parse "$tmpdir/nixos-networkd-config.nix" >/dev/null
    printf 'CHECKPOINT network/nixos-networkd-config: nix-parse=passed profile=ipv6-only static-dns=auto-dns-disabled\n'
else
    printf 'CHECKPOINT network/nixos-networkd-config: profile=ipv6-only static-dns=auto-dns-disabled nix-parse=unavailable\n'
fi
printf 'CHECKPOINT network/nixos-networkd-integration: installer branch emits the shared renderer as a declarative profile\n'

# Run the production shared NetworkManager profile builder with captured
# static addressing, then verify it records the MAC-based sysctl policy that
# the first-boot NIC resolver consumes.
awk '
    $0 == "create_network_backend_profiles() {" { capture = 1 }
    capture { print }
    capture && $0 == "}" { exit }
' "$repo_root/trans.sh" >"$tmpdir/create-network-backend-profiles"
(
    . "$tmpdir/create-network-backend-profiles"
    get_eths() { printf 'eth4\n'; }
    is_staticv4() { return 0; }
    is_staticv6() { return 1; }
    is_dhcpv4() { return 1; }
    is_slaac() { return 1; }
    is_dhcpv6() { return 1; }
    should_disable_accept_ra() { return 0; }
    should_disable_autoconf() { return 0; }
    get_netconf_to() {
        case "$1" in
        mac_addr) mac_addr=02:00:5e:10:00:09 ;;
        ipv4_addr) ipv4_addr=192.0.2.10/24 ;;
        ipv4_gateway) ipv4_gateway=192.0.2.1 ;;
        *) return 1 ;;
        esac
    }
    error_and_exit() { printf '%s\n' "$*" >&2; exit 1; }
    network_backend=NetworkManager
    distro=debian
    ip_mode=static
    dns_mode=static
    dns_servers=1.1.1.1
    target_root="$tmpdir/trans-networkmanager-target"
    mkdir -p "$target_root/etc"
    create_network_backend_profiles "$target_root" >"$tmpdir/trans-networkmanager-output"
    printf 'mac 02:00:5e:10:00:09 false false\n' \
        >"$tmpdir/expected-trans-network-sysctl-map"
    diff -u "$tmpdir/expected-trans-network-sysctl-map" \
        "$target_root/etc/reinstall/network-sysctl-map"
    if grep -Fq 'interface-name=eth4' \
        "$target_root/etc/NetworkManager/system-connections/reinstall-0.nmconnection"; then
        printf 'production NetworkManager profile pins the captured interface name\n' >&2
        exit 1
    fi
    grep -Fq 'mac-address=02:00:5e:10:00:09' \
        "$target_root/etc/NetworkManager/system-connections/reinstall-0.nmconnection"
    [ ! -e "$target_root/etc/sysctl.d/90-reinstall-network.conf" ]
)
printf 'CHECKPOINT network/shared-profile-builder: static-NM-profile=MAC-matched IPv6-sysctl=first-boot-map\n'

prepare_debian_dns_fixture() {
    mkdir -p "$1/etc/dhcp"
    cat >"$1/etc/dhcpcd.conf" <<'EOF'
duid
persistent
option domain_name_servers, domain_name, domain_search
EOF
    cat >"$1/etc/dhcp/dhclient.conf" <<'EOF'
supersede domain-name-servers 192.0.2.10;
supersede dhcp6.name-servers 2001:db8::10;
request subnet-mask, routers, domain-name, domain-name-servers;
EOF
    printf 'nameserver 192.0.2.200\n' >"$1/etc/resolv.conf"
}

prepare_debian_dns_fixture "$tmpdir/debian-static-dns"
assert_eq "$(reinstall_network_apply_debian_dns_policy static false \
    "$(printf '%s\n' 1.1.1.1 2606:4700:4700::1111)" \
    "$tmpdir/debian-static-dns/etc/dhcpcd.conf" \
    "$tmpdir/debian-static-dns/etc/dhcp/dhclient.conf" \
    "$tmpdir/debian-static-dns/etc/resolv.conf")" persisted
cat >"$tmpdir/expected-debian-dhcpcd.conf" <<'EOF'
nohook resolv.conf
duid
persistent
option domain_name_servers, domain_name, domain_search
EOF
cat >"$tmpdir/expected-debian-dhclient.conf" <<'EOF'
supersede domain-name-servers 1.1.1.1;
supersede dhcp6.name-servers 2606:4700:4700::1111;
request subnet-mask, routers, domain-name, domain-name-servers;
EOF
diff -u "$tmpdir/expected-debian-dhcpcd.conf" "$tmpdir/debian-static-dns/etc/dhcpcd.conf"
diff -u "$tmpdir/expected-debian-dhclient.conf" "$tmpdir/debian-static-dns/etc/dhcp/dhclient.conf"
diff -u "$tmpdir/expected-resolv.conf" "$tmpdir/debian-static-dns/etc/resolv.conf"
reinstall_network_write_debian_dns_config \
    "$tmpdir/debian-static-dns/etc/dhcpcd.conf" \
    "$tmpdir/debian-static-dns/etc/dhcp/dhclient.conf" \
    "$tmpdir/debian-static-dns/etc/resolv.conf" \
    '1.1.1.1,2606:4700:4700::1111'
diff -u "$tmpdir/expected-debian-dhclient.conf" "$tmpdir/debian-static-dns/etc/dhcp/dhclient.conf"

prepare_debian_dns_fixture "$tmpdir/debian-static-ipv6-dns"
reinstall_network_write_debian_dns_config \
    "$tmpdir/debian-static-ipv6-dns/etc/dhcpcd.conf" \
    "$tmpdir/debian-static-ipv6-dns/etc/dhcp/dhclient.conf" \
    "$tmpdir/debian-static-ipv6-dns/etc/resolv.conf" \
    '2001:db8::53'
cat >"$tmpdir/expected-debian-ipv6-dhclient.conf" <<'EOF'
supersede dhcp6.name-servers 2001:db8::53;
request subnet-mask, routers, domain-name, domain-name-servers;
EOF
cat >"$tmpdir/expected-debian-ipv6-resolv.conf" <<'EOF'
nameserver 2001:db8::53
EOF
diff -u "$tmpdir/expected-debian-ipv6-dhclient.conf" \
    "$tmpdir/debian-static-ipv6-dns/etc/dhcp/dhclient.conf"
diff -u "$tmpdir/expected-debian-ipv6-resolv.conf" \
    "$tmpdir/debian-static-ipv6-dns/etc/resolv.conf"

prepare_debian_dns_fixture "$tmpdir/debian-dhcp-dns-static-ip"
assert_eq "$(reinstall_network_apply_debian_dns_policy dhcp true \
    "$(printf '%s\n' 192.0.2.53 2001:db8::53)" \
    "$tmpdir/debian-dhcp-dns-static-ip/etc/dhcpcd.conf" \
    "$tmpdir/debian-dhcp-dns-static-ip/etc/dhcp/dhclient.conf" \
    "$tmpdir/debian-dhcp-dns-static-ip/etc/resolv.conf")" persisted
cat >"$tmpdir/expected-debian-dhcp-resolv.conf" <<'EOF'
nameserver 192.0.2.53
nameserver 2001:db8::53
EOF
diff -u "$tmpdir/expected-debian-dhcp-resolv.conf" \
    "$tmpdir/debian-dhcp-dns-static-ip/etc/resolv.conf"

prepare_debian_dns_fixture "$tmpdir/debian-dhcp-dynamic"
assert_eq "$(reinstall_network_apply_debian_dns_policy dhcp false '192.0.2.53' \
    "$tmpdir/debian-dhcp-dynamic/etc/dhcpcd.conf" \
    "$tmpdir/debian-dhcp-dynamic/etc/dhcp/dhclient.conf" \
    "$tmpdir/debian-dhcp-dynamic/etc/resolv.conf")" skipped
assert_eq "$(cat "$tmpdir/debian-dhcp-dynamic/etc/resolv.conf")" 'nameserver 192.0.2.200'

if reinstall_network_apply_debian_dns_policy static false '' \
    "$tmpdir/debian-dhcp-dynamic/etc/dhcpcd.conf" \
    "$tmpdir/debian-dhcp-dynamic/etc/dhcp/dhclient.conf" \
    "$tmpdir/debian-dhcp-dynamic/etc/resolv.conf"; then
    printf 'accepted missing DNS for a persisted Debian DNS policy\n' >&2
    exit 1
else
    [ "$?" -eq 2 ]
fi
if reinstall_network_apply_debian_dns_policy static false "1.1.1.1;touch $marker" \
    "$tmpdir/debian-dhcp-dynamic/etc/dhcpcd.conf" \
    "$tmpdir/debian-dhcp-dynamic/etc/dhcp/dhclient.conf" \
    "$tmpdir/debian-dhcp-dynamic/etc/resolv.conf"; then
    printf 'accepted shell syntax for Debian DNS configuration\n' >&2
    exit 1
fi
[ ! -e "$marker" ]
grep -Fq 'reinstall_network_apply_debian_dns_policy' "$repo_root/debian.cfg"
grep -Fq 'extract_env_from_cmdline' "$repo_root/reinstall.sh"
grep -Fq 'cp /etc/network/interfaces /configs/network-interfaces' "$repo_root/reinstall.sh"
grep -Fq 'cp /configs/network-interfaces /target/etc/network/interfaces' "$repo_root/debian.cfg"
grep -Fq 'cp /configs/etc/reinstall/network-sysctl-map /target/etc/reinstall/' "$repo_root/debian.cfg"
awk '
    /^d-i preseed\/late_command string / {
        active = 1
        sub(/^d-i preseed\/late_command string /, "")
    }
    active {
        continued = ($0 ~ /\\$/)
        sub(/[[:space:]]*\\$/, "")
        printf "%s ", $0
        if (!continued) {
            print ""
            exit
        }
    }
' "$repo_root/debian.cfg" >"$tmpdir/debian-late-command.sh"
sh -n "$tmpdir/debian-late-command.sh"
printf 'CHECKPOINT network/debian-target-dns: DNS policy cases pass; initrd IP configuration reaches target; late_command parses\n'

modify_linux_basic_init_line=$(awk '
    /^modify_linux\(\)/ { in_modify_linux = 1 }
    in_modify_linux && /basic_init \$os_dir/ { print NR; exit }
' "$repo_root/trans.sh")
modify_linux_resolver_finalizer_line=$(awk '
    /^modify_linux\(\)/ { in_modify_linux = 1 }
    in_modify_linux && /finalize_network_backend_resolver "\$os_dir"/ { print NR; exit }
    in_modify_linux && /^}/ { exit }
' "$repo_root/trans.sh")
if [ -z "$modify_linux_basic_init_line" ] ||
    [ -z "$modify_linux_resolver_finalizer_line" ] ||
    [ "$modify_linux_resolver_finalizer_line" -le "$modify_linux_basic_init_line" ]; then
    printf 'modify_linux must finalize explicit resolver state after basic_init\n' >&2
    exit 1
fi
printf 'CHECKPOINT network/cloud-image-resolver-order: explicit resolver finalization follows target package and basic initialization\n'

mkdir -p "$tmpdir/resolver-networkd/etc" "$tmpdir/resolver-networkmanager/etc" "$tmpdir/resolver-auto/etc"
printf 'nameserver 192.0.2.53\n' >"$tmpdir/resolver-networkd/etc/resolv.conf"
printf 'nameserver 192.0.2.53\n' >"$tmpdir/resolver-networkd/etc/resolv.conf.orig"
reinstall_network_finalize_resolver "$tmpdir/resolver-networkd" systemd-networkd
[ "$(readlink "$tmpdir/resolver-networkd/etc/resolv.conf")" = ../run/systemd/resolve/stub-resolv.conf ]
[ ! -e "$tmpdir/resolver-networkd/etc/resolv.conf.orig" ]
printf 'nameserver 192.0.2.53\n' >"$tmpdir/resolver-networkmanager/etc/resolv.conf"
printf 'nameserver 192.0.2.53\n' >"$tmpdir/resolver-networkmanager/etc/resolv.conf.orig"
reinstall_network_finalize_resolver "$tmpdir/resolver-networkmanager" NetworkManager
[ ! -e "$tmpdir/resolver-networkmanager/etc/resolv.conf" ]
[ ! -e "$tmpdir/resolver-networkmanager/etc/resolv.conf.orig" ]
printf 'nameserver 192.0.2.53\n' >"$tmpdir/resolver-auto/etc/resolv.conf"
reinstall_network_finalize_resolver "$tmpdir/resolver-auto" auto
[ "$(cat "$tmpdir/resolver-auto/etc/resolv.conf")" = 'nameserver 192.0.2.53' ]
printf 'CHECKPOINT network/resolver-finalizer: networkd=stub-symlink NetworkManager=removed auto=preserved\n'

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

# The public profile renderers return complete, persistent manager profiles.
reinstall_network_render_networkd_profile \
    eth0 02:00:5e:10:00:01 auto '' '' auto '' '' '' true false \
    >"$tmpdir/networkd-dhcp"
cat >"$tmpdir/expected-networkd-dhcp" <<'EOF'
[Match]
MACAddress=02:00:5e:10:00:01

[Network]
DHCP=ipv4
LinkLocalAddressing=yes
IPv6AcceptRA=yes
EOF
diff -u "$tmpdir/expected-networkd-dhcp" "$tmpdir/networkd-dhcp"
if grep -Fq 'Name=eth0' "$tmpdir/networkd-dhcp"; then
    printf 'networkd profile still pins the pre-install NIC name despite a MAC address\n' >&2
    exit 1
fi
printf 'CHECKPOINT network/networkd-profile-dhcp:\n'
sed 's/^/  | /' "$tmpdir/networkd-dhcp"

reinstall_network_render_nm_profile \
    eth0 02:00:5e:10:00:01 auto '' '' auto '' '' '' true false \
    >"$tmpdir/nm-dhcp"
cat >"$tmpdir/expected-nm-dhcp" <<'EOF'
[connection]
id=reinstall-eth0
type=802-3-ethernet
autoconnect=true

[802-3-ethernet]
mac-address=02:00:5e:10:00:01

[ipv4]
method=auto

[ipv6]
method=auto
EOF
diff -u "$tmpdir/expected-nm-dhcp" "$tmpdir/nm-dhcp"
if grep -Fq 'interface-name=eth0' "$tmpdir/nm-dhcp"; then
    printf 'NetworkManager profile still pins the pre-install NIC name despite a MAC address\n' >&2
    exit 1
fi
printf 'CHECKPOINT network/networkmanager-profile-dhcp:\n'
sed 's/^/  | /' "$tmpdir/nm-dhcp"

reinstall_network_render_networkd_profile \
    eth9 '' auto '' '' auto '' '' '' true false >"$tmpdir/networkd-name-fallback"
cat >"$tmpdir/expected-networkd-name-fallback" <<'EOF'
[Match]
Name=eth9

[Network]
DHCP=ipv4
LinkLocalAddressing=yes
IPv6AcceptRA=yes
EOF
diff -u "$tmpdir/expected-networkd-name-fallback" "$tmpdir/networkd-name-fallback"
reinstall_network_render_nm_profile \
    eth9 '' auto '' '' auto '' '' '' true false >"$tmpdir/nm-name-fallback"
cat >"$tmpdir/expected-nm-name-fallback" <<'EOF'
[connection]
id=reinstall-eth9
type=802-3-ethernet
interface-name=eth9
autoconnect=true

[ipv4]
method=auto

[ipv6]
method=auto
EOF
diff -u "$tmpdir/expected-nm-name-fallback" "$tmpdir/nm-name-fallback"
printf 'CHECKPOINT network/profile-nic-identity: MAC-only profiles survive rename; interface-name fallback retained without MAC\n'

if reinstall_network_render_networkd_profile \
    eth0 02:00:5e:10:00:01 manual '' '' auto '' '' '' true false \
    >"$tmpdir/networkd-invalid-manual"; then
    printf 'accepted a manual IPv4 profile without an address\n' >&2
    exit 1
fi
[ ! -s "$tmpdir/networkd-invalid-manual" ]
printf 'CHECKPOINT network/profile-invalid-manual: manual address-less profile rejected before writing output\n'

reinstall_network_render_networkd_profile \
    eth1 02:00:5e:10:00:02 manual '192.0.2.10/32' 192.0.2.1 \
    manual '2001:db8:1::10/64,2001:db8:1::11/64' 2001:db8:2::1 \
    '192.0.2.53,2001:db8:53::53' false false >"$tmpdir/networkd-static"
cat >"$tmpdir/expected-networkd-static" <<'EOF'
[Match]
MACAddress=02:00:5e:10:00:02

[Network]
DHCP=no
LinkLocalAddressing=yes
IPv6AcceptRA=no
Address=192.0.2.10/32
Address=2001:db8:1::10/64
Address=2001:db8:1::11/64
DNS=192.0.2.53
DNS=2001:db8:53::53

[Route]
Gateway=192.0.2.1
GatewayOnLink=yes

[Route]
Gateway=2001:db8:2::1
GatewayOnLink=yes
EOF
diff -u "$tmpdir/expected-networkd-static" "$tmpdir/networkd-static"
printf 'CHECKPOINT network/networkd-profile-static:\n'
sed 's/^/  | /' "$tmpdir/networkd-static"

reinstall_network_render_networkd_profile \
    eth2 02:00:5e:10:00:03 auto '' '' dhcp '' '' \
    '192.0.2.53,2001:db8:53::53' true true >"$tmpdir/networkd-ignore-auto-dns"
cat >"$tmpdir/expected-networkd-ignore-auto-dns" <<'EOF'
[Match]
MACAddress=02:00:5e:10:00:03

[Network]
DHCP=yes
LinkLocalAddressing=yes
IPv6AcceptRA=yes
DNS=192.0.2.53
DNS=2001:db8:53::53

[DHCP]
UseDNS=no

[DHCPv4]
UseDNS=no

[DHCPv6]
UseDNS=no

[IPv6AcceptRA]
UseDNS=no
EOF
diff -u "$tmpdir/expected-networkd-ignore-auto-dns" "$tmpdir/networkd-ignore-auto-dns"
printf 'CHECKPOINT network/networkd-profile-ignore-auto-dns:\n'
sed 's/^/  | /' "$tmpdir/networkd-ignore-auto-dns"

reinstall_network_render_networkd_profile \
    eth5 02:00:5e:10:00:06 auto '' '' auto '' '' \
    '' true true >"$tmpdir/networkd-auto-ra-ignore-dns"
cat >"$tmpdir/expected-networkd-auto-ra-ignore-dns" <<'EOF'
[Match]
MACAddress=02:00:5e:10:00:06

[Network]
DHCP=ipv4
LinkLocalAddressing=yes
IPv6AcceptRA=yes

[DHCP]
UseDNS=no

[DHCPv4]
UseDNS=no

[DHCPv6]
UseDNS=no

[IPv6AcceptRA]
UseDNS=no
EOF
diff -u "$tmpdir/expected-networkd-auto-ra-ignore-dns" \
    "$tmpdir/networkd-auto-ra-ignore-dns"
printf 'CHECKPOINT network/networkd-profile-ra-triggered-dhcpv6-dns-suppression:\n'
sed 's/^/  | /' "$tmpdir/networkd-auto-ra-ignore-dns"

reinstall_network_render_nm_profile \
    eth1 02:00:5e:10:00:02 manual '192.0.2.10/24' 192.0.2.1 \
    manual '2001:db8:1::10/64,2001:db8:1::11/64' 2001:db8:1::1 \
    '192.0.2.53,2001:db8:53::53' false false >"$tmpdir/nm-static"
cat >"$tmpdir/expected-nm-static" <<'EOF'
[connection]
id=reinstall-eth1
type=802-3-ethernet
autoconnect=true

[802-3-ethernet]
mac-address=02:00:5e:10:00:02

[ipv4]
method=manual
address1=192.0.2.10/24
gateway=192.0.2.1
dns=192.0.2.53;

[ipv6]
method=manual
address1=2001:db8:1::10/64
address2=2001:db8:1::11/64
gateway=2001:db8:1::1
dns=2001:db8:53::53;
EOF
diff -u "$tmpdir/expected-nm-static" "$tmpdir/nm-static"
printf 'CHECKPOINT network/networkmanager-profile-static:\n'
sed 's/^/  | /' "$tmpdir/nm-static"

reinstall_network_render_nm_profile \
    eth2 02:00:5e:10:00:03 auto '' '' dhcp '' '' \
    '192.0.2.53,2001:db8:53::53' true true >"$tmpdir/nm-dynamic-ignore-auto-dns"
cat >"$tmpdir/expected-nm-dynamic-ignore-auto-dns" <<'EOF'
[connection]
id=reinstall-eth2
type=802-3-ethernet
autoconnect=true

[802-3-ethernet]
mac-address=02:00:5e:10:00:03

[ipv4]
method=auto
dns=192.0.2.53;
ignore-auto-dns=true

[ipv6]
method=auto
dns=2001:db8:53::53;
ignore-auto-dns=true
EOF
diff -u "$tmpdir/expected-nm-dynamic-ignore-auto-dns" "$tmpdir/nm-dynamic-ignore-auto-dns"
printf 'CHECKPOINT network/networkmanager-profile-ignore-auto-dns:\n'
sed 's/^/  | /' "$tmpdir/nm-dynamic-ignore-auto-dns"

if reinstall_network_render_networkd_profile \
    eth3 02:00:5e:10:00:04 auto '' '' disabled '' '' '' true false \
    >"$tmpdir/networkd-invalid-ra"; then
    printf 'accepted IPv6 RA with IPv6 disabled\n' >&2
    exit 1
fi
[ ! -s "$tmpdir/networkd-invalid-ra" ]
printf 'CHECKPOINT network/profile-invalid-ra: IPv6 disabled with RA rejected before writing output\n'

profile_injection_interface=$(printf 'eth0\n[Network]')
profile_injection_address=$(printf '192.0.2.10/24\nAddress=192.0.2.11/24')
profile_injection_mac=$(printf '02:00:5e:10:00:05\n[Match]')
assert_profile_rejected reinstall_network_render_networkd_profile \
    "$profile_injection_interface" 02:00:5e:10:00:05 auto '' '' auto '' '' '' true false
assert_profile_rejected reinstall_network_render_networkd_profile \
    eth4 02:00:5e:10:00:05 auto '' '' auto '' '' "$(printf '8.8.8.8\n1.1.1.1')" true false
assert_profile_rejected reinstall_network_render_nm_profile \
    eth4 02:00:5e:10:00:05 auto '' '' auto '' '' "$(printf '8.8.8.8\n1.1.1.1')" true false
assert_profile_rejected reinstall_network_render_nm_profile \
    eth4 "$profile_injection_mac" auto '' '' auto '' '' '' true false
assert_profile_rejected reinstall_network_render_networkd_profile \
    eth4 02:00:5e:10:00:05 manual "$profile_injection_address" '' auto '' '' '' true false
assert_profile_rejected reinstall_network_render_nm_profile \
    eth4 02:00:5e:10:00:05 auto '' '' auto '' '' "8.8.8.8;touch $marker" true false
assert_profile_rejected reinstall_network_render_networkd_profile \
    eth4 02:00:5e:10:00:05 manual '192.0.2.10/33' '' auto '' '' '' true false
assert_profile_rejected reinstall_network_render_nm_profile \
    eth4 02:00:5e:10:00:05 manual '192.0.2.10/24' 2001:db8::1 auto '' '' '' true false
assert_profile_rejected reinstall_network_render_networkd_profile \
    eth4 02:00:5e:10:00:05 automatic '' '' auto '' '' '' true false
assert_profile_rejected reinstall_network_render_nm_profile \
    eth4 02:00:5e:10:00:05
if reinstall_network_validate_dns_servers "$(printf '8.8.8.8\n1.1.1.1')"; then
    printf 'accepted a newline-separated DNS list as comma-separated input\n' >&2
    exit 1
fi
[ ! -e "$marker" ]
printf 'CHECKPOINT network/profile-input-validation: rejected config-line injection, invalid MAC/IP/gateway/method, and incomplete args; sentinel=absent\n'

reinstall_network_render_sysctl_profile enp1s0 false false >"$tmpdir/nm-sysctl"
cat >"$tmpdir/expected-nm-sysctl" <<'EOF'
net.ipv6.conf.enp1s0.accept_ra=0
net.ipv6.conf.enp1s0.autoconf=0
EOF
diff -u "$tmpdir/expected-nm-sysctl" "$tmpdir/nm-sysctl"
reinstall_network_render_sysctl_profile enp1s0 false true >"$tmpdir/nm-sysctl-ra"
printf 'net.ipv6.conf.enp1s0.accept_ra=0\n' >"$tmpdir/expected-nm-sysctl-ra"
diff -u "$tmpdir/expected-nm-sysctl-ra" "$tmpdir/nm-sysctl-ra"
reinstall_network_render_sysctl_profile enp1s0 true false >"$tmpdir/nm-sysctl-autoconf"
printf 'net.ipv6.conf.enp1s0.autoconf=0\n' >"$tmpdir/expected-nm-sysctl-autoconf"
diff -u "$tmpdir/expected-nm-sysctl-autoconf" "$tmpdir/nm-sysctl-autoconf"
if ! reinstall_network_render_sysctl_profile enp1s0 true true >"$tmpdir/nm-sysctl-noop"; then
    printf 'valid no-op sysctl profile returned failure\n' >&2
    exit 1
fi
[ ! -s "$tmpdir/nm-sysctl-noop" ]
assert_sysctl_profile_rejected '' false false
assert_sysctl_profile_rejected enp1s0 yes false
assert_sysctl_profile_rejected enp1s0 false no

reinstall_network_render_nm_sysctl_map eth0 02:00:5e:10:00:01 false true \
    >"$tmpdir/nm-sysctl-map"
printf 'mac 02:00:5e:10:00:01 false true\n' >"$tmpdir/expected-nm-sysctl-map"
diff -u "$tmpdir/expected-nm-sysctl-map" "$tmpdir/nm-sysctl-map"
reinstall_network_render_nm_sysctl_map eth9 '' true false \
    >"$tmpdir/nm-sysctl-name-map"
printf 'name eth9 true false\n' >"$tmpdir/expected-nm-sysctl-name-map"
diff -u "$tmpdir/expected-nm-sysctl-name-map" "$tmpdir/nm-sysctl-name-map"
if reinstall_network_render_nm_sysctl_map eth0 '02:00:5e:10:00:01\nnet' false true \
    >"$tmpdir/rejected-nm-sysctl-map"; then
    printf 'accepted injected MAC in NetworkManager sysctl mapping\n' >&2
    exit 1
fi
[ ! -s "$tmpdir/rejected-nm-sysctl-map" ]
printf 'CHECKPOINT network/nm-sysctl-render: static fallback and MAC-mapped dynamic policy validate; injection rejected\n'

printf 'PASS network option and target DNS policy tests\n'
