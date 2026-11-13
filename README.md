# Seafile 离线迁移的持久化仓库

本仓库保存部署源码、技术决策、版本锁定、重建工具与验证记录。初始基线来自现有 **v0.8 双模式迁移包**，不改动原安装器的部署行为。

**复现条件：对应 Git 版本 + 私有素材库。** 素材包含业务数据、密码和原始镜像，不能由文字或镜像标签重新生成，因此单独保存，禁止提交到 GitHub。重建全过程不访问网络，也不需要运行 Docker。

当前基线 `v0.8.0-baseline.1`：43 个文件，7,110,885,237 字节。`releases/` 锁定每个文件的路径、长度与 SHA256；8 个文件由 Git 保存，35 个文件由私有素材库保存。基线状态是“可复现，待 Ubuntu 实机验收”。

## 立即重建

在仓库根目录执行，需 Python 3.10 或更高版本，无第三方 Python 依赖：

```powershell
python tools/offline.py verify-inputs
python tools/offline.py build --output dist/Seafile-Offline-Migration
python tools/offline.py pack --bundle dist/Seafile-Offline-Migration --output dist/Seafile-Offline-Migration-v0.8.0-baseline.1.tar
```

工具拒绝覆盖已存在的输出。重复构建请选择新的空输出路径。`pack` 同时生成 `.tar.sha256`；外层 TAR 的文件顺序、权限、时间和属主固定，相同输入生成相同字节。

私有素材默认在仓库的同级目录 `../seafile-offline-assets/objects/sha256/`。本机位置为 `C:\Users\path\Work\seafile-offline-assets`。换机器时携带完整素材库，并指定其位置：

```powershell
python tools/offline.py --assets E:/seafile-offline-assets verify-inputs
python tools/offline.py --assets E:/seafile-offline-assets build --output dist/Seafile-Offline-Migration
```

Linux 上将 `python` 替换为 `python3`。也可以通过环境变量 `SEAFILE_ASSET_DIR` 设置素材根目录；`--assets` 和 `--release` 是全局参数，放在子命令前。

## 在目标 Ubuntu 安装

目标机需要提前安装 rootful Docker Engine、Compose Plugin、Python 3 和基础系统工具。**当前包不含 Docker/Ubuntu 离线安装介质**。它支持将已有业务完整恢复到空目标环境，以及在严格匹配的现有 13.0.28 环境中保留数据并启用 SeaDoc。

```bash
sha256sum -c Seafile-Offline-Migration-v0.8.0-baseline.1.tar.sha256
tar -xf Seafile-Offline-Migration-v0.8.0-baseline.1.tar
cd Seafile-Offline-Migration
sha256sum -c SHA256SUMS
sudo bash ./install.sh
```

完整恢复、Office 保存与协作、SeaDoc、重启持久性都须按[验收计划](docs/06-acceptance-test.md)实测。不要把包校验或 Compose 解析结果写成部署验收通过。

## 长期保存和迭代

- 将 Git 仓库同步到 GitHub，按发布标签检出版本。
- 将私有素材库额外备份到受控磁盘。GitHub 不保存这些对象；遗失全部素材副本后无法还原业务包。
- 使用 `python tools/offline.py backup-assets --output E:/seafile-offline-assets-backup` 复制并校验当前版本需要的素材；目标必须不存在。
- 不重新执行 `docker pull ...latest` 代替历史镜像，不重打包原始数据库 TAR。原始归档本身就是锁定的输入。
- 调整安装器后建立新候选包、生成其 SHA256SUMS，再用新 `--release` 捕获并验证。每版在 `releases/<版本>/source/` 独立冻结源码；已冻结的版本锁不能随意修改。历史版本可用 `--release` 指定，或检出对应标签。详见[复现协议](docs/10-reproducibility.md)。

| 位置 | 用途 |
| --- | --- |
| `installer/` | 原 v0.8 安装器、Compose、包内说明、可维护的 ONLYOFFICE 补丁副本 |
| `tools/offline.py` | 捕获、校验、重建、确定性打包、私有素材备份 |
| `releases/v0.8.0-baseline.1/` | 完整文件锁、原始 SHA256SUMS、六镜像身份记录 |
| `docs/` | 基线、设计、操作与风险、决策、交接 |
| `tests/` | 使用合成数据验证重建与异常处理 |
| `evidence/` | 可公开的验证结论；业务日志保存在私有位置 |
| `dist/` | 本地生成的完整交付物，Git 忽略 |

后续接续本项目时先读 [AGENTS.md](AGENTS.md) 和 [SESSION_HANDOFF.md](docs/SESSION_HANDOFF.md)。
