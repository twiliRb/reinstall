#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo_root/lib/reinstall-btrfs-layout.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

root_uuid=11111111-1111-4111-8111-111111111111
efi_uuid=ABCD-1234
tab=$(printf '\t')
target_root="$tmpdir/target"
mkdir -p "$target_root/etc"
cat >"$target_root/etc/fstab" <<'EOF'
# Existing unrelated target mounts must survive regeneration.
   # /boot comments must also survive regeneration.
# / comments must also survive regeneration.
	# /efi comments must also survive regeneration.
UUID=33333333-3333-4333-8333-333333333333 /home btrfs defaults,subvol=@home 0 0
UUID=44444444-4444-4444-8444-444444444444 / btrfs defaults,subvol=@old 0 0
UUID=44444444-4444-4444-8444-444444444444 /boot ext4 defaults 0 2
UUID=44444444-4444-4444-8444-444444444444 /efi vfat defaults 0 2
UUID=55555555-5555-4555-8555-555555555555 none swap defaults 0 0
EOF
printf 'UUID=66666666-6666-4666-8666-666666666666\t/srv\tbtrfs\tdefaults\t0\t0\n' \
    >>"$target_root/etc/fstab"

reinstall_btrfs_write_fstab "$target_root" "$root_uuid" @ @boot compress=zstd "$efi_uuid"
expected_efi_fstab=$(cat <<EOF
# Existing unrelated target mounts must survive regeneration.
   # /boot comments must also survive regeneration.
# / comments must also survive regeneration.
	# /efi comments must also survive regeneration.
UUID=33333333-3333-4333-8333-333333333333 /home btrfs defaults,subvol=@home 0 0
UUID=55555555-5555-4555-8555-555555555555 none swap defaults 0 0
UUID=66666666-6666-4666-8666-666666666666${tab}/srv${tab}btrfs${tab}defaults${tab}0${tab}0
UUID=$root_uuid / btrfs defaults,compress=zstd,subvol=@ 0 0
UUID=$root_uuid /boot btrfs defaults,compress=zstd,subvol=@boot 0 0
UUID=$efi_uuid /efi vfat umask=077 0 2
EOF
)
[ "$(cat "$target_root/etc/fstab")" = "$expected_efi_fstab" ]
printf 'CHECKPOINT btrfs-config/efi-fstab: root, /boot and /efi entries\n'
awk '$1 ~ /^UUID=/ && ($2 == "/" || $2 == "/boot" || $2 == "/efi") { print "  | " $0 }' \
    "$target_root/etc/fstab"
cp "$target_root/etc/fstab" "$tmpdir/fstab.once"
reinstall_btrfs_write_fstab "$target_root" "$root_uuid" @ @boot compress=zstd "$efi_uuid"
[ "$(cat "$tmpdir/fstab.once")" = "$(cat "$target_root/etc/fstab")" ]
printf 'CHECKPOINT btrfs-config/idempotence: repeated EFI fstab generation preserved identical output\n'

reinstall_btrfs_write_fstab "$target_root" "$root_uuid" @ @boot compress=zstd
expected_bios_fstab=$(cat <<EOF
# Existing unrelated target mounts must survive regeneration.
   # /boot comments must also survive regeneration.
# / comments must also survive regeneration.
	# /efi comments must also survive regeneration.
UUID=33333333-3333-4333-8333-333333333333 /home btrfs defaults,subvol=@home 0 0
UUID=55555555-5555-4555-8555-555555555555 none swap defaults 0 0
UUID=66666666-6666-4666-8666-666666666666${tab}/srv${tab}btrfs${tab}defaults${tab}0${tab}0
UUID=$root_uuid / btrfs defaults,compress=zstd,subvol=@ 0 0
UUID=$root_uuid /boot btrfs defaults,compress=zstd,subvol=@boot 0 0
EOF
)
[ "$(cat "$target_root/etc/fstab")" = "$expected_bios_fstab" ]
printf 'CHECKPOINT btrfs-config/bios-fstab: root and /boot entries; existing /home and swap preserved\n'
awk '$1 ~ /^UUID=/ && ($2 == "/" || $2 == "/boot") { print "  | " $0 }' \
    "$target_root/etc/fstab"

empty_target="$tmpdir/empty-target"
mkdir -p "$empty_target/etc"
: >"$empty_target/etc/fstab"
reinstall_btrfs_write_fstab "$empty_target" "$root_uuid" @ @boot compress=zstd
[ "$(cat "$empty_target/etc/fstab")" = \
    "UUID=$root_uuid / btrfs defaults,compress=zstd,subvol=@ 0 0
UUID=$root_uuid /boot btrfs defaults,compress=zstd,subvol=@boot 0 0" ]

mounts_only_target="$tmpdir/mounts-only-target"
mkdir -p "$mounts_only_target/etc"
printf '%s\n' \
    'UUID=44444444-4444-4444-8444-444444444444 / btrfs defaults 0 0' \
    'UUID=44444444-4444-4444-8444-444444444444 /boot ext4 defaults 0 2' \
    'UUID=44444444-4444-4444-8444-444444444444 /efi vfat defaults 0 2' \
    >"$mounts_only_target/etc/fstab"
reinstall_btrfs_write_fstab "$mounts_only_target" "$root_uuid" @ @boot compress=zstd
[ "$(cat "$mounts_only_target/etc/fstab")" = \
    "UUID=$root_uuid / btrfs defaults,compress=zstd,subvol=@ 0 0
UUID=$root_uuid /boot btrfs defaults,compress=zstd,subvol=@boot 0 0" ]

expected_nixos=$(cat <<'EOF'
boot.supportedFilesystems = [ "btrfs" ];
boot.initrd.supportedFilesystems = [ "btrfs" ];
environment.systemPackages = [ pkgs.btrfs-progs ];
fileSystems."/".options = lib.mkForce [ "subvol=@" "compress=zstd" ];
fileSystems."/boot".options = lib.mkForce [ "subvol=@boot" "compress=zstd" ];
EOF
)
[ "$(reinstall_btrfs_nixos_config_snippet @ @boot compress=zstd)" = "$expected_nixos" ]
[ "$(reinstall_btrfs_kernel_rootflags @ compress=zstd)" = 'rootflags=subvol=@,compress=zstd' ]
[ "$(reinstall_btrfs_nixos_add_initrd_module 'virtio_pci virtio_blk')" = 'virtio_pci virtio_blk btrfs' ]
[ "$(reinstall_btrfs_nixos_add_initrd_module 'virtio_pci btrfs virtio_blk')" = 'virtio_pci btrfs virtio_blk' ]
printf 'CHECKPOINT btrfs-config/nixos-config:\n'
printf '%s\n' "$expected_nixos" | sed 's/^/  | /'
printf '  | %s\n' "$(reinstall_btrfs_kernel_rootflags @ compress=zstd)"
if command -v nix-instantiate >/dev/null 2>&1; then
    {
        printf '{ lib, pkgs, ... }: {\n'
        reinstall_btrfs_nixos_config_snippet @ @boot compress=zstd
        printf '}\n'
    } >"$tmpdir/reinstall-ci.nix"
    nix-instantiate --parse "$tmpdir/reinstall-ci.nix" >/dev/null
fi

marker="$tmpdir/command-ran"
if reinstall_btrfs_nixos_config_snippet "\$(touch $marker)" @boot compress=zstd; then
    printf 'accepted unsafe Btrfs subvolume name\n' >&2
    exit 1
fi
[ ! -e "$marker" ]

if reinstall_btrfs_write_fstab "$target_root" "\$(touch $marker)" @ @boot compress=zstd; then
    printf 'accepted an unsafe filesystem UUID\n' >&2
    exit 1
fi
[ ! -e "$marker" ]
if reinstall_btrfs_write_fstab "$target_root" '' @ @boot compress=zstd; then
    printf 'accepted an empty root UUID\n' >&2
    exit 1
fi
if reinstall_btrfs_write_fstab "$target_root" "$root_uuid" @ @boot compress=zstd 'not-a-fat-uuid'; then
    printf 'accepted an invalid FAT UUID\n' >&2
    exit 1
fi
printf 'CHECKPOINT btrfs-config/input-validation: unsafe subvolume/UUID, empty UUID and invalid FAT UUID rejected; command-sentinel=absent\n'

printf 'PASS Btrfs target configuration tests\n'
