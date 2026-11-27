# syntax=docker/dockerfile:1.7

ARG NODE_IMAGE=docker.io/library/node:24.22.3-bookworm-slim
ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.9.11

FROM ${UV_IMAGE} AS uv

FROM ${NODE_IMAGE} AS toolchain
ARG PNPM_VERSION=11.28.5
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*

COPY --from=uv /uv /uvx /usr/local/bin/
RUN npm install --global "pnpm@${PNPM_VERSION}" \
    && npm cache clean --force

FROM toolchain AS base
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash bubblewrap chromium curl ffmpeg fontconfig fonts-noto-cjk git gosu jq \
        openssh-client ripgrep tini tzdata unzip util-linux zip \
    && rm -rf /var/lib/apt/lists/*

COPY python/requirements.lock /tmp/dsh-python-requirements.txt
RUN uv venv --python /usr/bin/python3 /opt/dsh-python \
    && uv pip install --python /opt/dsh-python/bin/python --require-hashes \
        --requirements /tmp/dsh-python-requirements.txt \
    && rm /tmp/dsh-python-requirements.txt

FROM base AS dependencies
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*
COPY core/ /opt/dsh/
RUN --mount=type=cache,target=/home/node/.local/share/pnpm/store \
    pnpm --dir /opt/dsh install --prod --frozen-lockfile \
        --store-dir /home/node/.local/share/pnpm/store

COPY profiles/web/ /opt/dsh-seed/profiles/web/
RUN --mount=type=cache,target=/home/node/.local/share/pnpm/store \
    pnpm --dir /opt/dsh-seed/profiles/web install --prod --frozen-lockfile \
        --store-dir /home/node/.local/share/pnpm/store

COPY scripts/prepare-profile.mjs /usr/local/lib/dsh-docker/prepare-profile.mjs
RUN node /usr/local/lib/dsh-docker/prepare-profile.mjs \
    && /opt/dsh/node_modules/.bin/dsh --version \
    && /opt/dsh/node_modules/.bin/mnemon --version \
    && /opt/dsh/node_modules/.bin/agent-browser --version \
    && DSH_HOME=/opt/dsh-seed DSH_AGENTS_HOME=/tmp/dsh-build-agents \
        /opt/dsh/node_modules/.bin/dsh web --dump-config \
        > /opt/dsh-image/default-config.yml

FROM base AS runtime
LABEL org.opencontainers.image.title="deepseek-harness with mnemon and IM" \
      org.opencontainers.image.description="DSH Web with a persistent /home/node and preinstalled plugins" \
      org.opencontainers.image.licenses="MIT"

ENV HOME=/home/node \
    DSH_HOME=/home/node/.dsh \
    DSH_AGENTS_HOME=/home/node/.agents \
    MNEMON_DATA_DIR=/home/node/.mnemon \
    PNPM_HOME=/home/node/.local/share/pnpm \
    NPM_CONFIG_PREFIX=/home/node/.local \
    XDG_CONFIG_HOME=/home/node/.config \
    XDG_DATA_HOME=/home/node/.local/share \
    XDG_CACHE_HOME=/home/node/.cache \
    UV_CACHE_DIR=/home/node/.cache/uv \
    AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/chromium \
    PATH=/opt/dsh/node_modules/.bin:/opt/dsh-python/bin:/home/node/.local/bin:/home/node/.local/share/pnpm:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    DSH_BIND_HOST=auto \
    DSH_PORT=3080 \
    TZ=Asia/Shanghai

COPY --from=dependencies /opt/dsh/ /opt/dsh/
COPY --from=dependencies /opt/dsh-seed/ /opt/dsh-seed/
COPY --from=dependencies /opt/dsh-image/ /opt/dsh-image/
COPY scripts/entrypoint.sh /usr/local/bin/dsh-entrypoint
COPY scripts/web-options.mjs scripts/healthcheck.mjs /usr/local/lib/dsh-docker/
COPY LICENSE /usr/local/share/licenses/dsh-docker/LICENSE

WORKDIR /home/node/workspaces/default
RUN chmod 0755 /usr/local/bin/dsh-entrypoint \
    && chown -R node:node /home/node

VOLUME ["/home/node"]
EXPOSE 3080
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD ["node", "/usr/local/lib/dsh-docker/healthcheck.mjs"]

# The entrypoint initializes volume permissions, then execs as node.
USER root
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/dsh-entrypoint"]
CMD ["web"]
