# Aegis 访问服务 V1.0：当前开发计划

## 2026-09-22：已提交 mutation 的幂等重试修复

上游 [PR #21](https://github.com/gcsagroup/aegis-browser/pull/21) 已以 merge commit `6e2c5701f980e0ce50b9c5d04e151713b90ae49b` 合入；对应 upstream/main push CI run `35619634792` 与 C++ run `35619634801` 均成功。独立 Astra High 的合并后审查发现一个 P2 正确性缺口：同一 `operation_id` 与 `request_fingerprint` 首次成功后，`PrepareSiteGroupMutation` 会在重试时返回既有 `COMMITTED` journal 记录，但 coordinator 仍把它交给只接受 `PREPARED` 的 candidate builder，最终把 durable 成功误报为失败。

个人仓已通过 PR #153 将上游 merge ancestry 回灌到 `main@86609c69ed4c82061807e3e3b9a4a4ad089aecfb`，其 push CI run `35620964157` 成功；PR #154 再把该 ancestry 合入包含 PR #141 静态质量门的 `develop@f0d01d63d0e7bf6dea2390041f51026073272d1b`，push CI run `35622236927` 成功。两次同步均为 tree-preserving merge，个人 README 与 Codacy 徽章保持个人项目配置。

当前修复单元从该精确 develop 建立，只处理已提交 operation 的幂等响应：可信 selector、普通 DIRECT/PROXY 请求和 store 校验保持原顺序；发现相同指纹的 `COMMITTED` 记录时，立即返回 `kCommitted`、`StoreStatus::kValid` 与原 `committed_policy_generation`，不再次发布 runtime/transport，不请求 NetworkContext ACK，不清理 journal，也不增加 coordinator `state_generation`。`SUPERSEDED` 或其他非 `PREPARED` 阶段继续 fail closed。新增 coordinator 单元回归实际构造首次 PREPARED→ACK→COMMITTED，再用相同请求重试并断言立即返回原 generation、无第二次 Mojo publication、durable snapshot 不变。

交付包含 overlay、顺序补丁 `0159`、单元回归和本文档/Handoff。合并前必须绑定最终 HEAD 完成 patch format、GN wiring、本地 full quality、托管 quality/quality-gate 与 C++、Codacy Medium+ 门槛、全部 conversation resolved 和独立 Astra High 复审。仓库基础门与测试源码不等于固定 Chromium/GTest 已执行；在同一固定候选实际运行新增 coordinator 用例及既有真实入口矩阵前，native 证据继续 `NOT_RUN`，G0 继续 **UNVERIFIED**。

后续严格按顺序执行：本修复 PR 实际合并并确认精确 develop push CI 成功后，才重新执行个人 main 晋升和上游导出；上游导出继续恢复上游 README/Codacy 徽章，回灌继续保留个人 README。任何 HEAD 变化都使旧的质量、CI 与审查证据失效。

## 2026-09-21：个人 Codacy 与上游 README 隔离维护

用户要求恢复个人 main/develop 的 Codacy，并在晋升时忽略个人徽章。三份个人 README 使用个人项目 `72c871eba82e471ebc05eaacd4d45218`，分别标注 main/develop；上游保留其项目 `7b3008e649154ca0a7d5906c514488cc`。内部晋升保留个人 README，独立上游导出候选才恢复本次 upstream/main 的三份 README，并校验其他文件不变；同步回个人分支也保留个人展示。流程以 [DEV CI 指南](../../development/ci.zh-CN.md) 为准。

本项只维护展示和晋升隔离，不升级 native/G0 证据。PR #142 已以 squash commit `211bfd33fe0e07ab59fed8fccbf4b17bd0fc56d0` 合并到 develop，其 push CI run `35588469947` 的 quality / quality-gate 均成功；最终 HEAD `32cf623a99f0687f9f6e9602af56af98e2a3da98` 的本地 full quality、Codacy 与 Astra High 独立审查均通过。旧 main→develop PR #140 绑定旧 base，控制器按 fail-closed 拒绝继续；替代同步 PR #143 已在最终 HEAD `c619c4d8737b8f82c0669d411a9a60c15f76bf16` 关闭 Codacy review 提出的日志可诊断性、缺失 series 文件和末行无换行回归缺口，并以 merge commit `aded49ef24bc088d88b380f7db5a525830d63d65` 合入 develop。对应 develop push CI run `35590221938` 的 quality / quality-gate 均成功。

首个个人 main 晋升候选 PR #144 的托管检查通过后，Codacy review 发现代理候选没有显式把目标 host 加入 allowlist，且 `ReplaceSelection` 接受未排序 host 后会破坏 `binary_search` 前提。为避免修复先落到 main 并使 develop 落后，#144 已重新定向到 `develop@aded49ef24bc088d88b380f7db5a525830d63d65`：代理 mutation 从当前 endpoint 和权威 selection generation 构造候选，插入目标 host 并保持排序；transport 拒绝未排序 replacement。新增 unit 覆盖 DIRECT 后重新加入 PROXY allowlist 以及未排序 replacement fail-closed，并以顺序补丁 0156 保持 overlay 对齐。Astra High 随后发现 coordinator test 直接 include proxy selection source 却未声明直接 GN 依赖；0156 与 wiring 回归已补齐该依赖。

PR #144 最终 HEAD `b2b7b3b9246320b6a1530b1033016cc79fb7b13e` 的本地 full quality 为 PASS，`sourceStable=true`，输入/最终摘要同为 `5c3c5bb80bf5bcc2ceb86285b6f16c14b6de93407ee2ad0ac7fdde075e595711`；托管 quality、quality-gate、C++ unit、Codacy 与 Astra High 最终 HEAD 复审均通过，三个 Codacy conversation 均已解决。该 PR 已 squash merge 为 `develop@3b7f66658afeb192339b5ad60eaf9463cb5b96e6`，其 push CI run `35593565545` 的 quality / quality-gate 成功。后续文档修正 [PR #146](https://github.com/quinn521/aegis-browser/pull/146) 在最终 HEAD `a49738e099cd8e1a722a66129e854261735e4e8c` 取得本地 full quality PASS、`sourceStable=true` 和匹配摘要 `820a5a4267d1446fd6723f956ef17c152cde4d6f58a175d35f7986c2a8dc8788`；托管 CI run `35596978055` 的 quality / quality-gate、Medium+ Codacy 门槛和同一 Astra High reviewer 均通过，四个 Codacy conversation 均已解决。GitHub 已将 #146 squash merge 为 `develop@b2b34d42f5cb2b75b748352ef099c95801dbddb4`，对应 push CI run `35597328811` 成功。

[PR #147](https://github.com/quinn521/aegis-browser/pull/147) 已在最终 HEAD `08d49e6226b353ef04b086d12039767721ad4977`（tree `f45c0fa24f58d24078eac585ec0e595d8658bf9d`）完成 0157 修复。本地 full quality 为 PASS、`sourceStable=true`，输入/最终摘要同为 `9ccb7119e25d96b722695e89fb2a42b6534860cfb32eed913a75a1fd9f1ed8ac`；托管 CI run `35601244970`、C++ run `35601244785`、Codacy 和同一 Astra High reviewer 最终复审均通过，且无未解决 conversation。GitHub 已将 #147 squash merge 为 `develop@9d59d23609d47b1158767bd333579478f9ea7a43`，对应 develop push CI run `35601662252` 的 quality / quality-gate 成功。

个人 main 晋升候选 [PR #148](https://github.com/quinn521/aegis-browser/pull/148) 从该精确 `develop` 建立，初始 HEAD/tree 与 `9d59d23`/`f45c0fa` 完全一致，三份 README 保留个人 Codacy 项目 `72c871eba82e471ebc05eaacd4d45218` 的 main/develop 徽章。该初始 HEAD 的本地 full quality 为 PASS、`sourceStable=true`、摘要仍为 `9ccb7119...`，但 Codacy 在 `AccessServiceCoordinator::BeginPublication` 报出一个 Medium：54 行超过 50 行门槛。为避免修复只落到 main 并使 develop 落后，#148 转向 develop，只交付行为不变的 candidate preparation 提取、顺序补丁 0158、wiring 回归及本文档/Handoff。Minor 圈复杂度记录但不阻塞。修复 commit `f7d610d75af36e78e3a0d0a4841d180c232b5472`（tree `2e5a447546c6de03d94ead3ed1aff2a2cf0acb48`）的补丁格式、GN wiring 与 848 项 Access checks 通过；本地 full quality 为 PASS、`sourceStable=true`、输入/最终摘要同为 `19485eeceb33a1f4cdda6a38bc4bcf66a7f2e9b8a79d148557546fa599073084`；托管 C++ run `35602778691`、CI run `35602778700`、Codacy 无问题和同一 Astra High reviewer CLEAR 均已取得。本文档同步会产生新的最终 HEAD，因此合并前仍须把本地/托管/Codacy/同一 reviewer 证据重新绑定到该最终 HEAD，并确认全部 conversation resolved。mirror/upstream 按用户最新要求暂缓；仓库门禁不证明 Chromium GN/GTest/runtime，G0 继续 **UNVERIFIED**。

## 2026-09-21：commit/publish snapshot 阶段（代码已合并；native 验证仍欠账）

本阶段基线为 `develop@3154d39871ddd592a1be609abf9c90c78d7e29c6`，范围为普通 DIRECT/PROXY 网站协议组事务。[Fork PR #139](https://github.com/quinn521/aegis-browser/pull/139) 已合并，合并提交为 `2c591b7`。以下行为说明保留已交付的源码边界；固定 Chromium/GTest/真实入口仍是后续 native 证据欠账。

冻结事务顺序为：验证可信 selector 与 store → PREPARED journal 预留 operationSequence → 从旧 durable base 构造完整候选 → 发布到浏览器 request runtime → 向所属 NetworkContext 发布精确 operation/G/S/E 与 owner/partition → 全部候选 ACK → 再原子 durable commit → finalize。PREPARED 的 `committed_policy_generation` 始终为 0，候选及成功提交的 policy generation 都等于预留的 operationSequence。请求路由只读取内存快照，不读取 SQLite。`RepublishCurrentConfigWithAck` 不能作为候选发布证据。

Profile 持有首个可信 store（含 ephemeral 会话库），后续 mutation 传空指针复用，禁止替换库。候选保留无关网站组和独立规则。当前 transport 只有 partition/host 粒度：同 host 的其他规则需要相反 DIRECT/PROXY 策略时，发布前返回 `kUnsupportedTransportScope`，保留原状态；不宣称已实现按 top-level-site 区分的 transport。浏览器同步重绑定保留端点的 policy generation，并在 DIRECT 时从 CustomProxyConfig 的 exact-host 列表移除目标网站、保留其他网站；候选 config 与 metadata 使用同一 Mojo channel 顺序发送。失败仅在候选仍精确匹配时恢复旧快照/端点，并 supersede journal；清理写入失败透传 store 错误并保留待恢复边界。提交前重新核对 runtime、权威 selection source 的 S/E、完整端点及所有 NetworkContext 的集合；新 context、版本变化、错误或丢失 ACK、30 秒超时均阻止提交。迟到 ACK 不能复活已取消的事务；失败的 exact identity 释放 tracker 容量。Network Service 在受信任的 context channel 上保存 owner 绑定与候选回执，并按 proxy group 保存 selection generation 高水位；它允许独立组使用各自计数，拒绝同组回退，也不从数据库重建策略。BLOCK/ALLOW 的屏障及取消流程、可信 UI 入口、真实身份/节点提交与 Xray 集成不属于此阶段。

| 证据 | 当前边界 |
| --- | --- |
| 实现及测试源码 | 已增加 candidate builder、coordinator transaction、runtime rollback、transport/version ACK，以及 unit/真实主导航回归源码；0157 按 proxy group 绑定 selection generation；#148 的 0158 仅提取 transport candidate preparation，保持行为不变并同步 overlay/顺序补丁。 |
| 本地 standalone C++ | #148 修复 commit `f7d610d` 执行通过 848 checks，含 patch format 与 GN wiring；本文档提交后的最终 HEAD 仍需重跑。这不是 SQLite/GN/GTest/browser 执行证据。 |
| Chromium/GTest/真实入口 | **NOT_RUN / BLOCKED**：已核实旧 PR135 retry3 权威退出文件为 1，首个失败是 `ProxySelectionGenerationState` 的 inline constructor / missing out-of-line destructor style 检查。该源码问题已由 #139 的 0154 修复，但尚无重建后的固定候选 PASS；缓存和旧二进制均不是当前证据，旧工作区不改动。 |
| 独立审查 | #148 的 Astra High reviewer 已对 `f7d610d` / `2e5a447` 给出 CLEAR，无 Medium+ 发现；本文档提交产生新 HEAD 后，必须由同一 reviewer 复审并再次 CLEAR。 |
| 本地 full quality | 修复 commit `f7d610d` 对 `origin/develop@9d59d23` 为 PASS、`sourceStable=true`，输入/最终摘要同为 `19485eeceb33a1f4cdda6a38bc4bcf66a7f2e9b8a79d148557546fa599073084`；本文档提交使该证据失效，最终 HEAD 必须重新运行完整质量门并保持摘要一致。 |
| Hosted CI / 合并 | #148 修复 commit `f7d610d` 的 C++ run `35602778691`、CI run `35602778700` 与 Codacy 已通过；本文档提交后的最终 HEAD 必须重新通过同一门禁、全部 conversation resolved 和同一 Astra reviewer CLEAR，再 squash merge 到 develop 并核验精确 develop push CI。 |
| G0 | **UNVERIFIED**。基础质量或测试源码不能升级为 native/runtime 验收。 |

在宣告 G0 或依赖 native 验收继续扩展请求入口前，必须在同一固定候选实际执行 coordinator、store、runtime、transport、dispatch/tracker 单元与回归，并执行 `MainNavigationConsumesPreparedSnapshotBeforeCommit`、`MainNavigationRoutingIsolatedAcrossProfiles` 及既有导航/redirect/Worker/SharedWorker/Service Worker/missing endpoint/BLOCK/LoadingPredictor/frame prefetch 矩阵。零匹配、非零退出、不同候选均失败。上述未完成证据债与 #139 已完成的合并状态分开跟踪，也不能由仓库 CI 或测试源码替代。

本轮后续顺序：

1. 在 #148 完成 0158、wiring regression 和本文档/Handoff，转向 develop 后冻结最终 HEAD，取得 local full quality、hosted CI、无 Medium+ Codacy、全部 conversation resolved 和同一 Astra High reviewer CLEAR。
2. 将 #148 squash merge 到 develop，确认 GitHub 实际 MERGED，并核验精确合并提交的 develop push CI。
3. 仅在 #148 的 develop push CI 通过后，从最新 develop 建新的个人 main 晋升 worktree/PR，保留三份个人 Codacy README；最终 HEAD 门禁通过后使用 merge commit，并核验 main push CI。
4. mirror/upstream 导出按用户最新要求暂缓；后续仍严格一阶段一 PR，并在同 PR 更新 plan/Handoff。native/G0 欠账继续独立登记，不用仓库晋升结果升级。

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
