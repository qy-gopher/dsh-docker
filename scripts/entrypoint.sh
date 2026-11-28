#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

dsh_user_home="${HOME:-/home/node}"
if [[ "$dsh_user_home" != /* || "$dsh_user_home" == / ]]; then
    printf 'dsh-docker: HOME must be an absolute user-home directory.\n' >&2
    exit 1
fi

export DSH_HOME="${DSH_HOME:-$dsh_user_home/.dsh}"
export DSH_AGENTS_HOME="${DSH_AGENTS_HOME:-$dsh_user_home/.agents}"
export MNEMON_DATA_DIR="${MNEMON_DATA_DIR:-$dsh_user_home/.mnemon}"

managed_directories=(
    "$dsh_user_home"
    "$DSH_HOME" "$DSH_HOME/profiles"
    "$DSH_AGENTS_HOME" "$DSH_AGENTS_HOME/skills"
    "$MNEMON_DATA_DIR"
    "$dsh_user_home/.config" "$dsh_user_home/.cache"
    "$dsh_user_home/.local" "$dsh_user_home/.local/bin"
    "$dsh_user_home/.local/share" "$dsh_user_home/.local/share/pnpm"
    "$dsh_user_home/workspaces" "$dsh_user_home/workspaces/default"
)

if [[ "$(id -u)" == 0 ]]; then
    mkdir -p -- "${managed_directories[@]}"
    chown --no-dereference node:node -- "${managed_directories[@]}"
    if [[ "$PWD" == "$dsh_user_home"/workspaces/* && -d "$PWD" ]]; then
        chown --no-dereference node:node -- "$PWD"
    fi
    if [[ "${DSH_FIX_PERMISSIONS:-0}" == 1 ]]; then
        chown -R --no-dereference node:node -- "$dsh_user_home"
    fi
    exec gosu node /usr/local/bin/dsh-entrypoint "$@"
fi

mkdir -p -- "${managed_directories[@]}"
seed_directory="${DSH_SEED_DIR:-/opt/dsh-seed/profiles/web}"
profile_directory="$DSH_HOME/profiles/web"
staging_directory=''
arguments_file=''

cleanup() {
    if [[ -n "$staging_directory" ]]; then
        rm -rf -- "$staging_directory"
    fi
    if [[ -n "$arguments_file" ]]; then
        rm -f -- "$arguments_file"
    fi
}
trap cleanup EXIT

# Release the initialization lock before starting the long-lived application.
exec 9>"$DSH_HOME/profiles/.dsh-docker-init.lock"
flock -x 9
if [[ ! -f "$profile_directory/package.json" ]]; then
    if [[ -e "$profile_directory" || -L "$profile_directory" ]]; then
        if [[ ! -d "$profile_directory" || -L "$profile_directory" ]] \
            || [[ -n "$(find "$profile_directory" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
            printf 'dsh-docker: existing web profile has no package.json; repair it before restarting: %s\n' "$profile_directory" >&2
            exit 1
        fi
        rmdir -- "$profile_directory"
    fi
    if [[ ! -f "$seed_directory/package.json" || ! -d "$seed_directory/node_modules" ]]; then
        printf 'dsh-docker: the image has no complete preinstalled web profile.\n' >&2
        exit 1
    fi
    staging_directory="$(mktemp -d "$DSH_HOME/profiles/.web-init.XXXXXX")"
    cp -R --preserve=mode,timestamps,links --no-dereference \
        "$seed_directory/." "$staging_directory/"
    mv -- "$staging_directory" "$profile_directory"
    staging_directory=''
    printf 'dsh-docker: initialized the web profile with preinstalled mnemon and QQ Bot.\n'
fi
flock -u 9
exec 9>&-

if [[ $# == 0 ]]; then
    set -- web
fi
if [[ "$1" == dsh && "${2:-}" == web ]]; then
    shift
fi
if [[ "$1" == web ]]; then
    shift
    arguments_file="$(mktemp "${TMPDIR:-/tmp}/dsh-web-args.XXXXXX")"
    node "${DSH_DOCKER_LIB_DIR:-/usr/local/lib/dsh-docker}/web-options.mjs" > "$arguments_file"
    mapfile -d '' -t web_arguments < "$arguments_file"
    rm -f -- "$arguments_file"
    arguments_file=''
    exec dsh "${web_arguments[@]}" "$@"
fi

exec "$@"
