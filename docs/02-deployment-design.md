# 部署设计

交付物根目录保留历史布局：`install.sh`、`README.md`、`SHA256SUMS`、`01-images` 至 `07-patches`、`09-manifests`。重建工具从 Git 复制 8 个锁定文件，从私有素材库复制 35 个锁定文件；保留原始字节和总校验清单。

安装器为单入口交互菜单：1 完整恢复；2 保留数据升级并启用 SeaDoc；3 检查部署；4 查看服务；0 退出。需要 root，固定使用 `/opt` 和 `seafile-net`。不修改 Netplan，不安装 Docker。

预检包括 Linux/x86-64、rootful Docker、Compose、工具、端口、目标路径和卷冲突。原安装器分别检查 `/opt` 与 Docker 数据目录所在文件系统至少 25 GiB 可用；两者共用磁盘时应结合镜像展开、恢复和备份总需求另行确认容量，不能直接认为这两个门槛就是足够的容量规划。

用户输入固定 IPv4、ONLYOFFICE 端口（默认 6233）、时区（原脚本默认 `Etc/UTC`，中国环境可输入 `Asia/Shanghai`）。数据库与 JWT 从私有配置归档恢复，仓库不记录其值。

安装器把目标值写入 `.env`，覆盖四份 Compose 到 `/opt/seafile`，验证补丁 SHA256，再执行 Compose 解析与服务检查。恢复标记在 `/var/lib/seafile-offline-migration`，日志在 `/var/log/seafile-offline-migration`。这些目录不应在失败后直接删除重试。

`installer/README.md` 是原包原文，含联网准备时的历史命令。本仓库的冻结重建流程不执行其中的 `docker pull`。原安装器保留历史 `compose up -d` 调用方式；完全隔离网络下的启动行为仍须在目标机测试。
