# DEV CI 与上游推进操作指南

本指南对应个人 Fork `quinn521/aegis-browser` 的 DEV `main`。它建立基础质量门和可核验的合并证据，不替代 Chromium 完整构建、真实网络、签名、设备或发布验收。

## 固定工具链与本地完整门

仓库在 `.mise.toml` 固定 Node `22.23.1`、pnpm `9.15.0` 与 Python `3.11.9`。使用 mise 时先安装并进入固定环境：

```bash
mise install
mise exec -- node scripts/ci/run-quality.mjs \
  --scope full \
  --base "$(git merge-base HEAD origin/main)" \
  --report-dir ".artifacts/ci/local-$(git rev-parse --short HEAD)"
```

入口依次执行工具链预检、`pnpm install --frozen-lockfile`、现有 `pnpm run quality:fast`、修订 4 冻结文件校验、临时副本中的 13 项离线预览检查、CI 门禁回归、工作流验证与源码前后摘要比对。任一阶段非零即整体失败；报告写入被忽略的 `.artifacts/ci/`，不得提交该目录。

待提交工作树可以先运行一次，但提交后必须对最终干净 HEAD 重跑。只有报告的 `inputSource` 与 `finalSource` 相同、`result=PASS`，且最终 HEAD/树与报告绑定时，才是有效的本地证据。修改、rebase、冲突修复或重新生成锁文件后旧证据失效。

## PR、main 与证据身份

`.github/workflows/quality.yml` 对所有目标为 `main` 的 PR（含 Draft）和 `main` push 运行基础门；普通开发分支不重复执行 push 全量门。固定检查名是 `quality-gate`。它仅在 `quality` 明确为 `success` 时成功，failure、cancelled、skipped、timeout 或缺失均不得放行。

报告区分四种身份：

- `B`：目标 base 的精确 SHA；
- `H`：PR 最终 head；
- `M`：GitHub PR 合并候选，必须恰好以 B/H 为两个父提交；
- `S`：合并后 DEV main 的实际提交。

PR 检查测试 M；main push 检查 S。协调者必须从 GitHub API 回读最新 run/job、run attempt、check source、H/B/M/S 和冲突状态，不能仅信任候选代码生成的报告或评论。PR 同步、base 前移、rebase、修复或 run attempt 更新后，旧结果不能转用。

人工补跑只允许在 `main` 上选择精确 `target_sha`，同时提供其精确祖先 `base_sha`。这种 `workflow_dispatch` 结果保留事件类型，不伪装成 PR 或正常 main push 结果。

## 初次启用保护

首次 CI PR 在保护尚不存在时按分步方式初始化：

1. 本地最终 HEAD 全量通过，并让 Draft PR 的真实托管 `quality` 与 `quality-gate` 成功。
2. 保存仓库合并设置、main 保护与规则集快照；记录实际 check 名和 GitHub Actions 来源。
3. 增量启用 PR 必需、严格 base 同步、`quality-gate` 必需、禁止强推/删除以及管理员不可绕过；保留任何更严格旧设置。
4. 回读设置，确认管理员账号和合并身份不在 bypass 列表。套餐或 API 拒绝时保持阻塞，不关闭必需检查或使用管理员绕过。
5. 独立 reviewer 覆盖最终 H 后由协调任务精确 HEAD 合并；等待 S 的真实 main push run 成功后才允许继续上游导出。

GitHub 原生 auto-merge 可保持关闭。当前自动推进由协调任务执行，独立模型 review 是外部证据，并不等同 GitHub 已强制一名独立人类批准。

## 上游公开导出

不要从 DEV main 直接创建携带个人历史的上游分支。以最新 `upstream/main` 新建隔离分支，只应用已经在 DEV 合并且公开允许的差异，然后运行：

```bash
node scripts/ci/check-public-diff.mjs \
  --base upstream/main \
  --head HEAD

mise exec -- node scripts/ci/run-quality.mjs \
  --scope full \
  --base upstream/main \
  --public-base upstream/main \
  --report-dir ".artifacts/ci/upstream-$(git rev-parse --short HEAD)"
```

导出检查同时检查最终差异和每个新提交的历史，拒绝 `AGENTS.md`、`agent.md` 及大小写变体的新增、修改、删除或重命名；上游 base 中已有但完全未改的同名文件不会误报。不能用 `.gitignore` 掩盖已经跟踪的个人文件，也不能先提交个人文件再在后续提交删除。

上游得到新的 B/H/M，必须重跑本地、托管 CI 和独立 review；DEV 的成功只作为来源映射，不是上游成功。

## Chromium 集成边界与故障分类

报告中的 `nativeIntegration` 采用保守分类：overlay、patch、C++/GN、Chromium 固定版本及关键生成/同步脚本变更为 `REQUIRED`；未明确分类的产品路径为 `REVIEW_REQUIRED`；纯文档和本基础 CI 变更可为 `NOT_APPLICABLE`。`quality:fast` 中的独立 native runner 不等于固定 Chromium workspace 的 GN/GTest 或浏览器集成证明。

目前没有为公开 PR 确认安全、隔离、可销毁的专用 Chromium runner，因此 C 层保持 `BLOCKED`。不得把日常电脑注册成公开 PR runner，不得让候选 PR 自选可信标签或 SHA，也不得与正在使用 `/Volumes/ExternalSSD/repositories/aegis-chromium-151/src` 的任务并发 reset、重放或构建。后续控制器必须从可信端校验产品 H、Chromium/V8 base、patched tree、patch series、GN args、目标与退出码，并隔离凭据、缓存信任域和构建锁。

故障按第一处真实失败分类：

- 产品失败：测试、合同、构建或源码稳定性失败，交实现者修复并重跑；
- 基础设施失败：runner、额度、下载、缓存、账号或 GitHub 服务故障，同 SHA 最多补跑一次；
- 身份/治理失败：H/B/M/S、attempt、check source、保护或 review 不匹配，停止合并；
- C 层环境缺失：保留 `BLOCKED`，不能降级成基础门 PASS 或删除必要测试。

CI 故障期间暂停自动合并。修复配置走普通 PR；产品回退走可审查 revert，不强推 main、不删除用户文件或本地证据。
