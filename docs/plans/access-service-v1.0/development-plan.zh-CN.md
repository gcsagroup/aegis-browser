# Aegis 访问服务 V1.0：当前开发计划

更新日期：2026-09-24。Q 本轮冻结起点为 `origin/develop@7f74e0a4e971f91d08d90536e429aba7b82cf37d`；main/upstream 同为 `c1399852270c1bbce612dbea1558266d6fc57162`。当前证据、剩余矩阵和构建所有权见 [QUALITY-HANDOFF](QUALITY-HANDOFF.md)。以下旧日期段落保留为历史快照，不作为当前执行指令。
## 历史：2026-09-22 F 独立 transport scope 准入增量

本增量补齐普通网站 mutation 在同 host 或 DNS label 后缀已存在异组 PROXY 时的发布前拒绝，不重复旧 trusted-site UI 候选或 #155/#156 重试语义。#161 runner、#163 GN 修复、#166 模型路由补丁 0161 与 #171 回流的 TypeSafe 补丁 0162/0163 已进入当前基线；本增量的准入补丁顺序编号为 0164，后续修复为 0165–0167。实现、验收不变量、实际模型路由与证据边界见 [F Handoff](transport-scope-handoff-20260922.zh-CN.md)。standalone 行为检查已通过，nativeImpact 为 REQUIRED；固定 Chromium unit/browser runtime 未执行通过前保持 NOT_RUN，G0 仍 UNVERIFIED。

## 历史：PR #162 H12 精确证据快照（已被 H13 取代）

此快照绑定 B=`131da2fec25b783e0cc42374728e1f5ffb01cf53`、H=`6664528b5017487fddb9b2b919a83d9d8c157027`、tree=`5140c64316b6cdddc2c86554283261a7d98228d6`。GitHub PR merge candidate M=`0723b8d11f219f97eb6fbc44c1510a60c975d440` 的两个父提交依次为 B/H。

- H 的本地 full quality、fixed Chromium ordered-source admission 与 transition verification 均 PASS；补丁输入为 Chromium 169 项、V8 2 项，重放树分别为 `2b924501f5eb8aeac1ce9a911f710f773fe8690d` 与 `5a6be89cfa0c35d8eb6ee81aec3cb8100780f7e9`。
- 固定 Chromium 151 native 三目标 PASS：`access_service_coordinator_unittests` 16 项、`aegis_access_unittests` 45 项、`access_rule_store_unittests` 35 项，共 96 项。`browser_tests` 构建及 Access 冲突后导航、History 路由、Settings About 三项 fixture 均 PASS；History 与 Settings 的指定内层 Mocha 用例均已观测，sourceStable=true。
- 对应 PR #162 H 的独立代码复审为 CLEAR。GitHub `quality`、`quality-gate` 与 `c++-unit-tests` 均在 `pull_request` attempt 1 成功：CI run `35909462990`，C++ run `35909462942`。

以上只记录所列 B/H/M 和当时的证据；任何后续提交都须按 DEV CI 指南重新绑定并验证，不从此快照转用最终 HEAD 结论。

## 当前依据与结论

行为和完整门槛以[冻结修订 4](spec.zh-CN.md)为准；实施技术决策见[架构复核与实施方案](architecture-review-20260922.zh-CN.md)；逐项事实写入[A/PF 台账](acceptance-tracker.zh-CN.md)；下一工作窗口及证据边界见[Handoff](handoff-20260920.zh-CN.md)。历史 P0 切片保留在[p0-implementation](p0-implementation.zh-CN.md)。

之前累计在本页的 PR 推进日志已由本次清晰的当前计划替代，原文保留在[精确基线版本](https://github.com/quinn521/aegis-browser/blob/c4ffb50a0d8efc684aa1ba0022daf5113def19a6/docs/plans/access-service-v1.0/development-plan.zh-CN.md)，仅用于追溯，不再执行其中“下一步合并 #135/#148/#158”等历史指令。分支、模型分工、审查和最终 HEAD 门禁只引用[DEV CI 指南](../../development/ci.zh-CN.md)。

当前已有普通 DIRECT/PROXY coordinator、候选快照发布、执行 ACK、durable commit、幂等重试以及多个浏览器入口的源码回归。可信 `SetSiteProxy` 用户闭环、身份/节点生产提交、真实 Xray、计量/额度和完整请求矩阵尚未闭合。host 级单 endpoint transport 仍不足以实现全部规则语义；拒绝冲突不能代替不同路由并存。

截至 2026-09-24 本轮回读，#162 已 MERGED，最终 H=`4670c4dd5f24db61f38f102cc60475658e63554a`，S=`ca4e1b24c750746d6e20a83fa58f1d2500791d02`。该 H 三个选定 unit target 共 96 项及三组 browser fixture 的原始报告通过；native 总状态是 `PARTIAL_PASS`。这些历史结果不转用于新的候选。**W0 未闭环，G0 继续 UNVERIFIED，G1–G3 未达到。**

## 当前双窗口执行板

| 顺序 / 负责人 | 当前状态 | 下一动作与完成条件 |
| --- | --- | --- |
| Q：固定基线与矩阵 | `7f74e0a…` 冻结；17 个 unit 目标有 GN 源码声明；Access browser 源码定义 38 项 | 目标声明和测试源码不代替实际二进制枚举；在 Q 最终候选逐项运行 |
| Q：历史 #162 核验 | H13 三目标 16+45+35，native `PARTIAL_PASS`；Access 冲突导航/History/Settings 三组 PASS | 保留 H13 身份、原始路径与哈希；不恢复 H12/`682997a…` 的构建指令 |
| Q：W0 剩余执行 | 第三候选 Hceb6ead 的 native/browser 均 FAIL；后续独立预审发现 MHTML HTTP 子帧原禁网 default 被重建为可联网 factory。0187 已以 RFHI 可信资格修复源码并加入真实 MHTML 回归；H882c354 的六关键对象编译 PASS/sourceStable，但仍无完整链接或 runtime；详见 QUALITY-HANDOFF | 保留全部失败与主动中断回执；对最终候选运行 local full、17 target、Chrome 与 Content browser 矩阵，同 reviewer 复审及托管 CI；Q 继续持有独立构建时段 |
| Q：LoadingPredictor 回归设施 | 新增真实 `PrefetchManager::Start` 三项 regression 源码；已有 helper 和模式选择 unit 不足以替代 | 最终 H 实际 build/list/run 验证；当前缺运行证据，不是已证实产品语义失败 |
| F：W1a 接口/fixture 准备 | 与 Q 独立；#166 模型路由后续工作 DEFERRED | 可并行准备 W1a，不操作 Q source/out/锁；W0 关闭后再推进 W1b/W1c |
| W2 服务端实验 | 执行资源/负责人未绑定，BLOCKED（实验执行） | 可准备协议；实际部署或付费 API 调用需另有授权 |

Q 独占本轮新的 Chromium candidate、out、验证证据及共享 plan/Handoff/tracker 状态修订；F 的独立文件不由 Q 覆盖。精确目录、原始证据和缺口分类见 [QUALITY-HANDOFF](QUALITY-HANDOFF.md)。

## 实施顺序与依赖

W0–W6 是本计划的工作包，不改变冻结 P0–P8 和 G0–G3 的定义。只读设计、fixture 准备和独立服务端实验可以并行；依赖上一个代码单元的工作，按 DEV 指南在实际合并和精确 develop push CI 通过后接续。所有产品功能单元仍需同 PR 的 unit 与真实入口 regression，最终候选实际执行；原型不得用源码存在冒充运行通过。

| 工作包 | 对应冻结单元 | 工作与前置条件 | 退出证据 |
| --- | --- | --- | --- |
| W0 固定 Chromium 底座 | P0 | 复用已合入 runner/GN 修复和 #162 保护；在 Q 新候选覆盖全部必需目标及真实入口，补 LoadingPredictor fixture；核对 LLD/SDK 与独立参数变体，不修改其他任务的构建工作区 | 当前候选全部必需 Access unit、既有真实入口矩阵实际 PASS；零匹配/部分运行不算完成；保留全部目标、过滤器、日志、退出码和来源树 |
| W1 请求级路由原型 | P0/P1/P2 | W0 关闭现有基线欠账后，在隔离候选验证可信上下文从 Browser 到实际 proxy/stream 的载体、每组多端点注册与连接隔离；先交接口清单，再实现最小并发场景；同阶段完成固定 Chromium 的最小 HTTP/SOCKS5 Profile 认证与隔离原型 | A/B 同 CDN 异组、不同 host 异组、scheme/port、DIRECT/PROXY/REJECT、redirect、POST/PATCH、两 Profile、旧连接及 Network Service 重启的正反路径；A78 的两入口最小认证/隔离用例实际运行；接口和性能风险有明确结论 |
| W2 Vision 计量可行性 | P0 的早期风险实验；支持后续 P3c/P3d | 与 W0/W1 并行；绑定受控 Linux 服务端、固定 Xray/配置/内核、权威计数点、集中账本与预算原型。资源未就绪就记录 BLOCKED | 长连接未结束时计量、额度耗尽截断、崩溃/重启/失联恢复和 splice 对照；先冻结误差预算再测量；不把 Stats API 轮询当数据面额度执行 |
| W3 最小纵向闭环 | P1/P2/P3/P5/P6 子集 | W0/W1/W2 各自证据满足前置条件；单执行节点、有限预置测试账户；接可信网站开关、真实身份/节点代次、持久化和 UI 状态 | 同一浏览器产物：网站开启 → HTTP→REALITY → 故障不直连 → Network Service 重启恢复 → 两 Profile 不串用；候选提交失败/取消/旧 ACK 不误报、不重放 |
| W4 受控 Alpha | P3a/P3b/P3c/P3d/P4/P5/P6 的 G1 范围 | 在 W3 上补安装访客/账户、签名配置/续期/撤销、自动保持/切换、三策略/两动作、真实账本/限速公平、渠道原生能力隔离 | 按原规范逐项判断 G0 后再判断 G1；真实切换用两个受控执行实例验证，单节点故障拒绝不冒充切换；限定容量、用户、网络与未覆盖项 |
| W5 完整功能候选 | P1–P7 完整面 | 在 W1 认证原型基础上完成 SOCKS5 全矩阵、WS+TLS 兼容出站、OTR/Guest、完整采集/终止与 WebSocket/preconnect/BFCache/prerender/通用 prefetch/SW update 等适用矩阵 | 原 G2 的全部适用 A/PF 项通过；两个逻辑节点 fixture 不替代实际多节点拓扑验收；不得把 frame prefetch helper 扩大为全部预取支持 |
| W6 可分发候选 | P8 | 在 G2 精确产物上完成四渠道、Mac 支持矩阵、签名公证、Helper/Xray 完整性、安装升级回滚和故障/性能回归 | 原 G3 的最终包、部署、规模与回滚证据；发布动作另按项目授权 |

W2 提前的是架构可行性实验，不宣布依赖完整 P3a 的生产 P3c 已完成。W3 是工程验证里程碑，缺少完整调试、权益、切换或 P0 其他要求时不叫 G1，也不能自动判 G0。G0 的原有代理组合、BLOCK 在途/缓存、HTTP/SOCKS 认证、渠道/身份、资源及 Vision 风险等条件全部保留。

## W0/W1 的最小验证集合

先执行 coordinator/store/runtime/transport/dispatch/tracker 的必要 unit，以及已有真实导航、redirect、Worker/SharedWorker/Service Worker、missing endpoint、BLOCK、LoadingPredictor 和 frame prefetch 回归；包括 `MainNavigationConsumesPreparedSnapshotBeforeCommit` 与 `MainNavigationRoutingIsolatedAcrossProfiles`。源码中存在测试名不等于目标确实收录，必须记录实际可枚举测试、匹配数和结果。#161 报告的 17 个 Access 可执行目标是候选 runner 的范围线索，不替代真实 browser_tests，也不是永久固定数量。

W1 同时承担 A78 的早期认证可行性验证：固定 Chromium 实际通过正确 Profile 凭据，拒绝无效/跨 Profile 凭据和外部连接，不向未登记代理提供秘密，关闭 Profile 后会话失效。现有 adapter 只支持 HTTP，不能从 Xray 配置用户密码推断浏览器 SOCKS5 已支持；需要在原型中完成浏览器认证适配并运行证据。该项未通过时 W1 保持 BLOCKED，W4 不得判 G0/G1；W5 保留 SOCKS5 全协议/出站/临时上下文矩阵。

W1 新增路由实验见[技术方案第 2、5 节](architecture-review-20260922.zh-CN.md)。旧 host 保护与新增请求级能力分开验收：冲突拒绝的负路径不能代替多组并存正路径。精确 API、池键、cache/credential 隔离以及最低开销尚待原型证明；未证明前暂停更多规则和入口扩展。

受控代理/origin 记录关联 ID、路由、连接身份、字节及时序，不记录秘密。真实代理转发会合法到达 origin，证明无 DIRECT 旁路要依赖出口/连接和双端日志，不笼统要求 origin 零命中；拒绝的目标才要求有界窗口内零新派发。每个零增量断言以同配置健康请求证明观测有效；超时或页面无响应不是成功证据。

## W2 与控制面范围

W2 执行[计量实验矩阵](architecture-review-20260922.zh-CN.md)，输出明确路径决策：已证明可计量并限额的固定转发路径、需评审的内核适配，或 BLOCKED。保留 Vision；未证明的 splice 不可当作已支持优化，不虚构禁用选项。中心 durable 预留防止重发，实际字节恢复仍需独立证明，不能把预留全额当成已消费流量。

首阶段单执行节点、集中账本、有限测试账户保留独立凭据、签名配置、过期/吊销、账户和物理上限。自动访客/账户流程、真实备用切换和完整公平约束必须在 G1 前补齐。多节点租约先做 fixture；启用第二真实节点前补真实账本、额度及速率联调，不删最终范围。

每活跃 Profile 一个稳定 Xray，浏览器额外候选/排空最多两个，按需启动和空闲回收。W3/W4 按 PF07/PF08 测 1/3/5 Profile、50 次生命周期、峰值 RSS、CPU 和回收；RSS 部署预算在 Alpha 前冻结。多代理组不能被实现为每组无限常驻进程。

## 验证底座的后续建设

以下为建设计划；本轮未修改 required CI。`quality-gate` 成功和 `nativeIntegration=REQUIRED` 分类不替代 native 执行，所有文档交付仍按现行 full 门。

| 层 | 待建设能力 | 与当前工作的关系 |
| --- | --- | --- |
| L0/L1 | 静态、合同、单元与分语言覆盖率，保留未知/未覆盖文件口径 | 复用当前门；证据等价后另 PR 去重，不能因 native 慢而降低门槛 |
| L2 | 可信隔离 Mac ARM64 固定 Chromium 编译和精确 GTest | W0 优先建设/验证；锁定 Chromium/V8、patch/overlay、GN args、工具与产物 |
| L3 | 同产物的真实浏览器路由/恢复/隔离回归 | W0 既有矩阵及 W1/W3 每项新功能共同需要；纯 helper 不替代入口 |
| L4 | 夜间容量、性能、故障注入、长跑与 A/PF 证据汇总 | 在可靠 L2/L3 之后建设；适用失败阻止晋升，不靠重跑掩盖 flake |
| L5 | 最终包安装、升级、回滚、签名公证及渠道隔离 | W6；ad-hoc 签名和本地测试不等于分发通过 |

先验证可信 L2/L3 产物和汇总判定，再优化缓存/分片，随后 L4/L5。不将日常电脑注册为公开 PR runner，不让候选自行指定可信标签/身份；缓存只复用构建输入，不复用 PASS。相关 Mac 最低/当前系统矩阵在支持合同中绑定，其他平台另行验收。

质量演进的 Phase 1 静态、Phase 2 行为单测、Phase 3 Chromium native、Phase 4 browser regression、Phase 5 CI report mode、Phase 6 required gate 是验证体系分期，不能与 W0–W6 或 G0–G3 一一等同。W0 同时需要 Phase 3 和适用 Phase 4 证据；#161/#163 代码合并不等于 Phase 3 完成。Report mode 和新增 required gate 仍是后续独立工作，本次不提前接入。

## 交付与停止条件

每个工作包拆成可独立审查的小 PR；同 PR 更新 plan、Handoff 与涉及的验收映射。新产品单元必须实际执行相关 unit 与真实入口 regression，最终 HEAD 对应的 local full quality、托管 CI、Codacy 和独立 Review 按 DEV 指南完成；文档调整不补造产品测试。未知、缺失、零匹配、取消、过期 SHA 和部分运行不得提升证据等级。

W0 未完成时，浏览器线先处理 native 基线；W1 未通过时停止新增调试规则/请求入口；W2 未通过时不承诺实时计量、严格额度或 Alpha 可用。独立的设计/服务端实验继续推进，受阻状态和第一处失败归属写入 Handoff。若需要改冻结行为，另提带失败证据的规范修订；不在实现或本计划中静默放宽。

以精确产品 head/tree、Chromium/V8 patched tree、配置和二进制 hash、测试名/匹配数、退出码、原始日志、run/attempt 记录证据。基础 CI、native、真实服务、G0–G3 和分发分别报告。

本轮 Q 交付开发、测试、修复和可审查 develop PR。合并、晋升由协调者按当前真实授权和最终候选门槛判断；上述历史 Auto 描述不作为新的无条件授权。本轮不部署服务、不调用付费 API、不发布安装包。
