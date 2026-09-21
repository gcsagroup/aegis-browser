# Aegis 访问服务 V1.0：当前开发计划

## 2026-09-21：个人 Codacy 与上游 README 隔离维护

用户要求恢复个人 main/develop 的 Codacy，并在晋升时忽略个人徽章。三份个人 README 使用个人项目 `72c871eba82e471ebc05eaacd4d45218`，分别标注 main/develop；上游保留其项目 `7b3008e649154ca0a7d5906c514488cc`。内部晋升保留个人 README，独立上游导出候选才恢复本次 upstream/main 的三份 README，并校验其他文件不变；同步回个人分支也保留个人展示。流程以 [DEV CI 指南](../../development/ci.zh-CN.md) 为准。

本项只维护展示和晋升隔离，不升级 native/G0 证据。实时回读 PR #139 已合并到 `develop@2c591b739071487b82995e155d602a1f094caa09`，该提交 CI run `35580551685` 成功；下方 PR #139 OPEN/Draft 描述是旧快照，不能作为当前状态。本项最终 HEAD 的本地质量、托管 CI、独立审查及个人 main 恢复 PR 分别在交付 PR 中记录，未完成项不能写作 PASS。

## 2026-09-21：commit/publish snapshot 阶段（待验证）

本阶段基于 `develop@3154d39871ddd592a1be609abf9c90c78d7e29c6`，范围为普通 DIRECT/PROXY 网站协议组事务。此前上游 PR #19 已合并；当前交付复用 [Fork PR #139](https://github.com/quinn521/aegis-browser/pull/139)。2026-09-21 用户要求 review 进度、更新 plan/Handoff，并在本 PR 门禁通过且实际合并后进行一次上游晋升。以下历史核验记录不作为本阶段证据。

冻结事务顺序为：验证可信 selector 与 store → PREPARED journal 预留 operationSequence → 从旧 durable base 构造完整候选 → 发布到浏览器 request runtime → 向所属 NetworkContext 发布精确 operation/G/S/E 与 owner/partition → 全部候选 ACK → 再原子 durable commit → finalize。PREPARED 的 `committed_policy_generation` 始终为 0，候选及成功提交的 policy generation 都等于预留的 operationSequence。请求路由只读取内存快照，不读取 SQLite。`RepublishCurrentConfigWithAck` 不能作为候选发布证据。

Profile 持有首个可信 store（含 ephemeral 会话库），后续 mutation 传空指针复用，禁止替换库。候选保留无关网站组和独立规则。当前 transport 只有 partition/host 粒度：同 host 的其他规则需要相反 DIRECT/PROXY 策略时，发布前返回 `kUnsupportedTransportScope`，保留原状态；不宣称已实现按 top-level-site 区分的 transport。浏览器同步重绑定保留端点的 policy generation，并在 DIRECT 时从 CustomProxyConfig 的 exact-host 列表移除目标网站、保留其他网站；候选 config 与 metadata 使用同一 Mojo channel 顺序发送。失败仅在候选仍精确匹配时恢复旧快照/端点，并 supersede journal；清理写入失败透传 store 错误并保留待恢复边界。提交前重新核对 runtime、权威 selection source 的 S/E、完整端点及所有 NetworkContext 的集合；新 context、版本变化、错误或丢失 ACK、30 秒超时均阻止提交。迟到 ACK 不能复活已取消的事务；失败的 exact identity 释放 tracker 容量。Network Service 在受信任的 context channel 上保存 owner 绑定、单调的候选回执；它不从数据库重建策略。BLOCK/ALLOW 的屏障及取消流程、可信 UI 入口、真实身份/节点提交与 Xray 集成不属于此阶段。

| 证据 | 当前边界 |
| --- | --- |
| 实现及测试源码 | 已增加 candidate builder、coordinator transaction、runtime rollback、transport/version ACK，以及 unit/真实主导航回归源码；顺序补丁 0152/0153/0154/0155 必须与 overlay 对齐；0154 修复 ProxySelectionGenerationState 的 out-of-line 构造/析构。 |
| 本地 standalone C++ | 本轮执行通过 845 checks，包含 tracker version/abort 回归；不是 SQLite/GN/GTest/browser 执行证据。最终 HEAD 的完整质量报告另存 artifact 并在 PR 绑定。 |
| Chromium/GTest/真实入口 | **NOT_RUN / BLOCKED**：已核实旧 PR135 retry3 权威退出文件为 1，首个失败是 `ProxySelectionGenerationState` 的 inline constructor / missing out-of-line destructor style 检查。本 PR 以 0154 修复；正从已释放的旧候选创建独立 APFS 验证副本，复用依赖及缓存后重绑本 PR 补丁树。缓存和旧二进制均不是当前 PASS；旧工作区不改动。 |
| 独立审查 | GPT-6 独立源码审查与指定 PRO 的冻结源码包审查在 `0e4bb97` 未发现剩余源码阻塞；PRO 包审查不等于直接读取 checkout。二者均未清除 native 欠账。本轮 style/文档新提交仍需最终 HEAD 复审。 |
| 本地 full quality | `0e4bb97eb738f9d270d8fbedc2909df380851343` 的 `local-0e4bb97/report.json` 为 PASS，sourceStable=true，输入/最终摘要同为 `1842ba2323647ace020943db5711b2a9c8d7cca44ce44e4affb606ce3faf5acc`（1168 files），nativeIntegration=REQUIRED。该记录不能转用于本轮新 HEAD。 |
| Hosted CI / 合并 | `0e4bb97`：CI run `35577430465` attempt 1 的 quality/quality-gate SUCCESS；C++ run `35577430464` SUCCESS；Codacy ACTION_REQUIRED：10 项函数复杂度/长度、2 项 Markdown 空行。本轮按准备、发布、ACK 与回滚边界拆分函数并移除多余空行，不降低检查阈值，待新 HEAD 重跑。PR #139 仍 OPEN/Draft；新 HEAD 必须重新核验。 |
| G0 | **UNVERIFIED**。基础质量或测试源码不能升级为 native/runtime 验收。 |

合并前必须在同一固定候选实际执行 coordinator、store、runtime、transport、dispatch/tracker 单元与回归，并执行 `MainNavigationConsumesPreparedSnapshotBeforeCommit`、`MainNavigationRoutingIsolatedAcrossProfiles` 及既有导航/redirect/Worker/SharedWorker/Service Worker/missing endpoint/BLOCK/LoadingPredictor/frame prefetch 矩阵。零匹配、非零退出、不同候选均失败。之后冻结最终 HEAD，重跑 full quality（sourceStable 与源码摘要一致）、hosted 必需 CI 和独立 PRO 复审。**存在上述欠账时 PR 保持 Draft，不开启可导致提前合并的 auto-merge。**

本轮后续顺序：

1. 在独立候选中完成编译与上述全部必需回归，绑定 Chromium/V8 patched tree、GN args、二进制摘要和真实退出码；失败先修复，G0 不提前升级。
2. 更新本 PR 文档并冻结最终 HEAD，取得 local full quality、hosted 必需 CI 与独立 PRO review-clear 后 squash merge #139；回读实际 MERGED 和合并提交 S 的 develop push CI。
3. 仅在 S 的 develop CI 通过后做一次上游晋升：刷新 upstream/main，按分支指南安全同步 main/develop；从最终 develop 建个人晋升分支并保留个人 README；上游导出候选的三个 README 与本次 upstream/main 保持一致。个人 main 晋升 PR 使用 merge commit；核验 main push CI 后再提 upstream/main PR，分别审查 public diff、最终 HEAD quality/CI 和实际合并状态。
4. 本轮完成上述晋升前，不开始下一依赖功能阶段。后续仍从最新 develop 新建 `codex/*` 隔离 worktree，一阶段一 PR，并在同 PR 更新 plan/Handoff。

## 历史核验记录（2026-09-20，非当前门禁结论）

状态日期：2026-09-21（Asia/Shanghai）。本页是从当前 `develop` 继续实施的入口；[交接与精确证据](handoff-20260920.zh-CN.md)记录本次基线和待验证事项，[A01–A118 / PF01–PF13 验收追踪表](acceptance-tracker.zh-CN.md)是逐行覆盖与证据的唯一台账，[P0 历史实现记录](p0-implementation.zh-CN.md)保留切片过程。行为、验收项和 G0–G3 门槛以[冻结规范修订 4](spec.zh-CN.md)及[冻结清单](freeze.json)为准；本文不修改合同。分支、PR、Review 与最终 HEAD 门禁按[DEV CI 与上游推进指南](../../development/ci.zh-CN.md)执行。

## 当前判断与交付边界

2026-09-20 核验的 `quinn521/aegis-browser:develop@287aa54c678e8c174b6b286e387a1457cf3a218f` 已包含路由与匹配、网站协议组、原子规则存储和恢复、请求归属、BLOCK 屏障、定向取消、五项 generation 的生产所有者与 tuple 组装。真实 factory 已覆盖导航、文档子资源、重定向、Worker 主脚本及有 frame/无 frame 子资源、process-backed Service Worker 主/导入脚本及子资源、frame prefetch 和 LoadingPredictor 预取。这里的“存在”只代表源码和对应局部合同；不能推断用户开关、服务端或端到端流量已可用。

目前仍缺把可信网站选择、身份与节点提交、持久化、快照发布、执行点 ACK 和界面状态连接起来的生产协调器。在本次源码盘点中，`CommitIdentity`、`CommitSelection`、`PublishCommittedPolicySnapshot` 的调用位于定义/测试，未找到完整的生产调用链；合入前需在最新树复核。`SetSiteProxy` 用户入口、Xray/受控 HTTP→REALITY 主链路、托管注册/签名配置/租约/探测、真实字节计量/额度/公平限制也尚未闭合。WebSocket、preconnect、BFCache、prerender、通用 prefetch 和 Service Worker update checks 尚无可声明的完整覆盖；现有 prefetch 覆盖不能扩展解释为这些入口均已支持。

G0 保持 **UNVERIFIED**，G1–G3 **未达到**。早于补丁 `0150` 的固定 Chromium 151 候选已经完成 `-j4 unit_tests browser_tests` 构建尝试并以退出码 `1` 结束；第一处真实失败是 `IdentityGenerationState` 的 Chromium style 检查，要求复杂构造函数和析构函数采用显式 out-of-line 定义。PR #135 以新的顺序补丁 `0151-fix-aegis-identity-generation-state-style.patch` 修复该问题，但旧候选没有包含 `0150`/`0151`，因此其结果只能作为历史失败证据。最终候选仍需从 PR #135 的最终补丁树重新构建并实际运行所需 GTest/浏览器真实入口回归。[交接页](handoff-20260920.zh-CN.md)逐项区分仓库质量门、Chromium 构建和运行证据。

当前阶段由 [Fork PR #135](https://github.com/quinn521/aegis-browser/pull/135) 交付 Profile-owned `AccessServiceCoordinator` 生命周期、同 Profile 复用/跨 Profile 隔离单元回归，以及两个普通 Profile 的真实主导航路由隔离回归。独立 Review 先发现 coordinator 单测未进入开发者 `root_extra_deps` 测试图，本 PR 已补齐 `apps/browser/args/aegis.gn` 与 wiring 回归；随后旧固定 Chromium 候选暴露 `IdentityGenerationState` 构造/析构 style 编译失败，本 PR 追加顺序补丁 `0151` 将两者移到 `.cc` 定义。对 `da55df40ba992d669b454bd4579cac722e395c43` 的下一轮 PRO 复审又发现两个 P1：coordinator 独立测试目标仍使用基础 `run_all_unittests` runner，不能建立 `TestingBrowserProcess`；两个直接构造 `TestingProfile` 的生命周期测试也没有 `BrowserTaskEnvironment`。当前修复已把该目标改为 Chrome unit harness（`chrome/test:test_support`、`test_support_unit` 与 `content/test:test_support`），并将直接构造 Profile 的用例放入持有 `BrowserTaskEnvironment` 的 fixture，同时重新生成顺序补丁 `0150`。因此 `da55df40` 的本地质量、hosted CI 和独立复审证据全部视为 stale；PR #135 仍必须在新的**最终 HEAD**重新取得这些证据，并让同一最终补丁树的固定 Chromium 编译/运行停线通过后才可合并。

## 先关闭现有 Chromium 验证欠账

**暂停扩展新的请求入口功能**，直到 PR #135 最终补丁树对应的固定 Chromium 候选完成编译且全部当前必需的真实入口回归执行通过，阻塞失败关闭。旧候选已以退出码 `1` 暴露第一处源码失败，`0151` 是针对该失败的最小顺序修复；修复后必须在最终 patched tree 上重新构建，不能把旧候选的部分对象或日志拼接成 PASS。已计划的窄范围 prefetch 过滤器只能证明其列明子集，不能代替导航、重定向、Worker、BLOCK、在途取消、缺失代理 endpoint、Profile 隔离和真实派发入口用例。对每项列出确切测试名/过滤器、执行退出码、请求与 origin/proxy 观测、未覆盖场景；仅测试 helper 或在测试中直接调用 factory 的用例，应注明没有证明真实入口接线。失败时先确定第一处源码/构建/环境问题，修复并重跑相关回归；`BLOCKED` 或 `NOT_RUN` 均继续暂停，不以源码存在或 GN 生成作为继续扩展入口的通行证。

推进到下一请求入口实现的条件是：当前候选 `unit_tests` / `browser_tests` 目标完成构建，导航、重定向、Worker、BLOCK/在途取消、缺失 endpoint、Profile 隔离及真实派发入口的当前必需回归在同一最终源码/补丁树全部实际执行 **PASS**，所有阻塞失败已修复并重跑通过，结果与剩余非阻塞覆盖空白登记到[验收追踪表](acceptance-tracker.zh-CN.md)。任一必需回归为 `FAIL`、`BLOCKED` 或 `NOT_RUN` 时继续暂停新增请求入口；仅允许独立测试准备、接口设计和证据盘点并行，不得改动正在构建的工作区。满足此开发顺序条件仍不宣告 G0 或产品链路通过。

## 依赖顺序与可评审单元

| 顺序 | 对应单元 | 下一交付和前置条件 | 完成证据 |
| --- | --- | --- | --- |
| 1 | P0 验证底座 | 旧 149-patch Chromium 候选已因 `IdentityGenerationState` style 编译错误退出；在同一固定 Chromium 基线重放 PR #135 最终的 151-patch 序列（含 `0150`、`0151`），再关闭编译和真实入口回归欠账，评估固定源码、工具链和 GN 参数下的 HTTP 代理/拒绝路径。发现失败先修复对应最小源码或环境问题。 | 记录源码树、补丁、GN args、目标、退出码、测试名、过滤器和原始日志；按规范第 12 节逐项判 G0，不能只凭 GN 成功或窄范围 prefetch PASS 判通过。 |
| 2 | P1–P2 与 P4–P5 的最小协调闭环 | 在现有 Profile/StoragePartition 所有权基础上，定义并接入生产 coordinator：可信当前 host → 普通 `SetSiteProxy` 的网站协议组选择（DEV/Alpha 的三策略、ALLOW/BLOCK 为独立调试规则，按冻结合同协调）→ identity、selection、base-proxy 等真实代次 → PREPARED journal → candidate snapshot 发布到内存与所属 NetworkContext → 请求派发/取消的执行点 ACK → 原子 durable commit 与恢复 → UI 状态。先以受控本地 HTTP fixture 验证，Xray 依赖留在后续单元。 | 两个普通 Profile/多个 partition 无串用；超时和取消不接受迟到结果；重启只恢复已提交状态；退出账户不直连回退；BLOCK 先装本地屏障，按流终止且失败保留；保存失败不显示“已保存”；关闭恢复原有代理设置。记录 G/S/E/identity/base-proxy 精确版本和 ACK。 |
| 3 | P3 + P3a | 在协调闭环上接固定 Xray 资产与 Profile 级 HTTP 入口，打通受控服务端的 VLESS + RAW(TCP) + REALITY + XTLS Vision；接入自动登记、签名配置、准入、租约、健康探测、稳定分配和确认故障后的切换。 | 实际 HTTP→REALITY 往返、凭据隔离、超时/撤销/入口故障不直连、节点保持与切换记录；服务和部署参数版本绑定。SOCKS5 与兼容出站在 P7 完整验收。 |
| 4 | P3c–P3d | 主链路稳定后实现服务端实际双向字节计量、幂等账本与额度预算；执行物理 VPS/账户限速、公平分配与并发准入。跨节点账本和租约先用多节点 fixture 验证，部署第二个执行节点前完成真实联调。 | 对账、重试/乱序/断线/周期重置、额度耗尽在途截断、Vision/splice 快路径计量与预算实测，记录误差和容量上限；UI 秒级变化不能代替服务端对账。 |
| 5 | P3b + P4–P6 完整面 | 补精确正常/失败目标采集与全部可信请求归属、真实终止句柄；三策略联合发布和版本化撤销；提供 `SetSiteProxy`、工具栏/管理页、状态/用量与 DEV/Alpha 调试视图，并验证四渠道原生接口隔离。 | 导航、子资源、下载/流、frame/Worker 等逐入口覆盖报告；BLOCK/ALLOW 的旧代次和旧 ACK 竞争；离线关闭/阻断仍可操作；开关与连接状态分离；Beta/Release 无调试管理接口。 |
| 6 | P7 | 补全 SOCKS5 Profile 认证、WS+TLS 兼容出站、OTR/Guest、WebSocket、preconnect、BFCache、prerender、通用 prefetch、Service Worker update checks 等剩余适用请求矩阵。 | 两入站×两出站、临时 Profile 和复杂入口按冻结适用项逐项运行，未知/无可信归属保持受限；不能用已覆盖的 frame prefetch 代替通用 prefetch。 |
| 7 | P8 | 在最终候选头重放全部补丁，完成四渠道构建、性能/故障回归、全新安装/升级/回滚和交付档案。 | 按规范第 12、14 节将 A/PF 用例与源码、配置、部署、规模、日志绑定后分别判 G0–G3；发布动作另循项目授权。 |

第 2 步是可评审的最小协调里程碑，不宣称独立达到 G0 或“按钮可用即 Alpha”。可以先并行准备受控服务端环境和测试资源，但依赖它们的端到端结论必须等实际链路运行后记录。

实施与测试两条工作线共享同一固定候选合同：产品 head/tree、Chromium 基线及 patched tree、patch series、GN args、渠道/配置、用例和观察点。只有一名明确的隔离构建工作区所有者能修改补丁树或启动/重启构建；测试线准备受控代理与 origin fixture，分别记录两端日志、同一请求的关联 ID、直连/代理路径和故障注入结果。合成代理 fixture 自行响应时 `origin_count=0` 可以成立；真实转发代理则会合法触达 origin，必须以受控代理出口/连接与关联日志证明走代理，并证明没有 DIRECT origin 路径，不能只信转发请求头或笼统要求 origin 零请求。按目标和拒绝/BLOCK 生效时间记录基线与增量：缺 endpoint 的被拒绝请求在有界窗口内对代理及 origin 均零派发；重定向可先有一次合法代理请求，但被拒绝的重定向目标不得新增派发；BLOCK 前已在途的代理请求保留在基线，验证屏障生效后无新命中派发及在途终止时序，不抹掉历史计数。每个零增量断言都需同配置的健康控制请求证明日志确实能记录流量，超时/无响应本身不算 PASS。同时验证额度耗尽、离线、重启和迟到回调时没有 DIRECT fallback。测试证据只记录脱敏 ID、字节/状态与必要时序，不泄露凭据或请求秘密。真实受控服务尚未运行的场景不得记服务端 PASS。

此后每项新**产品功能**须在同一 PR 交付可运行 unit 与真实入口 regression，并在该 PR 最终 HEAD 对匹配固定候选实际执行两者；overlay/顺序补丁/BUILD 接线一并审查。未执行即登记 `NOT_RUN`，不算验收。只改文档的 PR 不需要补造产品测试；过去对 [Fork PR #129](https://github.com/quinn521/aegis-browser/pull/129)/[上游 PR #18](https://github.com/gcsagroup/aegis-browser/pull/18) 的一次性源码晋升例外不适用于新功能。各行实现、映射、执行、结果与覆盖分别更新[验收追踪表](acceptance-tracker.zh-CN.md)，不能因一个子场景通过把主行升为 PASS。

阶段交付采用“一阶段一 PR”：每完成一个可评审单元，都在该 PR 内同步更新本开发计划与对应 Handoff，记录本阶段精确边界、验证结果和下一依赖；随后由独立 PRO reviewer 对最终 HEAD 复审。下一阶段若依赖上一阶段代码，必须等上一 PR **实际合并**且合并后的最新 `develop` push CI 通过后，再从最新 `develop` 创建新的隔离工作分支；等待期间只做只读准备。

## macOS / 浏览器 CI 分层建设（待实施）

以下是**建设目标，不是现有 CI 已提供的能力或新的合并豁免**。2026-09-20 源码核对：`.github/workflows/quality.yml` 的 `quality-gate` 仅 `needs: quality`；`run-quality.mjs` 的 `nativeIntegration=REQUIRED` 是变更分类，不会自动执行固定 Chromium；`.github/workflows/cpp-unit-tests.yml` 与 full 质量门有 standalone C++/GN wiring 重复；`chromium-candidate.yml` 仍是手动三平台流程，`candidate.py` 的 macOS 默认目标为 `chrome`、`aegis_agent_core_unittests`、`aegis_github_update_unittests`，未把 Access `unit_tests`/`browser_tests` 的执行纳入必需门。因此现有 hosted `quality-gate` 成功不能推论 L2/L3 或 G0。建设只面向 **macOS ARM64**；最低支持版本与当前系统的验收矩阵待产品支持合同确认，其他平台后置，不借三平台旧流程冒充已完成 Mac 门。

| 层 | 拟建执行与产物 | 目标门槛和边界 |
| --- | --- | --- |
| L0 快速静态门 | 拟建整合现有 lint/类型检查、补丁格式与顺序/overlay/GN 接线、冻结清单与 license 元数据检查，并补齐尚未接入的 secret 检查；输出明确检查项、版本与首个失败。 | 每个相关 PR 快速反馈；secret 扫描须避免把密钥写进报告。路径/依赖/构建脚本变更不能泛化为纯文档或免测。 |
| L1 单元合同门 | 同一次测试执行生成 unit/合同结果及按 TypeScript、C++、Python 等实际 scope 分开的覆盖率报告，记录未测文件与阈值；不为 coverage 再跑同套测试。 | 每个相关 PR 必需；源码存在、覆盖率数值或独立 standalone PASS 不替代 L2/L3。 |
| L2 固定 Chromium 集成门 | 在可信隔离 Mac ARM64 候选上核对 Chromium/V8 基线、全部补丁、overlay tree、GN args，实际编译 Access 相关 `unit_tests`、`browser_tests` 和所需目标，运行精确 GTest filter；保存 patched tree、二进制 digest、目标/退出码/日志。 | 相关产品 PR 必需；GN 生成、对象编译或 `nativeIntegration=REQUIRED` 标签都不算 L2 PASS；零测试匹配必须失败。 |
| L3 真实浏览器门 | 用 L2 的同一精确产物执行导航、重定向、Worker、Profile 隔离、BLOCK/在途终止、缺 endpoint、真实派发入口与无 DIRECT fallback；按受控 proxy/origin 日志和关联 ID 记录正反路径及 helper-only 限制。 | 每项相关新产品功能 PR 必需，unit 与真实入口 regression 同 PR、最终 HEAD 均实际运行；当前停线条件仍先满足上节全部必需回归 PASS。零匹配、只启动不请求或只有合成 helper 不算 L3。 |
| L4 夜间扩展门 | 在锁定候选上扩展[131 行 A/PF 台账](acceptance-tracker.zh-CN.md)映射、性能、并发、长跑与故障注入；按 PF 样本/规模/分布和未覆盖行输出机器可读结果（映射结构尚待实现）。 | 夜间或专门容量窗口运行；与当前候选相关的失败阻止晋升/分发，修复并重验。L4 不能取代 PR 的 L0–L3 必需用例，也不将部分子项提升主行 PASS。 |
| L5 Mac 候选分发门 | 对固定候选 App 进行启动/退出、下载、权限、睡眠/唤醒、网络切换、进程恢复、四渠道隔离；再分别验证 Developer ID、Hardened Runtime、公证票据与 Gatekeeper、Helper/Xray 资产完整性、全新安装、升级和回滚。 | 分发前验收，不是日常 PR 绿灯；绑定确切 App/配置/系统矩阵。ad-hoc 签名只用于开发测试，不算分发通过。没有候选包与真实运行就保持 `NOT_RUN`，不能从 L0–L4 推断可发布。 |

实施顺序先建立**可信 L2/L3 产物与校验其结果的汇总门**，并用当前固定候选关闭入口回归欠账；再在证据等价的前提下去重 standalone/wiring、改进缓存和分片；之后建设 L4，再建设 L5。先评估 GitHub 托管 Mac ARM64 的容量和隔离能力；不足时才设计可销毁、专用且隔离信任域的 runner，不把日常电脑接成公开 PR runner。外部 PR 不能直接在长期自托管主机上执行候选代码，也不得接触签名身份或生产凭据；候选自身生成的 receipt 不作为可信门禁判据。

拟建汇总门由可信端按变更路径、依赖和实际产物决定所需层；未知分类升级人工/更严格验证，不能自动判 N/A。纯文档变更未来可以轻量化，但**当前 `full` 规则和[DEV CI 指南](../../development/ci.zh-CN.md)继续有效**，须通过另行 CI 变更和审查才调整。门应对必需层 `failure`、`missing`、`cancelled`、`unknown`、stale SHA、零测试匹配一律失败；N/A 需可信分类及理由。建立这些故障 fixture 后才切换保护条件；优化失败通过可审查 revert 恢复原 full 门，不删除历史证据。

为降低重复构建，一次编译的精确产物可供 L2/L3 多个测试分片使用；各分片独立 Profile、端口、受控代理与日志，并校验同一 artifact digest，不能在分片间串用状态。缓存键至少包括产品源码/补丁树、Chromium/V8 版本、工具链、SDK、架构与 GN args；缓存仅复用构建输入，不复用 PASS。普通功能 CI 锁定版本；监控上游最新 Chromium 的兼容性另设独立非必需任务，不让上游漂移改变 PR 判定。

每层证据沿用[DEV CI 指南](../../development/ci.zh-CN.md)的 B/H/M/S 身份：记录受测 SHA、artifact digest、run/attempt、测试过滤器及匹配数、真实退出码、原始日志和首个失败归属。PR 更新、base 前移或重跑 attempt 后旧证据不能转用；flake 记录触发条件并修复，隔离有独立登记且不得将必需安全测试移出门禁后宣称绿灯，不靠反复重跑掩盖第一次失败。机器可读 A/PF 映射和层级汇总是待建能力；当前逐行事实仍只写入[验收追踪表](acceptance-tracker.zh-CN.md)。

## 关键验收与故障处理

- G0 需要固定基线的实际构建和运行、两普通 Profile 的关键路由/隔离、原有代理组合、BLOCK 在途/缓存、认证/渠道身份、资源与 Vision 计量风险的 P0 证据；任何关键阻断未解决即保持 UNVERIFIED/BLOCKED。局部单测、源码扫描、GN 目标生成或文档预览不能替代它。
- G1 至少包含真实 HTTP→REALITY、两个普通 Profile、网站开关和调试三策略/两动作、阻断/恢复、自动配置/保持/切换、真实字节、账户和物理限制以及故障不直连；限定测试用户和容量并列明未覆盖项。G2/G3 继续按冻结范围与最终包验收，不将 G1 子场景升级为整行 PASS。
- 发布/撤销/重启/断线中，已要求代理的请求等待或失败；不得静默改走 DIRECT。BLOCK 超时保留屏障，旧 ACK 不解除新状态；旧 generation、旧身份和旧连接不得重用。已发送业务请求不自动重放。
- 若实现与冻结语义冲突，记录触发条件、失败证据和修订差异，按规范修订流程评审；不在实现中静默缩小范围。产品代码回退通过可审查的 revert，保留持久代理意图和证据，不清理其他任务的 Chromium workspace。

本期范围仍为 Chromium 桌面产品线先验收 macOS、HTTP/SOCKS5 本地入口与冻结两种出站。系统 VPN/TUN、其他应用代理、多区域运营、付费购买和其他平台验收不纳入此轮承诺。商业参数、真实容量和负责人由部署合同绑定，不写演示数字代替。
