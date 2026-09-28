#!/bin/sh
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
. "$repo_root/lib/reinstall-ssh.sh"

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/reinstall-ssh-test.XXXXXX")
trap 'rm -rf "$tmpdir"' 0

fail() {
    printf 'FAIL ssh-key initialization: %s\n' "$1" >&2
    exit 1
}

assert_mode() {
    path=$1
    expected=$2
    actual=$(stat -c '%a' "$path") || fail "could not read mode for $path"
    [ "$actual" = "$expected" ] || fail "expected mode $expected for $path, got $actual"
}

target_root=$tmpdir/target
mkdir -p "$target_root"
key_file=$tmpdir/keys
marker=$tmpdir/input-was-executed
cat >"$key_file" <<EOF
ssh-ed25519 fixture 'quoted' "\$HOME" "\$(touch '$marker')" \`touch '$marker'\` café
second line is preserved exactly
EOF

(umask 000; reinstall_ssh_write_authorized_keys "$target_root" /root "$key_file") || \
    fail 'root home initialization failed'
root_ssh=$target_root/root/.ssh
root_authorized_keys=$root_ssh/authorized_keys
cmp -s "$key_file" "$root_authorized_keys" || fail 'root authorized_keys differs from source bytes'
assert_mode "$root_ssh" 700
assert_mode "$root_authorized_keys" 600
[ ! -e "$marker" ] || fail 'key input was executed'
printf 'CHECKPOINT ssh/root-home: copied exact bytes; .ssh=0700; authorized_keys=0600; input remained data\n'

(umask 002; reinstall_ssh_write_authorized_keys "$target_root" /home/alice "$key_file") || \
    fail 'regular user home initialization failed'
user_ssh=$target_root/home/alice/.ssh
user_authorized_keys=$user_ssh/authorized_keys
cmp -s "$key_file" "$user_authorized_keys" || fail 'user authorized_keys differs from source bytes'
assert_mode "$user_ssh" 700
assert_mode "$user_authorized_keys" 600

(umask 077; reinstall_ssh_write_authorized_keys "$target_root" /home/alice "$key_file") || \
    fail 'repeat initialization failed'
cmp -s "$key_file" "$user_authorized_keys" || fail 'repeat call changed authorized_keys bytes'
assert_mode "$user_ssh" 700
assert_mode "$user_authorized_keys" 600
printf 'CHECKPOINT ssh/user-home-and-repeat: copied exact bytes; repeated call stayed idempotent; modes remained 0700/0600\n'

for invalid_home in home/alice relative/../escape /home/../root /home//alice /home/alice/; do
    if reinstall_ssh_write_authorized_keys "$target_root" "$invalid_home" "$key_file" >/dev/null 2>&1; then
        fail "accepted invalid home path: $invalid_home"
    fi
done
if reinstall_ssh_write_authorized_keys "$target_root" /home/missing "$tmpdir/not-found" >/dev/null 2>&1; then
    fail 'accepted a missing key source'
fi
mkdir -p "$tmpdir/key-directory"
if reinstall_ssh_write_authorized_keys "$target_root" /home/missing "$tmpdir/key-directory" >/dev/null 2>&1; then
    fail 'accepted a non-regular key source'
fi
[ ! -e "$target_root/home/missing/.ssh" ] || fail 'created target files before rejecting invalid input'

outside_root=$tmpdir/outside-target
mkdir -p "$outside_root"
ln -s "$outside_root" "$target_root/linked-home"
if reinstall_ssh_write_authorized_keys "$target_root" /linked-home/alice "$key_file" >/dev/null 2>&1; then
    fail 'followed a symlinked parent out of target-root'
fi
[ ! -e "$outside_root/alice/.ssh" ] || fail 'wrote through a symlinked parent outside target-root'
printf 'CHECKPOINT ssh/input-validation: rejected relative/traversal/non-canonical homes, symlink escapes, and missing/non-regular sources before writes\n'

printf 'PASS ssh authorized_keys initialization tests\n'
