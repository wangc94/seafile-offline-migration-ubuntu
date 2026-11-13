# Ubuntu Compose 配置说明（v0.8）

本目录包含首次完整恢复和保留数据升级共用的 Compose 文件：

- `seafile-server.yml`
- `caddy.yml`
- `onlyoffice.yml`
- `seadoc.yml`

由迁移包根目录的 `install.sh` 统一调用，不建议手工分别启动。

## RabbitMQ 节点身份和 ONLYOFFICE 数据卷

`onlyoffice.yml` 使用以下环境变量：

- `RABBITMQ_HOSTNAME`：首次完整恢复默认 `05831744982c`；保留数据升级时由安装器读取现有 RabbitMQ 节点 hostname。
- `ONLYOFFICE_PG_VOLUME`
- `ONLYOFFICE_RABBIT_VOLUME`
- `ONLYOFFICE_REDIS_VOLUME`

首次完整恢复使用迁移包定义的三个具名卷。保留数据升级则继续引用现有 Docker 卷的原名称，不复制、不重建、不删除原卷。

## SeaDoc

- Seafile 容器显式接收 `ENABLE_SEADOC` 和 `SEADOC_SERVER_URL`。
- SeaDoc 使用现有 MariaDB 的 `seahub_db` 和 Seafile 的 JWT 私钥。
- Docker 内部 Seahub 地址为 `http://seafile`。
- Caddy 配置 `/sdoc-server/*` 和 `/socket.io/*` 路由。

所有配置由 `install.sh` 交互式生成和校验。不要在目标机上直接执行单个 Compose 文件。
