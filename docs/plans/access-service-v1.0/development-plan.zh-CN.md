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

## 关键验收与故障处理

- G0 需要固定基线的实际构建和运行、两普通 Profile 的关键路由/隔离、原有代理组合、BLOCK 在途/缓存、认证/渠道身份、资源与 Vision 计量风险的 P0 证据；任何关键阻断未解决即保持 UNVERIFIED/BLOCKED。局部单测、源码扫描、GN 目标生成或文档预览不能替代它。
- G1 至少包含真实 HTTP→REALITY、两个普通 Profile、网站开关和调试三策略/两动作、阻断/恢复、自动配置/保持/切换、真实字节、账户和物理限制以及故障不直连；限定测试用户和容量并列明未覆盖项。G2/G3 继续按冻结范围与最终包验收，不将 G1 子场景升级为整行 PASS。
- 发布/撤销/重启/断线中，已要求代理的请求等待或失败；不得静默改走 DIRECT。BLOCK 超时保留屏障，旧 ACK 不解除新状态；旧 generation、旧身份和旧连接不得重用。已发送业务请求不自动重放。
- 若实现与冻结语义冲突，记录触发条件、失败证据和修订差异，按规范修订流程评审；不在实现中静默缩小范围。产品代码回退通过可审查的 revert，保留持久代理意图和证据，不清理其他任务的 Chromium workspace。

本期范围仍为 Chromium 桌面产品线先验收 macOS、HTTP/SOCKS5 本地入口与冻结两种出站。系统 VPN/TUN、其他应用代理、多区域运营、付费购买和其他平台验收不纳入此轮承诺。商业参数、真实容量和负责人由部署合同绑定，不写演示数字代替。
