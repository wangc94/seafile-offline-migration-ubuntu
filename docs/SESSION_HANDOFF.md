# 后续会话交接

更新时间：2026-11-13（Asia/Shanghai）。

## 当前目标和版本

让同一 Git 版本加私有素材库随时重建相同的 Seafile 离线迁移包。初始基线 `v0.8.0-baseline.1`，安装器仍是历史 v0.8，状态“可复现，待 Ubuntu 实机验收”。

## 已完成

- 读取原对话最近可用记录，定位 Downloads 真实迁移包，按原 SHA256SUMS 捕获全部 43 文件。
- Git 保存安装器、Compose、公开补丁与文档；35 个私有文件内容寻址保存到仓库外。
- 提供无网络/无 Docker daemon 的校验、重建、确定性打包和素材备份工具及自动测试。
- 每版在 releases 下冻结独立源码，installer 作为可维护工作副本；修改工作副本不会影响历史重建。
- 原始包只读；不启停业务服务，不改 `/opt` 或 Docker 数据卷。
- 实际验证结论、分发包 SHA256 见 `evidence/2026-11-13-reproduction.md`。
- 用户要求的再次复核已通过，见 `evidence/2026-11-13-recheck.md`：从 GitHub 全新下载基线实际重建成功，并完成两版本独立重建演练。可以本仓库为后续迭代基础；Ubuntu 业务验收和异盘素材备份仍待完成。

## 重要位置

- 仓库：`C:\Users\path\Work\seafile-offline-migration-ubuntu`。
- 原包：`C:\Users\path\Downloads\Seafile-Offline-Migration`。
- 私有素材：`C:\Users\path\Work\seafile-offline-assets`，默认自动定位于仓库同级。
- 生成的目录、TAR、`.sha256`：`dist/`，Git 忽略，不上传公开渠道。
- GitHub：`git@github.com:wangc94/seafile-offline-migration-ubuntu.git`；main 和 `v0.8.0-baseline.1` 已推送，基线提交 `0ab8a15` 的 GitHub Actions 已通过。
- 离线 Git 仓库备份：`dist/seafile-offline-repository.bundle`，可与私有素材库一起离线携带；可用 `git clone <bundle路径> <新目录>` 恢复。

## 接下来优先做

1. 用户提供第二块受控磁盘或私有远程存储时，用 backup-assets 形成异盘副本并校验；目前本机副本不构成异机灾备。
2. 在独立的 linux/amd64 Ubuntu 环境按验收计划测试完整恢复、Office、SeaDoc 和重启。
3. 再测试匹配环境的保留数据升级、备份与失败恢复。把证据关联到发布记录。
4. 若要从裸机完全离线安装，另行补充锁定的 Docker/Compose/系统依赖介质及供应流程。

## 不可忽略的约束

组件和镜像身份不因 `latest` 标签变化而升级；升级必须保留原卷与 RabbitMQ 节点身份，先冷备；不覆盖业务数据、不删除卷。静态检查、历史聊天说法和目标机业务验收必须分开记录。不要将素材、resolved Compose 或 raw inspect 上传 GitHub。
