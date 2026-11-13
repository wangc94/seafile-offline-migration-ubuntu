# 项目基线

记录日期：2026-11-13（Asia/Shanghai）。目标是将 Windows/WSL 的 Seafile 协作环境迁到完全离线的 Linux，并持续保存可以重建的交付物。

## 输入及事实来源

原对话：[离线协作方案](chatgpt-conversation://6ad9c334-6d0c-83eb-b828-9a7a039cf584)。当前可读取的最近记录支持 v0.8 双模式、SHA256 已检查、Ubuntu 实机未验收这些结论。实际文件取自 `C:\Users\path\Downloads\Seafile-Offline-Migration`；原文件只读，不覆盖、不重写。

本次直接读取了 43 个文件并核对原 SHA256SUMS，提取安装器和四份 Compose。包总文件长度为 7,110,885,237 字节；含 12 个 TAR（其中 2 个是镜像归档，内含 6 个镜像）。不能混称为“6 个镜像 TAR”。完整文件清单见 `releases/v0.8.0-baseline.1/manifest.json`。

| 组件 | 基线 | 说明 |
| --- | --- | --- |
| Seafile | 13.0.28 | 标签 `seafileltd/seafile-mc:13.0-latest`，身份锁定到已有归档 |
| ONLYOFFICE Docs | 8.1.0.1 | 含内部文件下载与回调补丁 |
| SeaDoc | 2.0 系列归档 | 标签 `seafileltd/sdoc-server:2.0-latest`；不推断更细版本 |
| MariaDB | 10.11 系列归档 | 原始物理数据目录，必须匹配原镜像 |
| Caddy Docker Proxy | 2.12-alpine 归档 | 统一反向代理 |
| Redis | 现有 `redis:latest` 归档 | 只认归档和 Image ID，不从标签猜具体版本 |
| 系统/CPU | Ubuntu 24.04 / linux/amd64 | Ubuntu 是制作基线，不是已完成本次实机验收的证明 |

目标环境需预装 Docker/Compose，固定 IPv4，采用 HTTP。其他 Linux 版本需交互确认，并不等于已经验证支持。主机没有局域网域名依赖；容器内部仍依赖 Docker 服务名解析。

## 范围

支持首次完整恢复至空环境；支持严格匹配现有 Seafile 13.0.28 拓扑的保留数据升级、启用 SeaDoc。暂不提供通用跨大版本升级、裸机系统安装介质或数据库热备一致性保证。

历史对话提到 Office 编辑及多人协作成功，未在当前仓库附原始业务测试证据，只标记为“历史报告”。本次没有启动或停止现有业务服务。
