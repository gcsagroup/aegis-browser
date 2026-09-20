# Aegis 访问服务 V1.0：当前开发计划

状态日期：2026-09-20（Asia/Shanghai）。本页是从当前 `develop` 继续实施的入口；[交接与精确证据](handoff-20260920.zh-CN.md)记录本次基线和待验证事项，[A01–A118 / PF01–PF13 验收追踪表](acceptance-tracker.zh-CN.md)是逐行覆盖与证据的唯一台账，[P0 历史实现记录](p0-implementation.zh-CN.md)保留切片过程。行为、验收项和 G0–G3 门槛以[冻结规范修订 4](spec.zh-CN.md)及[冻结清单](freeze.json)为准；本文不修改合同。分支、PR、Review 与最终 HEAD 门禁按[DEV CI 与上游推进指南](../../development/ci.zh-CN.md)执行。

## 当前判断与交付边界

2026-09-20 核验的 `quinn521/aegis-browser:develop@287aa54c678e8c174b6b286e387a1457cf3a218f` 已包含路由与匹配、网站协议组、原子规则存储和恢复、请求归属、BLOCK 屏障、定向取消、五项 generation 的生产所有者与 tuple 组装。真实 factory 已覆盖导航、文档子资源、重定向、Worker 主脚本及有 frame/无 frame 子资源、process-backed Service Worker 主/导入脚本及子资源、frame prefetch 和 LoadingPredictor 预取。这里的“存在”只代表源码和对应局部合同；不能推断用户开关、服务端或端到端流量已可用。

目前仍缺把可信网站选择、身份与节点提交、持久化、快照发布、执行点 ACK 和界面状态连接起来的生产协调器。在本次源码盘点中，`CommitIdentity`、`CommitSelection`、`PublishCommittedPolicySnapshot` 的调用位于定义/测试，未找到完整的生产调用链；合入前需在最新树复核。`SetSiteProxy` 用户入口、Xray/受控 HTTP→REALITY 主链路、托管注册/签名配置/租约/探测、真实字节计量/额度/公平限制也尚未闭合。WebSocket、preconnect、BFCache、prerender、通用 prefetch 和 Service Worker update checks 尚无可声明的完整覆盖；现有 prefetch 覆盖不能扩展解释为这些入口均已支持。

G0 保持 **UNVERIFIED**，G1–G3 **未达到**。2026-09-20 固定 Chromium 151 验证已有全补丁重放、overlay 对齐和 GN 目标生成记录，但 `unit_tests` / `browser_tests` 构建尚无完成结果，更没有本候选的 GTest、浏览器代理流量或完整 Chrome 运行结论。35 个 browser-test 定义是源码数量，不是 35 个通过的测试。[交接页](handoff-20260920.zh-CN.md)逐项区分仓库质量门、Chromium 构建和运行证据。

## 先关闭现有 Chromium 验证欠账

**暂停扩展新的请求入口功能**，直到当前固定 Chromium 候选的编译完成且全部当前必需的真实入口回归执行通过，阻塞失败关闭。先由现有构建所有者回收 `unit_tests` / `browser_tests` 结果；已计划的窄范围 prefetch 过滤器只能证明其列明子集，不能代替导航、重定向、Worker、BLOCK、在途取消、缺失代理 endpoint、Profile 隔离和真实派发入口用例。对每项列出确切测试名/过滤器、执行退出码、请求与 origin/proxy 观测、未覆盖场景；仅测试 helper 或在测试中直接调用 factory 的用例，应注明没有证明真实入口接线。失败时先确定第一处源码/构建/环境问题，修复并重跑相关回归；`BLOCKED` 或 `NOT_RUN` 均继续暂停，不以源码存在或 GN 生成作为继续扩展入口的通行证。

推进到下一请求入口实现的条件是：当前候选 `unit_tests` / `browser_tests` 目标完成构建，导航、重定向、Worker、BLOCK/在途取消、缺失 endpoint、Profile 隔离及真实派发入口的当前必需回归在同一最终源码/补丁树全部实际执行 **PASS**，所有阻塞失败已修复并重跑通过，结果与剩余非阻塞覆盖空白登记到[验收追踪表](acceptance-tracker.zh-CN.md)。任一必需回归为 `FAIL`、`BLOCKED` 或 `NOT_RUN` 时继续暂停新增请求入口；仅允许独立测试准备、接口设计和证据盘点并行，不得改动正在构建的工作区。满足此开发顺序条件仍不宣告 G0 或产品链路通过。

## 依赖顺序与可评审单元

| 顺序 | 对应单元 | 下一交付和前置条件 | 完成证据 |
| --- | --- | --- | --- |
| 1 | P0 验证底座 | 保留当前隔离 Chromium 构建的所有权；先关闭上节列出的现有编译和真实入口回归欠账，再评估固定源码/149 个 Chromium 补丁、工具链和 GN 参数下的 HTTP 代理/拒绝路径。发现失败先修复对应最小源码或环境问题。 | 记录源码树、补丁、GN args、目标、退出码、测试名、过滤器和原始日志；按规范第 12 节逐项判 G0，不能只凭 GN 成功或窄范围 prefetch PASS 判通过。 |
| 2 | P1–P2 与 P4–P5 的最小协调闭环 | 在现有 Profile/StoragePartition 所有权基础上，定义并接入生产 coordinator：可信当前 host → 普通 `SetSiteProxy` 的网站协议组选择（DEV/Alpha 的三策略、ALLOW/BLOCK 为独立调试规则，按冻结合同协调）→ identity、selection、base-proxy 等真实代次 → 原子持久化与恢复 → committed snapshot 发布到所属 NetworkContext → 请求派发/取消的执行点 ACK → UI 状态。先以受控本地 HTTP fixture 验证，Xray 依赖留在后续单元。 | 两个普通 Profile/多个 partition 无串用；超时和取消不接受迟到结果；重启只恢复已提交状态；退出账户不直连回退；BLOCK 先装本地屏障，按流终止且失败保留；保存失败不显示“已保存”；关闭恢复原有代理设置。记录 G/S/E/identity/base-proxy 精确版本和 ACK。 |
| 3 | P3 + P3a | 在协调闭环上接固定 Xray 资产与 Profile 级 HTTP 入口，打通受控服务端的 VLESS + RAW(TCP) + REALITY + XTLS Vision；接入自动登记、签名配置、准入、租约、健康探测、稳定分配和确认故障后的切换。 | 实际 HTTP→REALITY 往返、凭据隔离、超时/撤销/入口故障不直连、节点保持与切换记录；服务和部署参数版本绑定。SOCKS5 与兼容出站在 P7 完整验收。 |
| 4 | P3c–P3d | 主链路稳定后实现服务端实际双向字节计量、幂等账本与额度预算；执行物理 VPS/账户限速、公平分配与并发准入。跨节点账本和租约先用多节点 fixture 验证，部署第二个执行节点前完成真实联调。 | 对账、重试/乱序/断线/周期重置、额度耗尽在途截断、Vision/splice 快路径计量与预算实测，记录误差和容量上限；UI 秒级变化不能代替服务端对账。 |
| 5 | P3b + P4–P6 完整面 | 补精确正常/失败目标采集与全部可信请求归属、真实终止句柄；三策略联合发布和版本化撤销；提供 `SetSiteProxy`、工具栏/管理页、状态/用量与 DEV/Alpha 调试视图，并验证四渠道原生接口隔离。 | 导航、子资源、下载/流、frame/Worker 等逐入口覆盖报告；BLOCK/ALLOW 的旧代次和旧 ACK 竞争；离线关闭/阻断仍可操作；开关与连接状态分离；Beta/Release 无调试管理接口。 |
| 6 | P7 | 补全 SOCKS5 Profile 认证、WS+TLS 兼容出站、OTR/Guest、WebSocket、preconnect、BFCache、prerender、通用 prefetch、Service Worker update checks 等剩余适用请求矩阵。 | 两入站×两出站、临时 Profile 和复杂入口按冻结适用项逐项运行，未知/无可信归属保持受限；不能用已覆盖的 frame prefetch 代替通用 prefetch。 |
| 7 | P8 | 在最终候选头重放全部补丁，完成四渠道构建、性能/故障回归、全新安装/升级/回滚和交付档案。 | 按规范第 12、14 节将 A/PF 用例与源码、配置、部署、规模、日志绑定后分别判 G0–G3；发布动作另循项目授权。 |

第 2 步是可评审的最小协调里程碑，不宣称独立达到 G0 或“按钮可用即 Alpha”。可以先并行准备受控服务端环境和测试资源，但依赖它们的端到端结论必须等实际链路运行后记录。

实施与测试两条工作线共享同一固定候选合同：产品 head/tree、Chromium 基线及 patched tree、patch series、GN args、渠道/配置、用例和观察点。只有一名明确的隔离构建工作区所有者能修改补丁树或启动/重启构建；测试线准备受控代理与 origin fixture，分别记录两端日志、同一请求的关联 ID、直连/代理路径和故障注入结果。合成代理 fixture 自行响应时 `origin_count=0` 可以成立；真实转发代理则会合法触达 origin，必须以受控代理出口/连接与关联日志证明走代理，并证明没有 DIRECT origin 路径，不能只信转发请求头或笼统要求 origin 零请求。按目标和拒绝/BLOCK 生效时间记录基线与增量：缺 endpoint 的被拒绝请求在有界窗口内对代理及 origin 均零派发；重定向可先有一次合法代理请求，但被拒绝的重定向目标不得新增派发；BLOCK 前已在途的代理请求保留在基线，验证屏障生效后无新命中派发及在途终止时序，不抹掉历史计数。每个零增量断言都需同配置的健康控制请求证明日志确实能记录流量，超时/无响应本身不算 PASS。同时验证额度耗尽、离线、重启和迟到回调时没有 DIRECT fallback。测试证据只记录脱敏 ID、字节/状态与必要时序，不泄露凭据或请求秘密。真实受控服务尚未运行的场景不得记服务端 PASS。

此后每项新**产品功能**须在同一 PR 交付可运行 unit 与真实入口 regression，并在该 PR 最终 HEAD 对匹配固定候选实际执行两者；overlay/顺序补丁/BUILD 接线一并审查。未执行即登记 `NOT_RUN`，不算验收。只改文档的 PR 不需要补造产品测试；过去对 [Fork PR #129](https://github.com/quinn521/aegis-browser/pull/129)/[上游 PR #18](https://github.com/gcsagroup/aegis-browser/pull/18) 的一次性源码晋升例外不适用于新功能。各行实现、映射、执行、结果与覆盖分别更新[验收追踪表](acceptance-tracker.zh-CN.md)，不能因一个子场景通过把主行升为 PASS。

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
