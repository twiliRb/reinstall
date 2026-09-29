#!/usr/bin/env bash
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo_root/lib/reinstall-btrfs-layout.sh"

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/reinstall-debian-btrfs.XXXXXX")
trap 'rm -rf "$tmp_root"' EXIT HUP INT TERM

recipe=$(reinstall_btrfs_debian_partman_recipe efi)
[ "$recipe" = 'btrfs-efi :: 106 1 106 free $iflabel{ gpt } method{ efi } format{ } . 1 1 -1 btrfs method{ format } format{ } use_filesystem{ } filesystem{ btrfs } mountpoint{ / } .' ]
recipe=$(reinstall_btrfs_debian_partman_recipe bios)
[ "$recipe" = 'btrfs-bios :: 1 1 1 free $iflabel{ gpt } method{ biosgrub } . 1 1 -1 btrfs method{ format } format{ } use_filesystem{ } filesystem{ btrfs } mountpoint{ / } .' ]
if reinstall_btrfs_debian_partman_recipe unsupported >/dev/null 2>&1; then
    echo "unsupported Debian Btrfs recipe firmware was accepted" >&2
    exit 1
fi
printf 'PASS debian-btrfs/partman-recipes: EFI and BIOS use a separate ESP and Btrfs root\n'

target_root="$tmp_root/target"
mkdir -p "$target_root/etc/default"
cat >"$target_root/etc/fstab" <<'EOF'
# keep this comment
UUID=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa / ext4 defaults 0 1
UUID=bbbb-bbbb /boot/efi vfat umask=0077 0 1
UUID=cccccccc-cccc-4ccc-8ccc-cccccccccccc /home ext4 defaults 0 2
EOF
root_uuid=11111111-1111-4111-8111-111111111111
efi_uuid=2222-2222
options=compress=zstd:3,noatime
reinstall_btrfs_debian_write_fstab "$target_root" "$root_uuid" "$options" "$efi_uuid"
grep -Fxq "UUID=$root_uuid / btrfs defaults,$options,subvol=@ 0 0" "$target_root/etc/fstab"
grep -Fxq "UUID=$root_uuid /boot btrfs defaults,$options,subvol=@boot 0 0" "$target_root/etc/fstab"
grep -Fxq "UUID=$efi_uuid /boot/efi vfat umask=0077 0 1" "$target_root/etc/fstab"
grep -Fxq 'UUID=cccccccc-cccc-4ccc-8ccc-cccccccccccc /home ext4 defaults 0 2' "$target_root/etc/fstab"
[ "$(awk '$2 == "/" { count++ } END { print count + 0 }' "$target_root/etc/fstab")" -eq 1 ]
[ "$(awk '$2 == "/boot" { count++ } END { print count + 0 }' "$target_root/etc/fstab")" -eq 1 ]
root_options=$(awk '$2 == "/" { print $4 }' "$target_root/etc/fstab" | sed 's/,subvol=@$//')
boot_options=$(awk '$2 == "/boot" { print $4 }' "$target_root/etc/fstab" | sed 's/,subvol=@boot$//')
[ "$root_options" = "$boot_options" ]
printf 'PASS debian-btrfs/fstab: root and boot options match and EFI/unrelated mounts survive\n'

fedora_target="$tmp_root/fedora-target"
mkdir -p "$fedora_target/etc"
printf '%s\n' 'UUID=bbbb-bbbb /boot/efi vfat umask=0077 0 1' >"$fedora_target/etc/fstab"
reinstall_btrfs_write_fstab "$fedora_target" "$root_uuid" @ @boot "$options" "$efi_uuid" /boot/efi
grep -Fxq "UUID=$efi_uuid /boot/efi vfat umask=077 0 2" "$fedora_target/etc/fstab"
if grep -Eq '^[^#]+ /efi ' "$fedora_target/etc/fstab"; then
    echo "Fedora Btrfs fstab has an unexpected /efi mount" >&2
    exit 1
fi
printf 'PASS btrfs-fstab/fedora-efi: /boot/efi is retained on the Anaconda route\n'

cat >"$target_root/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_CMDLINE_LINUX="quiet rootflags=subvol=@,compress=zlib:9"
GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0"
EOF
reinstall_btrfs_debian_set_grub_rootflags "$target_root" "$options"
reinstall_btrfs_debian_set_grub_rootflags "$target_root" "$options"
grep -Fxq 'GRUB_CMDLINE_LINUX="quiet rootflags=subvol=@,compress=zstd:3,noatime"' "$target_root/etc/default/grub"
[ "$(grep -o 'rootflags=' "$target_root/etc/default/grub" | wc -l | tr -d ' ')" -eq 1 ]
printf 'PASS debian-btrfs/grub-rootflags: configured rootflags replace old values idempotently\n'

if reinstall_btrfs_debian_write_fstab "$target_root" "$root_uuid" compress-force=zstd "$efi_uuid" >/dev/null 2>&1; then
    echo "compress-force was accepted for Debian Btrfs" >&2
    exit 1
fi
if reinstall_btrfs_debian_write_fstab "$target_root" invalid-uuid "$options" "$efi_uuid" >/dev/null 2>&1; then
    echo "invalid Debian Btrfs UUID was accepted" >&2
    exit 1
fi

grep -q 'anna/choose_modules string partman-btrfs' "$repo_root/debian.cfg"
grep -q 'reinstall_btrfs_validate_mount_options' "$repo_root/debian.cfg"
grep -q 'btrfs subvolume snapshot' "$repo_root/debian.cfg"
grep -q 'reinstall_btrfs_set_nocompress_flag' "$repo_root/debian.cfg"
grep -q 'install_btrfs_chattr_tool' "$repo_root/reinstall.sh"
grep -q 'archive.debian.org/debian/pool/main/e/e2fsprogs' "$repo_root/reinstall.sh"
grep -q '645cf33d95167713f479815f07dd88a135d55f3a881e409c765cc7e9a6ec5cd1' "$repo_root/reinstall.sh"
grep -q 'in-target update-initramfs -u -k all' "$repo_root/debian.cfg"
grep -q 'in-target update-grub' "$repo_root/debian.cfg"
printf 'PASS debian-btrfs/installer-dry-run: pre-partition validation and root/initramfs/boot setup are wired\n'

grub_function=$(awk '
    /^        reinstall_btrfs_debian_refresh_grub\(\) \{ \\/ { capture = 1 }
    capture {
        line = $0
        sub(/^        /, "", line)
        sub(/ \\$/, "", line)
        print line
    }
    capture && /^        \}; \\/ { exit }
' "$repo_root/debian.cfg")
[ -n "$grub_function" ] || {
    echo "Could not extract the Debian Btrfs GRUB refresh adapter." >&2
    exit 1
}
eval "$grub_function"

COMMAND_LOG="$tmp_root/grub-commands"
TARGET_ARCH=amd64
BIOS_DISK=sda
in-target() {
    printf '%s\n' "$*" >>"$COMMAND_LOG"
    if [ "$1" = dpkg ] && [ "${2:-}" = --print-architecture ]; then
        printf '%s\n' "$TARGET_ARCH"
    fi
}
sh() {
    [ "${1:-}" = /get-xda.sh ] || return 1
    printf '%s\n' "$BIOS_DISK"
}

efi_target="$tmp_root/efi"
mkdir -p "$efi_target/EFI/kali"
: >"$efi_target/EFI/kali/grubx64.efi"
: >"$COMMAND_LOG"
reinstall_btrfs_debian_refresh_grub efi "$efi_target"
grep -Fq 'grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=kali --force-extra-removable --no-nvram --recheck' "$COMMAND_LOG"
efi_install_line=$(grep -n '^grub-install .*--target=x86_64-efi' "$COMMAND_LOG" | cut -d: -f1)
efi_update_line=$(grep -n '^update-grub$' "$COMMAND_LOG" | cut -d: -f1)
[ -n "$efi_install_line" ] && [ -n "$efi_update_line" ] && [ "$efi_install_line" -lt "$efi_update_line" ]
printf 'PASS debian-btrfs/grub-refresh-efi: installed vendor and removable stubs are regenerated before grub.cfg\n'

arm_efi_target="$tmp_root/arm-efi"
mkdir -p "$arm_efi_target/EFI/debian"
: >"$arm_efi_target/EFI/debian/shimaa64.efi"
TARGET_ARCH=arm64
: >"$COMMAND_LOG"
reinstall_btrfs_debian_refresh_grub efi "$arm_efi_target"
grep -Fq 'grub-install --target=arm64-efi --efi-directory=/boot/efi --bootloader-id=debian --force-extra-removable --no-nvram --recheck' "$COMMAND_LOG"
printf 'PASS debian-btrfs/grub-refresh-arm64: target architecture and installed vendor are preserved\n'

missing_vendor_target="$tmp_root/efi-without-vendor"
mkdir -p "$missing_vendor_target/EFI"
: >"$COMMAND_LOG"
if reinstall_btrfs_debian_refresh_grub efi "$missing_vendor_target" >/dev/null 2>&1; then
    echo "Debian Btrfs EFI refresh accepted an ESP without an installed vendor loader." >&2
    exit 1
fi
if grep -q '^grub-install ' "$COMMAND_LOG"; then
    echo "Debian Btrfs EFI refresh ran grub-install without a discovered vendor loader." >&2
    exit 1
fi

: >"$COMMAND_LOG"
reinstall_btrfs_debian_refresh_grub bios unused
grep -Fq 'grub-install --target=i386-pc --recheck /dev/sda' "$COMMAND_LOG"
bios_install_line=$(grep -n '^grub-install .*--target=i386-pc' "$COMMAND_LOG" | cut -d: -f1)
bios_update_line=$(grep -n '^update-grub$' "$COMMAND_LOG" | cut -d: -f1)
[ -n "$bios_install_line" ] && [ -n "$bios_update_line" ] && [ "$bios_install_line" -lt "$bios_update_line" ]
printf 'PASS debian-btrfs/grub-refresh-bios: embedded prefix is reinstalled on selected disk before grub.cfg\n'

BIOS_DISK='bad/disk'
: >"$COMMAND_LOG"
if reinstall_btrfs_debian_refresh_grub bios unused >/dev/null 2>&1; then
    echo "Debian Btrfs BIOS refresh accepted an invalid boot disk name." >&2
    exit 1
fi
if grep -q '^grub-install ' "$COMMAND_LOG"; then
    echo "Debian Btrfs BIOS refresh attempted grub-install with an invalid disk name." >&2
    exit 1
fi

boot_mount_line=$(grep -n 'mount -o "$btrfs_boot_mount_options"' "$repo_root/debian.cfg" | cut -d: -f1)
initramfs_line=$(grep -n 'in-target update-initramfs -u -k all' "$repo_root/debian.cfg" | head -n 1 | cut -d: -f1)
grub_refresh_line=$(grep -n 'reinstall_btrfs_debian_refresh_grub "$btrfs_grub_mode"' "$repo_root/debian.cfg" | cut -d: -f1)
[ -n "$boot_mount_line" ] && [ -n "$initramfs_line" ] && [ -n "$grub_refresh_line" ]
[ "$boot_mount_line" -lt "$initramfs_line" ] && [ "$initramfs_line" -lt "$grub_refresh_line" ]
if grep -q 'lsattr -d "$btrfs_admin/@boot"' "$repo_root/debian.cfg"; then
    echo "Debian Btrfs late-command still requires an unbundled lsattr binary." >&2
    exit 1
fi
printf 'PASS debian-btrfs/grub-refresh-order: @boot is mounted before initramfs and firmware references are refreshed\n'
