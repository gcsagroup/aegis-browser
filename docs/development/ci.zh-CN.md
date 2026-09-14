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

入口依次执行工具链预检、`pnpm install --frozen-lockfile`、`pnpm run quality:fast`、分语言覆盖率生成与校验、许可证元数据记录、修订 4 冻结文件校验、临时副本中的 13 项离线预览检查、CI 门禁回归、工作流验证与源码前后摘要比对。任一阶段非零即整体失败；报告写入被忽略的 `.artifacts/ci/`，不得提交该目录。

## Lint、单元测试与覆盖率口径

根 `pnpm run lint` 使用 ESLint 9 flat config，实际分析 `packages/core/src/**/*.ts` 与 `scripts/ci/**/*.mjs`。它采用 JavaScript/TypeScript recommended 的正确性规则；`tsc --noEmit` 仍由独立 `typecheck` 执行。为了接纳现有代码，例外限制在具体范围：测试文件允许现有 `@ts-nocheck`、精度边界常量与字符串 escape；`privacy/pii.ts` 保留现有正则 escape；`structure-signature.ts` 保留两个空扩展 interface。新增 CI fixture 会证明合法代码退出 0、未定义标识符退出非 0。这里没有把 ESLint 描述成格式化器或完整风格门。

基础 `quality` job 复用一次现有套件，不为覆盖率重跑整套测试。其报告目录包含 `coverage-manifest.json`，各语言分别记录 scope、报告路径、摘要与哈希，`aggregateCoverage` 固定为 `null`：

| 语言 | 本 job 的覆盖范围 | 报告与边界 |
| --- | --- | --- |
| TypeScript | `packages/core/src` 的 28 个生产 `.ts`；同次 Vitest 170 项单测 | LCOV、JSON summary、text；所有未执行生产文件仍进分母。Access 的 TS vectors 只校验共享结构，不等价于 C++ 行为覆盖。 |
| JavaScript | `scripts/ci`、core 工具与 `apps/browser/scripts` 中受控的 Node `.js/.mjs/.cjs` | c8 从同次 Node 子进程的 V8 数据生成报告，并用 `--all` 纳入未执行生产脚本；renderer/WebUI JavaScript 未测。 |
| C++ | `aegis_access` standalone 的 `access_route_planner.cc` 与 `site_proxy_rule_group.cc` | 同次 487-check native binary 使用匹配 clang/llvm profile 生成 LCOV；完整 Chromium、GURL/SQLite、GN/GTest 和浏览器集成未测。 |
| Python | `local-pypi-proxy.py` 与两个 Access vector generators | 固定 coverage.py 隔离 venv；复用 proxy 4 项测试和 native 生成器调用，另有两个拒绝 fixture，combine 后生成 XML/JSON/LCOV/text；两个 prototype worker 未测。 |
| Swift | `apps/ios` 的 25 个产品 Swift 文件 | 独立 `ios-coverage` required job 在双 Simulator 上生成 xccov JSON；它不是实机、签名或发布证据，Codacy 转换仍待办。 |
| Bash / PowerShell | 独立 Linux kcov 与 Windows Pester required jobs | 只代表列明脚本的行为/行覆盖；macOS 专属 shell 分支和真实 Windows UI 仍按报告列为未测。 |
| Java | Android instrumentation | 专用 emulator CI 另行串行接入；在该结果出现前保持 `SEPARATE_FOLLOW_UP`。 |

产品交付仍以 macOS 为第一优先级；`ios-coverage` 只验证仓库中既有 iOS 代码，不改变产品路线图或平台排程。

HTML、CSS、JSON/data 与 GN/GNI 按静态/数据输入单列，不伪造行覆盖率。native 分类仍可对未知产品路径给出 `REVIEW_REQUIRED`；本质量工作不会把它改成 `NOT_APPLICABLE`。

## Codacy Production 准备状态

根 `.codacy.yml` 已按官方 Java glob 语义精确忽略依赖、构建/生成输出与补丁运输文件，未整体排除 `third_party`，因此 `apps/browser/overlay/third_party/aegis*` 中的本仓集成仍可分析。配置文件不能启用 Codacy 工具；工具选择与仓库授权必须在 Codacy UI 完成。

当前状态是：`CONFIG_PREPARED`、`APP_AUTH_PENDING`、`FIRST_ANALYSIS_PENDING`、`COVERAGE_UPLOAD_PENDING`。`APP_AUTH_PENDING` 表示当前 GitHub token 无法核实 Codacy App 安装/授权状态，并不证明已经安装或尚未安装。管理员后续只授权目标 Aegis 仓库，核对 Codacy 项目确实对应 `quinn521/aegis-browser` 的 DEV `main`，再以首次分析显示的精确 SHA 验证身份。

本阶段只生成并上传 CI artifact，不加入 token、coverage upload job 或 Codacy/coverage 徽章。未来上传必须使用短期仓库级 secret，禁止给 fork PR 暴露 secret，并把覆盖报告绑定到实际被测提交：PR `pull_request` CI 测试的是 GitHub 合并候选 M，不是产品分支 H；main push 则绑定 S。本地账号、密码、API token 与仓库 token 均不得进入仓库、日志或公开文档。

待提交工作树可以先运行一次，但提交后必须对最终干净 HEAD 重跑。只有报告的 `inputSource` 与 `finalSource` 相同、`result=PASS`，且最终 HEAD/树与报告绑定时，才是有效的本地证据。修改、rebase、冲突修复或重新生成锁文件后旧证据失效。

## PR、main 与证据身份

`.github/workflows/quality.yml` 对所有目标为 `main` 的 PR（含 Draft）和 `main` push 运行基础门；普通开发分支不重复执行 push 全量门。固定汇总检查名是 `quality-gate`。它仅在 `quality`、`ios-coverage`、`shell-coverage`、`powershell-coverage` 四个必需 job 都明确为 `success` 时成功；failure、cancelled、skipped、timeout 或缺失均不得放行。

报告区分四种身份：

- `B`：目标 base 的精确 SHA；
- `H`：PR 最终 head；
- `M`：GitHub PR 合并候选，必须恰好以 B/H 为两个父提交；
- `S`：合并后 DEV main 的实际提交。

PR 检查测试 M；main push 检查 S。协调者必须从 GitHub API 回读最新 run/job、run attempt、check source、H/B/M/S 和冲突状态，不能仅信任候选代码生成的报告或评论。PR 同步、base 前移、rebase、修复或 run attempt 更新后，旧结果不能转用。

人工补跑只允许在 `main` 上选择精确 `target_sha`，同时提供其精确祖先 `base_sha`。这种 `workflow_dispatch` 结果保留事件类型，不伪装成 PR 或正常 main push 结果。

## 初次启用保护

首次 CI PR 在保护尚不存在时按分步方式初始化：

1. 本地最终 HEAD 全量通过，并让 Draft PR 的四个必需执行 job 与 `quality-gate` 全部成功。
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
