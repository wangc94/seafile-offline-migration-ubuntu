# 可复现协议

## 复现的精确定义

指定 Git 标签、版本 manifest 与私有素材库，恢复到相同文件集合、路径、长度和每文件 SHA256；原始 `SHA256SUMS` 也作为文件锁定，保证安装器识别的包身份不改变。外层分发 TAR 另固定排序、mtime=0、uid/gid=0、空属主名和清单权限，同输入输出字节一致。

不承诺 Windows 文件 ACL、目录修改时间与原 Downloads 一致；内层 TAR 完全不解压重写，保留其所有原始恢复元数据。包内不加入新的发布说明或构建时间，以免改变原包。

## 存储布局

`manifest.json` 的 `storage=git` 指向仓库中的源文件；`storage=asset` 指向素材根目录下 `objects/sha256/<完整 SHA256>`。清单还记录文件路径、大小和分发权限。`images.lock.json` 只保存原 inspect 中 Image ID、RepoTags、RepoDigests、OS 和架构，不含环境变量。Image ID 和 RepoDigest 各自照实保存，不能一般性认为两者相等。

所有 12 个原始 TAR、12 个独立 `.sha256`、resolved Compose 和原始运行清单均进入私有素材库。源码只采用明确允许的 7 个文件，再加根 SHA256SUMS。ONLYOFFICE 补丁在源码目录另留可读副本，部署仍从锁定配置 TAR 使用原副本；修改可读副本不会隐式改变冻结包。

## 捕获和重建

初次捕获命令：

```powershell
python tools/offline.py --release v0.8.0-baseline.1 capture --package C:/Users/path/Downloads/Seafile-Offline-Migration
```

`capture` 先解析原 SHA256SUMS，拒绝额外/缺失文件，对每个输入核对哈希，按允许清单保存公开源码，其余作为私有对象保存。现有同哈希对象也会再校验。发布 manifest 最后写入，作为捕获完成标记。此命令不会重写原包；当前版本已捕获，重复执行会拒绝覆盖。

`build` 校验清单、检查输入可用性，逐个流式复制并计算 SHA256，最后校验完整文件集合与总校验清单。缺失素材不会通过自动下载弥补；输入变化不会通过重算清单掩盖。仅完成后的 staging 目录发布为目标目录。

`pack` 校验完整目录，写入固定 TAR 结构，再逐项读取 TAR 核对内部字节，然后发布归档和 `.sha256`。中断时 `.partial-*` 不作为完成品；不要部署没有成功校验输出的归档。

## 新版本

1. 检出工作分支，修改 `installer/`、设计和验收记录，不动旧包/私有原对象。
2. 在仓库外受控位置制作新候选包；仅在有意改变输入时生成新 SHA256SUMS。
3. 分配新的版本名，使用 `--release <新版本> capture`。已有源码内容若与候选不同，capture 会拒绝覆盖；应先把已评审的新源码同步到 `installer/`，核对后再捕获。
4. 将工具的默认版本、README 与交接同步到新版本。重建、校验、异常测试和确定性打包；按影响做目标机验收。
5. 提交并创建对应标签。旧版依赖旧标签中的 `installer/`，所以必须检出旧标签重建旧版本，不能在新源码上跳过哈希保护。

旧标签是历史恢复入口。私有素材按哈希追加，不因升级删除历史对象。Git 提交不会自动备份素材。

## 素材灾备

```powershell
python tools/offline.py backup-assets --output E:/seafile-offline-assets-v0.8
python tools/offline.py --assets E:/seafile-offline-assets-v0.8 verify-inputs
```

`backup-assets` 只导出当前指定 release 的对象，并对源和复制结果校验；多版本需逐版本备份，或完整复制整个对象库后分别校验。目标须不存在，不能位于 Git 仓库或源素材库内部。建议另保留仓库 Git bundle/镜像和第二处素材副本，定期离线演练重建。
