#!/bin/sh
# shellcheck shell=dash

# Return the package-manager hook profile for a verified distro/release pair.
# Empty output deliberately means that the caller should not install a hook.
reinstall_grub_hook_profile_for_os() {
    [ "$#" -eq 2 ] || return 2

    case "$1:$2" in
        arch:*) printf '%s\n' pacman ;;
        gentoo:*) printf '%s\n' portage ;;
        fedora:43|fedora:44) printf '%s\n' dnf5 ;;
        anolis:7) printf '%s\n' yum3 ;;
        anolis:8|anolis:23) printf '%s\n' dnf4 ;;
        almalinux:8|almalinux:9|almalinux:10|\
        rocky:8|rocky:9|rocky:10|\
        openeuler:20.03|openeuler:22.03|openeuler:24.03|\
        opencloudos:23) printf '%s\n' dnf4 ;;
        *) : ;;
    esac
}

# Resolve a selected device (or one of its partitions) to a whole-disk by-id
# alias that the target's device rules will recreate. Optional directory roots
# are test seams; the returned identity is always /dev/disk/by-id.
reinstall_grub_hook_resolve_by_id_disk() {
    [ "$#" -ge 1 ] && [ "$#" -le 3 ] || return 2
    local _reinstall_grub_device=$1
    local _reinstall_grub_by_id_dir=${2:-/dev/disk/by-id}
    local _reinstall_grub_sysfs_class_block=${3:-/sys/class/block}
    local _reinstall_grub_type _reinstall_grub_parent _reinstall_grub_disk
    local _reinstall_grub_real_disk _reinstall_grub_candidate _reinstall_grub_real_candidate
    local _reinstall_grub_name _reinstall_grub_rank _reinstall_grub_best_rank=99
    local _reinstall_grub_best_name _reinstall_grub_lex_first
    local _reinstall_grub_transport _reinstall_grub_device_name _reinstall_grub_nsid _reinstall_grub_nsid_file
    _reinstall_grub_best_name=

    _reinstall_grub_type=$(lsblk -dnro TYPE "$_reinstall_grub_device" 2>/dev/null) || return 1
    case $_reinstall_grub_type in
        disk) _reinstall_grub_disk=$_reinstall_grub_device ;;
        part)
            _reinstall_grub_parent=$(lsblk -dnro PKNAME "$_reinstall_grub_device" 2>/dev/null) || return 1
            [ -n "$_reinstall_grub_parent" ] || return 1
            _reinstall_grub_disk=/dev/$_reinstall_grub_parent
            _reinstall_grub_type=$(lsblk -dnro TYPE "$_reinstall_grub_disk" 2>/dev/null) || return 1
            [ "$_reinstall_grub_type" = disk ] || return 1
            ;;
        *) return 1 ;;
    esac

    _reinstall_grub_real_disk=$(readlink -f "$_reinstall_grub_disk" 2>/dev/null) || return 1
    [ -n "$_reinstall_grub_real_disk" ] || return 1
    _reinstall_grub_device_name=${_reinstall_grub_real_disk##*/}
    _reinstall_grub_transport=$(lsblk -dnro TRAN "$_reinstall_grub_disk" 2>/dev/null) ||
        _reinstall_grub_transport=
    [ -d "$_reinstall_grub_by_id_dir" ] || return 1

    for _reinstall_grub_candidate in "$_reinstall_grub_by_id_dir"/*; do
        [ -L "$_reinstall_grub_candidate" ] || continue
        _reinstall_grub_name=${_reinstall_grub_candidate##*/}
        case $_reinstall_grub_name in
            wwn-*|nvme-eui.*|nvme-uuid.*) _reinstall_grub_rank=0 ;;
            ata-*)
                case $_reinstall_grub_transport in
                    ata|sata) _reinstall_grub_rank=1 ;;
                    *) continue ;;
                esac
                ;;
            scsi-*)
                case $_reinstall_grub_transport in
                    ata|sata|scsi|sas|iscsi|fc) _reinstall_grub_rank=1 ;;
                    *) continue ;;
                esac
                ;;
            virtio-*)
                case $_reinstall_grub_device_name in vd*) _reinstall_grub_rank=2 ;; *) continue ;; esac
                ;;
            nvme-*)
                case $_reinstall_grub_device_name in nvme[0-9]*n[0-9]*) ;; *) continue ;; esac
                _reinstall_grub_nsid=
                for _reinstall_grub_nsid_file in \
                    "$_reinstall_grub_sysfs_class_block/$_reinstall_grub_device_name/nsid" \
                    "$_reinstall_grub_sysfs_class_block/$_reinstall_grub_device_name/device/nsid"; do
                    if [ -r "$_reinstall_grub_nsid_file" ]; then
                        _reinstall_grub_nsid=$(cat "$_reinstall_grub_nsid_file") || return 1
                        break
                    fi
                done
                [ "$_reinstall_grub_nsid" = 1 ] || continue
                _reinstall_grub_rank=2
                ;;
            mmc-*)
                case $_reinstall_grub_device_name in mmcblk[0-9]*) _reinstall_grub_rank=2 ;; *) continue ;; esac
                ;;
            *) continue ;;
        esac
        case $_reinstall_grub_name in
            ''|*/*|*[!A-Za-z0-9._:+-]*) continue ;;
        esac
        case $_reinstall_grub_name in *-part[0-9]*) continue ;; esac

        _reinstall_grub_real_candidate=$(readlink -f "$_reinstall_grub_candidate" 2>/dev/null) || continue
        [ "$_reinstall_grub_real_candidate" = "$_reinstall_grub_real_disk" ] || continue

        if [ "$_reinstall_grub_rank" -lt "$_reinstall_grub_best_rank" ] || {
            [ "$_reinstall_grub_rank" -eq "$_reinstall_grub_best_rank" ] &&
                { [ -z "$_reinstall_grub_best_name" ] ||
                    _reinstall_grub_lex_first=$(printf '%s\n%s\n' \
                        "$_reinstall_grub_name" "$_reinstall_grub_best_name" |
                        LC_ALL=C sort | sed -n '1p') &&
                    [ "$_reinstall_grub_name" = "$_reinstall_grub_lex_first" ]; }
        }; then
            _reinstall_grub_best_rank=$_reinstall_grub_rank
            _reinstall_grub_best_name=$_reinstall_grub_name
        fi
    done

    [ -n "$_reinstall_grub_best_name" ] || return 1
    printf '/dev/disk/by-id/%s\n' "$_reinstall_grub_best_name"
}

_reinstall_grub_hook_atomic_write() {
    [ "$#" -eq 2 ] || return 2
    local _reinstall_grub_file="$1"
    local _reinstall_grub_mode="$2"
    local _reinstall_grub_tmp="${_reinstall_grub_file}.tmp.$$"

    if ! (umask 022; cat >"$_reinstall_grub_tmp"); then
        rm -f "$_reinstall_grub_tmp"
        return 1
    fi
    if ! chmod "$_reinstall_grub_mode" "$_reinstall_grub_tmp" ||
        ! mv -f "$_reinstall_grub_tmp" "$_reinstall_grub_file"; then
        rm -f "$_reinstall_grub_tmp"
        return 1
    fi
}

_reinstall_grub_hook_write_portage_bashrc() {
    [ "$#" -eq 1 ] || return 2
    local _reinstall_grub_file="$1"
    local _reinstall_grub_tmp="${_reinstall_grub_file}.tmp.$$"
    local _reinstall_grub_mode=644

    if [ -f "$_reinstall_grub_file" ]; then
        _reinstall_grub_mode=$(stat -c '%a' "$_reinstall_grub_file") || return 1
        if ! awk \
            -v begin='# BEGIN reinstall-grub-update-hook' \
            -v end='# END reinstall-grub-update-hook' '
            $0 == begin { if (inside) { bad = 1; exit 2 }; inside = 1; next }
            $0 == end { if (!inside) { bad = 1; exit 2 }; inside = 0; next }
            !inside { print }
            END { if (inside || bad) exit 2 }
        ' "$_reinstall_grub_file" >"$_reinstall_grub_tmp"; then
            rm -f "$_reinstall_grub_tmp"
            printf 'reinstall-grub hook: malformed managed block in %s\n' "$_reinstall_grub_file" >&2
            return 1
        fi
    else
        : >"$_reinstall_grub_tmp" || return 1
    fi

    if ! cat >>"$_reinstall_grub_tmp" <<'EOF'
# BEGIN reinstall-grub-update-hook
if [ "${_REINSTALL_GRUB_POST_PKG_POSTINST_WRAPPED-}" != yes ]; then
    if declare -f post_pkg_postinst >/dev/null 2>&1; then
        eval "$(declare -f post_pkg_postinst | sed '1s/^post_pkg_postinst[[:space:]]*()/_reinstall_grub_previous_post_pkg_postinst ()/')"
    fi
    post_pkg_postinst() {
        if declare -f _reinstall_grub_previous_post_pkg_postinst >/dev/null 2>&1; then
            _reinstall_grub_previous_post_pkg_postinst "$@" || return $?
        fi
        if [ "${CATEGORY-}" = sys-boot ] && [ "${PN-}" = grub ]; then
            /usr/local/sbin/reinstall-grub-install || return $?
        fi
    }
    _REINSTALL_GRUB_POST_PKG_POSTINST_WRAPPED=yes
fi
# END reinstall-grub-update-hook
EOF
    then
        rm -f "$_reinstall_grub_tmp"
        return 1
    fi

    if ! chmod "$_reinstall_grub_mode" "$_reinstall_grub_tmp" ||
        ! mv -f "$_reinstall_grub_tmp" "$_reinstall_grub_file"; then
        rm -f "$_reinstall_grub_tmp"
        return 1
    fi
}

# Write the shared runner and profile-specific hook without installing any
# package-manager providers. Call setup below when optional providers apply.
reinstall_grub_hook_write() {
    [ "$#" -eq 3 ] || return 2
    local _reinstall_grub_root="$1"
    local _reinstall_grub_profile="$2"
    local _reinstall_grub_disk="$3"
    local _reinstall_grub_runner="$_reinstall_grub_root/usr/local/sbin/reinstall-grub-install"
    local _reinstall_grub_default_bin _reinstall_grub_hook _reinstall_grub_dir

    [ -d "$_reinstall_grub_root" ] || return 2
    case $_reinstall_grub_disk in
        /dev/disk/by-id/*) ;;
        *) printf 'reinstall-grub hook: expected a /dev/disk/by-id whole-disk path\n' >&2; return 2 ;;
    esac
    case ${_reinstall_grub_disk#/dev/disk/by-id/} in
        ''|*/*|*[!A-Za-z0-9._:+-]*)
            printf 'reinstall-grub hook: invalid by-id disk path\n' >&2
            return 2
            ;;
    esac

    case $_reinstall_grub_profile in
        pacman) _reinstall_grub_default_bin=/usr/bin/grub-install ;;
        portage) _reinstall_grub_default_bin=/usr/sbin/grub-install ;;
        dnf4|dnf5|yum3) _reinstall_grub_default_bin=/usr/sbin/grub2-install ;;
        *) printf 'reinstall-grub hook: unsupported profile %s\n' "$_reinstall_grub_profile" >&2; return 2 ;;
    esac

    _reinstall_grub_dir=${_reinstall_grub_runner%/*}
    mkdir -p "$_reinstall_grub_dir" || return 1
    if ! {
        cat <<EOF
#!/bin/sh
_reinstall_grub_install_bin=\${REINSTALL_GRUB_INSTALL_BIN:-$_reinstall_grub_default_bin}
_reinstall_grub_disk='$_reinstall_grub_disk'
if "\$_reinstall_grub_install_bin" --target=i386-pc "\$_reinstall_grub_disk"; then
    exit 0
else
    _reinstall_grub_status=\$?
    printf 'reinstall-grub hook: %s failed with status %s\\n' "\$_reinstall_grub_install_bin" "\$_reinstall_grub_status" >&2
    exit "\$_reinstall_grub_status"
fi
EOF
    } | _reinstall_grub_hook_atomic_write "$_reinstall_grub_runner" 755; then
        printf 'reinstall-grub hook: failed writing runner under %s\n' "$_reinstall_grub_root" >&2
        return 1
    fi

    case $_reinstall_grub_profile in
        pacman)
            _reinstall_grub_hook=$_reinstall_grub_root/etc/pacman.d/hooks/reinstall-grub.hook
            _reinstall_grub_dir=${_reinstall_grub_hook%/*}
            mkdir -p "$_reinstall_grub_dir" || return 1
            if ! {
                cat <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = grub

[Action]
Description = Reinstall BIOS GRUB on the installation disk
When = PostTransaction
Exec = /usr/local/sbin/reinstall-grub-install
EOF
            } | _reinstall_grub_hook_atomic_write "$_reinstall_grub_hook" 644; then
                printf 'reinstall-grub hook: failed writing pacman hook\n' >&2
                return 1
            fi
            ;;
        portage)
            _reinstall_grub_hook=$_reinstall_grub_root/etc/portage/bashrc
            _reinstall_grub_dir=${_reinstall_grub_hook%/*}
            mkdir -p "$_reinstall_grub_dir" || return 1
            _reinstall_grub_hook_write_portage_bashrc "$_reinstall_grub_hook" || return 1
            ;;
        dnf4)
            _reinstall_grub_hook=$_reinstall_grub_root/etc/dnf/plugins/post-transaction-actions.d/reinstall-grub.action
            _reinstall_grub_dir=${_reinstall_grub_hook%/*}
            mkdir -p "$_reinstall_grub_dir" || return 1
            if ! {
                printf '%s\n' 'grub2*:in:/usr/local/sbin/reinstall-grub-install'
            } | _reinstall_grub_hook_atomic_write "$_reinstall_grub_hook" 644; then
                printf 'reinstall-grub hook: failed writing dnf4 action\n' >&2
                return 1
            fi
            ;;
        dnf5)
            _reinstall_grub_hook=$_reinstall_grub_root/etc/dnf/libdnf5-plugins/actions.d/reinstall-grub.actions
            _reinstall_grub_dir=${_reinstall_grub_hook%/*}
            mkdir -p "$_reinstall_grub_dir" || return 1
            if ! {
                printf '%s\n' 'post_transaction:grub2*:in:raise_error=1:/usr/local/sbin/reinstall-grub-install'
            } | _reinstall_grub_hook_atomic_write "$_reinstall_grub_hook" 644; then
                printf 'reinstall-grub hook: failed writing dnf5 action\n' >&2
                return 1
            fi
            ;;
        yum3)
            _reinstall_grub_hook=$_reinstall_grub_root/etc/yum/post-actions/reinstall-grub.action
            _reinstall_grub_dir=${_reinstall_grub_hook%/*}
            mkdir -p "$_reinstall_grub_dir" || return 1
            if ! {
                printf '%s\n' \
                    'grub2*:install:/usr/local/sbin/reinstall-grub-install' \
                    'grub2*:update:/usr/local/sbin/reinstall-grub-install'
            } | _reinstall_grub_hook_atomic_write "$_reinstall_grub_hook" 644; then
                printf 'reinstall-grub hook: failed writing yum3 action\n' >&2
                return 1
            fi
            ;;
    esac
}

reinstall_grub_hook_install_provider() {
    [ "$#" -eq 2 ] || return 2
    local _reinstall_grub_root="$1"
    local _reinstall_grub_profile="$2"
    local _reinstall_grub_manager _reinstall_grub_package

    case $_reinstall_grub_profile in
        pacman|portage) return 0 ;;
        dnf5)
            _reinstall_grub_manager=dnf5
            _reinstall_grub_package=libdnf5-plugin-actions
            ;;
        dnf4)
            _reinstall_grub_manager=dnf
            _reinstall_grub_package=python3-dnf-plugin-post-transaction-actions
            ;;
        yum3)
            _reinstall_grub_manager=yum
            _reinstall_grub_package=yum-plugin-post-transaction-actions
            ;;
        *) printf 'reinstall-grub hook: unsupported profile %s\n' "$_reinstall_grub_profile" >&2; return 2 ;;
    esac

    if ! chroot "$_reinstall_grub_root" "$_reinstall_grub_manager" -y install "$_reinstall_grub_package"; then
        printf 'reinstall-grub hook: failed to install %s provider in %s\n' \
            "$_reinstall_grub_package" "$_reinstall_grub_root" >&2
        return 1
    fi
}

# Production entry point: do not make the hook live unless any required
# optional package-manager provider was installed successfully.
reinstall_grub_hook_setup() {
    [ "$#" -eq 3 ] || return 2
    reinstall_grub_hook_install_provider "$1" "$2" || return $?
    reinstall_grub_hook_write "$1" "$2" "$3"
}
