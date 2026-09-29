#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo_root/lib/reinstall-grub-hook.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

assert_profile() {
    expected=$1
    distro=$2
    release=$3
    actual=$(reinstall_grub_hook_profile_for_os "$distro" "$release")
    [ "$actual" = "$expected" ] || {
        printf 'profile mismatch for %s %s: expected <%s>, got <%s>\n' \
            "$distro" "$release" "$expected" "$actual" >&2
        exit 1
    }
}

assert_profile pacman arch ''
assert_profile portage gentoo ''
assert_profile dnf5 fedora 43
assert_profile dnf5 fedora 44
assert_profile yum3 anolis 7
assert_profile dnf4 anolis 8
assert_profile dnf4 anolis 23
assert_profile dnf4 almalinux 8
assert_profile dnf4 almalinux 9
assert_profile dnf4 almalinux 10
assert_profile dnf4 rocky 8
assert_profile dnf4 rocky 9
assert_profile dnf4 rocky 10
assert_profile dnf4 openeuler 20.03
assert_profile dnf4 openeuler 22.03
assert_profile dnf4 openeuler 24.03
assert_profile dnf4 opencloudos 23
for unsupported in \
    'fedora 45' 'anolis 9' 'centos 9' 'oracle 9' 'redhat 9' \
    'opencloudos 8' 'opencloudos 9' 'aosc rolling' 'fnos 0' 'debian 13'; do
    unsupported_distro=${unsupported%% *}
    unsupported_release=${unsupported#* }
    assert_profile '' "$unsupported_distro" "$unsupported_release"
done
printf 'CHECKPOINT grub-hook/profile-map: verified profiles returned; unsupported combinations fail closed\n'

target_disk=/dev/disk/by-id/wwn-a-target
stubbin="$tmpdir/bin"
mkdir -p "$stubbin"
cat >"$stubbin/grub-install" <<'EOF'
#!/bin/sh
printf '<%s>\n' "$@" >>"$GRUB_CALLS"
if [ "${GRUB_FAIL-0}" -ne 0 ]; then
    exit "$GRUB_FAIL"
fi
EOF
chmod +x "$stubbin/grub-install"

for profile in pacman portage dnf4 dnf5 yum3; do
    target_root="$tmpdir/target-$profile"
    mkdir -p "$target_root/etc"
    if [ "$profile" = portage ]; then
        mkdir -p "$target_root/etc/portage"
        printf '%s\n' '# existing config' 'custom_portage_setting="kept"' \
            >"$target_root/etc/portage/bashrc"
    fi
    if [ "$profile" = dnf4 ] || [ "$profile" = dnf5 ] || [ "$profile" = yum3 ]; then
        mkdir -p "$stubbin"
        cat >"$stubbin/chroot" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$CHROOT_CALLS"
if [ "${CHROOT_FAIL-0}" -ne 0 ]; then
    exit "$CHROOT_FAIL"
fi
EOF
        chmod +x "$stubbin/chroot"
        CHROOT_CALLS="$tmpdir/chroot-calls" PATH="$stubbin:$PATH" \
            reinstall_grub_hook_setup "$target_root" "$profile" "$target_disk"
        case $profile in
            dnf5) grep -F 'dnf5 -y install libdnf5-plugin-actions' "$tmpdir/chroot-calls" >/dev/null ;;
            dnf4) grep -F 'dnf -y install python3-dnf-plugin-post-transaction-actions' "$tmpdir/chroot-calls" >/dev/null ;;
            yum3) grep -F 'yum -y install yum-plugin-post-transaction-actions' "$tmpdir/chroot-calls" >/dev/null ;;
        esac
    else
        reinstall_grub_hook_setup "$target_root" "$profile" "$target_disk"
    fi

    runner="$target_root/usr/local/sbin/reinstall-grub-install"
    [ -x "$runner" ]
    case $profile in
        pacman) expected_grub_install_bin=/usr/bin/grub-install ;;
        portage) expected_grub_install_bin=/usr/sbin/grub-install ;;
        *) expected_grub_install_bin=/usr/sbin/grub2-install ;;
    esac
    grep -F "_reinstall_grub_install_bin=\${REINSTALL_GRUB_INSTALL_BIN:-$expected_grub_install_bin}" \
        "$runner" >/dev/null
    : >"$tmpdir/grub-calls"
    GRUB_CALLS="$tmpdir/grub-calls" REINSTALL_GRUB_INSTALL_BIN="$stubbin/grub-install" \
        "$runner"
    [ "$(cat "$tmpdir/grub-calls")" = "<--target=i386-pc>
<$target_disk>" ]
    if GRUB_CALLS="$tmpdir/grub-calls" GRUB_FAIL=23 \
        REINSTALL_GRUB_INSTALL_BIN="$stubbin/grub-install" \
        "$runner" 2>"$tmpdir/runner-error"; then
        printf 'runner swallowed grub-install failure for %s\n' "$profile" >&2
        exit 1
    else
        status=$?
        [ "$status" -eq 23 ]
        grep -F 'failed with status 23' "$tmpdir/runner-error" >/dev/null
    fi

    case $profile in
        pacman)
            hook="$target_root/etc/pacman.d/hooks/reinstall-grub.hook"
            grep -F 'Operation = Install' "$hook" >/dev/null
            grep -F 'Operation = Upgrade' "$hook" >/dev/null
            grep -F 'Target = grub' "$hook" >/dev/null
            grep -F 'When = PostTransaction' "$hook" >/dev/null
            ;;
        portage)
            hook="$target_root/etc/portage/bashrc"
            grep -F 'custom_portage_setting="kept"' "$hook" >/dev/null
            grep -F "[ \"\${CATEGORY-}\" = sys-boot ]" "$hook" >/dev/null
            grep -F "[ \"\${PN-}\" = grub ]" "$hook" >/dev/null
            ;;
        dnf4)
            hook="$target_root/etc/dnf/plugins/post-transaction-actions.d/reinstall-grub.action"
            grep -F 'grub2*:in:/usr/local/sbin/reinstall-grub-install' "$hook" >/dev/null
            ;;
        dnf5)
            hook="$target_root/etc/dnf/libdnf5-plugins/actions.d/reinstall-grub.actions"
            grep -F 'post_transaction:grub2*:in:raise_error=1:/usr/local/sbin/reinstall-grub-install' "$hook" >/dev/null
            ;;
        yum3)
            hook="$target_root/etc/yum/post-actions/reinstall-grub.action"
            grep -F 'grub2*:install:/usr/local/sbin/reinstall-grub-install' "$hook" >/dev/null
            grep -F 'grub2*:update:/usr/local/sbin/reinstall-grub-install' "$hook" >/dev/null
            ;;
    esac

    cp "$hook" "$tmpdir/hook-once"
    if [ "$profile" = portage ]; then
        cp "$hook" "$tmpdir/bashrc-once"
        reinstall_grub_hook_setup "$target_root" "$profile" "$target_disk"
        cmp -s "$tmpdir/bashrc-once" "$hook"
        [ "$(grep -c '^# BEGIN reinstall-grub-update-hook$' "$hook")" -eq 1 ]
    else
        if [ "$profile" = dnf4 ] || [ "$profile" = dnf5 ] || [ "$profile" = yum3 ]; then
            CHROOT_CALLS="$tmpdir/chroot-calls" PATH="$stubbin:$PATH" \
                reinstall_grub_hook_setup "$target_root" "$profile" "$target_disk"
        else
            reinstall_grub_hook_setup "$target_root" "$profile" "$target_disk"
        fi
        cmp -s "$tmpdir/hook-once" "$hook"
    fi
done
printf 'CHECKPOINT grub-hook/writer: manager hooks are generated and repeated setup is idempotent\n'

provider_failure_root="$tmpdir/provider-failure"
mkdir -p "$provider_failure_root"
if CHROOT_CALLS="$tmpdir/chroot-calls" CHROOT_FAIL=29 PATH="$stubbin:$PATH" \
    reinstall_grub_hook_setup "$provider_failure_root" dnf4 "$target_disk" \
        2>"$tmpdir/provider-error"; then
    printf 'provider installation failure was ignored\n' >&2
    exit 1
else
    status=$?
    [ "$status" -ne 0 ]
    [ ! -e "$provider_failure_root/usr/local/sbin/reinstall-grub-install" ]
    [ ! -e "$provider_failure_root/etc/dnf/plugins/post-transaction-actions.d/reinstall-grub.action" ]
    grep -F 'failed to install' "$tmpdir/provider-error" >/dev/null
fi
printf 'CHECKPOINT grub-hook/provider-failure: failed provider installation leaves no hook artifacts\n'

device_root="$tmpdir/device-root"
by_id="$tmpdir/by-id"
fakebin="$tmpdir/lsblk-bin"
mkdir -p "$device_root" "$by_id" "$fakebin"
: >"$device_root/disk"
ln -s "$device_root/disk" "$by_id/ata-disk"
ln -s "$device_root/disk" "$by_id/scsi-disk"
ln -s "$device_root/disk" "$by_id/wwn-z-disk"
ln -s "$device_root/disk" "$by_id/wwn-a-disk"
ln -s "$device_root/disk" "$by_id/ata-disk-part1"
cat >"$fakebin/lsblk" <<'EOF'
#!/bin/sh
field=$2
device=$3
case $field in
    TYPE)
        case $device in
            "$DISK_TEST_DEVICE") printf 'disk\n' ;;
            *) exit 1 ;;
        esac
        ;;
    TRAN)
        case $device in
            "$DISK_TEST_DEVICE") printf '%s\n' "$DISK_TEST_TRAN" ;;
            *) exit 1 ;;
        esac
        ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$fakebin/lsblk"
resolved=$(DISK_TEST_DEVICE="$device_root/disk" DISK_TEST_TRAN=sata PATH="$fakebin:$PATH" \
    reinstall_grub_hook_resolve_by_id_disk "$device_root/disk" "$by_id")
[ "$resolved" = /dev/disk/by-id/wwn-a-disk ]

ata_priority_by_id="$tmpdir/by-id-ata-priority"
ata_priority_device="$device_root/ata-priority-disk"
mkdir -p "$ata_priority_by_id"
: >"$ata_priority_device"
ln -s "$ata_priority_device" "$ata_priority_by_id/virtio-disk"
ln -s "$ata_priority_device" "$ata_priority_by_id/ata-disk"
resolved=$(DISK_TEST_DEVICE="$ata_priority_device" DISK_TEST_TRAN=sata PATH="$fakebin:$PATH" \
    reinstall_grub_hook_resolve_by_id_disk "$ata_priority_device" "$ata_priority_by_id")
[ "$resolved" = /dev/disk/by-id/ata-disk ]

scsi_device="$device_root/sdb"
scsi_by_id="$tmpdir/by-id-scsi"
mkdir -p "$scsi_by_id"
: >"$scsi_device"
ln -s "$scsi_device" "$scsi_by_id/ata-Model_Serial"
if DISK_TEST_DEVICE="$scsi_device" DISK_TEST_TRAN=scsi PATH="$fakebin:$PATH" \
    reinstall_grub_hook_resolve_by_id_disk "$scsi_device" "$scsi_by_id"; then
    printf 'resolver accepted an Alpine-only ATA alias for a SCSI disk\n' >&2
    exit 1
fi
ln -s "$scsi_device" "$scsi_by_id/scsi-3500000000000001"
resolved=$(DISK_TEST_DEVICE="$scsi_device" DISK_TEST_TRAN=scsi PATH="$fakebin:$PATH" \
    reinstall_grub_hook_resolve_by_id_disk "$scsi_device" "$scsi_by_id")
[ "$resolved" = /dev/disk/by-id/scsi-3500000000000001 ]

sysfs_class_block="$tmpdir/sys-class-block"
mkdir -p "$sysfs_class_block/nvme0n1"
printf '1\n' >"$sysfs_class_block/nvme0n1/nsid"
for fallback_name in virtio-only nvme-Model_Serial; do
    fallback_by_id="$tmpdir/by-id-$fallback_name"
    case $fallback_name in
        virtio-only) fallback_device="$device_root/vda"; fallback_transport=virtio ;;
        nvme-Model_Serial) fallback_device="$device_root/nvme0n1"; fallback_transport=nvme ;;
    esac
    mkdir -p "$fallback_by_id"
    : >"$fallback_device"
    ln -s "$fallback_device" "$fallback_by_id/$fallback_name"
    resolved=$(DISK_TEST_DEVICE="$fallback_device" DISK_TEST_TRAN="$fallback_transport" PATH="$fakebin:$PATH" \
        reinstall_grub_hook_resolve_by_id_disk "$fallback_device" "$fallback_by_id" "$sysfs_class_block")
    [ "$resolved" = "/dev/disk/by-id/$fallback_name" ]
    if [ "$fallback_name" = virtio-only ]; then
        ln -s "$fallback_device" "$fallback_by_id/nvme-Model_Serial"
        resolved=$(DISK_TEST_DEVICE="$fallback_device" DISK_TEST_TRAN="$fallback_transport" PATH="$fakebin:$PATH" \
            reinstall_grub_hook_resolve_by_id_disk "$fallback_device" "$fallback_by_id" "$sysfs_class_block")
        [ "$resolved" = /dev/disk/by-id/virtio-only ]
    fi
done
nvme_secondary_device="$device_root/nvme1n1"
nvme_secondary_by_id="$tmpdir/by-id-nvme-secondary"
mkdir -p "$nvme_secondary_by_id" "$sysfs_class_block/nvme1n1"
: >"$nvme_secondary_device"
printf '2\n' >"$sysfs_class_block/nvme1n1/nsid"
ln -s "$nvme_secondary_device" "$nvme_secondary_by_id/nvme-Model_Serial"
if DISK_TEST_DEVICE="$nvme_secondary_device" DISK_TEST_TRAN=nvme PATH="$fakebin:$PATH" \
    reinstall_grub_hook_resolve_by_id_disk \
        "$nvme_secondary_device" "$nvme_secondary_by_id" "$sysfs_class_block"; then
    printf 'resolver accepted a serial-only NVMe alias for a non-primary namespace\n' >&2
    exit 1
fi
if DISK_TEST_DEVICE="$device_root/disk" DISK_TEST_TRAN=sata PATH="$fakebin:$PATH" \
    reinstall_grub_hook_resolve_by_id_disk "$device_root/disk" "$tmpdir/empty-by-id"; then
    printf 'resolver accepted a disk with no by-id identity\n' >&2
    exit 1
fi
printf 'CHECKPOINT grub-hook/by-id: preferred whole-disk identity chosen; missing by-id identity rejected\n'

printf 'PASS GRUB hook tests\n'
