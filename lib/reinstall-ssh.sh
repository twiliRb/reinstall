# shellcheck shell=sh
# Write an SSH public-key file into a target filesystem without interpreting
# its contents. User homes must be canonical absolute paths within target-root.
reinstall_ssh_path_has_symlink() (
    target_root=$1
    path=$2
    while [ "$target_root" != / ] && [ "${target_root%/}" != "$target_root" ]; do
        target_root=${target_root%/}
    done

    remaining=${path#/}
    current=$target_root
    while [ -n "$remaining" ]; do
        component=${remaining%%/*}
        if [ "$current" = / ]; then
            current=/$component
        else
            current=$current/$component
        fi
        [ -L "$current" ] && return 0
        case "$remaining" in
            */*) remaining=${remaining#*/} ;;
            *) remaining= ;;
        esac
    done
    return 1
)

reinstall_ssh_write_authorized_keys() (
    umask 077

    [ "$#" -eq 3 ] || return 2
    target_root=$1
    user_home=$2
    key_file=$3

    [ -d "$target_root" ] || return 1
    [ -f "$key_file" ] && [ -r "$key_file" ] || return 1

    case "$user_home" in
        /*) ;;
        *) return 1 ;;
    esac
    case "$user_home" in
        /|*/|*//*|*/./*|*/.|*/../*|*/..) return 1 ;;
    esac
    reinstall_ssh_path_has_symlink "$target_root" "$user_home" && return 1

    case "$target_root" in
        /) home_dir=$user_home ;;
        */) home_dir=${target_root%/}$user_home ;;
        *) home_dir=$target_root$user_home ;;
    esac
    ssh_dir=$home_dir/.ssh
    authorized_keys=$ssh_dir/authorized_keys

    # Do not let an existing target symlink redirect writes outside target-root.
    if [ -L "$home_dir" ] || [ -L "$ssh_dir" ] || [ -L "$authorized_keys" ]; then
        return 1
    fi

    mkdir -p "$home_dir" || return 1
    if [ ! -d "$ssh_dir" ]; then
        mkdir "$ssh_dir" || return 1
    fi
    [ -d "$ssh_dir" ] && [ ! -L "$ssh_dir" ] || return 1
    chmod 700 "$ssh_dir" || return 1

    if [ -e "$authorized_keys" ]; then
        [ -f "$authorized_keys" ] || return 1
        chmod 600 "$authorized_keys" || return 1
    else
        : >"$authorized_keys" || return 1
        chmod 600 "$authorized_keys" || return 1
    fi

    cat "$key_file" >"$authorized_keys" || return 1
    chmod 600 "$authorized_keys"
)
