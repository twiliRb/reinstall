#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo_root/lib/reinstall-btrfs-layout.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' 0 HUP INT TERM

truncate -s 96M "$tmpdir/arch-root.img"
if ! reinstall_ext4_format_root "$tmpdir/arch-root.img" arch >"$tmpdir/mkfs.log" 2>&1; then
    cat "$tmpdir/mkfs.log" >&2
    exit 1
fi
[ "$(blkid -s TYPE -o value "$tmpdir/arch-root.img")" = ext4 ]
[ -z "$(e2label "$tmpdir/arch-root.img")" ]
printf 'CHECKPOINT ext4-format/default-root: type=ext4 label=unchanged\n'

truncate -s 96M "$tmpdir/alpine-root.img"
if ! reinstall_ext4_format_root "$tmpdir/alpine-root.img" alpine >"$tmpdir/mkfs.log" 2>&1; then
    cat "$tmpdir/mkfs.log" >&2
    exit 1
fi
[ "$(blkid -s TYPE -o value "$tmpdir/alpine-root.img")" = ext4 ]
_alpine_features=$(dumpe2fs -h "$tmpdir/alpine-root.img" 2>/dev/null |
    sed -n 's/^Filesystem features:[[:space:]]*//p')
case " $_alpine_features " in
    *' 64bit '*)
        printf 'Alpine ext4 unexpectedly has the 64bit feature\n' >&2
        exit 1
        ;;
esac
printf 'CHECKPOINT ext4-format/alpine-root: type=ext4 64bit=disabled\n'
