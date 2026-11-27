#!/usr/bin/env bash
set -Eeuo pipefail

container_engine="${CONTAINER_ENGINE:-docker}"
test_image="${DSH_TEST_IMAGE:-dsh-docker:local}"
repository_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_identifier="dsh-docker-smoke-$(date +%s)-$$"
test_volume="$test_identifier-home"
test_container="$test_identifier-web"
temporary_directory="$(mktemp -d /tmp/dsh-docker-smoke.XXXXXX)"

print_logs() {
    "$container_engine" logs "$test_container" 2>&1 \
        | sed -E 's@([?&#](token|auth|key)=)[^[:space:]&#]+@\1<redacted>@g' >&2 || true
}
cleanup() {
    local result=$?
    if [[ $result != 0 ]]; then print_logs; fi
    "$container_engine" rm -f "$test_container" >/dev/null 2>&1 || true
    "$container_engine" volume rm "$test_volume" >/dev/null 2>&1 || true
    rm -rf -- "$temporary_directory"
    return "$result"
}
trap cleanup EXIT

start_web() {
    "$container_engine" run -d --name "$test_container" \
        --volume "$test_volume:/home/node" --publish 127.0.0.1::3080 \
        --env DSH_PUBLIC_URL=http://localhost:3080/ \
        --env DSH_TRUSTED_HOSTS=127.0.0.1 \
        --env HTTP_PROXY= --env HTTPS_PROXY= --env ALL_PROXY= \
        --env http_proxy= --env https_proxy= --env all_proxy= \
        "$test_image" >/dev/null
    for attempt in {1..60}; do
        if [[ "$("$container_engine" inspect --format '{{.State.Running}}' "$test_container")" != true ]]; then
            printf 'The Web container exited during startup.\n' >&2
            return 1
        fi
        if "$container_engine" exec --user node "$test_container" \
            node /usr/local/lib/dsh-docker/healthcheck.mjs >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    printf 'The Web UI did not become ready within 60 seconds.\n' >&2
    return 1
}

"$container_engine" volume create "$test_volume" >/dev/null
printf 'Checking a fresh home and Web startup...\n'
start_web
"$container_engine" exec --user node "$test_container" bash -euc '
    test "$(id -u)" = 1000
    test "$HOME" = /home/node
    dsh --version
    mnemon --version
    python -c "import docx, openpyxl, pptx, pypdf"
    node -e '\''const fs=require("node:fs"); const p=JSON.parse(fs.readFileSync(process.env.DSH_HOME+"/profiles/web/package.json")); for(const name of ["dsh-mnemon","@xmanrui/dsh-im"]) { if(!p.dsh.profile.bundles.includes(name)) throw new Error(name+" is disabled"); if(!fs.existsSync(process.env.DSH_HOME+"/profiles/web/node_modules/"+name)) throw new Error(name+" is missing"); }'\''
'
host_port="$("$container_engine" port "$test_container" 3080/tcp | head -n 1)"
python3 "$repository_directory/tests/authenticated_web.py" \
    "$container_engine" "$test_container" "http://$host_port/" "$temporary_directory"

printf 'Installing an additional bundle into the running container...\n'
python3 - "$repository_directory/tests/fixtures/plugin" "$temporary_directory/plugin.tgz" <<'PY'
from pathlib import Path
import sys, tarfile
source = Path(sys.argv[1])
with tarfile.open(sys.argv[2], 'w:gz') as archive:
    for path in sorted(source.iterdir()):
        archive.add(path, arcname='package/' + path.name)
PY
"$container_engine" cp "$temporary_directory/plugin.tgz" "$test_container:/home/node/.dsh/smoke-plugin.tgz"
"$container_engine" exec --user node "$test_container" \
    dsh plugin --profile web add -w file:/home/node/.dsh/smoke-plugin.tgz
"$container_engine" exec --user node "$test_container" bash -euc '
    printf "\n# DSH_DOCKER_USER_CONFIGURATION\n" >> "$DSH_HOME/profiles/web/cordis.patch.yml"
    mkdir -p "$DSH_HOME/integrations/dsh-im"
    printf "persistent IM state\n" > "$DSH_HOME/integrations/dsh-im/docker-smoke-state"
    printf "persistent workspace\n" > "$HOME/workspaces/default/docker-smoke-file"
    mnemon --store docker-smoke remember "DSH_DOCKER_PERSISTENT_MEMORY" --no-diff
'

printf 'Recreating the container with the same home...\n'
"$container_engine" stop --time 45 "$test_container" >/dev/null
"$container_engine" rm "$test_container" >/dev/null
start_web
"$container_engine" exec --user node "$test_container" bash -euc '
    test -f "$DSH_HOME/profiles/web/node_modules/dsh-docker-smoke-plugin/index.mjs"
    node -e '\''const fs=require("node:fs"); const p=JSON.parse(fs.readFileSync(process.env.DSH_HOME+"/profiles/web/package.json")); if(!p.dsh.profile.bundles.includes("dsh-docker-smoke-plugin")) throw new Error("Installed bundle was lost");'\''
    rg --quiet DSH_DOCKER_USER_CONFIGURATION "$DSH_HOME/profiles/web/cordis.patch.yml"
    rg --quiet "persistent IM state" "$DSH_HOME/integrations/dsh-im/docker-smoke-state"
    rg --quiet "persistent workspace" "$HOME/workspaces/default/docker-smoke-file"
    mnemon --store docker-smoke recall DSH_DOCKER_PERSISTENT_MEMORY --basic \
        | rg --quiet DSH_DOCKER_PERSISTENT_MEMORY
'
"$container_engine" logs "$test_container" > "$temporary_directory/recreated.log" 2>&1
rg --quiet DSH_DOCKER_SMOKE_PLUGIN_LOADED "$temporary_directory/recreated.log"
printf 'Smoke test passed: Web, plugins, memory, IM state, and workspace survive container recreation.\n'
