# DEV CI 与上游推进操作指南

本指南对应个人 Fork `quinn521/aegis-browser` 的 DEV `develop`。它建立基础质量门和可核验的合并证据，不替代 Chromium 完整构建、真实网络、签名、设备或发布验收。

## 规则入口与本机配置

本指南的 `develop` 版本是日常开发、PR 审查、合并与公开晋升流程的唯一维护入口。历史方案只用于追溯，不另行维护同一套操作规则。晋升用 `main` 可能尚未包含最新 DEV 流程，开始交付任务时应先刷新并读取 `origin/develop` 对应版本。

个人偏好和本机模型覆盖设置放在本机 `AGENTS.md`，通过 `.git/info/exclude`（或已有本机排除规则）忽略，不提交仓库。通用模型分工见下节；个人文件引用本指南，不复制整套分支流程。Git worktree 不会自动复制未跟踪文件；新工作区如需个人入口，应在本机配置并用 `git check-ignore AGENTS.md` 验证。已跟踪的文件不能依靠 ignore 隐藏，须单独处理，不能为清理而删除用户文件。

只有涉及开发交付、审查、合并或同步时才读取本指南；无关问答和不涉及交付的简单编辑不强制读取。

## AI 辅助开发的模型分工

以下是本项目使用 AI 辅助开发时的默认分工，不要求贡献者购买或使用特定模型。用户明确指定时按任务要求选择；模型分工不改变本指南的质量门和合并条件。

| 任务 | 模型与推理强度 | 交付要求 |
| --- | --- | --- |
| 日常实现、普通低风险修复 | `gpt-5.6-sol`，`high` | 代码、相关测试及实际执行结果；发现设计问题及时反馈。 |
| 涉及模块边界、接口或架构不确定性 | 先 `gpt-6-astra`，`high` 设计，再由 Sol 实现 | 设计明确范围、模块边界、接口、不变量、验收用例和回滚办法；实现复杂度决定 Sol 使用 `high` 或 `xhigh`。 |
| 复杂状态或跨模块实现 | `gpt-5.6-sol`，`xhigh` | 验证关键状态变化和跨模块回归。 |
| 聚焦调试多次不收敛 | 重新检查设计，再用 `gpt-5.6-sol`，`xhigh` | 根据失败证据调整假设，避免重复无效检查。 |
| 独立 Review | 新上下文的 `gpt-6-astra`，`high` | 对照原始需求检查代码，也可质疑架构；问题注明具体位置、触发条件和影响。 |
| 高风险设计或评审 | 按需使用 `gpt-6-astra`，`xhigh` | 说明关键风险及对应验证证据。 |
| 修复与复审 | 原实现者修复，同一独立评审者复审 | 关闭阻塞问题，验证相关回归，复审绑定最终 HEAD。 |

普通低风险改动无需单独的架构阶段；是否需要独立评审按任务要求和本指南的交付门槛判断，不能据此免除合并前的必要评审。单纯问答、只读检查和一般规划沿用当前任务模型；形成架构设计交付物时使用上表的设计分工。

模型和推理强度需要在任务或工具中显式选择，文档不会自动切换运行中的模型。要求的模型不可用时，说明实际使用的模型、未知的推理强度及尚缺的阶段，不把替代执行报告成指定模型已完成。

独立评审使用原始需求、设计、精确 base/head SHA、代码差异和验证证据，不继承实现者的讨论上下文。修复仍由原实现者完成；复审保留评审者上下文并覆盖最终代码。模型评审不能替代测试、托管 CI 或服务端要求的人工 Approve，也不授予合并、发布、凭据使用或绕过保护的权限。最终 HEAD 的必需门槛通过后，才进入后续合并与合并后 CI 验证。

所有 `feat(...)` 功能 PR 都必须在同一 PR 内同时交付两类可执行测试：**单元测试**直接验证新增逻辑、边界和错误返回；**回归测试**固定至少一个既有安全/兼容性不变量或本功能可能重新引入的历史故障。两类测试都必须在最终 HEAD 实际执行并通过，缺任一类不得合并；不能以静态字符串检查、仅编译通过、增加 mock 数量或其他模块的既有测试代替。若改动实际上只有文档，应使用 `docs(...)` 而不是用 `feat(...)` 绕过该门槛。

## Codex + GitHub Copilot + Codacy 三层职责

三层工具各自负责不同证据，不能互相替代：

| 层 | 主要职责 | 不能替代 |
| --- | --- | --- |
| Codex | 设计、实现、修复、测试执行、按本指南准备 PR 与证据 | 独立 Review、托管 CI、Codacy 服务端分析、GitHub 服务端保护 |
| GitHub Copilot code review | 在 GitHub PR 上读取项目上下文做语义 Review，重点发现行为、接口、安全/隐私、状态机、测试缺口和治理问题 | Codacy 的确定性扫描、独立 reviewer、必需检查、人类审批 |
| Codacy Production | 静态质量与安全规则、复杂度/重复代码及已接入指标的持续分析 | 业务语义 Review、真实运行测试、Chromium/设备/签名/发布证据 |

仓库级 Copilot 规则放在 `.github/copilot-instructions.md`；对 CI/治理文件的额外约束放在 `.github/instructions/ci-governance.instructions.md`。Copilot 应优先报告可复现的语义问题，不重复低价值格式噪音。服务端是否启用自动 Review、是否在每次 push 后复审、是否允许 Copilot approval 计入合并条件，都必须从 GitHub 实时回读，不能由这些 Markdown 文件推断。

日常 `develop` 路径为：Codex 在隔离分支实现并跑最终 HEAD 本地门 → GitHub PR 上进行 Copilot Review 与独立 Review → `quality-gate`、Codacy 和实际保护条件分别核验 → 合并到 `develop` → 再核验 S 的真实 push CI。任一 Review 或门禁发现问题都回到原实现者修复，新的 HEAD 使旧 Review/检查证据失效时必须重新覆盖。

上游公开 PR 使用同一套仓库指令，但 GitHub Copilot 自动 Review 的服务端策略独立配置在 `gcsagroup/aegis-browser`，仅针对上游 `main` 的 PR；推荐每次新 push 自动复审、Draft 不自动 Review，并保持 Copilot approval 不计入必需审批。这样 Copilot 提供第二视角，但不会获得绕过人工与确定性门禁的合并权。

## 分支职责与日常路径

个人 Fork 的 GitHub 默认分支为 `main`，用于仓库默认入口、对外展示和公开晋升；开发、维护与发布准备的工作主线仍为 `develop`。日常开发从最新 `origin/develop` 建隔离 `codex/*` 分支，PR 目标为 `develop`，合并后验证该提交的真实 push CI。`main` 不接收个人日常功能 PR。准备公开晋升时先确认个人 `main` 没有未发布的独有产品提交，并只以 fast-forward 同步最新 `upstream/main`；再把更新后的 `main` 合入 `develop`，解决冲突并验证 develop。随后从最终 `develop` 创建一次性 promotion 分支，按下述 README 镜像规则处理后向个人 `main` 提 PR，经最终 HEAD Review、托管 CI 与合并后 main push CI 固化个人发布候选。个人 `main` 成功后，才以该精确状态向 `gcsagroup/aegis-browser:main` 提 PR。禁止强推 main/develop，也不能将 develop 的绿灯直接当作 main 或上游通过。

当前 README 采用临时镜像规则：个人 `main` 的 `README.md`、`README.zh-CN.md`、`README.zh-TW.md` 必须与当次 `upstream/main` 对应文件逐字一致；`develop` 上的 README 修改继续保留用于开发，但在公开晋升时暂不带入 `main`。promotion 分支应从最终 `develop` 创建，再从已刷新后的 `upstream/main` 恢复这三份 README，确认三者 blob/hash 一致后才向个人 `main` 提 PR。该规则只忽略这三份 README，不允许借此丢弃其他 develop 改动。

2026-09-15 的分支迁移取代之前 DEV main 的工作方式；PR #20 的 main-only 验证方案已废止，不能沿用其目标分支或旧结果放行 develop。既有历史 SHA/报告保留原事件和分支身份。

`quality.yml` 同时保留 `develop` 与 `main` 的自动验证，便于个人开发与公共上游使用相同配置；其他分支不重复运行 push CI。push 并发组包含完整 ref，develop/main 互不占组；PR 按编号隔离并取消旧运行，人工补跑按 run ID 隔离。默认分支、保护与 Codacy 分支配置属于服务端设置，须由协调者独立回读，不由 YAML 或徽章证明。

## 固定工具链与本地完整门

仓库在 `.mise.toml` 固定 Node `22.23.1`、pnpm `9.15.0` 与 Python `3.11.9`。使用 mise 时先安装并进入固定环境：

```bash
mise install
mise exec -- node scripts/ci/run-quality.mjs \
  --scope full \
  --base "$(git merge-base HEAD origin/develop)" \
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
| C++ | `aegis_access` standalone 的 `access_route_planner.cc`、`site_proxy_rule_group.cc` 与 `request_ownership_registry.cc` | 同次 native binary 执行路由/协议组合同以及 RequestOwnershipRegistry 单元与回归合同，并使用匹配 clang/llvm profile 生成 LCOV；完整 Chromium、GURL/SQLite、GN/GTest 和浏览器集成证据仍单独记录。 |
| Python | `local-pypi-proxy.py` 与两个 Access vector generators | 固定 coverage.py 隔离 venv；复用 proxy 4 项测试和 native 生成器调用，另有两个拒绝 fixture，combine 后生成 XML/JSON/LCOV/text；两个 prototype worker 未测。 |
| Swift | `apps/ios` 的 25 个产品 Swift 文件 | 独立 `iOS Coverage` workflow 在双 Simulator 上生成 xccov JSON，状态为 `MANUAL_REPORTING_WORKFLOW`；它不属于当前 macOS 必需门，也不是实机、签名或发布证据，Codacy 转换仍待办。 |
| Bash / PowerShell | 手动 Linux kcov 与 Windows Pester coverage jobs | 只代表列明脚本的行为/行覆盖；macOS 专属 shell 分支和真实 Windows UI 仍按报告列为未测。 |
| Java | `Driver.java` Android instrumentation 验收工具 | 独立 `Android Java Coverage` workflow 在专用 API 36 emulator 上执行六项 fixture 并生成 JaCoCo exec/XML，状态为 `MANUAL_REPORTING_WORKFLOW`；它不属于 macOS `quality-gate`，也不代表浏览器 Java runtime、真机或发布验收。 |

当前只关注 macOS；Linux、Windows、iOS 和 Android 验证后置，仅保留手动入口。共享合同、静态产品拓扑与本机 fixture 继续验证。

HTML、CSS、JSON/data 与 GN/GNI 按静态/数据输入单列，不伪造行覆盖率。native 分类仍可对未知产品路径给出 `REVIEW_REQUIRED`；本质量工作不会把它改成 `NOT_APPLICABLE`。

`quality:fast` 保留 core、Mac 脚本、Agent UI、本地模型验证和共享合同。Android 工具/打包 fixture 及 Windows WinRM 自测移至显式 `pnpm run quality:other-platforms`；该入口不会被自动质量门调用。JavaScript c8 `--all` 仍保留完整生产脚本清单，未执行的平台脚本如实进入分母，不通过裁剪统计范围提高覆盖率。

`.github/workflows/other-platform-coverage.yml` 仅支持 `workflow_dispatch`，保留原 Linux Bash 与 Windows PowerShell job 的固定工具、SHA 绑定、失败传播和 artifact。它们不作为自动 CI 的 skipped checks 出现。

## Codacy Production 准备状态

根 `.codacy.yml` 已按官方 Java glob 语义精确忽略依赖、构建/生成输出与补丁运输文件，未整体排除 `third_party`，因此 `apps/browser/overlay/third_party/aegis*` 中的本仓集成仍可分析。配置文件不能启用 Codacy 工具；工具选择与仓库授权必须在 Codacy UI 完成。

README 的 CI 与 Codacy Grade 徽章均选择个人 Fork 的 `develop`。2026-09-15 协调者已在 Codacy UI 回读 App 接入、develop 分析启用且设为默认，main 保留分析。此配置状态不等于当前提交的 Grade 或覆盖率已通过；协调者仍须核对项目对应 `quinn521/aegis-browser`、目标分支 `develop` 及当前被测 SHA，不能复用 main 分支的旧 Grade 作为新分支结果。覆盖率上传仍需单独配置与验收。

质量工作流只生成并上传 CI artifact，不加入 token 或 coverage upload job；Grade 徽章不是覆盖率上传证明。未来上传必须使用短期仓库级 secret，禁止给 fork PR 暴露 secret，并把覆盖报告绑定到实际被测提交：PR `pull_request` CI 测试的是 GitHub 合并候选 M，不是产品分支 H；develop/main push 则绑定 S。本地账号、密码、API token 与仓库 token 均不得进入仓库、日志或公开文档。

待提交工作树可以先运行一次，但提交后必须对最终干净 HEAD 重跑。只有报告的 `inputSource` 与 `finalSource` 相同、`result=PASS`，且最终 HEAD/树与报告绑定时，才是有效的本地证据。修改、rebase、冲突修复或重新生成锁文件后旧证据失效。

## PR、develop/main 与证据身份

`.github/workflows/quality.yml` 对所有目标为 `develop` 或 `main` 的 PR（含 Draft）和这两个分支的 push 运行 macOS 优先基础门；普通开发分支不重复执行 push 全量门。固定汇总检查名是 `quality-gate`。它仅在唯一必需执行 job `quality` 明确为 `success` 时成功，结果映射必须恰好包含 `quality`；failure、cancelled、skipped、timeout 或缺失均不得放行。

`.github/workflows/ios-coverage.yml` 是独立报告 workflow。仅通过 `workflow_dispatch` 手动生成报告，PR/develop/main push 不自动运行。它继续严格绑定当次 GitHub tested SHA，测试失败仍为非零；当前分支保护的必需状态检查为 `quality-gate`，因此 iOS 报告不改变 macOS 优先的合并门。

`.github/workflows/android-java-coverage.yml` 也是独立报告 workflow，仅通过 `workflow_dispatch` 手动运行，PR 和 develop/main push 不再自动触发。当前仅推进 macOS，其余平台后置。它构建 normal 与 coverage 两种验收工具以证明普通 APK 不含 JaCoCo，仅在专用 emulator 运行 coverage APK 的六项 fixture，并把 JaCoCo exec/XML、原始 class 摘要与实际 GitHub tested SHA 写入 artifact。固定检查名为 `android-java-coverage`，不并入 macOS `quality-gate`；`browserTested=false` 明确保留工具覆盖率与浏览器 runtime 验收的边界。

报告区分四种身份：

- `B`：目标 base 的精确 SHA；
- `H`：PR 最终 head；
- `M`：GitHub PR 合并候选，必须恰好以 B/H 为两个父提交；
- `S`：PR 合并后目标分支（`develop` 或个人 `main`）的实际提交。

PR 检查测试 M；develop/main push 检查 S。协调者必须从 GitHub API 回读最新 run/job、run attempt、check source、H/B/M/S 和冲突状态，不能仅信任候选代码生成的报告或评论。PR 同步、base 前移、rebase、修复或 run attempt 更新后，旧结果不能转用。

人工补跑只允许在 `develop` 或 `main` 上选择该次所选分支的精确 `target_sha`，同时提供其精确祖先 `base_sha`。这种 `workflow_dispatch` 结果保留事件类型，不伪装成 PR 或正常 develop/main push 结果。

## 初次启用保护

首次 CI PR 在保护尚不存在时按分步方式初始化：

1. 本地最终 HEAD 全量通过，并让 Draft PR 的 `quality` 与 `quality-gate` 全部成功；其他平台报告不属于当前自动门。
2. 保存仓库合并设置、develop/main 保护与规则集快照；记录实际 check 名和 GitHub Actions 来源。
3. 增量启用 PR 必需、严格 base 同步、`quality-gate` 必需、禁止强推/删除；人工审批、最后推送批准、旧批准失效及管理员策略按实际服务端配置记录，不擅自降低已有规则。
4. 回读设置，记录管理员账号和合并身份的 bypass 状态；不得把管理员可绕过误报为不可绕过。套餐或 API 拒绝时报告限制，不关闭必需检查。
5. 独立 reviewer 覆盖最终 H 后由协调任务精确 HEAD 合并；日常功能先等待 S 的真实 develop push run 成功。公开晋升还必须完成最新 upstream/main → 个人 main 快进同步、main → develop 对齐，再从最终 develop 创建 promotion 分支、按 README 镜像规则恢复三份 README 后向个人 main 提 PR，并等待个人 main 的 S push run 成功后才允许创建上游 PR。

对 `develop` 或个人 `main` 的交付 PR，在服务端保护能够阻止未完成 Review/CI 的前提下，创建 PR 后开启 GitHub 原生 auto-merge；Review、Codacy 或 CI 发现问题时先修复并 push 新 HEAD，让 review 与检查覆盖最终提交。若仓库只有同一管理员身份、GitHub 人类 Approve 无法满足，则不得伪造自我批准；只能在独立 Review 与所有必需检查成功后由管理员精确合并。独立模型 Review 是外部证据，并不等同 GitHub 已强制一名独立人类批准。

## 上游公开导出

不要从 DEV `develop` 直接向上游提 PR。先按本指南完成个人 `main` 的晋升：个人 main 已 fast-forward 吸收最新 `upstream/main`，develop 已反向吸收该 main，最终 develop 已生成 promotion 分支并按 README 镜像规则恢复三份 README，该 promotion PR 已 Review/CI/合并且 main push CI 成功。随后以个人 `main` 的精确 SHA 作为上游 PR head，并以最新 `upstream/main` 为 base；创建上游 PR 前，在独立干净 worktree 中 checkout 该 `origin/main` 精确 SHA，使下列 `HEAD` 明确等于待发布的个人 main，再运行：

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

CI 故障期间暂停自动合并。修复配置走普通 PR；产品回退走可审查 revert，不强推 develop 或 main、不删除用户文件或本地证据。
