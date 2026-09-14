# DEV 到上游的 CI、审查与自动合并实施方案

日期：2026-09-14。状态：实施设计，尚未代表 CI 已建立或合并门槛已启用。

## 1. 目标与当前事实

用户要求：先在个人 Fork 的开发分支建立 CI；推送前本机运行完整质量门；经独立 review、CI 和合并后 main 验证，再向上游提交。实现任务负责代码和修复，当前协调任务负责独立 review 与 auto merge。个人 `AGENTS.md` / `agent.md` 不进入上游。

仓库角色：

| 角色 | 仓库与分支 | 用途 |
| --- | --- | --- |
| DEV | `quinn521/aegis-browser:main` | 个人开发集成主线；DEV 是仓库角色，不是长期分支名 |
| 开发 | 个人 Fork 的 `codex/*` | CI 与功能切片先向 DEV main 提 PR |
| 上游提交 | 个人 Fork 的独立 `codex/upstream-*` | 携带已在 DEV 验证的公开变更 |
| 上游 | `gcsagroup/aegis-browser:main` | 接收经 DEV 验证的 PR，独立执行自己的门槛 |

本次只读核验：DEV main 为 `2817334499cd76f39b3d2e8ee758e6870cbfe6c3`；Actions 工作流数量为 0，main 未保护，`allow_auto_merge=false`。当前调用账号有 DEV admin 权限。上游 main 为 `b5fffc324ca9b85ec4cbc244165434f044ac57ec`。这些是观察值，实施与合并前必须刷新。

现有 `package.json` 固定 `pnpm@9.15.0`，`quality:fast` 已包含 core 检查、原生独立 runner、脚本、Agent UI、Android 工具、模型中转、仓库合同和 core 构建。历史 169 个 core 用例、487 次 native 断言仅对应旧功能提交 `fe807d4`，测试数量不作为今后固定通过阈值。

构建区已存在，Chromium 151 的 Access 独立 GN 目标历史上编译和运行通过。完整 Chrome、真实网络和 G0 尚未验收。本次不改变访问服务修订 4 的冻结行为。

## 2. 交付顺序与职责

完整顺序：

1. 从最新 DEV main 创建隔离开发分支，实施 CI 或功能切片。
2. 提交前运行完整本地质量门；生成最终提交后核对源码树及证据身份。
3. 向 DEV main 提 Draft PR，在 GitHub 托管 runner 上执行质量门。
4. Astra high 独立 review；Sol 修复，原 reviewer 在保留上下文的情况下复审最终 HEAD。
5. 当前协调任务确认本地、CI、review、分支保护和冲突状态，执行 DEV 合并。
6. 对 DEV main 的实际合并提交执行 push CI。失败则停止向上游推进。
7. 创建只包含已验证公开变更的上游提交分支；排除个性化文件，重新运行本地及 PR CI。
8. 上游 PR 满足自身最终代码审查和必需检查后才合并；再检查上游 main。

CI 实现采用 Sol xhigh；架构调整采用 Astra high；独立 review 使用 fresh-context Astra high。实现任务不得自行批准自己的 review，也不自行执行合并。用户已授权当前协调任务在门槛全部满足后自动合并，正常绿灯不重复请求确认。

## 3. 本地与托管质量门共用入口

### 3.1 建议接口

新增一个轻量编排入口，例如 `scripts/ci/run-quality.sh`，提供 `--scope full --base <SHA> --report-dir <path>`。具体语言可由实现者选择，但必须直接复用现有脚本，不复制测试实现。

`full` 顺序包含：

1. 环境预检：Node、pnpm、Python、C++ 编译器、Git、ripgrep、必要的 shell 工具；不满足时明确非零退出。
2. 锁文件安装：固定 pnpm，使用 `pnpm install --frozen-lockfile`，不得静默改写依赖声明或工作区配置。
3. `pnpm run quality:fast`，完整保留现有阶段，不通过删测试或吞错误修复 CI。
4. 冻结合同校验：本期修订4的 `freeze.json` 本身、覆盖范围及受保护文件须与可信目标base中的已批准冻结版本一致；再校验哈希、字节数、必需文件、修订与数量一致性。不能只拿候选提交自己的清单验证自己的文件，也不能把历史 `documentChecks: PASS` 当作本次执行结果。上游首次引入冻结文件、目标base尚无清单时，使用已独立验证的冻结提交 `d60b5952b40e511d6f98f3f33be926dbe7ab1eb7` 的清单与文件作为初始基准，由可信协调端固定来源和对象，不能让PR参数自选“可信基准”。未来有明确授权的重新冻结应单独审查并更新基准，不夹带在普通CI/功能PR中。
5. 交互预览：运行既有 `verify-preview.cjs`；将其 `jsdom@26.1.0` 依赖纳入锁文件，消除本机 `NODE_PATH` 隐式依赖。保持冻结脚本字节不变，在外围解决结果输出和依赖问题。
6. 本次改动涉及 workflow/门禁脚本时执行其有意义的单元和行为回归，以及 workflow 语法/表达式校验。
7. 与 base 的差异校验和运行后源码完整性核对；不忽略脚本意外修改 `pnpm-workspace.yaml`、锁文件或冻结文件。

不得一边执行 `quality:fast`，一边又独立重复跑它已经覆盖的每个子项。Chromium 构建是独立层，不藏入该入口并默认触发大型下载。

### 3.2 提交前后身份

允许本地在待提交工作树上执行检查；报告记录输入源码清单/树摘要、base、工具版本和开始结束状态。最终提交必须与已测输入逐字对应，且运行期间没有源码变更，否则证据失效并重跑受影响门槛。

可选 pre-push hook 只是便利入口，不能替代服务端检查，也不能批量覆盖用户现有 Git hooks。第一期默认显式运行并由协调任务验证，不引入强制 hook。

### 3.3 初期 runner 基线

首期完整 `quality:fast` 使用 GitHub 托管 macOS runner，以适配现有 Apple/签名相关脚本夹具；建议从 `macos-15` 开始，在实施时核验镜像和 Xcode 可用性。固定 Node 22 的明确补丁版本、pnpm 9.15.0、Python 3.11 的明确补丁版本；实际版本落入配置与报告。不要使用本机绝对解释器路径。

基础门不得下载 Chromium、真实签名、使用测试账号或改系统代理。Linux 可作为后续额外平台；若改为 Linux 主门，须先证明完整现有套件在该环境通过，不通过跳过 macOS 断言获得绿灯。Windows/Android 实机和跨平台浏览器发行仍是独立验收。

## 4. PR 与 main 工作流

建议新增 `.github/workflows/quality.yml`，先在 DEV 分支实现，配置可移植到上游。

| 事件 | 用途 | 执行内容 |
| --- | --- | --- |
| `pull_request` → main | 每个 PR，包括 Draft | 完整基础质量门、变更范围与身份记录、结果汇总 |
| `push` → main | 实际合并后 | 完整基础质量门，绑定实际 main SHA |
| `workflow_dispatch` | 受控补跑 | 校验输入 SHA/分支关系；不伪装成正常 PR 或 main 触发 |

第一期不为普通开发分支再设置重复的 push 全量任务；PR 的 synchronize 事件即可覆盖后续推送。同一个 PR 的新提交取消旧 PR 运行；PR、main 与人工补跑使用不同并发组。main 按提交串行，不能用新 main 的成功宣称被取消的旧 main 已通过。

第一期无需合并队列；以后启用 merge queue 时必须增加 `merge_group` 事件及对应身份验证。PR 目标基线变化时，严格保护要求更新分支后重新运行，不能复用旧 base 的合并候选结果。

不要在整个必需工作流上使用 `paths-ignore`。设置固定、唯一的汇总 job 名称，例如 `quality-gate`，以 `always()` 收尾，逐项断言必需 job 的结果为 `success`。不能以汇总 job 自身执行成功、任务被跳过、缓存命中或空测试集合来代表测试成功。非适用的重量级测试只能标记为 `NOT_APPLICABLE` 并带可信的范围判断；必跑基础质量门始终执行。

普通质量工作流默认 `permissions: contents: read`，checkout 不持久化写入凭据；第三方 Actions 固定经核验的完整 commit SHA，依赖安装遵守锁文件。PR 标题/分支名等不可信字段经参数或环境传入，不插值为 shell 代码。不在 `pull_request_target` 中检出并运行 PR 代码，也不通过带写权限的 `workflow_run` 消费候选 artifact 后执行脚本。缓存按 OS/工具链/锁文件及可信域划分，只缓存可再生依赖，不能缓存成功结论或让外部 PR 污染受信任构建缓存。

初期超时预算：环境安装 10 分钟、基础质量门 30 分钟，artifact 保留 14 天；观察首轮真实运行后再调整。相同 SHA 的基础设施失败最多自动重试一次；产品失败交还实现者，禁止无止境重试。

## 5. 三种源码身份与证据

定义 `H=PR最终head`、`B=目标base`、`M=GitHub生成的合并候选`、`S=最终main提交`。

- 本地检查绑定 H 或可验证地等价于 H 的完整输入树。
- 独立 review 至少覆盖 B→H 的产品/测试差异；本地 rebase 或冲突修复后 H 变化必须复审。
- 默认 PR CI 测试 M，并记录关联的 H、B、M；不能把 `GITHUB_SHA` 无条件叫作 PR HEAD。
- 若工作流另测 H，报告明确所测对象；不能据此跳过目标集成验证。
- main push CI 绑定 S；H/M 成功不能替代 S。
- 上游 base 不同或过滤文件形成新提交时，得到新的 H/B/M，需要重新验证；DEV 证据只提供可追溯来源。

建议报告最小结构（工具版本和哈希按实际追加）：

```json
{
  "schemaVersion": 1,
  "repository": "owner/repo",
  "event": "pull_request",
  "pullRequest": 123,
  "headSha": "H",
  "baseSha": "B",
  "testedSha": "M",
  "testedTree": "tree",
  "runId": "run-id",
  "runAttempt": 1,
  "scope": "full",
  "result": "PASS",
  "checks": [],
  "nativeIntegration": "NOT_APPLICABLE"
}
```

GitHub 运行元数据是核验身份的来源。PR 可编辑的 JSON、评论、文档中的 PASS 和上传 artifact 不能单独授权合并。协调任务回查 API 的 run/job、源码 ref、调用方、workflow 身份与最新 HEAD，报告只作辅助。失败日志必须保留有效退出码，使用管道输出时启用 `pipefail`；最终报告不能被一次成功 cleanup 覆盖成 PASS。

本地证据保存在被忽略的 `.artifacts/ci/<head-or-tree>/<run>/`，只上传脱敏摘要和必要日志；不打包工作目录、用户 Profile、`.local`、wheelhouse 或凭据。检查运行报告不得重写冻结的 `preview-checks.json`；若现有预览工具写回文件，外围在任务临时副本执行并核对原文件未变。

## 6. Chromium 集成层

基础层通过只证明仓库质量。下列变更另要求真实 Chromium 证据：原生 `.cc/.h`、overlay、patch/series、GN args、Chromium 版本/依赖、生成器、网络入口和连接生命周期。对未分类的生产路径保守要求人工核对，不能默认“不需要”。纯文档/CI配置可以不构建 Chromium，但 CI 改动若影响 native 执行或可信调度，必须跑该调度回归。

| 范围 | 最小验证 |
| --- | --- |
| Access 组件内部变更 | 补丁/overlay 一致、GN 生成、受影响目标构建、实际 GTest |
| 新增 url/net 等 Chromium 依赖 | 上述全部；相应调用与依赖目标的真实编译，不用纯 clang runner 代替 |
| Network Service、取消、连接池或代理组合变更 | 受影响集成/browser tests、必要的 Chrome 构建和可观察的网络场景 |
| 发布候选 | 完整平台构建、运行和专项验收；不由基础 CI 自动授予发布资格 |

现有外盘 Chromium 构建区目前被访问服务实现任务使用。CI 工作不得并发 reset、重放补丁或构建同一输出目录；第一期只定义入口和证据合同，第二期接入专用受控环境。访问服务原生变更在集成层未就绪时需明确保留原生门槛，不能凭基础 CI 自动合并。

专用 runner 不能直接暴露给公开 `pull_request`。采用私有控制仓库或等价隔离的受控调度：由可信控制端读取已经审查的精确 SHA，先验证其所属仓库/PR和当前状态，再授权构建；被测代码的 workflow、标签、PR标题或 artifact 不能自行决定可信级别。执行环境应隔离主机凭据与其他项目，可销毁；复用大型源码/缓存时隔离可信域并加锁。仅“同仓库分支”或一次界面批准不等于代码安全。

该层报告同时绑定产品 H、Chromium/V8 base 与 patched commit/tree、patch series 与 GN args 哈希、工具链、目标、测试退出码。控制器核验产物来源及精确身份；无法证明时保持阻塞。没有安全隔离 runner 时交付状态写 BLOCKED，不自动把用户日常电脑注册成公开仓库 runner，也不把本机手动运行称为 hosted CI。

## 7. 分支保护与 auto merge

首次启用按以下顺序，避免要求不存在的 check 导致无解等待：

1. CI 开发 PR 先在本机完整通过，再使 PR 工作流真实运行成功。
2. 记录 GitHub 实际生成的 job/check 名称和预期来源 App。
3. 保存现有 DEV 分支保护/规则集和仓库合并设置快照；增量配置 PR 必需、`quality-gate` 必需、严格基线同步、禁止强推与删除，保留已有更严格条款。传统保护启用 `enforce_admins`；规则集采用等价的管理员不可绕过设置，并确认当前合并账号/App不在 bypass 列表。只是不使用 `--admin` 并不能保证管理员受保护约束。
4. 回读验证配置，包括管理员与实际合并身份不可绕过。首个 CI PR 本身也通过独立 review 与真实 CI 后合并；配置接口被拒绝则如实报告权限/套餐阻塞，不绕过。
5. 合并后确认 S 的 main push 工作流真实启动并成功，再开始正常自动推进。

第一期 auto merge 由当前协调任务执行，GitHub 原生 `allow_auto_merge` 可以保持关闭。不要盲目使用只等 CI 的 `--auto`，因为本仓库尚无可靠的机器可核验独立 reviewer GitHub App。

合并前一次完整核对：PR 属于本任务范围、不是 Draft、H/B 没变、完整本地证据有效、对应 PR CI 成功、必要 Chromium 证据满足、fresh-context 独立 review 无阻塞、修复后的 review 覆盖 H、无冲突、保护配置有效。随后使用精确 head 条件提交合并请求，例如支持匹配 head 的 CLI/API。base 移动由严格分支保护阻止竞态；API失败刷新状态再判断，不带 `--admin` 绕过。

GitHub 同一账号不能给自己提供有效的人类批准，这不应导致虚构 review。第一期将独立模型评审保留为协调任务的可信证据，GitHub 分支保护负责 CI；必须明确这种分工不等于 GitHub 已强制验证独立模型审查。后续如需脱离协调任务的全自动合并，单独建设隔离的审查签发身份/必需 check，并防止 PR 自己产生批准，不能将 self-reported JSON 当批准。

检查脚本/工作流由 PR 本身修改时，独立 reviewer 必须审查门禁是否被削弱；协调器读取的合并政策来自受信任控制版本，不能直接执行候选 PR 的“允许合并”脚本。

合并提交优先保留可追踪历史；使用 squash 时记录 DEV 合并提交与来源 PR/head 的映射。main 失败则暂停后续合并和上游提交，修复或经 review 的 revert；不强推 main。

## 8. 个人配置排除与上游同步

DEV 可以保留个性化 `AGENTS.md`、`agent.md`、大小写变体及已确认的本机配置。上游检查针对相对上游 base 的实际差异和输出提交历史，覆盖新增/修改/删除/重命名的个人指令文件；上游本来存在且未变的同名文件不能被删除或误判。对用户已确认的个性化目录维护精确清单，不笼统排除全部 Skills 或文档。

不要直接从 DEV main 建带个人文件历史的提交再“删除文件”来掩盖：以最新上游 main 新建导出分支，应用已在 DEV 合并的公开差异，保留 upstream 原有个性化路径内容；新提交中不携带被排除文件历史。输出一份源 PR/DEV S→上游新 H、允许差异与排除路径摘要。发现意外额外文件、二进制或非任务提交即停止导出并人工检查。

Fork main 上已经跟踪的个人文件不靠 `.gitignore` 移除；不为上游污染检查而删除用户本地文件。个人路径、令牌、runner 注册信息放 GitHub 仓库设置/私有控制环境，不写可公开 workflow 或文档。可移植质量脚本/workflow随功能进入上游。

上游 PR 对新 H/B/M 完整验证。DEV main CI 尚未成功时不得推进；上游无 CI 配置时优先提交 CI 引入/适配，不能把 DEV 的绿灯当作上游已通过。GitHub `GITHUB_TOKEN` 触发后续事件存在限制，不能假定自动创建 PR 或合并后必然产生预期运行；控制任务使用已有授权身份调用时仍需核对真实 run 已出现。

## 9. 文件与接口交付建议

以下名称可以在实现时等价调整，职责与行为不得省略：

| 路径 | 职责 |
| --- | --- |
| `.github/workflows/quality.yml` | PR/main 托管质量门与固定汇总 check |
| `scripts/ci/run-quality.sh` | 本地和 CI 共用的完整编排入口 |
| `scripts/ci/check-access-freeze.mjs` | 冻结哈希/字节数/编号合同校验 |
| `scripts/ci/check-public-diff.mjs` | 上游导出前个人配置、范围与路径检查 |
| `scripts/ci/*_test.*` | 真实失败传播、身份和导出边界行为测试 |
| `docs/development/ci.zh-CN.md` | 日常命令、证据位置、合并及故障操作指南 |
| `package.json` / lockfile | 固定预览依赖与质量入口；最小变更 |

合并前状态读取/保护配置可先采用当前协调任务的明确操作与证据，不急于写有管理权限的自动化工作流。第二阶段再增加经过 review 的私有 native 控制器及构建入口。禁止新增通用任意 shell dispatch、共享管理员令牌或默认发布任务。

## 10. 必须实测的验收用例

| 编号 | 场景 | 预期 |
| --- | --- | --- |
| CI01 | 干净 checkout、无本机 node_modules/NODE_PATH | 固定依赖安装后完整质量门通过 |
| CI02 | 本地最终源码与提交源码不同，或运行中源码变化 | 证据无效，禁止推送放行/合并 |
| CI03 | core/native/脚本任一真实失败 | 完整入口、对应job、汇总均非零失败 |
| CI04 | 冻结文件被改一字节、缺文件，或同步篡改文件及清单哈希/覆盖范围 | 对照可信冻结基准失败，不自动刷新freeze |
| CI05 | 仅文档PR | 基础质量门仍出现并执行，native按可信范围可不适用 |
| CI06 | 必需job cancelled/skipped/missing/timeout | 汇总或协调门阻止合并 |
| CI07 | PR再推新提交、rebase、base前移 | 旧H/B/M结果不可放行，新运行/复审覆盖新身份 |
| CI08 | PR的GITHUB_SHA是合并候选 | 报告明确H/B/M，不错绑head |
| CI09 | 本机绿色但GitHub安装/测试失败 | 不合并，按环境或代码分类处理 |
| CI10 | Fork保留AGENTS.md，导出公开内容 | Fork文件仍在，上游diff和新增提交无个人文件 |
| CI11 | agent.MD等大小写变体、重命名、上游已有同名文件 | 泄漏被拒绝，既有上游文件不误删 |
| CI12 | DEV合并成功但main push CI失败 | 不向上游推进；保留失败run，进入修复流程 |
| CI13 | 报告伪造PASS、SHA不符、runAttempt旧、API未知 | 协调器拒绝，不降级为允许 |
| CI14 | 外部PR请求使用专用runner、同构建区已有任务 | 不自动执行不可信代码，不并发改同一构建区 |
| CI15 | 上游导出改变HEAD或冲突修复 | 重新review与验证，不继承DEV批准 |
| CI16 | 阻塞review尚未关闭但CI绿色 | 协调任务不合并 |
| CI17 | 正常CI PR最终HEAD审查与CI通过 | 精确HEAD合并；真实main运行通过后才继续 |
| CI18 | 首次CI不存在、设置尚未生效 | 分步初始化并回读；不伪称分支保护已完成 |
| CI19 | 合并账号拥有admin，base移动或必需检查失败 | 管理员也受规则约束，合并被拒绝 |

负例先用临时 Git 仓库/事件夹具验证，不污染产品分支；首次启用还需实际 Draft PR 证明失败 check 在 GitHub 可见且保护生效。演练用PR可在保留证据后关闭，不把故意失败代码合入 main。不复制实现本身来写“必然通过”的测试。

## 11. 交付切片、工期与完成定义

| 切片 | 交付 | 估计 |
| --- | --- | --- |
| A：基础CI | 共用完整入口、依赖固定、托管工作流、冻结/公开差异检查、回归 | 1–2工作日 |
| B：合并治理 | 分支保护回读、H/B/M/S证据、review协调和DEV→上游流程实测 | 约1工作日，可与A后半段重叠 |
| C：Chromium集成 | 受控runner/隔离、构建身份、并发锁、真实GN/GTest及所需集成场景 | 环境具备时2–4工作日 |

基础可用预计2–3工作日；含安全可用的专用构建层约4–7工作日。前提是GitHub额度/网络可用、依赖安装正常、native环境可安全隔离；runner缺失不能承诺固定完成时间。首轮hosted结果出来后更新估算。本方案不是访问服务全部功能的工期。

A/B完成：配置代码已独立review、DEV PR实际hosted CI通过、保护配置有效、已合并且S的main CI成功、上游导出无个人配置、日常流程可复现。C完成：不是只有YAML或文档，而是可信环境中真实编译测试通过，并能阻止不适用/不可信/失败输入。未满足层级明确标记pending，不声称全链路已完成。

## 12. 回滚与停止规则

保留设置变更前快照；配置修复通过普通PR执行，恢复设置只针对本次引入项且不削弱既有门槛。CI故障期间暂停auto merge，不以关闭required checks代替修复。代码回滚使用可审查revert，不删源码、凭据、用户Profile或大型缓存。

出现并发工作树写入、HEAD变动、未知API结果、native构建区占用、runner信任不明确、个人文件泄漏或未解决review时暂停依赖动作，仍可继续无依赖的本地修复。基础设施阻塞与产品失败分别记录；不无意义反复请求同一授权。

## 13. 新实现任务交接

实施工作树：`/Volumes/ExternalSSD/repositories/aegis-browser-worktrees/ci-gates-plan`，初始分支 `codex/ci-gates-plan`，base为本文件第1节DEV SHA；本方案仅新增文档，未修改现有功能和CI。实现前刷新origin/main，与功能任务协调package.json等共享文件，原Chromium构建区不可并发占用。

功能任务 `01a09eaf-6ce3-76f3-9412-542511a3d978` 继续访问服务；CI任务专职本方案A/B/C。先完成A/B到可review的DEV Draft PR，不在缺少native隔离环境时停止所有基础工作；C如阻塞，明确所需环境和已完成边界。每次交付提供PR、base/head、命令/退出码、run/attempt、review状态和下一步。合并由原协调任务执行。

## 14. 官方行为依据

- [GitHub：必需状态检查故障排查](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks)：最新提交、路径过滤和合并队列的检查要求。
- [GitHub：工作流事件](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows)：PR合并候选身份、push、dispatch与merge_group语义。
- [GitHub：受保护分支](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)：严格状态检查与分支更新要求。
- [GitHub：安全使用参考](https://docs.github.com/en/actions/reference/security/secure-use)：公开仓库的不可信代码与self-hosted runner风险。
- [GitHub：触发工作流](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow)：GITHUB_TOKEN生成事件的触发限制，实施时以实时官方文档和实际run为准。
