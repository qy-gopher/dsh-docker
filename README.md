# dsh-docker

构建预装 dsh-mnemon 和腾讯官方 QQ 机器人插件的 DeepSeek Harness Web 镜像。用户 home 固定为 `/home/node`，插件、配置、记忆、会话、QQ 机器人状态和工作区都通过一个目录持久化。主程序放在 `/opt/dsh`，更换镜像后沿用用户数据。

## 快速启动

需要 Docker Engine 和 Docker Compose v2.24 或更新版本。

默认拉取公开镜像 `ghcr.io/qy-gopher/dsh-docker:latest`，支持 amd64、arm64，Docker 会自动选择当前机器的架构。将 [compose.yaml](compose.yaml) 和 [.env.example](.env.example) 放到部署目录，执行：

```sh
cp .env.example .env
docker compose up -d
docker compose logs -f dsh
```

启动时会拉取最新镜像，用户数据保存到部署目录的 `./data`。

需要固定镜像版本时，修改 `.env` 中的 `DSH_IMAGE`，使用发布的版本标签或 `sha-<完整提交 SHA>` 标签。更新镜像并重建容器：

```sh
docker compose pull
docker compose up -d
```

用日志中打印的完整登录链接进入 DSH，默认访问地址为 `http://localhost:3080/`。API Key 可以填写到 `.env` 的 `DEEPSEEK_API_KEY`，也可以进入 DSH 的模型设置后保存。安装插件、打开界面不需要模型 Key；调用模型需要配置凭据。

启动后，进入“设置 → QQ 机器人”，使用手机 QQ 扫码绑定。机器人凭据保存在持久化 profile 的配置中，机器人状态、媒体与默认工作区保存在 `/home/node/.dsh-qqbot`。

## 镜像内容

| 组件 | 固定版本或内容 |
|---|---|
| 基础镜像 | Node.js `24.22.3` / Debian Bookworm slim |
| pnpm | `11.28.5` |
| DSH | `0.2.2-rc.5` |
| dsh-mnemon | `0.5.55` |
| QQ 机器人插件 | `@tencent-connect/dsh-qqbot@0.5.5` |
| Mnemon CLI | `@mnemon-dev/mnemon@0.2.15` |
| 浏览器自动化 | Debian Chromium、`agent-browser@0.45.0`，支持 amd64、arm64 |
| Python | Debian Python 3.11、uv `0.9.11`、python-docx、openpyxl、python-pptx、pypdf |
| 日常工具 | Bash、Git、SSH、curl、rg、jq、zip/unzip、ffmpeg、中文字体 |
| 运行辅助 | tini、gosu、bubblewrap（`bwrap`，供 DSH 沙箱使用）；保留 DSH 随包交付的原生依赖 |

Node 依赖使用两个提交到仓库的 `pnpm-lock.yaml`；Python 依赖使用包含校验哈希的 `python/requirements.lock`。Python 库安装在镜像的 `/opt/dsh-python` 虚拟环境中，`python` 已加入 PATH。

原生依赖所需的安装脚本在各自的 `pnpm-workspace.yaml` 中明确允许，编译工具只安装到构建阶段。最终镜像使用基础运行阶段和已构建的依赖。

主程序安装必需的 peer 依赖；插件 profile 使用 DSH 的默认策略，复用宿主提供的框架依赖。

镜像默认启用 `web` profile 中的两个插件。Mnemon CLI 单独提供默认本地记忆后端。DSH 的 Office 渲染使用随 npm 依赖交付的 LibreOffice Kit。Chromium 和 agent-browser 在构建时安装，启动后可以直接进行无头浏览器自动化。Chromium 使用 Debian 软件仓库的版本，实际版本记录在 `/opt/dsh-image/versions.json`。

### 浏览器自动化

agent-browser 已加入 PATH，默认通过 `AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/chromium` 使用镜像内的浏览器，无需再执行 `agent-browser install`。例如：

```sh
docker compose exec --user node dsh agent-browser open https://example.com
docker compose exec --user node dsh agent-browser snapshot -i
docker compose exec --user node dsh agent-browser screenshot /home/node/workspaces/default/example.png
docker compose exec --user node dsh agent-browser close
```

不同任务可用 `--session 名称` 隔离浏览器会话。需要跨容器重建保留登录状态时，用 `--profile /home/node/.config/agent-browser/任务名称` 指定持久化浏览器目录；同一目录只供一个活动会话使用。截图、下载和导出的状态文件放到 `/home/node` 下，即可随现有数据目录持久化。代理可以通过 `agent-browser skills get core` 读取与安装版本对应的操作说明。

Compose 为浏览器设置 `1gb` 的 `/dev/shm`。agent-browser 会自动适配 Docker/Podman 中的浏览器沙箱与共享内存限制。使用其他自动化库时，显式指定 `/usr/bin/chromium`；Playwright 的 `chromium.launch()` 需要传入 `executablePath`，容器环境通常还需要 `args: ['--no-sandbox']`。

## 持久化与目录

Compose 把宿主机 `./data` 挂载到容器 `/home/node`。因此容器中的 `~` 就是 `/home/node`：

数据目录挂载使用 `:Z`，为启用 SELinux 的 Docker/Podman 设置私有容器标签。在 Fedora 等系统上，这让容器可以访问宿主机的数据目录；标签由挂载配置处理，文件所有权由入口脚本初始化。

```text
/opt/dsh/                              DSH 主程序和镜像内置依赖
/opt/dsh-seed/profiles/web/             完整预装 profile，供首次初始化
/opt/dsh-image/versions.json            镜像组件版本清单

/home/node/                            持久化 home
├── .dsh/
│   ├── profiles/web/                   用户插件、lockfile、启用列表、配置
│   ├── .credentials.yaml              DSH 管理的凭据
│   ├── sessions/                      会话
│   ├── storages/                      工作区等持久记录
│   └── attachments/                   附件
├── .dsh-qqbot/                        QQ 机器人状态与模型偏好
│   ├── media/                         QQ 媒体附件
│   └── workspace/                     QQ 默认工作区
├── .mnemon/                           记忆、档案、Provider 状态
├── .agents/                           共享 AGENTS.md 与 skills
├── .config/
├── .local/                            用户全局 CLI 与 pnpm 数据
├── .cache/
└── workspaces/
    └── default/                       Web 默认工作区
```

QQ 机器人默认使用 `/home/node/.dsh-qqbot/workspace`。如果希望 QQ 项目也集中在 `workspaces` 下，可以创建 `/home/node/workspaces/qqbot`，然后在插件配置中将 `cwd` 设为该目录。容器内工作区的绝对路径应保持稳定：mnemon 的集中工作区模式根据路径生成存储 ID。

入口脚本先准备持久化目录权限，随后以 `node` 用户（UID/GID `1000:1000`）运行。默认 Compose 保留这一初始化流程；若自行设置 `user: 1000:1000`，需要提前确保挂载目录及工作目录可写。恢复的旧目录如果属于其他 UID，可将 `DSH_FIX_PERMISSIONS=1` 用于一次启动，完成后恢复为 `0`。

### 首次启动和镜像升级

镜像在构建阶段准备完整的预装 profile。首次启动时，入口脚本在锁保护下把它复制到 `.dsh/profiles/web`，保留包目录和相对符号链接，并通过目录重命名完成初始化。已有 profile 的插件、启用列表和配置继续沿用。没有 `package.json` 的非空 profile 会报错并保留文件，便于人工修复。

更换镜像会更新 `/opt/dsh` 中的主程序；数据卷中的插件版本和用户配置保持原状。这样用户自行安装或升级的插件不会被镜像默认版本覆盖。需要升级已有插件时，使用 DSH 插件管理命令。跨 CPU 架构迁移 home 后，平台原生依赖需要在目标架构重新安装。

构建时从固定版本的 mnemon bundle 读取完整默认配置，再将 `remoteAccess` 设置为 `trusted-host`，允许经过 DSH 认证的远程界面管理记忆与设置。这份覆盖只写入首次初始化的 profile。DSH 的 patch 替换整个 `config` 对象，升级 mnemon 后应核对保留的配置与新默认值。

## 安装与更新用户插件

```sh
docker compose exec --user node dsh dsh plugin --profile web add -w 插件完整包名@版本
docker compose restart dsh
```

例如更新预装插件：

```sh
docker compose exec --user node dsh dsh plugin --profile web add -w dsh-mnemon@0.5.55
docker compose exec --user node dsh dsh plugin --profile web add -w @tencent-connect/dsh-qqbot@0.5.5
docker compose restart dsh
```

依赖、lockfile、启用列表和配置都位于持久化 profile 中。其他 profile 的插件需要分别安装。用户通过 `npm install -g` 安装的 CLI 默认放到 `/home/node/.local`；通过 `pnpm add -g` 安装的 CLI 放到持久化的 `PNPM_HOME`。DSH 主程序仍由镜像管理。

已有部署从 dsh-im 切换到腾讯官方插件时，更新镜像和 `compose.yaml` 后执行：

```sh
docker compose exec --user node dsh dsh plugin --profile web remove -w @xmanrui/dsh-im
docker compose exec --user node dsh dsh plugin --profile web add -w @tencent-connect/dsh-qqbot@0.5.5
docker compose restart dsh
```

已有 profile 会保留原插件，需要执行上述命令完成切换，然后在“设置 → QQ 机器人”重新绑定。旧 IM 状态保留在数据目录中。

### DSH 沙箱

镜像安装 Debian 的 `bubblewrap` 包，提供 `/usr/bin/bwrap`，版本记录在 `/opt/dsh-image/versions.json`。Compose 设置 `seccomp=unconfined` 和 `apparmor=unconfined`，允许 `node` 用户通过非特权用户命名空间创建 bwrap 所需的挂载与 PID 命名空间。这会放开容器默认的 seccomp 和 AppArmor 限制；DSH 命令的文件访问范围由 bwrap 挂载规则约束。

默认 `DSH_PERMISSION_MODE=workspace-write`：工作区和显式授权的额外目录可写，其他路径只读，`/tmp` 为每次命令独立的临时目录。可通过 `DSH_PERMISSION_MODE` 修改应用启动默认值。宿主机内核必须支持并允许非特权用户命名空间。

直接使用 `docker run` 时，同样传入 `--security-opt seccomp=unconfined --security-opt apparmor=unconfined`。已有部署更新 Compose 权限后，执行 `docker compose up -d --force-recreate dsh` 使设置生效。

可在容器中以实际运行用户检查 bwrap：

```sh
docker compose exec --user node dsh bwrap \
  --ro-bind / / --dev /dev --unshare-pid --proc /proc --die-with-parent -- true
```

## 局域网与反向代理

默认仅将端口发布到宿主机回环地址。在 `.env` 中配置局域网访问，例如：

```dotenv
DSH_PUBLISH_ADDRESS=0.0.0.0
DSH_PUBLISH_PORT=3080
DSH_PUBLIC_URL=http://192.168.1.10:3080/
```

```sh
docker compose up -d
```

`DSH_PUBLIC_URL` 的访问地址会自动加入 DSH 的可信主机列表。需要允许额外域名时，使用 `DSH_TRUSTED_HOSTS`，例如 `nas.example.com,192.168.1.10:3080`。

DSH 拒绝 `--host 0.0.0.0`；入口脚本从容器网卡选择具体 IP，再传给 DSH。`DSH_PUBLISH_ADDRESS=0.0.0.0` 配置的是 Docker 宿主机端口发布。更改宿主机端口时，同时更新 `DSH_PUBLIC_URL`。

如果由已有反向代理提供 HTTPS，将 `DSH_PUBLIC_URL` 设为实际 HTTPS 根地址。代理需要转发 WebSocket，并保留与浏览器 Origin 一致的 Host。登录使用 DSH 自身的完整登录链接或设备配对。

### 出站代理

在 `.env` 中直接设置标准代理环境变量，大小写两种形式用于兼容不同工具：

```dotenv
HTTP_PROXY=http://proxy:8080
http_proxy=http://proxy:8080
HTTPS_PROXY=http://proxy:8080
https_proxy=http://proxy:8080
NO_PROXY=localhost,127.0.0.1,::1
no_proxy=localhost,127.0.0.1,::1
NODE_USE_ENV_PROXY=1
```

Compose 通过服务的 `env_file` 读取部署目录的 `.env`，将代理变量直接传入容器。文件中明确设置的代理值（包括空值）优先于宿主机的同名环境变量；不再通过 `${HTTP_PROXY}` 等表达式从启动 Compose 的 shell 获取代理。`NODE_USE_ENV_PROXY=1` 启用 Node.js 的环境代理支持，第三方工具根据自身对代理环境变量的支持使用代理。修改后执行 `docker compose up -d --force-recreate dsh` 重新创建容器，使配置生效；`docker compose restart` 会沿用旧环境变量。

这里的 `proxy` 必须是容器能够访问的代理地址，`localhost` 或 `127.0.0.1` 指向容器自身。代理运行在宿主机时，填写容器可访问的宿主机局域网 IP，并在代理软件中允许局域网连接。也可以在 `.env` 中设置标准 `ALL_PROXY` / `all_proxy`；不使用代理时，将大小写的 HTTP、HTTPS、ALL 代理变量都留空。

检查实际容器中的代理值：

```sh
docker compose exec dsh printenv HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy
```

已有部署需要先更新 `compose.yaml`，仅拉取镜像不会改变旧 Compose 的变量来源。升级前可临时清除启动 Compose 进程的代理变量，强制使用 `.env` 中的 HTTP/HTTPS 代理；已有本地镜像时使用 `--pull never`：

```sh
env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy -u ALL_PROXY -u all_proxy \
  docker compose --env-file .env up -d --force-recreate --pull never dsh
```

## 构建与验证

```sh
make build
make test
make smoke
```

有 Podman 时也可以使用：

```sh
make build CONTAINER_ENGINE=podman
make smoke CONTAINER_ENGINE=podman
```

`make test` 覆盖具体 IP 绑定、公开 URL 与可信地址、认证响应的健康检查、首次初始化、并发初始化、符号链接和已有用户配置保留，以及 Compose 中 `.env` 代理覆盖宿主机变量和空值禁用代理。`make smoke` 创建临时数据卷，启动 Web、以 `node` 用户验证 DSH 实际选择 bwrap，以及工作区和额外目录写入、范围外写入拒绝、只读模式、独立 `/tmp` 与 PID 命名空间；随后验证 Chromium 与 agent-browser 的页面打开、中文快照、点击和截图，验证临时登录与 QQ 绑定页接口、安装一个本地测试插件、保存真实 Mnemon 记忆和 QQ 状态，再重建容器验证插件加载与数据保留。浏览器测试使用内嵌页面；测试不调用模型 API，结束后清理自己的容器和卷。

`.github/workflows/build.yml` 先运行单元测试、amd64 构建与持久化测试，以及 arm64 构建。全部通过后，默认分支的推送或手动运行会发布包含 `linux/amd64`、`linux/arm64` 的多架构镜像到 `ghcr.io/<账号或组织>/<仓库名>`，并更新 `latest` 和 `sha-<完整提交 SHA>` 标签。推送 `v*` 标签也会发布对应标签的镜像；语义版本标签另外生成版本号和主次版本标签，例如 `v1.2.3` 会生成 `v1.2.3`、`1.2.3`、`1.2`。Pull Request 和其他分支只构建验证。

发布使用 GitHub 自动提供的 `GITHUB_TOKEN`，不需要额外配置 Registry Secret。本仓库的 GHCR 镜像已公开，部署方式见“快速启动”。

### 修改默认版本或插件组合

修改 `core/package.json` 中的主程序、Mnemon CLI 和 agent-browser 版本；修改 `profiles/web/package.json` 的插件依赖与 `dsh.profile.bundles`。默认插件应声明 DSH bundle。然后重新生成锁文件并验证：

```sh
make lock
make build
make test
make smoke
```

`make lock` 先构建 Dockerfile 的 `toolchain` 阶段，再在临时容器中运行固定版本的 pnpm、uv 和同一套 Python。修改 Python 库时编辑 `python/requirements.in`。修改 Node 或 uv 镜像版本时，同步调整 `Dockerfile` 和锁文件脚本的默认值；pnpm 版本同时记录在 Dockerfile 和 `core/package.json`。

如果构建使用宿主机回环代理，可以给临时构建容器指定网络，例如 Linux 上的：

```sh
make lock CONTAINER_ENGINE=podman CONTAINER_NETWORK=host
make build CONTAINER_ENGINE=podman CONTAINER_NETWORK=host
```

这个选项只作用于依赖生成和镜像构建。Compose 的 Web 服务使用其默认容器网络。

## 备份

停止服务后备份整个 `data/` 目录，恢复到同一挂载路径：

```sh
docker compose stop
tar -czf dsh-home-backup.tar.gz data
docker compose start
```

缓存可以重新下载。若备份中省略 profile 的 `node_modules`，应保留 `package.json`、lockfile 和配置，并在恢复后通过 `dsh plugin --profile web install` 重装依赖。完整 home 备份也包含用户登录与机器人凭据。

## 上游与许可证

- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)：CLI、profile、home 路径、Web 绑定与认证。
- [dsh-mnemon](https://github.com/omdsh-dev/dsh-mnemon)：记忆存储与远程管理。
- [Mnemon CLI](https://github.com/mnemon-dev/mnemon)：默认本地记忆后端。
- [dsh-qqbot](https://github.com/tencent-connect/dsh-qqbot)：腾讯官方 QQ 机器人插件，npm 完整包名为 `@tencent-connect/dsh-qqbot`。

本仓库构建脚本使用 MIT 许可证。镜像内第三方组件适用各自的许可证。
