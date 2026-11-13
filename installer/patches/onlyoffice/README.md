# ONLYOFFICE 内部通信补丁

`utils.py` 是从原 `02-config/seafile-config.tar` 的 `seafile/patches/onlyoffice/utils.py` 精确提取的可读副本，SHA256：

`900ba73c637ef3271770fb6fd22ee7b90644d293706457fed59a30c61b83a926`

它为 ONLYOFFICE 生成内部文件下载地址 `http://seafile:8082` 和内部保存回调根地址 `http://seafile`。浏览器的 APIJS 仍用目标 IP 与端口。原始上游文件也在私有补丁备份 TAR 中保存；不把包含业务配置的其他补丁备份直接公开。

部署安装器固定验证上述哈希，并只读挂载到 Seafile 13.0.28 的 Seahub 路径。此源码副本用于审阅和后续迭代，冻结包仍使用原配置 TAR 中的副本。修改这里后需要有意制作新配置归档、新包清单及新的候选版本；不会隐式重写历史归档。

该文件包含 Seafile/Seahub 上游代码，保留其原始来源关系；未在本仓库为上游代码重新授予许可证。
