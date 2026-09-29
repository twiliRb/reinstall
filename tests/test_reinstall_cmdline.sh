#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_root/lib/reinstall-cmdline.sh"

# BIOS bootloader discovery may cache the running system disk before CLI
# options are applied. Selecting a different target must invalidate that ID.
xda=vda
main_disk=source-disk-id
boot_xda=vda
reinstall_cmdline_select_target_disk /dev/vdb
[[ "$xda" == vdb ]]
[[ -z "$main_disk" ]]
[[ "$(reinstall_cmdline_bootloader_disk)" == vda ]]
printf 'CHECKPOINT cmdline/target-disk: selected=%s bootloader=%s cached-source-id=cleared\n' \
    "$xda" "$(reinstall_cmdline_bootloader_disk)"

# The optional filesystem selector defaults to ext4. Btrfs is limited to
# verified root-boot targets and version/kernel-aware mount options.
reinstall_validate_filesystem ext4 arch
reinstall_validate_filesystem btrfs arch
reinstall_validate_filesystem btrfs gentoo
reinstall_validate_filesystem btrfs nixos
reinstall_validate_filesystem btrfs aosc
for target in \
    'fedora 43' 'fedora 44' 'debian 10' 'debian 11' 'debian 12' 'debian 13' \
    'kali rolling' 'kali last-snapshot' 'opensuse 16.0' 'opensuse tumbleweed' \
    'alpine 3.21' 'alpine 3.22' 'alpine 3.23' 'alpine 3.24' \
    'ubuntu 18.04' 'ubuntu 20.04' 'ubuntu 22.04' 'ubuntu 24.04' 'ubuntu 26.04' \
    'oracle 8' 'oracle 9' 'oracle 10' 'almalinux 10' 'almalinux 10.2'; do
    read -r target_distro target_release <<<"$target"
    reinstall_validate_filesystem btrfs "$target_distro" "$target_release"
done
for target in 'debian 9' 'almalinux 10.1' 'oracle 7' 'centos 9' 'anolis 23'; do
    read -r target_distro target_release <<<"$target"
    if reinstall_validate_filesystem btrfs "$target_distro" "$target_release"; then
        printf 'accepted Btrfs on an unsupported distro/release: %s\n' "$target" >&2
        exit 1
    fi
done
if reinstall_validate_filesystem btrfs debian 9; then
    printf 'accepted Btrfs on an unsupported distro\n' >&2
    exit 1
else
    [[ $? == 2 ]]
fi
if reinstall_validate_filesystem xfs arch; then
    printf 'accepted an unsupported filesystem value\n' >&2
    exit 1
else
    [[ $? == 1 ]]
fi
for supported_e2fsprogs_version in 1.46.2 1.46.3 1.47.0 2.0.0; do
    reinstall_e2fsprogs_supports_nocompress "$supported_e2fsprogs_version"
done
for unsupported_e2fsprogs_version in 1.46.1 1.45.6 1.0.99 invalid 1.46; do
    if reinstall_e2fsprogs_supports_nocompress "$unsupported_e2fsprogs_version"; then
        printf 'accepted e2fsprogs without chattr +m support: %s\n' \
            "$unsupported_e2fsprogs_version" >&2
        exit 1
    fi
done

mke2fs_output=$'mke2fs 1.47.4 (5-Feb-2023)\nUsing EXT2FS Library version 1.47.4'
[[ "$(reinstall_e2fsprogs_version_from_mke2fs_output "$mke2fs_output")" == 1.47.4 ]]
mke2fs_old_output='mke2fs 1.46.2 (28-Feb-2021)'
[[ "$(reinstall_e2fsprogs_version_from_mke2fs_output "$mke2fs_old_output")" == 1.46.2 ]]
[[ -z "$(reinstall_e2fsprogs_version_from_mke2fs_output 'not mke2fs version output')" ]]
[[ "$(reinstall_btrfs_default_kernel_variant oracle 10)" == uek ]]
[[ "$(reinstall_btrfs_default_kernel_variant debian 13)" == default ]]
[[ "$(reinstall_btrfs_target_kernel_baseline oracle 9 uek)" == 5.15 ]]
if reinstall_btrfs_target_kernel_baseline oracle 9 default; then
    printf 'accepted non-UEK Oracle Btrfs target\n' >&2
    exit 1
fi

[[ "$(reinstall_btrfs_validate_mount_options debian 10 default zstd '' '' 0)" == compress=zstd ]]
[[ "$(reinstall_btrfs_validate_mount_options debian 10 default zlib 9 '' 0)" == compress=zlib:9 ]]
[[ "$(reinstall_btrfs_validate_mount_options debian 10 default zstd 0 '' 0)" == compress=zstd ]]
[[ -z "$(reinstall_btrfs_validate_mount_options debian 10 default none '' '' 0)" ]]
[[ "$(reinstall_btrfs_validate_mount_options debian 10 default lzo 0 '' 0)" == compress=lzo ]]
[[ "$(reinstall_btrfs_validate_mount_options debian 13 default zstd '' 'noatime' 1)" == noatime ]]
[[ "$(reinstall_btrfs_validate_mount_options debian 13 default zstd '' 'compress=no,noatime' 1)" == noatime ]]
[[ "$(reinstall_btrfs_validate_mount_options debian 11 default zstd 15 '' 0)" == compress=zstd:15 ]]
[[ "$(reinstall_btrfs_validate_mount_options arch '' default zstd -15 '' 0)" == compress=zstd:-15 ]]
for invalid in \
    'debian 10 default zstd 1' \
    'debian 10 default zstd -1' \
    'debian 10 default lzo 1' \
    'debian 10 default none 1' \
    'debian 10 default zlib 10' \
    'debian 10 default zstd 16' \
    'oracle 9 default zstd 0'; do
    read -r invalid_distro invalid_release invalid_variant invalid_compression invalid_level <<<"$invalid"
    if reinstall_btrfs_validate_mount_options "$invalid_distro" "$invalid_release" \
        "$invalid_variant" "$invalid_compression" "$invalid_level" '' 0; then
        printf 'accepted invalid/incompatible Btrfs config: %s\n' "$invalid" >&2
        exit 1
    fi
done
if reinstall_btrfs_validate_mount_options debian 10 default zstd '' 'unknown_option' 1; then
    printf 'accepted an unknown generic Btrfs option\n' >&2
    exit 1
fi
if reinstall_btrfs_validate_mount_options arch '' default zstd '' 'compress-force=zstd' 1; then
    printf 'accepted compress-force\n' >&2
    exit 1
fi
if reinstall_btrfs_validate_mount_options arch '' default zstd '' 'ro' 1; then
    printf 'accepted a read-only root override\n' >&2
    exit 1
fi
if reinstall_btrfs_validate_mount_options arch '' default zstd '' 'compress=zstd,nodatacow' 1; then
    printf 'accepted compression with nodatacow\n' >&2
    exit 1
fi
if reinstall_btrfs_validate_mount_options arch '' default zstd '' 'compress=zstd,nodatasum' 1; then
    printf 'accepted compression with nodatasum\n' >&2
    exit 1
fi
if reinstall_btrfs_validate_mount_options debian 10 default zstd '' 'discard=async' 1; then
    printf 'accepted a target-unsupported discard mode\n' >&2
    exit 1
fi
[[ "$(reinstall_btrfs_validate_mount_options debian 10 default zstd '' 'space_cache=v2' 1)" == space_cache=v2 ]]
[[ "$(reinstall_btrfs_validate_mount_options debian 10 default zstd '' inode_cache 1)" == inode_cache ]]
if reinstall_btrfs_validate_mount_options debian 12 default zstd '' inode_cache 1; then
    printf 'accepted removed inode_cache on a new target kernel\n' >&2
    exit 1
else
    [[ $? == 2 ]]
fi
if reinstall_btrfs_validate_mount_options arch '' default zstd '' usebackuproot 1; then
    printf 'accepted removed usebackuproot on an unbounded rolling kernel\n' >&2
    exit 1
fi
for discard_conflict in 'discard,nodiscard' 'nodiscard,discard=async'; do
    if reinstall_btrfs_validate_mount_options arch '' default zstd '' "$discard_conflict" 1; then
        printf 'accepted conflicting discard options: %s\n' "$discard_conflict" >&2
        exit 1
    fi
done
for option_conflict in \
    'acl,noacl' 'autodefrag,noautodefrag' 'commit=30,commit=60' \
    'dev,nodev' 'exec,noexec' 'fatal_errors=bug,fatal_errors=panic' \
    'flushoncommit,noflushoncommit' 'lazytime,nolazytime' \
    'max_inline=4096,max_inline=8192' 'space_cache=v1,space_cache=v2' \
    'ssd,nossd' 'ssd_spread,nossd_spread' 'nossd,ssd_spread' \
    'suid,nosuid' 'sync,async' 'thread_pool=4,thread_pool=8' \
    'verbosity=1,verbosity=2' 'nodatacow,datasum'; do
    if reinstall_btrfs_validate_mount_options arch '' default zstd '' "$option_conflict" 1; then
        printf 'accepted conflicting Btrfs mount options: %s\n' "$option_conflict" >&2
        exit 1
    fi
done
[[ "$(reinstall_btrfs_validate_mount_options arch '' default zstd '' 'defaults,noatime,compress=zstd:0' 1)" == noatime,compress=zstd ]]
printf 'CHECKPOINT cmdline/filesystem-policy: distro matrix, target kernel gates, compression and override validation passed\n'

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

marker="$tmpdir/command-ran"
username="A user 'with quotes' \"double\" \$HOME \`touch $marker\` & 雪"

username_arg=$(reinstall_cmdline_serialize extra_username "$username")
port_arg=$(reinstall_cmdline_serialize extra_ssh_port '2222')
source_sha=0123456789abcdef0123456789abcdef01234567
confhome_arg=$(reinstall_cmdline_serialize extra_confhome \
    "https://raw.githubusercontent.com/twiliRb/reinstall/$source_sha")
filesystem_arg=$(reinstall_cmdline_serialize extra_filesystem btrfs)
btrfs_target_distro_arg=$(reinstall_cmdline_serialize extra_btrfs_target_distro debian)
btrfs_target_releasever_arg=$(reinstall_cmdline_serialize extra_btrfs_target_releasever 13)
btrfs_target_variant_arg=$(reinstall_cmdline_serialize extra_btrfs_target_kernel_variant default)
btrfs_compression_arg=$(reinstall_cmdline_serialize extra_btrfs_compression zstd)
btrfs_level_arg=$(reinstall_cmdline_serialize extra_btrfs_compression_level -15)
printf '%s\n' "root=/dev/vda $username_arg $port_arg $confhome_arg $filesystem_arg $btrfs_target_distro_arg $btrfs_target_releasever_arg $btrfs_target_variant_arg $btrfs_compression_arg $btrfs_level_arg" >"$tmpdir/cmdline"

username=
ssh_port=
confhome=
filesystem=ext4
btrfs_compression=zlib
btrfs_compression_level=0
btrfs_options=
btrfs_options_override=0
btrfs_compression_set=0
btrfs_compression_level_set=0
[[ "$filesystem" == ext4 ]]
reinstall_cmdline_load_file "$tmpdir/cmdline" extra

if [[ "$username" != "A user 'with quotes' \"double\" \$HOME \`touch $marker\` & 雪" ]]; then
    printf 'cmdline round-trip mismatch: %q\n' "$username" >&2
    exit 1
fi
[[ "$ssh_port" == 2222 ]]
[[ "$confhome" == "https://raw.githubusercontent.com/twiliRb/reinstall/$source_sha" ]]
[[ "$filesystem" == btrfs ]]
[[ "$btrfs_target_distro" == debian ]]
[[ "$btrfs_target_releasever" == 13 ]]
[[ "$btrfs_target_kernel_variant" == default ]]
[[ "$btrfs_compression" == zstd ]]
[[ "$btrfs_compression_level" == -15 ]]
[[ -z "$btrfs_options" ]]
[[ "$btrfs_options_override" == 0 ]]
[[ "$btrfs_compression_set" == 1 && "$btrfs_compression_level_set" == 1 ]]

btrfs_options_arg=$(reinstall_cmdline_serialize extra_btrfs_options 'noatime,compress=zstd:-15')
printf '%s\n' "root=/dev/vda $filesystem_arg $btrfs_options_arg" >"$tmpdir/btrfs-options-cmdline"
btrfs_compression=zstd
btrfs_compression_level=
btrfs_options=
btrfs_options_override=0
btrfs_compression_set=0
btrfs_compression_level_set=0
reinstall_cmdline_load_file "$tmpdir/btrfs-options-cmdline" extra
[[ "$filesystem" == btrfs ]]
[[ "$btrfs_options" == 'noatime,compress=zstd:-15' ]]
[[ "$btrfs_options_override" == 1 ]]
if reinstall_cmdline_load_file "$tmpdir/cmdline" extra; then
    printf 'accepted mutually exclusive typed and generic Btrfs options\n' >&2
    exit 1
fi
for invalid_target in 'oracle 10 default' 'debian 13 ueK' 'debian 13 default/evil'; do
    read -r target_distro target_release target_variant <<<"$invalid_target"
    btrfs_target_distro=
    btrfs_target_releasever=
    btrfs_target_kernel_variant=
    target_payload='root=/dev/vda'
    target_payload+=" $(reinstall_cmdline_serialize extra_btrfs_target_distro "$target_distro")"
    target_payload+=" $(reinstall_cmdline_serialize extra_btrfs_target_releasever "$target_release")"
    target_payload+=" $(reinstall_cmdline_serialize extra_btrfs_target_kernel_variant "$target_variant")"
    printf '%s\n' "$target_payload" >"$tmpdir/invalid-btrfs-target"
    if reinstall_cmdline_load_file "$tmpdir/invalid-btrfs-target" extra; then
        printf 'accepted unsafe/inconsistent Btrfs target identity: %s\n' "$invalid_target" >&2
        exit 1
    fi
done
btrfs_target_distro=
btrfs_target_releasever=
btrfs_target_kernel_variant=
target_payload='root=/dev/vda'
target_payload+=" $(reinstall_cmdline_serialize extra_btrfs_target_distro arch)"
target_payload+=" $(reinstall_cmdline_serialize extra_btrfs_target_kernel_variant default)"
printf '%s\n' "$target_payload" >"$tmpdir/btrfs-target-without-release"
reinstall_cmdline_load_file "$tmpdir/btrfs-target-without-release" extra
[[ "$btrfs_target_distro" == arch ]]
[[ -z "$btrfs_target_releasever" ]]
[[ "$btrfs_target_kernel_variant" == default ]]
btrfs_target_distro=
btrfs_target_releasever=
btrfs_target_kernel_variant=
[[ ! -e "$marker" ]]
printf 'CHECKPOINT cmdline/extra-roundtrip: filesystem=%s username=preserved command-sentinel=absent\n' "$filesystem"

# Every finalos_* field emitted by setos() must survive a two-stage reboot.
finalos_fields=(
    a distro releasever efi vmlinuz initrd modloop repo img udeb_mirror ks
    firmware codename deb_mirror kernel iso minimal mirror boot_wim image_name
    confirmed_no_efi img_type img_type_warp fnos_part_size mirrorlist squashfs
)
extra_fields=(
    addrs allow_ping cloud_image deb_mirror elts force_boot_mode force_cn
    force_old_windows_setup hold kernel link_grub_dir localtest main_disk
    mirrorlist no_auto_drivers no_cloud_kernel rdp_port source_id ssh_port
    username web_path web_port ip_mode dns_mode dns_servers
)
finalos_payload='root=/dev/vda'
for field in "${finalos_fields[@]}"; do
    value="finalos $field 'single' \"double\" \$HOME \`touch $marker\` \$(touch $marker) 雪"
    finalos_payload+=" $(reinstall_cmdline_serialize "finalos_$field" "$value")"
done
printf '%s\n' "$finalos_payload" >"$tmpdir/finalos-fields-cmdline"
reinstall_cmdline_load_file "$tmpdir/finalos-fields-cmdline" all
for field in "${finalos_fields[@]}"; do
    expected="finalos $field 'single' \"double\" \$HOME \`touch $marker\` \$(touch $marker) 雪"
    [[ "${!field}" == "$expected" ]]
done

extra_payload='root=/dev/vda'
for field in "${extra_fields[@]}"; do
    value="extra $field 'single' \"double\" \$HOME \`touch $marker\` \$(touch $marker) 雪"
    extra_payload+=" $(reinstall_cmdline_serialize "extra_$field" "$value")"
done
printf '%s\n' "$extra_payload" >"$tmpdir/extra-fields-cmdline"
reinstall_cmdline_load_file "$tmpdir/extra-fields-cmdline" extra
for field in "${extra_fields[@]}"; do
    expected="extra $field 'single' \"double\" \$HOME \`touch $marker\` \$(touch $marker) 雪"
    [[ "${!field}" == "$expected" ]]
done
[[ ! -e "$marker" ]]
printf 'CHECKPOINT cmdline/field-roundtrip: finalos=%s extra=%s command-sentinel=absent\n' \
    "${#finalos_fields[@]}" "${#extra_fields[@]}"

# The generated web path is used as a filesystem path and must stay under its
# static root. The websocket command itself is fixed source; its values arrive
# only as positional parameters.
reinstall_validate_web_path '/Ab3d_012/X-y'
for invalid_web_path in '/../../etc/passwd' '/abc/../def' '/abc/$(touch-marker)' '/with space'; do
    if reinstall_validate_web_path "$invalid_web_path"; then
        printf 'accepted unsafe web path: %s\n' "$invalid_web_path" >&2
        exit 1
    fi
done
unsafe_web_path="\$(touch $marker)"
mkdir -p "$tmpdir/bin"
cat >"$tmpdir/bin/tail" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$TAIL_ARGS_FILE"
printf 'sample log line\n'
EOF
chmod +x "$tmpdir/bin/tail"
websocket_log_script=$(reinstall_websocket_log_script)
PATH_INFO=$unsafe_web_path TAIL_ARGS_FILE="$tmpdir/tail-args" PATH="$tmpdir/bin:$PATH" \
    sh -c "$websocket_log_script" websocketd "$unsafe_web_path" /reinstall.log \
    >"$tmpdir/websocket-output"
[[ "$(cat "$tmpdir/tail-args")" == $'-fn+0\n/reinstall.log' ]]
grep -Fq 'sample log line' "$tmpdir/websocket-output"
[[ ! -e "$marker" ]]
printf 'CHECKPOINT cmdline/websocket: path-validation=passed tail-arguments=%s\n' \
    "$(tr '\n' ',' <"$tmpdir/tail-args" | sed 's/,$//')"

# Values embedded in generated initrd shell snippets must remain shell data.
shell_value="Network 'value' \"quotes\" \$HOME \`touch $marker\` \$(touch $marker) & 雪"
printf 'quoted_value=%s\n' "$(reinstall_shell_quote "$shell_value")" >"$tmpdir/serialized-shell.sh"
. "$tmpdir/serialized-shell.sh"
[[ "$quoted_value" == "$shell_value" ]]
[[ ! -e "$marker" ]]

# Legacy unencoded words remain inert data while old boot entries are phased
# out; arbitrary source URLs fail closed.
legacy_payload="\$(touch\$IFS$marker)"
printf '%s\n' "extra_username=$legacy_payload" >"$tmpdir/legacy-cmdline"
username=
reinstall_cmdline_load_file "$tmpdir/legacy-cmdline" extra
[[ "$username" == "$legacy_payload" ]]
[[ ! -e "$marker" ]]

bad_confhome=$(reinstall_cmdline_serialize extra_confhome 'https://example.invalid/reinstall/main')
printf '%s\n' "$bad_confhome" >"$tmpdir/bad-confhome"
if reinstall_cmdline_load_file "$tmpdir/bad-confhome" extra; then
    printf 'accepted an unpinned external project source\n' >&2
    exit 1
fi
printf 'CHECKPOINT cmdline/source-and-injection: legacy-value=inert pinned-source=accepted unpinned-source=rejected sentinel=absent\n'

# GNU getopt's eval round-trip is safe only because getopt shell-quotes every
# argument. Keep this adversarial value as a regression test for that boundary.
opts=$(getopt -o '' --long user: -- --user "$username")
eval "set -- $opts"
[[ $# == 3 && $1 == --user && $2 == "$username" && $3 == -- ]]
[[ ! -e "$marker" ]]
printf 'CHECKPOINT cmdline/getopt: argc=%s quoted-input=inert sentinel=absent\n' "$#"

printf 'PASS command-line parser/serializer tests\n'
