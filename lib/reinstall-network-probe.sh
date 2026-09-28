# shellcheck shell=sh
# Sourceable connectivity probes used by initrd-network.sh and the contract
# tests. DNS resolvers are deliberately not connectivity probe destinations:
# Internet availability is determined by testing the download path on TCP 443.

reinstall_network_fallback_dns_server() {
    case "$1:$2:$3" in
        4:1:true) printf '%s' '223.5.5.5' ;;
        4:2:true) printf '%s' '119.29.29.29' ;;
        6:1:true) printf '%s' '2400:3200::1' ;;
        6:2:true) printf '%s' '2402:4e00::' ;;
        4:1:false) printf '%s' '1.1.1.1' ;;
        4:2:false) printf '%s' '8.8.8.8' ;;
        6:1:false) printf '%s' '2606:4700:4700::1111' ;;
        6:2:false) printf '%s' '2001:4860:4860::8888' ;;
        *) return 2 ;;
    esac
}

reinstall_network_internet_probe_servers() {
    local family=$1 in_china=$2
    case "$family:$in_china" in
        4:true) printf '%s %s' '223.5.5.5' '119.29.29.29' ;;
        4:false) printf '%s %s' '1.1.1.1' '8.8.8.8' ;;
        6:true) printf '%s %s' '2400:3200::1' '2402:4e00::' ;;
        6:false) printf '%s %s' '2606:4700:4700::1111' '2001:4860:4860::8888' ;;
        *) return 2 ;;
    esac
}

test_by_wget() {
    local src=$1 dst=$2 url

    # IPv6 URLs need brackets.
    case "$dst" in
        *:*) url="https://[$dst]" ;;
        *) url="https://$dst" ;;
    esac

    # TCP 443 reachability is enough; the HTTP response itself may be 404.
    wget -T "$TEST_TIMEOUT" \
        --bind-address="$src" \
        --no-check-certificate \
        --max-redirect 0 \
        --tries 1 \
        -O /dev/null \
        "$url" 2>&1 | grep -iq -m1 connected
}

test_by_nc() {
    local src=$1 dst=$2
    nc -z -v \
        -w "$TEST_TIMEOUT" \
        -s "$src" \
        "$dst" 443
}

test_connect() {
    if is_debian_kali; then
        test_by_wget "$1" "$2"
    else
        test_by_nc "$1" "$2"
    fi
}

test_against_probe_servers() {
    local source_addr=$1 servers=$2 server
    for server in $servers; do
        if test_connect "$source_addr" "$server"; then
            return 0
        fi
    done
    return 1
}

test_internet() {
    local probe_servers
    for i in $(seq 5); do
        echo "Testing Internet Connection. Test $i... "
        if is_need_test_ipv4 &&
            current_ipv4_addr="$(get_first_ipv4_addr | remove_netmask)" &&
            probe_servers=$(reinstall_network_internet_probe_servers 4 "$is_in_china") &&
            test_against_probe_servers "$current_ipv4_addr" "$probe_servers" >/dev/null 2>&1; then
            echo "IPv4 has internet."
            ipv4_has_internet=true
        fi
        if is_need_test_ipv6 &&
            current_ipv6_addr="$(get_first_ipv6_addr | remove_netmask)" &&
            probe_servers=$(reinstall_network_internet_probe_servers 6 "$is_in_china") &&
            test_against_probe_servers "$current_ipv6_addr" "$probe_servers" >/dev/null 2>&1; then
            echo "IPv6 has internet."
            ipv6_has_internet=true
        fi
        if ! is_need_test_ipv4 && ! is_need_test_ipv6; then
            break
        fi
        sleep 1
    done
}
