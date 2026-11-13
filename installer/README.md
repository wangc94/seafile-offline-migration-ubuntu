# Seafile + ONLYOFFICE + SeaDoc 离线迁移包（安装器 v0.8）

## 目标环境

- Linux x86-64 / amd64
- Ubuntu 24.04 是本次迁移包的基线验证环境，但不再作为强制版本条件
- 其他 Linux 发行版或其他 Ubuntu 版本会显示兼容性警告，用户明确确认后允许继续
- 已安装并启动 rootful Docker Engine 和 Docker Compose Plugin
- 目标 Linux 主机网卡已配置固定 IPv4
- HTTP 访问
- 不依赖局域网 DNS、内网域名或 Windows Hosts 配置

服务版本：Seafile 13.0.28、ONLYOFFICE Docs 8.1.0.1、SeaDoc 2.0、MariaDB 10.11、Caddy Docker Proxy 2.12-alpine，以及本次归档中的 Redis 镜像。

## 1. 使用方式

将整个 `Seafile-Offline-Migration` 目录复制到目标 Linux 主机可访问的磁盘。确认 `install.sh` 位于迁移包根目录。

```bash
cd /path/to/Seafile-Offline-Migration
sudo bash ./install.sh
```

菜单：

- `1`：首次安装 / 从迁移包完整恢复到空目标环境
- `2`：保留数据升级 / 在受支持的现有 Seafile 13.0.28 环境中启用 SeaDoc
- `3`：检查当前部署
- `4`：查看服务状态
- `0`：退出

两种模式互斥。首次恢复模式会解包迁移包中的数据库和业务数据；保留数据升级模式绝不会解包这些旧数据归档，而是备份并继续使用目标机当前的数据目录和 Docker 数据卷。保留数据升级仅支持本迁移包明确列出的 Seafile 13.0.28 已验证拓扑，不是通用跨版本升级工具。

两种模式都会交互式询问目标 Linux 主机已配置的固定 IPv4、ONLYOFFICE 访问端口（默认 6233）和 Seafile 服务时区（默认 Etc/UTC）。脚本展示摘要并确认后才开始执行。安装器不会修改 Netplan。

## 2. 固定配置

- 安装根目录：`/opt`
- Docker 网络：`seafile-net`
- ONLYOFFICE 内部文件服务器：`http://seafile:8082`
- ONLYOFFICE 保存回调根地址：`http://seafile`
- RabbitMQ 节点 hostname：首次完整恢复固定为 `05831744982c`；保留数据升级时从现有 RabbitMQ 节点身份读取并保持不变
- ONLYOFFICE 补丁 SHA256：`900ba73c637ef3271770fb6fd22ee7b90644d293706457fed59a30c61b83a926`

用户输入的 IP 用于浏览器访问和 Caddy 路由；Docker 内部通信继续使用 Docker 服务名。这些服务名只在 Docker 网络内解析，不是局域网域名，也不需要写入 `/etc/hosts`。

## 3. SeaDoc 知识库

本版本按 Seafile 13.0 官方集成部署配置加入 SeaDoc，修正了 Seafile 容器侧 `ENABLE_SEADOC` / `SEADOC_SERVER_URL` 环境变量传递，并采用官方 `SEAHUB_SERVICE_URL` 变量名：

- `COMPOSE_FILE` 包含 `seadoc.yml`。
- `ENABLE_SEADOC=true`。
- SeaDoc 镜像：`seafileltd/sdoc-server:2.0-latest`。
- SeaDoc 持久化目录：`/opt/seadoc-data`，容器内挂载到 `/shared`。
- SeaDoc 使用现有 MariaDB 的 `seahub_db`，不新增数据库容器。
- SeaDoc 使用与 Seafile 相同的 `JWT_PRIVATE_KEY`。
- SeaDoc 使用官方集成配置中的 `SEAHUB_SERVICE_URL=${SEAFILE_SERVICE_URL:-http://seafile}`，通过 Docker 服务名访问 Seahub。
- Docker 内部 Seahub 地址为 `http://seafile`。
- 浏览器端入口为 `http://<目标IP>/sdoc-server/`。
- Caddy 配置 `/sdoc-server/*` 与 `/socket.io/*` 路由，支持 API 和 WebSocket。

原 Windows 准备机此前未启用 SeaDoc，因此本迁移按首次启用处理：使用原 MariaDB `seahub_db` 备份，并在目标机创建新的 `/opt/seadoc-data` 持久化目录。如果准备机上已经存在非空 `/opt/seadoc-data`，必须先单独备份，不能直接忽略。

### SeaDoc 镜像离线准备

在联网准备机的 WSL Docker 环境执行：

```bash
docker pull seafileltd/sdoc-server:2.0-latest

MIGRATION_DIR="/mnt/c/Users/path/Downloads/Seafile-Offline-Migration"

docker image inspect seafileltd/sdoc-server:2.0-latest \
  > "$MIGRATION_DIR/09-manifests/seadoc-image-inspect.json"

docker image save \
  -o "$MIGRATION_DIR/01-images/seadoc-image.tar" \
  seafileltd/sdoc-server:2.0-latest

cd "$MIGRATION_DIR"
sha256sum 01-images/seadoc-image.tar \
  > 01-images/seadoc-image.tar.sha256
```

镜像应为 `linux/amd64`，标签为 `seafileltd/sdoc-server:2.0-latest`。

## 4. 恢复内容

首次完整恢复模式导入六个 Docker 镜像并恢复 Seafile 配置和文件数据、MariaDB 原始数据、ONLYOFFICE 数据与字体、Caddy 持久化数据、ONLYOFFICE PostgreSQL/RabbitMQ/Redis 三个数据卷，以及 ONLYOFFICE 内部通信补丁。

首次完整恢复时，三个原匿名卷恢复为以下具名卷：

- `seafile-onlyoffice-postgresql`
- `seafile-onlyoffice-rabbitmq`
- `seafile-onlyoffice-redis`

这三个卷在 `onlyoffice.yml` 中声明为 `external: true`。首次完整恢复时安装器创建并恢复这三个新具名卷；保留数据升级时，安装器会从现有 ONLYOFFICE 容器读取原 Docker 卷名称，并让新 Compose 继续引用这些原卷，不复制、不重建、不删除。

首次完整恢复时 RabbitMQ hostname 使用备份中的原节点名称；保留数据升级时从现有 RabbitMQ 节点身份读取并保持不变。字体归档的 `onlyoffice-fonts/` 顶层目录会被正确展开到 `/opt/onlyoffice-fonts`，不会产生重复嵌套。

## 5. 安全行为

- 不安装或升级 Docker；不支持 rootless Docker。
- 不执行 `docker compose down -v`、`docker volume prune` 或数据目录清理。
- 发现同名容器、非空目标目录、非空同名卷或不属于本 Compose 项目的同名网络时停止，避免覆盖。
- 数据库和 JWT 密钥从配置归档恢复，不要求重新输入。
- `.env` 权限设置为仅 root 可读写。
- 安装日志：`/var/log/seafile-offline-migration/`
- 阶段标记：`/var/lib/seafile-offline-migration/`
- 安装器会固定本次迁移包身份；恢复中途不得替换为另一版迁移包。更换迁移包需先人工检查和处理恢复状态。
- 发生中断或解包失败时保留现场，不自动删除 staging 目录或数据卷。不要擅自清理；先检查日志和目标状态。

## 6. 完整性检查

安装器要求迁移包根目录存在 `SHA256SUMS`，并会逐个验证全部 12 个 TAR 的独立 SHA256、TAR 结构和总校验清单。复制或更新迁移包文件后，必须重新生成并验证总清单：

```bash
cd /path/to/Seafile-Offline-Migration
find . -type f ! -name 'SHA256SUMS' -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
sha256sum -c SHA256SUMS
```

## 7. 自动检查与人工验收

自动检查包括 Linux 系统、x86-64 架构、rootful Docker、Compose、磁盘空间；Ubuntu 24.04 为基线环境，其他发行版/版本经用户确认后允许继续、镜像身份、数据库连通性、ONLYOFFICE healthcheck、RabbitMQ 原节点身份与 Mnesia 目录、Docker 内部通信、浏览器端 APIJS、字体及补丁挂载。

自动检查通过后仍必须人工完成：

1. 浏览器登录 Seafile。
2. 打开 DOCX，检查中文字体。
3. 单人编辑、退出后重新下载，检查保存回写。
4. 两个用户同时编辑，检查实时协作和最终保存。

## 8. 敏感数据

迁移包包含管理员凭据、数据库密码、JWT 密钥、用户资料和内部服务数据。应存放在受控介质中，不要公开上传或分享。保留原始 Windows 准备机和迁移包，直到 Ubuntu 完成编辑、回写、多人协作及重启恢复验收。


## 9. 操作系统版本检查（v0.4）

安装器不再强制要求 Ubuntu 24.04。

- 必须运行于 Linux。
- 必须为 x86-64（`uname -m` 返回 `x86_64`），因为归档中的六个 Docker 镜像均为 linux/amd64。
- Ubuntu 24.04 作为本次迁移包的基线验证环境，直接继续。
- 其他 Ubuntu 版本、其他 Linux 发行版或无法识别的发行版会显示警告，并要求操作者明确输入 `y` 才继续。
- Docker Engine、Docker Compose、rootful Docker、网络、挂载、磁盘空间及业务数据检查仍然保留。

取消 Ubuntu 24.04 的强制检测，不代表已经实测支持所有 Linux 发行版。目标系统仍需满足 Docker 和容器运行时要求。


## 10. v0.6 SeaDoc 配置修正

- `seafile-server.yml` 显式传入 `ENABLE_SEADOC=${ENABLE_SEADOC:-true}`。
- `seafile-server.yml` 显式传入 `SEADOC_SERVER_URL=http(s)://<SEAFILE_SERVER_HOSTNAME>/sdoc-server`。
- `seadoc.yml` 使用官方变量名 `SEAHUB_SERVICE_URL=${SEAFILE_SERVICE_URL:-http://seafile}`。
- 保留官方 Caddy `/sdoc-server/*` 和 `/socket.io/*` 路由标签。
- 安装器会在启动后检查 Seafile 容器内的 `ENABLE_SEADOC` 和 `SEADOC_SERVER_URL`，再检查 `/sdoc-server/` 欢迎页。

官方参考：
- https://manual.seafile.com/13.0/extension/setup_seadoc/
- https://github.com/haiwen/seafile-admin-docs/blob/master/manual/repo/docker/seadoc.yml
- https://github.com/haiwen/seafile-admin-docs/blob/master/manual/repo/docker/ce/seafile-server.yml

## 11. SeaDoc 功能验收

自动检查会验证 SeaDoc 容器、Caddy 路由和官方欢迎页。仍需人工登录 Seafile：

1. 创建一个知识库。
2. 新建一篇知识库页面。
3. 编辑并保存中文内容。
4. 刷新页面，确认内容仍在。
5. 两个用户同时打开同一页面，检查协作编辑。
6. 重启 SeaDoc 和 Seafile 容器，再次打开页面确认持久化。

官方部署说明：
https://manual.seafile.com/13.0/extension/setup_seadoc/


## 12. v0.7 SeaDoc 修正

- SeaDoc `SEAHUB_SERVICE_URL` 采用 Seafile 13 官方集成 Compose 的变量表达式：
  `SEAHUB_SERVICE_URL=${SEAFILE_SERVICE_URL:-http://seafile}`。
- 安装器验证 SeaDoc 镜像 inspect 元数据必须为 `linux/amd64`。
- SeaDoc 启动后不再仅以容器 `running` 作为就绪条件；安装器会轮询 Caddy 的 `/sdoc-server/` 入口，直到返回 HTTP 200，再进入后续验收。

官方参考：
- Seafile 13 SeaDoc Integration：
  https://manual.seafile.com/13.0/extension/setup_seadoc/
- Seafile 官方论坛关于 Seafile 13 默认 `seadoc.yml` 的核对：
  https://forum.seafile.com/t/i-cant-start-seadoc-docker-seafile-13/25037/3


## 13. v0.8 保留数据升级模式

菜单选择 `2`，适用于**已经运行本迁移包对应软件栈的 Seafile 13.0.28 主机**，目标是在不重新导入旧数据的前提下增加 SeaDoc。

### 严格支持范围

升级模式只自动处理同时满足以下条件的现有部署：

- Seafile 数据版本为 `13.0.28`。
- 当前 Seafile、MariaDB、Redis、Caddy、ONLYOFFICE 容器的 Image ID 与本迁移包记录的已验证镜像一致。
- 现有数据路径符合本迁移包已验证布局：
  - `/opt/seafile-data`
  - `/opt/seafile-mysql/db`
  - `/opt/onlyoffice`
  - `/opt/onlyoffice-fonts`
  - `/opt/seafile-caddy`
- 已挂载本迁移包要求的 ONLYOFFICE 内部通信补丁，且 SHA256 匹配。
- ONLYOFFICE PostgreSQL、RabbitMQ、Redis 数据分别位于 Docker volume。
- RabbitMQ 当前节点名与容器 hostname 一致。

不满足任一条件，安装器会在停止服务和修改配置之前退出。此模式**不是 Seafile 12 到 13、13 到 14 等跨版本升级器**，也不自动改写自定义数据路径。

### 升级过程

1. 识别当前容器、镜像、数据路径、Docker 卷和 RabbitMQ 节点身份。
2. 交互式确认目标 IP、ONLYOFFICE 端口和时区。
3. 要求指定升级前备份目录；检查空间后停止现有服务。
4. 对 `/opt/seafile`、Seafile 数据、MariaDB 数据、ONLYOFFICE bind 数据、字体、Caddy 数据和三个 ONLYOFFICE Docker 卷制作冷备份。
5. 为备份生成独立 `SHA256SUMS` 并立即验证。
6. 只导入 SeaDoc 镜像，不重新导入或替换现有五个基础服务镜像。
7. 更新 Compose 和 `.env`，启用 SeaDoc。
8. ONLYOFFICE Compose 继续引用原有三个 Docker 卷名称，不复制、不重建、不删除这些卷；RabbitMQ hostname 使用检测到的原节点身份。
9. 启动服务并执行自动检查。

升级前备份默认放在：

`/opt/seafile-upgrade-backups/<时间戳>/`

也可以在向导中指定外接磁盘或其他独立存储路径。备份空间至少需要覆盖当前持久化数据总量，并额外预留约 10% 和 1 GiB。

### 数据保护边界

- 不解压 `03-database/mariadb-data.tar`、`04-seafile-data/seafile-data.tar`、`05-onlyoffice/onlyoffice-data.tar` 或 `06-docker-volumes/*/data.tar`。
- 不删除原 Docker 卷；升级后的 Compose 通过 `external: true` 继续使用原卷名。
- 不重新初始化数据库。
- 失败后保留升级前备份和现场，不自动删除数据。
- 如果配置已经应用但启动/验收失败，安装器不会擅自回滚数据库。应先检查日志和升级备份，再决定恢复原 Compose 配置或执行完整数据回滚。

升级备份目录中的 `SHA256SUMS` 可用于独立验证升级前数据备份。建议将备份目录放在独立磁盘或独立文件系统；升级期间原服务会停止，备份成功后才修改 Compose 和 `.env`。

## 14. v0.8 升级模式限制

升级模式仅为 Seafile 13.0.28 + ONLYOFFICE 8.1.0.1 的已验证部署拓扑增加 SeaDoc，不代表通用 Seafile 版本升级工具。对于不同版本、不同镜像 ID、自定义路径、非 Docker volume 的 ONLYOFFICE 内部数据卷或不一致的 RabbitMQ 节点身份，必须先单独制定迁移方案，不能绕过安装器检查强行继续。
