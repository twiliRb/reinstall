#!/bin/sh

# Emit a POSIX-shell replacement for Alpine 3.24's Bash process substitution.
# The active TTY file is whitespace-delimited. Use BusyBox xargs to preserve
# the previous tokenization while feeding one device per line to the read loop.
reinstall_alpine_active_tty_reader_replacement() {
    cat <<'REINSTALL_ALPINE_TTY_REPLACEMENT'
done <<EOF
$(cat "$ROOT"/sys/class/tty/"$1"/active | xargs -n 1)
EOF
REINSTALL_ALPINE_TTY_REPLACEMENT
}
