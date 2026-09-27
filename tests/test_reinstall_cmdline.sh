#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_root/lib/reinstall-cmdline.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

marker="$tmpdir/command-ran"
username="A user 'with quotes' \"double\" \$HOME \`touch $marker\` & 雪"

username_arg=$(reinstall_cmdline_serialize extra_username "$username")
port_arg=$(reinstall_cmdline_serialize extra_ssh_port '2222')
source_sha=0123456789abcdef0123456789abcdef01234567
confhome_arg=$(reinstall_cmdline_serialize extra_confhome \
    "https://raw.githubusercontent.com/twiliRb/reinstall/$source_sha")
printf '%s\n' "root=/dev/vda $username_arg $port_arg $confhome_arg" >"$tmpdir/cmdline"

username=
ssh_port=
confhome=
reinstall_cmdline_load_file "$tmpdir/cmdline" extra

if [[ "$username" != "A user 'with quotes' \"double\" \$HOME \`touch $marker\` & 雪" ]]; then
    printf 'cmdline round-trip mismatch: %q\n' "$username" >&2
    exit 1
fi
[[ "$ssh_port" == 2222 ]]
[[ "$confhome" == "https://raw.githubusercontent.com/twiliRb/reinstall/$source_sha" ]]
[[ ! -e "$marker" ]]

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
    username web_path web_port
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

# GNU getopt's eval round-trip is safe only because getopt shell-quotes every
# argument. Keep this adversarial value as a regression test for that boundary.
opts=$(getopt -o '' --long user: -- --user "$username")
eval "set -- $opts"
[[ $# == 3 && $1 == --user && $2 == "$username" && $3 == -- ]]
[[ ! -e "$marker" ]]

printf 'command-line parser/serializer tests passed\n'
