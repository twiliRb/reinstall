#!/bin/sh
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
. "$repo_root/lib/reinstall-network-probe.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' 0
calls="$tmpdir/tcp-calls"
TEST_TIMEOUT=1
qemu_dns_ipv4=10.0.2.3
qemu_dns_ipv6=fd00::3
runtime_dns_servers="$qemu_dns_ipv4,$qemu_dns_ipv6"
dns_mode=dhcp
is_in_china=false
use_wget=false

fail() {
    printf 'FAIL network probe: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    if [ "$1" != "$2" ]; then
        printf 'expected <%s>, got <%s>\n' "$2" "$1" >&2
        exit 1
    fi
}

line_exists() {
    expected=$1
    file=$2
    while IFS= read -r line; do
        [ "$line" = "$expected" ] && return 0
    done <"$file"
    return 1
}

is_debian_kali() { [ "$use_wget" = true ]; }
is_need_test_ipv4() { [ "$ipv4_has_internet" = false ]; }
is_need_test_ipv6() { [ "$ipv6_has_internet" = false ]; }
get_first_ipv4_addr() { printf '10.0.2.15/24\n'; }
get_first_ipv6_addr() { printf 'fd00::15/64\n'; }
remove_netmask() { sed 's#/.*##'; }
sleep() { :; }
seq() { printf '1\n2\n3\n4\n5\n'; }

public_443_available=true
nc() {
    previous=
    destination=
    port=
    for argument do
        if [ -n "$previous" ]; then
            destination=$previous
            port=$argument
        fi
        previous=$argument
    done
    printf '%s:%s\n' "$destination" "$port" >>"$calls"
    case "$destination:$port" in
        "$qemu_dns_ipv4:53"|"$qemu_dns_ipv6:53") return 0 ;;
        "$qemu_dns_ipv4:443"|"$qemu_dns_ipv6:443") return 1 ;;
        1.1.1.1:443|8.8.8.8:443|2606:4700:4700::1111:443|2001:4860:4860::8888:443)
            [ "$public_443_available" = true ] ;;
        *) return 1 ;;
    esac
}
wget() {
    printf '%s\n' "$@" >"$tmpdir/wget-args"
    printf 'Connected to mocked TCP/443 endpoint\n'
}

# Model the reported QEMU condition: its DNS resolver answers on port 53 but
# does not expose HTTPS. The Internet check must use its independent TCP probes.
nc -z -v -w 1 "$qemu_dns_ipv4" 53 || fail 'QEMU DNS fixture did not answer on port 53'
: >"$calls"
ipv4_has_internet=false
ipv6_has_internet=false
test_internet >"$tmpdir/probe-success.log"
assert_eq "$ipv4_has_internet" true
if line_exists "$qemu_dns_ipv4:443" "$calls" || line_exists "$qemu_dns_ipv6:443" "$calls"; then
    fail 'a configured DNS resolver was probed as an Internet HTTPS endpoint'
fi
if ! line_exists '1.1.1.1:443' "$calls"; then
    fail 'the fixed public IPv4 TCP/443 probe was not attempted'
fi
printf 'CHECKPOINT network-probe/qemu-dns-53-only: resolver=%s:53 reachable; internet=true from fixed TCP/443 probe; resolver was not probed on 443\n' "$qemu_dns_ipv4"

# A DNS response alone is not treated as proof that HTTPS downloads can work.
public_443_available=false
: >"$calls"
ipv4_has_internet=false
ipv6_has_internet=false
test_internet >"$tmpdir/probe-failure.log"
assert_eq "$ipv4_has_internet" false
if line_exists "$qemu_dns_ipv4:443" "$calls" || line_exists "$qemu_dns_ipv6:443" "$calls"; then
    fail 'a configured DNS resolver was probed as an Internet HTTPS endpoint'
fi
if ! line_exists '8.8.8.8:443' "$calls"; then
    fail 'the secondary fixed public IPv4 TCP/443 probe was not attempted'
fi
printf 'CHECKPOINT network-probe/dns-is-not-https: resolver=%s:53 reachable; fixed TCP/443 probes failed; internet=false\n' "$qemu_dns_ipv4"

# The IPv6 path must use its own fixed TCP/443 probes and retain both success
# and failure behavior, independent of an acquired IPv6 RDNSS address.
public_443_available=true
: >"$calls"
ipv4_has_internet=true
ipv6_has_internet=false
test_internet >"$tmpdir/probe-ipv6-success.log"
assert_eq "$ipv6_has_internet" true
if line_exists "$qemu_dns_ipv6:443" "$calls"; then
    fail 'the acquired IPv6 RDNSS resolver was probed on TCP/443'
fi
if ! line_exists '2606:4700:4700::1111:443' "$calls"; then
    fail 'the fixed public IPv6 TCP/443 probe was not attempted'
fi
printf 'CHECKPOINT network-probe/ipv6-success: RDNSS=%s was excluded; fixed IPv6 TCP/443 probe succeeded\n' "$qemu_dns_ipv6"

public_443_available=false
: >"$calls"
ipv4_has_internet=true
ipv6_has_internet=false
test_internet >"$tmpdir/probe-ipv6-failure.log"
assert_eq "$ipv6_has_internet" false
if ! line_exists '2001:4860:4860::8888:443' "$calls"; then
    fail 'the secondary fixed public IPv6 TCP/443 probe was not attempted'
fi
printf 'CHECKPOINT network-probe/ipv6-failure: RDNSS=%s:53 did not imply working TCP/443\n' "$qemu_dns_ipv6"

# Debian initrds use wget rather than nc. Preserve the IPv6 URL bracket syntax
# and source-address binding in the extracted transport helper.
use_wget=true
test_connect '192.0.2.44' '2001:db8::53' || fail 'mocked wget probe failed'
use_wget=false
if ! line_exists '--bind-address=192.0.2.44' "$tmpdir/wget-args" ||
    ! line_exists 'https://[2001:db8::53]' "$tmpdir/wget-args"; then
    fail 'Debian wget probe did not bind the source or bracket its IPv6 URL'
fi
printf 'CHECKPOINT network-probe/debian-wget: source address bound; IPv6 HTTPS URL bracketed\n'

assert_eq "$(reinstall_network_internet_probe_servers 4 false)" '1.1.1.1 8.8.8.8'
assert_eq "$(reinstall_network_internet_probe_servers 4 true)" '223.5.5.5 119.29.29.29'
assert_eq "$(reinstall_network_internet_probe_servers 6 false)" '2606:4700:4700::1111 2001:4860:4860::8888'
assert_eq "$(reinstall_network_internet_probe_servers 6 true)" '2400:3200::1 2402:4e00::'
printf 'CHECKPOINT network-probe/region-targets: IPv4/IPv6 fixed probe endpoints selected independently of runtime DNS=%s\n' "$runtime_dns_servers"
assert_eq "$(reinstall_network_fallback_dns_server 4 1 false)" '1.1.1.1'
assert_eq "$(reinstall_network_fallback_dns_server 4 2 false)" '8.8.8.8'
assert_eq "$(reinstall_network_fallback_dns_server 6 1 false)" '2606:4700:4700::1111'
assert_eq "$(reinstall_network_fallback_dns_server 6 2 false)" '2001:4860:4860::8888'
assert_eq "$(reinstall_network_fallback_dns_server 4 1 true)" '223.5.5.5'
assert_eq "$(reinstall_network_fallback_dns_server 4 2 true)" '119.29.29.29'
assert_eq "$(reinstall_network_fallback_dns_server 6 1 true)" '2400:3200::1'
assert_eq "$(reinstall_network_fallback_dns_server 6 2 true)" '2402:4e00::'
printf 'CHECKPOINT network-probe/dns-fallback: default IPv4/IPv6 resolvers remain available when DHCP/RA DNS is absent\n'
printf 'PASS initrd network connectivity probe isolation tests\n'
