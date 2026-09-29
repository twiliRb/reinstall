#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
config=$repo_root/deprecated/redhat.cfg
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/bin" "$tmpdir/target/boot"
printf '%s\n' 'cpe:/o:fedoraproject:fedora:44' >"$tmpdir/system-release-cpe"
cat >"$tmpdir/cmdline" <<EOF
$(printf '%s ' \
    "$(source "$repo_root/lib/reinstall-cmdline.sh"; reinstall_cmdline_serialize extra_filesystem btrfs)" \
    "$(source "$repo_root/lib/reinstall-cmdline.sh"; reinstall_cmdline_serialize extra_btrfs_target_distro fedora)" \
    "$(source "$repo_root/lib/reinstall-cmdline.sh"; reinstall_cmdline_serialize extra_btrfs_target_releasever 44)" \
    "$(source "$repo_root/lib/reinstall-cmdline.sh"; reinstall_cmdline_serialize extra_btrfs_target_kernel_variant default)")
EOF

cat >"$tmpdir/bin/findmnt" <<'EOF'
#!/bin/sh
case " $* " in
    *' -o FSTYPE '*) printf '%s\n' btrfs ;;
    *) exit 1 ;;
esac
EOF
cat >"$tmpdir/bin/mount" <<'EOF'
#!/bin/sh
printf 'mount %s\n' "$*" >>"$FEDORA_BTRFS_LOG"
EOF
cat >"$tmpdir/bin/chattr" <<'EOF'
#!/bin/sh
printf 'chattr %s\n' "$*" >>"$FEDORA_BTRFS_LOG"
EOF
cat >"$tmpdir/bin/lsattr" <<'EOF'
#!/bin/sh
printf '%s %s\n' '--------m-------' "$3"
EOF
chmod +x "$tmpdir/bin/"*
export PATH="$tmpdir/bin:$PATH"
export FEDORA_BTRFS_LOG=$tmpdir/commands.log

# %post is a fresh shell. Run only its selector prelude and verify that it
# decodes extra_filesystem before deciding whether to configure Btrfs.
awk '
    /^# Kickstart runs each section in a fresh shell\./ { copy = 1 }
    copy && index($0, "if [ \"$filesystem\" = btrfs ]; then") { exit }
    copy { print }
' "$config" | sed "s#/proc/cmdline#$tmpdir/cmdline#g" >"$tmpdir/post-selector.sh"
printf 'printf "%%s\\n" "$filesystem"\n' >>"$tmpdir/post-selector.sh"
[[ "$(bash "$tmpdir/post-selector.sh")" == btrfs ]]

# %pre-install is also independent from %pre. Execute its complete Btrfs
# storage check with local helpers, a private command line and mocked mounts.
awk '
    /^%pre-install / { copy = 1; next }
    copy && /^%end$/ { exit }
    copy { print }
' "$config" |
    sed \
        -e "s#\. /reinstall-cmdline.sh#. \"$repo_root/lib/reinstall-cmdline.sh\"#" \
        -e "s#/proc/cmdline#$tmpdir/cmdline#g" \
        -e "s#</etc/system-release-cpe#<\"$tmpdir/system-release-cpe\"#" \
        -e "s#target_root=/mnt/sysroot#target_root=\"$tmpdir/target\"#" \
        >"$tmpdir/pre-install.sh"
bash -e "$tmpdir/pre-install.sh"
grep -Fq "mount -o remount,compress=zstd $tmpdir/target" "$FEDORA_BTRFS_LOG"
grep -Fq "chattr +m $tmpdir/target/boot" "$FEDORA_BTRFS_LOG"
printf 'CHECKPOINT fedora-btrfs/fresh-shell-sections: %%pre-install identity/options and %%post filesystem selector loaded independently\n'

printf 'PASS Fedora Btrfs adapter tests\n'
