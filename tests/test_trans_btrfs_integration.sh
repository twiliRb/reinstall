#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2034,SC2329
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
trans_script=$repo_root/trans.sh
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

source "$repo_root/lib/reinstall-cmdline.sh"
source "$repo_root/lib/reinstall-btrfs-layout.sh"

extract_trans_function() {
    local function_name=$1
    awk -v brace_signature="$function_name() {" -v subshell_signature="$function_name() (" '
        $0 == brace_signature { copy = 1; found = 1; closing = "}" }
        $0 == subshell_signature { copy = 1; found = 1; closing = ")" }
        copy { print }
        copy && $0 == closing { exit }
        END { if (!found) exit 1 }
    ' "$trans_script"
}

for function_name in \
    get_btrfs_layout_plan \
    reinstall_btrfs_install_mode \
    reinstall_btrfs_preflight_runtime_support \
    reinstall_btrfs_opensuse_cloud_image_supported \
    reinstall_btrfs_almalinux_cloud_preflight_pending \
    reinstall_btrfs_almalinux_release_supported \
    reinstall_btrfs_almalinux_cpe_version \
    reinstall_btrfs_almalinux_image_version \
    reinstall_btrfs_almalinux_cloud_image_url_supported \
    reinstall_btrfs_almalinux_selector_matches_image \
    reinstall_btrfs_almalinux_preflight_cleanup \
    reinstall_btrfs_reuse_almalinux_preflight_qcow \
    reinstall_btrfs_trans_mode_supported \
    reinstall_btrfs_uses_trans_root_layout \
    reinstall_btrfs_require_trans_mode \
    copy_btrfs_source_subvolumes \
    mount_nouuid \
    write_btrfs_fstab \
    write_btrfs_fstab_for_target \
    write_redhat_btrfs_efi_stub \
    write_top_level_btrfs_efi_stub \
    set_redhat_btrfs_grub_config_target \
    normalize_redhat_btrfs_bls_paths \
    append_btrfs_grub_cmdline \
    prepare_opensuse_btrfs_root \
    finalize_opensuse_btrfs_root \
    mount_part_basic_layout \
    ensure_mkinitcpio_btrfs_module; do
    extract_trans_function "$function_name" >>"$tmpdir/trans-functions.sh"
done
source "$tmpdir/trans-functions.sh"

# Cloud-copy adapters may consume official source images whose root is Btrfs.
grep -Fq "grep -E ' (btrfs|ext4|xfs|fat|vfat)\$'" "$trans_script"
source_partition=$(printf '%s\n' 'nbd0p1 vfat' 'nbd0p2 btrfs' |
    grep -E ' (btrfs|ext4|xfs|fat|vfat)$' | awk '{print $1}' | tac | head -n1)
[[ "$source_partition" == nbd0p2 ]]
grep -Fq 'cp -a /nbd/. /os/' "$trans_script"
grep -Fq 'btrfs_top_mount_options=$(reinstall_btrfs_top_level_mount_options "$root_compression")' "$trans_script"

source_mount_log=$tmpdir/source-image-mounts.log
lsblk() {
    case "$3" in
    */btrfs* | */nbd0p2) printf '%s\n' btrfs ;;
    */xfs*) printf '%s\n' xfs ;;
    *) return 1 ;;
    esac
}
mount() { printf '%s\n' "$*" >>"$source_mount_log"; }
mount_nouuid -o ro /dev/nbd0p2 "$tmpdir/mount"
mount_nouuid /dev/btrfs "$tmpdir/mount"
mount_nouuid -o ro /dev/xfs "$tmpdir/mount"
[[ "$(sed -n '1p' "$source_mount_log")" == "-o ro,nologreplay /dev/nbd0p2 $tmpdir/mount" ]]
[[ "$(sed -n '2p' "$source_mount_log")" == "-o ro,nologreplay /dev/btrfs $tmpdir/mount" ]]
[[ "$(sed -n '3p' "$source_mount_log")" == "-o nouuid -o ro /dev/xfs $tmpdir/mount" ]]
printf 'CHECKPOINT trans-btrfs/cloud-source-mount: Btrfs stays read-only without log replay; XFS keeps nouuid\n'
unset -f lsblk
printf 'CHECKPOINT trans-btrfs/cloud-source-filesystem: Btrfs root images are detected and dotfiles are copied\n'

source_root=$tmpdir/source-root
source_target=$tmpdir/source-target
source_mount_log=$tmpdir/source-subvolume-mounts.log
mkdir -p "$source_root/etc" "$source_target/home" "$source_target/var" \
    "$tmpdir/source-home/alice" "$tmpdir/source-var/lib" \
    "$tmpdir/source-var/log" "$tmpdir/source-varlog"
printf '%s\n' \
    'UUID=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa / btrfs subvol=root,compress=zstd 0 0' \
    'UUID=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa /home btrfs subvol=home,compress=zstd 0 0' \
    'UUID=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa /var/log btrfs subvol=varlog,compress=zstd 0 0' \
    'UUID=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa /var btrfs subvol=@var,compress=zstd 0 0' \
    'UUID=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb /srv btrfs subvol=srv 0 0' \
    'UUID=cccccccc-cccc-4ccc-8ccc-cccccccccccc /data ext4 defaults 0 2' >"$source_root/etc/fstab"
printf home-data >"$tmpdir/source-home/alice/file"
printf var-data >"$tmpdir/source-var/lib/file"
printf hidden-parent-data >"$tmpdir/source-var/log/overwritten"
printf visible-child-data >"$tmpdir/source-varlog/overwritten"
printf child-only-data >"$tmpdir/source-varlog/child-only"
mount() {
    printf '%s\n' "$*" >>"$source_mount_log"
    local destination=${!#}
    case "$*" in
    *subvol=home*) cp -a "$tmpdir/source-home/." "$destination/" ;;
    *subvol=varlog*) cp -a "$tmpdir/source-varlog/." "$destination/" ;;
    *subvol=@var*) cp -a "$tmpdir/source-var/." "$destination/" ;;
    *) return 1 ;;
    esac
}
umount() { printf '%s\n' "$*" >>"$source_mount_log"; }
copy_btrfs_source_subvolumes \
    "$source_root" "$source_target" /dev/nbd0p2 \
    aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa 12345678-02 source
[[ $(cat "$source_target/home/alice/file") == home-data ]]
[[ $(cat "$source_target/var/lib/file") == var-data ]]
[[ $(cat "$source_target/var/log/overwritten") == visible-child-data ]]
[[ $(cat "$source_target/var/log/child-only") == child-only-data ]]
[[ ! -e "$source_target/var/log/hidden-parent-file" ]]
grep -Fq 'ro,nologreplay,subvol=home' "$source_mount_log"
grep -Fq 'ro,nologreplay,subvol=@var' "$source_mount_log"
printf 'CHECKPOINT trans-btrfs/source-subvolume-copy: nested mounts replace parent content in path order\n'

symlink_source=$tmpdir/symlink-source
symlink_target=$tmpdir/symlink-target
outside_target=$tmpdir/outside-target
mkdir -p "$symlink_source/etc" "$symlink_target" "$outside_target"
printf '%s\n' 'UUID=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa /home btrfs subvol=home 0 0' >"$symlink_source/etc/fstab"
ln -s "$outside_target" "$symlink_target/home"
if copy_btrfs_source_subvolumes \
    "$symlink_source" "$symlink_target" /dev/nbd0p2 \
    aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa 12345678-02 source; then
    echo "Source-image symlink was followed while copying a Btrfs subvolume." >&2
    exit 1
fi
[[ -z "$(find "$outside_target" -mindepth 1 -print -quit)" ]]
printf 'CHECKPOINT trans-btrfs/source-subvolume-copy: target symlinks cannot redirect writes outside @\n'

[[ "$(reinstall_btrfs_top_level_mount_options '')" == subvolid=5 ]]
[[ "$(reinstall_btrfs_top_level_mount_options compress=zstd)" == subvolid=5,compress=zstd ]]
printf 'CHECKPOINT trans-btrfs/top-level-mount-options: no-compression mode omits the trailing comma\n'

is_use_cloud_image() { [ "${cloud_image:-0}" = 1 ]; }
is_efi() { return 0; }
get_disk_size() { printf '%s\n' 53687091200; }

filesystem=btrfs
xda=sda
cloud_image=0
img_type=
distro=arch
releasever=
target_kernel_variant=default
for layout_case in custom none; do
    case "$layout_case" in
    custom)
        btrfs_root_options=$(reinstall_btrfs_validate_mount_options \
            arch '' default zstd '' 'compress=zlib:9,noatime' true)
        expected_options=compress=zlib:9,noatime
        ;;
    none)
        btrfs_root_options=$(reinstall_btrfs_validate_mount_options \
            arch '' default none '' '' false)
        expected_options=
        ;;
    esac
    [[ "$btrfs_root_options" == "$expected_options" ]]
    reinstall_btrfs_trans_mode_supported
    reinstall_btrfs_uses_trans_root_layout
    layout_plan=$(get_btrfs_layout_plan)
    [[ "$(printf '%s\n' "$layout_plan" | awk -F '\t' '$1 == "subvolume" && $3 == "/" {print $4}')" == \
        "$expected_options" ]]
    [[ "$(printf '%s\n' "$layout_plan" | awk -F '\t' '$1 == "subvolume" && $3 == "/boot" {print $4}')" == \
        no-compression ]]
done
printf 'CHECKPOINT trans-btrfs/layout-options: direct mode passes zlib custom options and none through the shared layout planner\n'

for distro in alpine arch gentoo aosc nixos; do
    releasever=
    [[ "$(reinstall_btrfs_install_mode)" == direct ]]
    reinstall_btrfs_trans_mode_supported
    reinstall_btrfs_uses_trans_root_layout
done
printf 'CHECKPOINT trans-btrfs/direct-modes: alpine, arch, gentoo, aosc and nixos use the shared root layout\n'

cloud_image=1
img_type=qemu
for distro_release in fedora:44 oracle:10 ubuntu:26.04; do
    distro=${distro_release%%:*}
    releasever=${distro_release#*:}
    [[ "$(reinstall_btrfs_install_mode)" == cloud-qemu ]]
    if [[ $distro == oracle ]]; then
        [[ "$(reinstall_btrfs_default_kernel_variant "$distro" "$releasever")" == uek ]]
        target_kernel_variant=uek
    else
        target_kernel_variant=default
    fi
    reinstall_btrfs_trans_mode_supported
    reinstall_btrfs_uses_trans_root_layout
done
printf 'CHECKPOINT trans-btrfs/cloud-copy-modes: Fedora, Oracle UEK and Ubuntu qemu routes admitted\n'

cloud_image=0
img_type=
for releasever in 43 44; do
    distro=fedora
    [[ "$(reinstall_btrfs_install_mode)" == installer ]]
    reinstall_btrfs_trans_mode_supported
    if reinstall_btrfs_uses_trans_root_layout; then
        printf 'Fedora Kickstart must own its installer layout\n' >&2
        exit 1
    fi
done
for releasever in 10 11 12 13; do
    distro=debian
    [[ "$(reinstall_btrfs_install_mode)" == debian-installer ]]
    reinstall_btrfs_trans_mode_supported
    if reinstall_btrfs_uses_trans_root_layout; then
        printf 'Debian D-I must own its installer layout\n' >&2
        exit 1
    fi
done
for releasever in rolling last-snapshot; do
    distro=kali
    reinstall_btrfs_trans_mode_supported
    if reinstall_btrfs_uses_trans_root_layout; then
        printf 'Kali D-I must own its installer layout\n' >&2
        exit 1
    fi
done
printf 'CHECKPOINT trans-btrfs/installer-adapters: Fedora Kickstart and Debian/Kali D-I admitted without shared layout ownership\n'

basearch=x86_64
img_type_warp=
cloud_image=1
img_type=qemu
for distro_release in \
    'opensuse:16.0:https://downloadcontentcdn.opensuse.org/distribution/leap/16.0/appliances/Leap-16.0-Minimal-VM.x86_64-Cloud.qcow2' \
    'opensuse:tumbleweed:https://mirror.nju.edu.cn/opensuse/tumbleweed/appliances/openSUSE-Tumbleweed-Minimal-VM.x86_64-Cloud.qcow2'; do
    distro=${distro_release%%:*}
    remainder=${distro_release#*:}
    releasever=${remainder%%:*}
    img=${remainder#*:}
    [[ "$(reinstall_btrfs_install_mode)" == cloud-qemu ]]
    reinstall_btrfs_opensuse_cloud_image_supported
    reinstall_btrfs_trans_mode_supported
    reinstall_btrfs_uses_trans_root_layout
done
printf 'CHECKPOINT trans-btrfs/opensuse-cloud-gate: only Leap 16.0 and Tumbleweed official UEFI qcow2 routes admitted\n'

expect_rejected_mode() {
    local expected_mode=$1
    distro=$2
    releasever=$3
    cloud_image=$4
    img_type=$5
    [[ "$(reinstall_btrfs_install_mode)" == "$expected_mode" ]]
    if reinstall_btrfs_trans_mode_supported; then
        printf 'unexpectedly admitted Btrfs mode %s:%s\n' "$distro" "$expected_mode" >&2
        exit 1
    fi
    if reinstall_btrfs_uses_trans_root_layout; then
        printf 'unexpectedly assigned the shared root layout to %s:%s\n' "$distro" "$expected_mode" >&2
        exit 1
    fi
}

expect_rejected_mode installer ubuntu 26.04 0 ''
expect_rejected_mode installer fedora 42 0 ''
expect_rejected_mode debian-installer debian 9 0 ''
expect_rejected_mode debian-installer kali 2026.3 0 ''
expect_rejected_mode cloud-qemu almalinux 10 1 qemu
expect_rejected_mode cloud-qemu almalinux 10.2 1 qemu

almalinux_os_release=$tmpdir/almalinux-os-release
printf '%s\n' 'ID="almalinux"' 'VERSION_ID="10.2"' >"$almalinux_os_release"
[[ "$(reinstall_btrfs_almalinux_image_version "$almalinux_os_release")" == 10.2 ]]
printf '%s\n' 'ID="almalinux"' 'VERSION_ID="10"' \
    'CPE_NAME="cpe:/o:almalinux:almalinux:10.2"' >"$almalinux_os_release"
[[ "$(reinstall_btrfs_almalinux_image_version "$almalinux_os_release")" == 10.2 ]]
printf '%s\n' 'ID="almalinux"' 'VERSION_ID="10.2"' \
    'CPE_NAME="cpe:/o:almalinux:almalinux:10::baseos"' >"$almalinux_os_release"
[[ "$(reinstall_btrfs_almalinux_image_version "$almalinux_os_release")" == 10.2 ]]
printf '%s\n' 'ID="almalinux"' 'VERSION_ID="10.1"' >"$almalinux_os_release"
if reinstall_btrfs_almalinux_image_version "$almalinux_os_release"; then
    printf 'unexpectedly accepted AlmaLinux 10.1 image metadata\n' >&2
    exit 1
fi
printf '%s\n' 'ID="almalinux"' 'VERSION_ID="10.2"' \
    'CPE_NAME="cpe:/o:almalinux:almalinux:10.1"' >"$almalinux_os_release"
if reinstall_btrfs_almalinux_image_version "$almalinux_os_release"; then
    printf 'unexpectedly accepted conflicting AlmaLinux CPE metadata\n' >&2
    exit 1
fi
printf '%s\n' 'ID="rocky"' 'VERSION_ID="10.2"' >"$almalinux_os_release"
if reinstall_btrfs_almalinux_image_version "$almalinux_os_release"; then
    printf 'unexpectedly accepted non-AlmaLinux image metadata\n' >&2
    exit 1
fi
printf 'CHECKPOINT trans-btrfs/almalinux-image-parser: requires actual AlmaLinux 10.2+ os-release/CPE and rejects conflict or other IDs\n'

cloud_image=1
img_type=qemu
distro=almalinux
releasever=10
basearch=x86_64
unset elarch
img=https://repo.almalinux.org/almalinux/10/cloud/x86_64_v2/images/AlmaLinux-10-GenericCloud-latest.x86_64_v2.qcow2
btrfs_compression=zstd
btrfs_compression_level=
btrfs_options=
btrfs_options_override=false
btrfs_almalinux_image_verified=false
if reinstall_btrfs_trans_mode_supported; then
    printf 'unverified AlmaLinux image passed Btrfs mode gate\n' >&2
    exit 1
fi
reinstall_btrfs_almalinux_cloud_image_url_supported
btrfs_almalinux_image_version=10.2
btrfs_almalinux_image_verified=true
reinstall_btrfs_trans_mode_supported
reinstall_btrfs_uses_trans_root_layout
releasever=10.3
if reinstall_btrfs_trans_mode_supported; then
    printf 'AlmaLinux image selector mismatch passed Btrfs mode gate\n' >&2
    exit 1
fi
releasever=10
img=https://example.invalid/AlmaLinux-10-GenericCloud-latest.x86_64.qcow2
if reinstall_btrfs_trans_mode_supported; then
    printf 'non-official AlmaLinux image passed Btrfs mode gate\n' >&2
    exit 1
fi
printf 'CHECKPOINT trans-btrfs/almalinux-mode-gate: official qcow route opens only after verified matching 10.2+ image metadata\n'

cached_qcow=$tmpdir/almalinux-cache.qcow2
installer_qcow=$tmpdir/installer/cloud_image.qcow2
mkdir -p "$(dirname "$installer_qcow")"
printf 'verified qcow payload\n' >"$cached_qcow"
btrfs_almalinux_cached_qcow=$cached_qcow
btrfs_almalinux_image_verified=true
reinstall_btrfs_reuse_almalinux_preflight_qcow "$installer_qcow"
[[ ! -e "$cached_qcow" ]]
[[ "$(cat "$installer_qcow")" == 'verified qcow payload' ]]
[[ -z "$btrfs_almalinux_cached_qcow" ]]
printf 'CHECKPOINT trans-btrfs/almalinux-cache: preflight qcow is moved into installer storage without re-download\n'

releasever=15.6
distro=opensuse
cloud_image=1
img_type=qemu
img=https://downloadcontentcdn.opensuse.org/distribution/leap/15.6/appliances/Leap-15.6-Minimal-VM.x86_64-Cloud.qcow2
if reinstall_btrfs_trans_mode_supported; then
    printf 'unexpectedly admitted unsupported openSUSE release %s\n' "$releasever" >&2
    exit 1
fi
releasever=tumbleweed
img=https://example.invalid/openSUSE-Tumbleweed-Minimal-VM.x86_64-Cloud.qcow2
if reinstall_btrfs_trans_mode_supported; then
    printf 'unexpectedly admitted a custom openSUSE image URL\n' >&2
    exit 1
fi
img=https://downloadcontentcdn.opensuse.org/tumbleweed/appliances/openSUSE-Tumbleweed-Minimal-VM.x86_64-Cloud.qcow2
is_efi() { return 1; }
if reinstall_btrfs_trans_mode_supported; then
    printf 'unexpectedly admitted an openSUSE BIOS cloud mode\n' >&2
    exit 1
fi
is_efi() { return 0; }
img='https://downloadcontentcdn.opensuse.org/tumbleweed/appliances/openSUSE-Tumbleweed-Minimal-VM.x86_64-Cloud.qcow2?mirror=custom'
if reinstall_btrfs_trans_mode_supported; then
    printf 'unexpectedly admitted an openSUSE image URL with extra query data\n' >&2
    exit 1
fi
img=https://downloadcontentcdn.opensuse.org/tumbleweed/appliances/openSUSE-Tumbleweed-Minimal-VM.x86_64-Cloud.qcow2
expect_rejected_mode cloud-qemu redhat 10 1 qemu
expect_rejected_mode cloud-raw fedora 44 1 raw
expect_rejected_mode cloud-unsupported arch '' 1 ''
expect_rejected_mode cloud-required oracle 10 0 ''
printf 'CHECKPOINT trans-btrfs/default-deny: Ubuntu installer, unverified AlmaLinux images, unsupported openSUSE and unsupported cloud routes remain blocked\n'

# The central mode guard must execute before create_part reaches package or
# partition commands, so an unwired adapter cannot touch the target disk.
awk '
    /^create_part\(\) \{/ { in_create_part = 1; next }
    in_create_part && /reinstall_btrfs_require_trans_mode/ { guard_line = NR }
    in_create_part && /apk add parted e2fsprogs/ { partition_line = NR; exit }
    END { if (!guard_line || !partition_line || guard_line >= partition_line) exit 1 }
' "$trans_script"
awk '
    /^create_part\(\) \{/ { in_create_part = 1 }
    /^umount_pseudo_fs\(\) \{/ { in_create_part = 0 }
    in_create_part && /if reinstall_btrfs_uses_trans_root_layout/ && !layout_guard { layout_guard = NR }
    in_create_part && /btrfs_layout_plan=\$\(get_btrfs_layout_plan\)/ { layout_call = NR }
    END { if (!layout_guard || !layout_call || layout_guard >= layout_call) exit 1 }
' "$trans_script"
awk '
    /^extract_env_from_cmdline\(\) \{/ { in_extract = 1 }
    in_extract && /reinstall_btrfs_require_trans_mode/ { mode_gate = NR }
    in_extract && /reinstall_btrfs_preflight_runtime_support/ { runtime_probe = NR; exit }
    END { if (!mode_gate || !runtime_probe || mode_gate >= runtime_probe) exit 1 }
' "$trans_script"
awk '
    /^extract_env_from_cmdline\(\) \{/ { in_extract = 1 }
    in_extract && /if reinstall_btrfs_almalinux_cloud_preflight_pending/ { deferred = NR }
    in_extract && /reinstall_btrfs_require_trans_mode/ { gate = NR }
    in_extract && /reinstall_btrfs_preflight_runtime_support/ { runtime = NR; exit }
    END { if (!deferred || !gate || !runtime || deferred >= gate || gate >= runtime) exit 1 }
' "$trans_script"
awk '
    /^trans\(\) \{/ { in_trans = 1 }
    in_trans && /reinstall_btrfs_preflight_almalinux_cloud_image/ { preflight = NR }
    in_trans && /^[[:space:]]+create_part$/ { partition = NR; exit }
    END { if (!preflight || !partition || preflight >= partition) exit 1 }
' "$trans_script"
awk '
    /^reinstall_btrfs_preflight_almalinux_cloud_image\(\) \{/ { in_preflight = 1 }
    in_preflight && /qemu-nbd --read-only --connect=\/dev\/nbd0/ { readonly_attach = NR }
    in_preflight && /mount -o "\$mount_opts"/ { readonly_mount = NR }
    in_preflight && /reinstall_btrfs_almalinux_preflight_cleanup/ { cleanup = NR }
    in_preflight && /^}/ { exit }
    END { if (!readonly_attach || !readonly_mount || !cleanup) exit 1 }
' "$trans_script"
awk '
    /^reinstall_btrfs_almalinux_preflight_cleanup\(\) \{/ { in_cleanup = 1 }
    in_cleanup && /partx -d \/dev\/nbd0/ { partx_cleanup = NR }
    in_cleanup && /qemu-nbd --disconnect \/dev\/nbd0/ { nbd_cleanup = NR }
    in_cleanup && /awk -v target="\$mount_dir"/ { mount_cleanup = NR }
    in_cleanup && /^}/ { exit }
    END { if (!partx_cleanup || !nbd_cleanup || !mount_cleanup) exit 1 }
' "$trans_script"
awk '
    /^download_qcow\(\) \{/ { in_download = 1 }
    in_download && /reinstall_btrfs_reuse_almalinux_preflight_qcow/ { cache = NR }
    in_download && /download "\$img"/ { normal_download = NR; exit }
    END { if (!cache || !normal_download || cache >= normal_download) exit 1 }
' "$trans_script"
partition_marker=$tmpdir/partition-command-ran
error_and_exit() { exit 73; }
apk() { touch "$partition_marker"; }
parted() { touch "$partition_marker"; }
if (
    distro=ubuntu
    releasever=26.04
    cloud_image=0
    img_type=
    reinstall_btrfs_require_trans_mode
); then
    printf 'unwired mode passed the pre-partition guard\n' >&2
    exit 1
else
    status=$?
    [[ $status == 73 ]]
fi
[[ ! -e $partition_marker ]]
printf 'CHECKPOINT trans-btrfs/pre-partition-gate: unsupported installer mode rejected before any partition command\n'

partition_marker=$tmpdir/debian-runtime-probe-ran
apk() { touch "$partition_marker"; }
reinstall_btrfs_activate_kernel_support() { touch "$partition_marker"; }
mke2fs() { touch "$partition_marker"; }
check_btrfs_nocompress_support() { touch "$partition_marker"; }
distro=debian
releasever=13
cloud_image=0
img_type=
reinstall_btrfs_preflight_runtime_support
[[ ! -e $partition_marker ]]
printf 'CHECKPOINT trans-btrfs/debian-preflight-isolation: D-I skips Alpine module, loop-mount and chattr probes\n'

is_efi() { return 0; }
blkid() {
    case "$*" in
    *test-esp* | */sdap1) printf '%s\n' '2222-2222' ;;
    *) printf '%s\n' '11111111-1111-4111-8111-111111111111' ;;
    esac
}
btrfs_device=/dev/test-root
btrfs_efi_device=/dev/test-esp
btrfs_root_subvolume=@
btrfs_boot_subvolume=@boot
btrfs_root_options=compress=zstd:3,noatime
mkdir -p "$tmpdir/target/etc"
cat >"$tmpdir/target/etc/fstab" <<'EOF'
UUID=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa / btrfs subvol=root 0 0
UUID=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa /home btrfs subvol=home 0 0
PARTUUID=12345678-02 /var btrfs subvol=@var 0 0
UUID=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb /srv btrfs subvol=srv 0 0
UUID=cccccccc-cccc-4ccc-8ccc-cccccccccccc /data ext4 defaults 0 2
EOF
cloud_source_part_fstype=btrfs
cloud_source_part_uuid=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
cloud_source_part_partuuid=12345678-02
cloud_source_part_label=source
os_part_uuid=11111111-1111-4111-8111-111111111111
distro=ubuntu
write_btrfs_fstab_for_target "$tmpdir/target"
grep -Fq 'UUID=11111111-1111-4111-8111-111111111111 / btrfs defaults,compress=zstd:3,noatime,subvol=@ 0 0' "$tmpdir/target/etc/fstab"
grep -Fq 'UUID=11111111-1111-4111-8111-111111111111 /boot btrfs defaults,compress=zstd:3,noatime,subvol=@boot 0 0' "$tmpdir/target/etc/fstab"
grep -Fq 'UUID=2222-2222 /boot/efi vfat umask=077 0 2' "$tmpdir/target/etc/fstab"
grep -Fq 'UUID=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb /srv btrfs subvol=srv 0 0' "$tmpdir/target/etc/fstab"
grep -Fq 'UUID=cccccccc-cccc-4ccc-8ccc-cccccccccccc /data ext4 defaults 0 2' "$tmpdir/target/etc/fstab"
if grep -Eq '^(UUID=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa|PARTUUID=12345678-02) .+ btrfs ' "$tmpdir/target/etc/fstab"; then
    echo "Source-volume Btrfs mounts were retained in the target fstab." >&2
    exit 1
fi
distro=arch
write_btrfs_fstab_for_target "$tmpdir/target"
grep -Fq 'UUID=2222-2222 /efi vfat umask=077 0 2' "$tmpdir/target/etc/fstab"
printf 'CHECKPOINT trans-btrfs/fstab-adapters: cloud-target EFI paths and Arch /efi path preserved\n'

mount_log=$tmpdir/mount.log
mount() { printf '%s\n' "$*" >>"$mount_log"; }
xda() { printf 'sdap%s\n' "$1"; }
mount_part_basic_layout "$tmpdir/mounted-root" "$tmpdir/mounted-root/boot/efi"
grep -Fq -- '-t btrfs -o subvol=@,compress=zstd:3,noatime /dev/sdap2 '"$tmpdir/mounted-root" "$mount_log"
grep -Fq -- '-t btrfs -o subvol=@boot,compress=zstd:3,noatime /dev/sdap2 '"$tmpdir/mounted-root/boot" "$mount_log"
printf 'CHECKPOINT trans-btrfs/shared-mount-options: @ and @boot receive the normalized root options\n'

grub_defaults=$tmpdir/target/etc/default/grub
mkdir -p "$(dirname "$grub_defaults")"
printf '%s\n' 'GRUB_CMDLINE_LINUX="console=ttyS0"' >"$grub_defaults"
append_btrfs_grub_cmdline "$tmpdir/target"
cp "$grub_defaults" "$tmpdir/grub.first"
append_btrfs_grub_cmdline "$tmpdir/target"
[[ $(grep -Fc '# reinstall managed Btrfs rootflags' "$grub_defaults") == 1 ]]
grep -Fq 'root=UUID=11111111-1111-4111-8111-111111111111 rootfstype=btrfs rootflags=subvol=@,compress=zstd:3,noatime' "$grub_defaults"
printf 'CHECKPOINT trans-btrfs/grub-rootflags: normalized root flags installed idempotently\n'

mkdir -p "$tmpdir/grub-stubs/redhat" "$tmpdir/grub-stubs/ubuntu"
write_redhat_btrfs_efi_stub "$tmpdir/grub-stubs/redhat/grub.cfg" 11111111-1111-4111-8111-111111111111
grep -Fqx 'search --no-floppy --fs-uuid --set=root 11111111-1111-4111-8111-111111111111' "$tmpdir/grub-stubs/redhat/grub.cfg"
grep -Fqx 'set btrfs_relative_path="y"' "$tmpdir/grub-stubs/redhat/grub.cfg"
grep -Fqx 'btrfs-mount-subvol ($root) /boot @boot' "$tmpdir/grub-stubs/redhat/grub.cfg"
grep -Fqx 'set prefix=($root)/boot/grub2' "$tmpdir/grub-stubs/redhat/grub.cfg"
write_top_level_btrfs_efi_stub "$tmpdir/grub-stubs/ubuntu/grub.cfg" 11111111-1111-4111-8111-111111111111 grub
grep -Fqx 'search.fs_uuid 11111111-1111-4111-8111-111111111111 root' "$tmpdir/grub-stubs/ubuntu/grub.cfg"
grep -Fqx "set prefix=(\$root)'/@boot/grub'" "$tmpdir/grub-stubs/ubuntu/grub.cfg"
grep -Fqx 'configfile $prefix/grub.cfg' "$tmpdir/grub-stubs/ubuntu/grub.cfg"
mkdir -p "$tmpdir/redhat-target/etc"
printf '%s\n' 'old ESP menu' >"$tmpdir/redhat-target/etc/grub2-efi.cfg"
set_redhat_btrfs_grub_config_target "$tmpdir/redhat-target"
[[ $(readlink "$tmpdir/redhat-target/etc/grub2-efi.cfg") == /boot/grub2/grub.cfg ]]
if command -v grub-script-check >/dev/null 2>&1; then
    grub-script-check "$tmpdir/grub-stubs/redhat/grub.cfg"
    grub-script-check "$tmpdir/grub-stubs/ubuntu/grub.cfg"
fi
mkdir -p "$tmpdir/bls"
cat >"$tmpdir/bls/kernel.conf" <<'EOF'
linux /boot/vmlinuz-6.15-test
initrd /boot/initramfs-6.15-test.img
options root=UUID=11111111-1111-4111-8111-111111111111 rootflags=subvol=@
EOF
normalize_redhat_btrfs_bls_paths "$tmpdir/bls"
grep -Fqx 'linux /vmlinuz-6.15-test' "$tmpdir/bls/kernel.conf"
grep -Fqx 'initrd /initramfs-6.15-test.img' "$tmpdir/bls/kernel.conf"
normalize_redhat_btrfs_bls_paths "$tmpdir/bls"
grep -Fqx 'linux /vmlinuz-6.15-test' "$tmpdir/bls/kernel.conf"
printf 'CHECKPOINT trans-btrfs/efi-stubs: Red Hat patched GRUB mounts @boot and Ubuntu uses the absolute @boot path\n'

opensuse_target=$tmpdir/opensuse-target
opensuse_log=$tmpdir/opensuse.log
mkdir -p "$opensuse_target/etc/default" "$opensuse_target/boot/efi/EFI/opensuse"
printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' >"$opensuse_target/etc/default/grub"
printf '%s\n' \
    'UUID=old-root / xfs defaults 0 0' \
    'UUID=old-boot /boot xfs defaults 0 0' \
    'UUID=old-efi /boot/efi vfat umask=0077 0 2' >"$opensuse_target/etc/fstab"
chattr() { printf 'chattr %s\n' "$*" >>"$opensuse_log"; }
chroot() {
    printf 'chroot %s\n' "$*" >>"$opensuse_log"
    case "$*" in *'rpm -q btrfsprogs'*) return 1 ;; esac
    return 0
}
distro=opensuse
filesystem=btrfs
btrfs_root_options=compress=zstd:5,noatime
prepare_opensuse_btrfs_root "$opensuse_target"
grep -Fqx 'UUID=11111111-1111-4111-8111-111111111111 / btrfs defaults,compress=zstd:5,noatime,subvol=@ 0 0' "$opensuse_target/etc/fstab"
grep -Fqx 'UUID=11111111-1111-4111-8111-111111111111 /boot btrfs defaults,compress=zstd:5,noatime,subvol=@boot 0 0' "$opensuse_target/etc/fstab"
grep -Fqx 'UUID=2222-2222 /boot/efi vfat umask=077 0 2' "$opensuse_target/etc/fstab"
grep -Fq 'GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT:+$GRUB_CMDLINE_LINUX_DEFAULT }root=UUID=11111111-1111-4111-8111-111111111111 rootfstype=btrfs rootflags=subvol=@,compress=zstd:5,noatime"' "$opensuse_target/etc/default/grub"
grep -Fq 'add_dracutmodules+=" btrfs "' "$opensuse_target/etc/dracut.conf.d/10-reinstall-btrfs.conf"
grep -Fqx 'SUSE_BTRFS_SNAPSHOT_BOOTING="true"' "$opensuse_target/etc/default/grub"
grep -Fq 'search --no-floppy --fs-uuid --set=root 11111111-1111-4111-8111-111111111111' "$opensuse_target/boot/efi/EFI/opensuse/grub.cfg"
grep -Fqx 'set btrfs_relative_path="y"' "$opensuse_target/boot/efi/EFI/opensuse/grub.cfg"
grep -Fqx 'export btrfs_relative_path' "$opensuse_target/boot/efi/EFI/opensuse/grub.cfg"
grep -Fqx 'btrfs-mount-subvol ($root) /boot @boot' "$opensuse_target/boot/efi/EFI/opensuse/grub.cfg"
grep -Fq 'set prefix=($root)/boot/grub2' "$opensuse_target/boot/efi/EFI/opensuse/grub.cfg"
grep -Fq 'chattr +m '"$opensuse_target"'/boot' "$opensuse_log"
finalize_opensuse_btrfs_root "$opensuse_target"
grep -Fq "chroot $opensuse_target zypper --non-interactive install --no-recommends btrfsprogs" "$opensuse_log"
grep -Fq "chroot $opensuse_target dracut --force --regenerate-all" "$opensuse_log"
grep -Fq "chroot $opensuse_target grub2-mkconfig -o /boot/grub2/grub.cfg" "$opensuse_log"
printf 'CHECKPOINT trans-btrfs/opensuse-boot-adapter: +m, shared fstab options, rootflags, dracut and GRUB2 verified\n'

awk '
    /^install_qcow_by_copy\(\)/ { in_copy = 1 }
    in_copy && /prepare_opensuse_btrfs_root \/os/ { prepare = NR }
    in_copy && prepare && /umount \/os\/boot\/efi\// && NR > prepare { unmount_efi = NR }
    in_copy && prepare && /umount \/os\/boot\// && NR > prepare { unmount_boot = NR }
    in_copy && prepare && /umount \/os\// && NR > prepare { unmount_root = NR }
    in_copy && prepare && /mount_part_basic_layout \/os \/os\/boot\/efi/ && NR > prepare { remount = NR }
    in_copy && /modify_linux \/os/ { modify = NR }
    in_copy && /finalize_opensuse_btrfs_root \/os/ { finalize = NR }
    /^get_partition_table_format\(\)/ { exit }
    END {
        if (!prepare || !unmount_efi || !unmount_boot || !unmount_root || !remount || !modify || !finalize ||
            prepare >= unmount_efi || unmount_efi >= unmount_boot || unmount_boot >= unmount_root ||
            unmount_root >= remount || remount >= modify || modify >= finalize) exit 1
    }
' "$trans_script"
awk '
    /^modify_linux\(\) \{/ { in_modify = 1 }
    in_modify && /find_and_mount\(\) \{/ { in_find = 1 }
    in_find && /\/proc\/mounts/ { mounted_guard = NR }
    in_find && /^    }/ { exit }
    END { if (!mounted_guard) exit 1 }
' "$trans_script"
printf 'CHECKPOINT trans-btrfs/opensuse-dry-run-order: boot policy precedes root/@boot/ESP remount, SUSE provisioning and final boot regeneration\n'

mkinitcpio_target=$tmpdir/arch
mkdir -p "$mkinitcpio_target/etc"
printf '%s\n' 'MODULES=(virtio_pci)' >"$mkinitcpio_target/etc/mkinitcpio.conf"
ensure_mkinitcpio_btrfs_module "$mkinitcpio_target"
ensure_mkinitcpio_btrfs_module "$mkinitcpio_target"
[[ "$(cat "$mkinitcpio_target/etc/mkinitcpio.conf")" == 'MODULES=(btrfs virtio_pci)' ]]
printf 'CHECKPOINT trans-btrfs/arch-initramfs: Btrfs module enabled idempotently\n'

printf 'PASS trans Btrfs integration tests\n'
