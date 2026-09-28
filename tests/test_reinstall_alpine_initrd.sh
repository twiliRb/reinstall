#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo_root/lib/reinstall-alpine-initrd.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

mkdir -p \
    "$tmpdir/sys/class/tty/tty0" \
    "$tmpdir/sys/class/tty/tty1"
printf 'tty1 ttyS0\n' >"$tmpdir/sys/class/tty/tty0/active"
printf 'tty2\ntty4\n' >"$tmpdir/sys/class/tty/tty1/active"

replacement=$(reinstall_alpine_active_tty_reader_replacement)
{
    cat <<'EOF'
#!/bin/sh
set -eu
ROOT=$1
list_console_devices() {
    if ! [ -e "$ROOT"/sys/class/tty/"$1"/active ]; then
        echo "$1"
        return
    fi

    while read -r dev; do
        list_console_devices "$dev"
EOF
    printf '%s\n' "$replacement"
    cat <<'EOF'
}
list_console_devices tty0
EOF
} >"$tmpdir/run-init-snippet.sh"

busybox ash "$tmpdir/run-init-snippet.sh" "$tmpdir" >"$tmpdir/actual"
printf 'tty2\ntty4\nttyS0\n' >"$tmpdir/expected"
if ! diff -u "$tmpdir/expected" "$tmpdir/actual"; then
    echo "Alpine init console reader did not resolve active TTYs." >&2
    exit 1
fi

printf 'CHECKPOINT alpine-initrd/ash: active-consoles=%s\n' \
    "$(tr '\n' ',' <"$tmpdir/actual" | sed 's/,$//')"
echo "PASS Alpine BusyBox ash console-reader contract"
