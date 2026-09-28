#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo_root/lib/reinstall-btrfs-layout.sh"

assert_plan() {
    _actual=$1
    _expected=$2
    if [ "$_actual" != "$_expected" ]; then
        printf 'unexpected ext4 layout plan\nexpected:\n%s\nactual:\n%s\n' \
            "$_expected" "$_actual" >&2
        exit 1
    fi
}

efi_plan=$(reinstall_ext4_layout_plan efi 53687091200)
assert_plan "$efi_plan" "$(printf 'table\tgpt\npartition\t1\tesp\tvfat\t1MiB\t101MiB\tboot\npartition\t2\troot\text4\t101MiB\t100%%\t-')"
printf 'CHECKPOINT ext4-layout/efi: table=gpt esp=1 root=2 root-fs=ext4\n'

bios_2t_plan=$(reinstall_ext4_layout_plan bios 2199023255552)
assert_plan "$bios_2t_plan" "$(printf 'table\tmsdos\npartition\t1\troot\text4\t1MiB\t100%%\tboot')"
printf 'CHECKPOINT ext4-layout/bios-at-2tib: table=msdos root=1\n'

bios_large_plan=$(reinstall_ext4_layout_plan bios 2199023255553)
assert_plan "$bios_large_plan" "$(printf 'table\tgpt\npartition\t1\tbios_grub\tnone\t1MiB\t2MiB\tbios_grub\npartition\t2\troot\text4\t2MiB\t100%%\t-')"
printf 'CHECKPOINT ext4-layout/bios-above-2tib: table=gpt bios-grub=1 root=2\n'

for invalid_mode in uefi '' EFI; do
    if reinstall_ext4_layout_plan "$invalid_mode" 10737418240 >/dev/null 2>&1; then
        printf 'accepted invalid firmware mode: <%s>\n' "$invalid_mode" >&2
        exit 1
    fi
done
for invalid_size in 0 -1 1.5 12GiB ''; do
    if reinstall_ext4_layout_plan bios "$invalid_size" >/dev/null 2>&1; then
        printf 'accepted invalid disk size: <%s>\n' "$invalid_size" >&2
        exit 1
    fi
done
if reinstall_ext4_layout_plan bios 1024 extra >/dev/null 2>&1; then
    printf 'accepted extra layout arguments\n' >&2
    exit 1
fi
printf 'CHECKPOINT ext4-layout/input-validation: invalid mode, size and argument count rejected\n'

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/reinstall-ext4-layout-test.XXXXXX")
trap 'rm -rf "$tmpdir"' 0
mkdir -p "$tmpdir/bin"
cat >"$tmpdir/bin/parted" <<'EOF'
#!/bin/sh
printf 'parted|%s\n' "$*" >>"$COMMAND_LOG"
EOF
cat >"$tmpdir/bin/mkfs.fat" <<'EOF'
#!/bin/sh
printf 'mkfs.fat|%s\n' "$*" >>"$COMMAND_LOG"
EOF
cat >"$tmpdir/bin/mkfs.ext4" <<'EOF'
#!/bin/sh
printf 'mkfs.ext4|%s\n' "$*" >>"$COMMAND_LOG"
EOF
chmod +x "$tmpdir/bin/parted" "$tmpdir/bin/mkfs.fat" "$tmpdir/bin/mkfs.ext4"
export PATH="$tmpdir/bin:$PATH"
COMMAND_LOG=$tmpdir/commands
export COMMAND_LOG
update_part() {
    if [ "${REFRESH_FAILURE:-}" = partx ]; then
        reinstall_refresh_partitions /dev/sda
    else
        printf 'update_part|re-read-partition-table\n' >>"$COMMAND_LOG"
    fi
}
sleep() { printf 'sleep|%s\n' "$*" >>"$COMMAND_LOG"; }
sync() { printf 'sync\n' >>"$COMMAND_LOG"; }
partprobe() { printf 'partprobe|%s\n' "$*" >>"$COMMAND_LOG"; }
partx() {
    printf 'partx|%s\n' "$*" >>"$COMMAND_LOG"
    [ "${REFRESH_FAILURE:-}" != partx ]
}
ensure_service_stopped() { printf 'stop-service|%s\n' "$*" >>"$COMMAND_LOG"; }
retry() { printf 'retry|%s\n' "$*" >>"$COMMAND_LOG"; }
mdev() { printf 'mdev|%s\n' "$*" >>"$COMMAND_LOG"; }
ensure_service_started() { printf 'start-service|%s\n' "$*" >>"$COMMAND_LOG"; }

reinstall_ext4_create_partitions /dev/nvme0n1 efi 53687091200 arch update_part
expected_commands=$(printf '%s\n' \
    'parted|/dev/nvme0n1 -s -- mklabel gpt' \
    'parted|/dev/nvme0n1 -s -- mkpart " " fat32 1MiB 101MiB' \
    'parted|/dev/nvme0n1 -s -- set 1 boot on' \
    'parted|/dev/nvme0n1 -s -- mkpart " " ext4 101MiB 100%' \
    'update_part|re-read-partition-table' \
    'mkfs.fat|/dev/nvme0n1p1' \
    'mkfs.ext4|-F /dev/nvme0n1p2')
actual_commands=$(cat "$COMMAND_LOG")
[ "$actual_commands" = "$expected_commands" ] || {
    printf 'unexpected ext4 partition application\nexpected:\n%s\nactual:\n%s\n' \
        "$expected_commands" "$actual_commands" >&2
    exit 1
}
printf 'CHECKPOINT ext4-layout/apply-efi: parted=planned-order esp=/dev/nvme0n1p1 root=/dev/nvme0n1p2 formatted=true\n'

: >"$COMMAND_LOG"
reinstall_ext4_create_partitions /dev/sda bios 2199023255552 alpine update_part
expected_commands=$(printf '%s\n' \
    'parted|/dev/sda -s -- mklabel msdos' \
    'parted|/dev/sda -s -- mkpart primary ext4 1MiB 100%' \
    'parted|/dev/sda -s -- set 1 boot on' \
    'update_part|re-read-partition-table' \
    'mkfs.ext4|-F -O ^64bit /dev/sda1')
actual_commands=$(cat "$COMMAND_LOG")
[ "$actual_commands" = "$expected_commands" ] || {
    printf 'unexpected BIOS ext4 partition application\nexpected:\n%s\nactual:\n%s\n' \
        "$expected_commands" "$actual_commands" >&2
    exit 1
}
printf 'CHECKPOINT ext4-layout/apply-bios: at-2tib=msdos partition=1 alpine-64bit=disabled\n'

: >"$COMMAND_LOG"
reinstall_ext4_create_partitions /dev/sda bios 2199023255553 arch update_part
expected_commands=$(printf '%s\n' \
    'parted|/dev/sda -s -- mklabel gpt' \
    'parted|/dev/sda -s -- mkpart " " 1MiB 2MiB' \
    'parted|/dev/sda -s -- set 1 bios_grub on' \
    'parted|/dev/sda -s -- mkpart " " ext4 2MiB 100%' \
    'update_part|re-read-partition-table' \
    'mkfs.ext4|-F /dev/sda2')
actual_commands=$(cat "$COMMAND_LOG")
[ "$actual_commands" = "$expected_commands" ] || {
    printf 'unexpected large BIOS ext4 partition application\nexpected:\n%s\nactual:\n%s\n' \
        "$expected_commands" "$actual_commands" >&2
    exit 1
}
printf 'CHECKPOINT ext4-layout/apply-large-bios: above-2tib=gpt bios-grub=1 root=2\n'

: >"$COMMAND_LOG"
REFRESH_FAILURE=partx
export REFRESH_FAILURE
if reinstall_ext4_create_partitions /dev/sda bios 1073741824 arch update_part; then
    printf 'formatted ext4 partitions after partition refresh failed\n' >&2
    exit 1
fi
if grep -Eq '^mkfs[.]' "$COMMAND_LOG"; then
    printf 'ran mkfs after partition refresh failed\n' >&2
    cat "$COMMAND_LOG" >&2
    exit 1
fi
grep -Fq 'partx|-u /dev/sda' "$COMMAND_LOG" || {
    printf 'partition refresh failure was not observed\n' >&2
    cat "$COMMAND_LOG" >&2
    exit 1
}
if grep -Fq 'mdev|' "$COMMAND_LOG"; then
    printf 'continued refresh after partx failed\n' >&2
    cat "$COMMAND_LOG" >&2
    exit 1
fi
printf 'CHECKPOINT ext4-layout/refresh-failure: partx-error=propagated mkfs=not-run later-steps=not-run\n'
