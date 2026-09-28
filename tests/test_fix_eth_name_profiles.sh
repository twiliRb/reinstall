#!/bin/sh
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' 0

awk '
    $0 == "fix_network_manager() {" { capture = 1 }
    capture { print }
    capture && /^}/ { exit }
' "$repo_root/fix-eth-name.sh" >"$tmpdir/fix-network-manager.sh"
[ -s "$tmpdir/fix-network-manager.sh" ]
. "$tmpdir/fix-network-manager.sh"

get_ethx_by_mac() {
    case "${2:-}" in
    slave) printf 'ens8\n' ;;
    *) printf 'ens3\n' ;;
    esac
}

connections="$tmpdir/target/etc/NetworkManager/system-connections"
mkdir -p "$connections" "$tmpdir/target/etc/reinstall" \
    "$tmpdir/target/proc/sys/net/ipv6/conf/ens3" \
    "$tmpdir/target/proc/sys/net/ipv6/conf/eth9"
cat >"$connections/reinstall-0.nmconnection" <<'EOF'
[connection]
id=reinstall-eth0
type=802-3-ethernet
autoconnect=true

[802-3-ethernet]
mac-address=02:00:5e:10:00:01
EOF
printf 'mac 02:00:5e:10:00:01 false false\nname eth9 false true\n' \
    >"$tmpdir/target/etc/reinstall/network-sysctl-map"
cat >"$connections/cloud-init-eth0.nmconnection" <<'EOF'
[connection]
id=cloud-init-eth0
type=802-3-ethernet
autoconnect=true

[802-3-ethernet]
mac-address=02:00:5e:10:00:01
EOF

fix_network_manager "$tmpdir/target"

[ -f "$connections/reinstall-0.nmconnection" ]
[ ! -f "$connections/cloud-init-eth0.nmconnection" ]
grep -Fqx 'id=ens3' "$connections/ens3.nmconnection"

cat >"$tmpdir/expected-unmanaged.conf" <<'EOF'
[device-ens8-unmanaged]
match-device=interface-name:ens8
managed=0
EOF
diff -u "$tmpdir/expected-unmanaged.conf" \
    "$tmpdir/target/etc/NetworkManager/conf.d/99-ens8-unmanaged.conf"
cat >"$tmpdir/expected-resolved-sysctl.conf" <<'EOF'
net.ipv6.conf.ens3.accept_ra=0
net.ipv6.conf.ens3.autoconf=0
net.ipv6.conf.eth9.accept_ra=0
EOF
diff -u "$tmpdir/expected-resolved-sysctl.conf" \
    "$tmpdir/target/etc/sysctl.d/90-reinstall-network.conf"
[ "$(cat "$tmpdir/target/proc/sys/net/ipv6/conf/ens3/accept_ra")" = 0 ]
[ "$(cat "$tmpdir/target/proc/sys/net/ipv6/conf/ens3/autoconf")" = 0 ]
[ "$(cat "$tmpdir/target/proc/sys/net/ipv6/conf/eth9/accept_ra")" = 0 ]
[ ! -e "$tmpdir/target/proc/sys/net/ipv6/conf/eth9/autoconf" ]
[ ! -e "$tmpdir/target/etc/reinstall/network-sysctl-map" ]

alpine_root="$tmpdir/alpine"
mkdir -p "$alpine_root/etc/NetworkManager/system-connections" \
    "$alpine_root/etc/reinstall" \
    "$alpine_root/proc/sys/net/ipv6/conf/ens3"
cat >"$alpine_root/etc/sysctl.conf" <<'EOF'
kernel.domainname=example.test
# BEGIN reinstall network policy
net.ipv6.conf.eth0.autoconf=1
# END reinstall network policy
EOF
printf 'mac 02:00:5e:10:00:01 false true\n' \
    >"$alpine_root/etc/reinstall/network-sysctl-map"
fix_network_manager "$alpine_root"
cat >"$tmpdir/expected-alpine-sysctl.conf" <<'EOF'
kernel.domainname=example.test

# BEGIN reinstall network policy
net.ipv6.conf.ens3.accept_ra=0
# END reinstall network policy
EOF
diff -u "$tmpdir/expected-alpine-sysctl.conf" "$alpine_root/etc/sysctl.conf"
[ "$(cat "$alpine_root/proc/sys/net/ipv6/conf/ens3/accept_ra")" = 0 ]
cp "$alpine_root/etc/sysctl.conf" "$tmpdir/alpine-sysctl-first-run"
fix_network_manager "$alpine_root"
diff -u "$tmpdir/alpine-sysctl-first-run" "$alpine_root/etc/sysctl.conf"
printf 'CHECKPOINT networkmanager-first-boot: generated-MAC-profile=preserved cloud-init-profile=renamed azure-slave=unmanaged sysctl-remapped-by-MAC=true sysctl-persistence=Debian-and-Alpine\n'
