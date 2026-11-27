#!/usr/bin/env bash
set -Eeuo pipefail

repository_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
container_engine="${CONTAINER_ENGINE:-docker}"
node_image="${NODE_IMAGE:-docker.io/library/node:24.22.3-bookworm-slim}"
uv_image="${UV_IMAGE:-ghcr.io/astral-sh/uv:0.9.11}"
pnpm_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["packageManager"].split("@", 1)[1])' "$repository_directory/core/package.json")"
tools_image="${LOCK_TOOLS_IMAGE:-dsh-docker:lock-tools}"
build_options=(--target toolchain --tag "$tools_image"
    --build-arg "NODE_IMAGE=$node_image" --build-arg "UV_IMAGE=$uv_image"
    --build-arg "PNPM_VERSION=$pnpm_version")
run_options=(--rm --user "$(id -u):$(id -g)" --tmpfs /tmp:rw,exec,mode=1777)
if [[ -n "${CONTAINER_NETWORK:-}" ]]; then
    build_options+=(--network "$CONTAINER_NETWORK")
    run_options+=(--network "$CONTAINER_NETWORK")
fi
mount_specification="$repository_directory:/repo"
if [[ "$(basename -- "$container_engine")" == podman ]]; then
    build_options+=(--format docker)
    run_options+=(--userns=keep-id)
    mount_specification+=:Z
fi

"$container_engine" build "${build_options[@]}" "$repository_directory"

"$container_engine" run "${run_options[@]}" \
    --env XDG_CACHE_HOME=/tmp/dsh-lock-cache \
    --env XDG_DATA_HOME=/tmp/dsh-lock-data \
    --env PNPM_HOME=/tmp/dsh-lock-pnpm \
    --env UV_CACHE_DIR=/tmp/dsh-uv-cache \
    --volume "$mount_specification" --entrypoint /bin/bash "$tools_image" \
    -euc '
        pnpm --dir /repo/core install --lockfile-only --store-dir /tmp/dsh-pnpm-store
        pnpm --dir /repo/profiles/web install --lockfile-only --store-dir /tmp/dsh-pnpm-store
        uv --quiet pip compile --python /usr/bin/python3 --generate-hashes \
            /repo/python/requirements.in --output-file /repo/python/requirements.lock
    ' dsh-lock
