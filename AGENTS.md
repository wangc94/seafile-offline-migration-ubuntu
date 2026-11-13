# 项目协作约定

先读 `README.md`、`docs/SESSION_HANDOFF.md`、`docs/00-project-baseline.md`、`docs/09-known-issues.md`，再改动。仓库是方案和源码的权威记录，不能依赖聊天历史续接。

- 核心要求：对应 Git 版本加私有素材库可以在无网络、无 Docker daemon 的构建机重建相同离线部署包。
- 不提交 `.env`、数据库、镜像 TAR、业务文件、原始 inspect、包含密码的 resolved Compose 或安装日志。素材保存在仓库外；公开记录只写校验值与必要身份字段。
- 不更改冻结基线以使测试“通过”。历史源码在 `releases/<版本>/source/` 独立冻结；历史版本可指定 --release 或按标签检出。有意变更新建发布清单并记录原因。
- v0.8 是历史候选安装器，未通过 Ubuntu 两种模式的业务验收。区分：本次执行验证、历史用户报告、待实机验证、已知问题。
- 不运行原安装器来做开发验证：它会操作 `/opt`、Docker 和数据卷。允许 Bash 语法检查及使用合成凭据的 Compose config。
- 不自动删除业务目录、恢复状态或原始卷，不执行 `docker compose down -v`、`docker volume prune`。
- 修改后执行相关检查：`python -m unittest discover -s tests -v`、`python tools/check_repository.py`；涉及 Compose 执行 `python tools/check_compose.py`；安装器执行 `bash -n installer/install.sh`。更新交接、决策与证据。
- 发布不能仅靠成功退出码：核对完整文件集合、所有 SHA256、确定性归档结果，业务验收另行记录。

<!-- context7 -->
Use the `ctx7` CLI to fetch current documentation whenever the user asks about a library, framework, SDK, API, CLI tool, or cloud service, including syntax, configuration, migration, debugging, setup and CLI usage. Prefer this over web search for library docs. Do not use for refactoring, writing scripts from scratch, business logic debugging, code review, or general programming concepts.

1. Resolve: `npx ctx7@latest library <official-name> "<full specific question>"`.
2. Choose the best `/org/project` match using name, relevance, source reputation, snippet count and benchmark. Try an alternate query if necessary.
3. Fetch: `npx ctx7@latest docs <libraryId> "<full specific question>"`; answer using the fetched documentation.

Always resolve first unless the user supplies a valid `/org/project` ID. Use version IDs from results for version-specific questions. Maximum three commands per question. Never include secrets. On quota errors tell the user and suggest `npx ctx7@latest login` or `CONTEXT7_API_KEY`; do not silently fall back to memory. Run outside the default sandbox when permitted; on DNS/network errors retry outside it subject to host permissions.
<!-- context7 -->
