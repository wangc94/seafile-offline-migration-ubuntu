# 2026-11-13 初始归档与重建验证

日期：2026-11-13（Asia/Shanghai）。对象：`v0.8.0-baseline.1`。安装器：历史 v0.8，源文件未修改。原始数据路径只读，未运行安装器或改变业务服务。

## 实际执行结果

| 项目 | 结果 |
| --- | --- |
| 原 SHA256SUMS 与完整文件集合 | 43 文件，7,110,885,237 字节；全部一致 |
| 私有素材捕获 | 35 文件存入仓库外 SHA256 内容寻址库 |
| Git 源文件与版本锁校验 | 8 个包内文件的源码/校验清单与原包一致 |
| 完整目录重建 | 从 Git 工作区源码与独立素材库恢复 43 文件，逐项哈希和集合校验通过 |
| 原包再次验证 | `verify --bundle <Downloads 原包>` 通过 |
| 独立 Git clone 重建 | 新检出仓库 + 显式私有素材路径重建全部 43 文件并通过校验 |
| 两次整包 TAR 构建 | 长度和 SHA256 一致，见下方 |
| Python 工具测试（Windows Python 3.13） | 18 项运行，17 通过、1 项符号链接测试因主机权限跳过 |
| Python 工具测试（WSL Ubuntu Python 3） | 18 项全部通过，含符号链接拒绝测试 |
| 原安装器 `bash -n`（WSL） | 通过 |
| Compose config（Windows Docker CLI 29.7.2） | 使用合成凭据，无需 daemon；六服务、三个 external 卷、SeaDoc 内部 URL 断言通过 |
| 提交文件范围 | 不含原始 TAR、数据库、业务文件、`.env`、raw inspect、resolved Compose |

整包 TAR 长度：**7,110,922,240 字节**。

整包 TAR SHA256（两次构建相同）：

```text
9d44e7d68f41bcef1acd72f5aa64574d8f5890b1bb2b1319e9ef91d16c266918
```

产物：`dist/Seafile-Offline-Migration/`、`dist/Seafile-Offline-Migration-v0.8.0-baseline.1.tar`、同名 `.tar.sha256`。第二次独立打包记录在 `.local/repro-check.tar`；这些文件均被 Git 忽略，不上传 GitHub。

自动测试覆盖：捕获到重建的往返、输入缺失、同长度内容篡改、源码变化、重复输出、越界/重复/父子冲突路径、符号链接、额外/缺失文件、SHA 清单解析、归档确定性、损坏对象不可覆盖、私有备份独立性、拒绝备份到 Git 目录、失败不发布归档。

## 复验命令

```powershell
python tools/check_repository.py
python -m unittest discover -s tests -v
python tools/check_compose.py
python tools/offline.py verify-inputs
python tools/offline.py verify --bundle dist/Seafile-Offline-Migration
```

Linux 使用 `python3`，原安装器语法检查为 `bash -n installer/install.sh`。

## 技术依据和证据限制

本次通过 Context7 `/docker/docs` 获取 Docker 官方配置校验与卷保留文档；使用 [`docker compose config`](https://docs.docker.com/reference/cli/docker/compose/config/) 解析配置，卷语义参照 [`docker compose down`](https://docs.docker.com/reference/cli/docker/compose/down/)。未执行任何 down 命令。

当前 Docker Desktop Linux daemon 未启动，这未影响本次不依赖 daemon 的重建与 Compose config。未做 Docker load、容器启动、数据库恢复、Ubuntu 首次部署、保留数据升级、Office/SeaDoc 编辑、主机重启或断网运行测试。不能从以上结果推断这些业务场景已通过。

素材库与原包均在本机；未声称已有异盘灾备。GitHub Actions 配置仅检查公开源码与合成数据，无法取得私有业务素材，不能代替完整恢复验收。
