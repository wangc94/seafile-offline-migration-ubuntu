# 操作入口

## 构建机

本机私有素材已经从 Downloads 原包独立保存到 `C:\Users\path\Work\seafile-offline-assets`，原包仍在原位置。构建机只需 Python 3.10+ 和文件系统空间，无需联网或 Docker daemon。

```powershell
python tools/offline.py verify-inputs
python tools/offline.py build --output dist/Seafile-Offline-Migration
python tools/offline.py verify --bundle dist/Seafile-Offline-Migration
python tools/offline.py pack --bundle dist/Seafile-Offline-Migration --output dist/Seafile-Offline-Migration-v0.8.0-baseline.1.tar
```

初次交付已在 `dist/` 生成；相同命令再次运行会拒绝覆盖，用其他输出名或先将已确认的旧交付物人工归档。不要为了绕过覆盖保护删除业务文件。

换机器：检出对应标签，将私有素材库复制至受控目录，然后 `python tools/offline.py --assets <素材根目录> verify-inputs` 和 `build`。Linux 使用 `python3`。默认参数和更多命令见 README。

## 目标机

提前准备 Docker Engine、Compose Plugin、Python 3、GNU tar、sha256sum、ip、ss 等系统工具；目标平台 linux/amd64，固定 IPv4，满足磁盘空间要求。此基线不提供 Docker 或操作系统的离线安装包。

复制交付 TAR 及其 `.sha256` 到受控目录，按 README 解包校验后运行 `sudo bash ./install.sh`。全新机选择 1，符合支持条件的已有环境选择 2。输入本机实际固定 IPv4；时区按需求输入 `Asia/Shanghai`。

安装后按 `docs/06-acceptance-test.md` 逐项记录。业务日志含内部数据或凭据时只保存至私有证据目录，提交脱敏结论及校验值。
