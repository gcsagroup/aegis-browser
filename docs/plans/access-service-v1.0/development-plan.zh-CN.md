# Aegis 访问服务 V1.0：当前开发计划

更新日期：2026-09-28。此次计划编辑基线为 `origin/develop@358477d7b8c7d064989ff685fc54b6df274113b6`（#201），上游 `main@dcfd5ac0759184ad757c2a097bb3409e767b8366`。各候选的实际验证身份分别记录在 [Handoff](handoff-20260920.zh-CN.md)；#200 的本地与 CI 结果、历史 #26 H 的 native 结果均不转作本基线的 Chromium 或真实服务证据。

## 近期唯一主目标：先跑通一条真实链路

在固定 macOS 浏览器产物中，首个切片选用无冲突独立规则的配置，用一个测试 Profile、一个测试账户、一个已授权受控节点，完成：**开启网站代理 → 页面经指定出口成功加载 → 节点故障时不直连 → 恢复后重新成功访问 → 关闭规则后恢复当前原生行为**。随后把真实计量与额度截断接到同一条浏览器—代理—受控 origin 链路，不用独立 relay 夹具代替产品接通。

这是 W1 向 W3 推进的阶段性工程验证，**不宣布完整 W1/W2/W3 退出，不降低修订 4、G0–G3 或 Alpha 门槛**。单 Profile 是首个运行切片，不豁免两 Profile 隔离、HTTP/SOCKS5 认证、完整 BLOCK、生命周期、性能与分发验收。资源未绑定或未授权时如实标为 BLOCKED；可验证本地前置路径，但不能冒称受控节点闭环已完成。

| 步骤 | 本轮必须观察的实际行为 | 可靠性断言与证据 |
| --- | --- | --- |
| 开启并成功加载 | 经可信产品入口提交规则，真实配对安装/finalize 后从指定代理出口到达 origin，页面成功加载 | 同一关联 ID 连接浏览器提交结果、代理路由/连接和 origin 日志；不能用 test setter 开启生产 guard 或只凭 UI/ACK 判成功 |
| 节点故障 | 对已提交代理规则的目标施加有界、已授权故障，受约束的新请求失败且不走 DIRECT/原有代理备用 | 以同配置健康请求证明观测有效；区分故障前已发送流量与故障后新派发，不以超时、无日志或 origin 总量冒充无旁路 |
| 恢复后再次访问 | 节点恢复后通过支持的恢复流程重新访问成功；另验证 Network Service 重启后身份/策略重新建立 | 旧 ACK、取消和旧连接不得重新授权；不重放已发送业务，不永久 Busy，不靠清库或测试专用绕过恢复；明确自动恢复与需用户重试的真实行为 |
| 关闭规则 | 通过产品入口关闭网站开关所拥有的协议组；无更具体独立规则时，新请求按当前原生配置执行，该组的旧代理选择不残留 | 同时覆盖原生直连和已有原生代理的适用配置；另验证更具体的独立 PROXY/REJECT 继续生效、限制状态正确显示，不隐式解除它们；不恢复过期配置备份、不影响无关目标；三端证据按关联 ID 核对 |
| 接入计量与额度 | 在上述同一产品链路接入已绑定的真实服务执行点、账户账本与有限预算 | 长连接未结束时计量；额度耗尽停止新增许可发送，区分在途/缓冲字节；崩溃恢复不重发、不重复结算；PF04/PF09 与完整 A118 条件仍分别判断 |

每一步先锁定输入、预期结果、故障触发点及有界观察窗口，再运行并保留原始结果。同一候选改动后重新绑定精确输入；不可拼接不同 SHA 的局部 PASS 宣称整条链路通过。短期覆盖补强直接围绕此表的成功、失败、恢复和隔离断言；先查已有可执行测试再补缺口，不为增加测试数量重复已有用例。

## 当前执行板（2026-09-28）

| 工作线 | 已交付及证据边界 | 接续动作与退出条件 |
| --- | --- | --- |
| W0 / Q | #187 已完成有界底座退出。历史 #26 精确 H=`1c73c5a8c9a14e6da7ebc7cf42d088fce67659f9` 的 attempt2 native 为 17/17 targets、181 tests PASS、sourceStable；H browser 正在构建，S 未运行 | 完成当前 H 的 72 Chrome + 6 Content 实际枚举/运行并核最终来源；成功或失败均保留回执、安全释放重型槽并交 I。S 保留欠账，未证明是 F 技术前置时不自动排在 F 前面 |
| W1 / F | 未合并 H=`3bf39b32bff99376d35cc2e1cc1a60809b5ed520` 的正向 `PrefetchUsesSelectedProxy` 失败；v2 guard/finalize 修订只有静态检查，尚未编译运行，生产 guard 仍关闭 | 获槽后先验证现有 v2；现有失败正例直接发布测试 runtime/endpoint，仅作前置诊断，另补通过 coordinator 的开启/故障/恢复/关闭真实入口用例。逐个运行验证后再接下一改动，关闭真实正向代理与恢复阻塞。每次修复证明原失败消失、安全约束保持、系统恢复可用；永久 fence/Busy 不是恢复完成 |
| W2 / M | #196/#197 本地租约/relay 夹具、#198 适配设计、#200 合成 SM-00 预检已交付；#200 最终 H 本地 91 metering + 10 preflight 通过，仅为本地范围 | 复用已有代码，先明确同链路真实计量的第一处接入阻塞；资源、鉴权、writer、配置与预算绑定后再实施真实执行。暂停脱离闭环的功能扩展和纯整理 |
| I | #199/#200 的实际 S push 已核；本次文档从 #201 基线接续 | 每个任务先写明解除哪一步的阻塞。Q 当前 H → 实际释放/重新签收 → F 正向与恢复优先；历史 S 与晋升门槛分别保留 |

重型 Chromium 时段唯一。当前 Q 的 H 构建继续，保留已投入的源码、增量产物和失败证据；不因本计划切换而中断或修改运行输入。下一重型槽优先给 F。历史 S 若确为闭环技术前置，由 I 写清具体依赖后另签时段；否则留待后续补证。所有依赖 S 证据的晋升继续等待，不以重新排序豁免它。实际交接仍核源树、产物、进程、锁和容量；计划不授予并发写 source/out 的权限。

**W0 有界底座退出不等于 G0；G0 继续 UNVERIFIED，131 个 A/PF 主行不升级，当前尚不具备对外交付 Alpha 的证据。** 下列有日期的旧执行板和候选只用于追溯。

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

之前累计在本页的 PR 推进日志已由本次清晰的当前计划替代，原文保留在[精确基线版本](https://github.com/quinn521/aegis-browser/blob/c4ffb50a0d8efc684aa1ba0022daf5113def19a6/docs/plans/access-service-v1.0/development-plan.zh-CN.md)，仅用于追溯，不再执行其中“下一步合并 #135/#148/#158”等历史指令。分支、交付职责、审查和最终 HEAD 门禁只引用[DEV CI 指南](../../development/ci.zh-CN.md)。

当前已有普通 DIRECT/PROXY coordinator、候选快照发布、执行 ACK、durable commit、幂等重试以及多个浏览器入口的源码回归。可信 `SetSiteProxy` 用户闭环、身份/节点生产提交、真实 Xray、计量/额度和完整请求矩阵尚未闭合。host 级单 endpoint transport 仍不足以实现全部规则语义；拒绝冲突不能代替不同路由并存。

历史 #162 最终 H=`4670c4dd5f24db61f38f102cc60475658e63554a`、S=`ca4e1b24c750746d6e20a83fa58f1d2500791d02` 的三个选定 unit target 共 96 项及三组 browser fixture 通过，native 总状态是 `PARTIAL_PASS`。它们不转用于新候选。后续 #187 已关闭 QUALITY-HANDOFF 列明的有界 W0 底座欠账；G0 继续 UNVERIFIED，G1–G3 未达到。

## 历史：2026-09-24 18:16 UTC 执行板

| 顺序 / 负责人 | 当前状态 | 下一动作与完成条件 |
| --- | --- | --- |
| Q：固定基线与矩阵 | 初始冻结 D7f74e0a；最终 H1f86a6e 的 17 个原生目标及 Chrome/Content browser 已实际非零枚举和运行 | 保留每次候选的精确身份；不从源码声明、旧头或单项通过推断 G0/主行验收 |
| Q：历史 #162 核验 | H13 三目标 16+45+35，native `PARTIAL_PASS`；Access 冲突导航/History/Settings 三组 PASS | 保留 H13 身份、原始路径与哈希；不恢复 H12/`682997a…` 的构建指令 |
| Q：W0 选定矩阵 | #177 最终 H1f86a6e：17 target/181 native、56 Chrome browser、6 Content browser 均 PASS/sourceStable；local full、托管 PR CI、独立 Review、develop S push CI 均通过 | 保留旧失败与中断回执；按 QUALITY-HANDOFF 的覆盖边界继续 G0/主行验收。Q 已释放重型构建槽，由 #23 的独立原生任务串行使用 |
| Q：W0 新候选回归 | 0197–0200 增加 relay 取消/watchdog、真实缓存命中后 REJECT、已提交 MHTML 子帧预取早拒绝；精确身份和本轮结果见 QUALITY-HANDOFF 与独立原始回执 | 候选须重新执行 source admission、原生与真实入口矩阵及质量门；旧 H 的通过不转作新 H 的结果，完整 BFCache/prerender、G0 与主行仍分别判断 |
| Q：LoadingPredictor 回归设施 | #177 最终 H 的 Chrome 56/56 与 Content 6/6 已实际 build/list/run；真实 `PrefetchManager::Start` 回归包含在该证据范围 | 不扩称预测生成、导航触发或全部浏览器入口已覆盖；剩余范围见 QUALITY-HANDOFF |
| F：W1a 接口/fixture 准备 | 与 Q 独立；#166 模型路由后续工作 DEFERRED | 可并行准备 W1a，不操作 Q source/out/锁；W0 关闭后再推进 W1b/W1c |
| W2 服务端实验 | 执行资源/负责人未绑定，BLOCKED（实验执行） | 可准备协议；实际部署或付费 API 调用需另有授权 |

上述 #177/#23 槽位安排仅为历史记录，不能据此启动构建或认定当前 owner。实际时段按本页当前执行板及实时交接核验；历史精确目录、原始证据和缺口分类见 [QUALITY-HANDOFF](QUALITY-HANDOFF.md)。

## 实施顺序与依赖

W0–W6 是本计划的工作包，不改变冻结 P0–P8 和 G0–G3 的定义。只读设计与直接解除上述闭环阻塞的准备可以并行；真实服务实验仍须资源和授权到位；依赖上一个代码单元的工作，按 DEV 指南在实际合并和精确 develop push CI 通过后接续。所有产品功能单元仍需同 PR 的 unit 与真实入口 regression，最终候选实际执行；原型不得用源码存在冒充运行通过。

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

[P3c/A118 单执行点服务端适配设计](W2-SERVER-METERING-DESIGN-20260928.zh-CN.md)已由 #198 交付，限定为边界、资源/阈值清单和验收方案。#200 提供[纯离线合成清单校验器](../../../prototypes/access-metering/sm00_preflight.py)与[运行说明](../../../prototypes/access-metering/README.md)：`PYTHONDONTWRITEBYTECODE=1 python3 prototypes/access-metering/sm00_preflight.py --check-only --manifest prototypes/access-metering/sm00_synthetic_manifest.json`。结果仅为 `LOCAL_PREFLIGHT_ONLY`，没有生产 adapter、受控负载 runner 或真实 SM-00 实验结果。候选 VPS 的存在不替代固定 Linux/Xray 身份、鉴权映射、下行计数点、负责人和预算绑定；同一 VPS 的两条线路不算两个独立故障域。RateLease/PF09 和 PF04 UI 采样分别后续交付，不能由设计或本地计量结果提升 A118 状态。

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

同一条链路同时只推进一个尚未得到运行验证的行为改动：先验证已存在的候选，再根据第一处失败实施下一修复。每次修复的完成条件同时包含：原失败消失、安全不变量保持、恢复后可继续使用；代码提交、负例通过或文档更新不能替代其中任何一项。保留 fence 可作为安全中间状态，但永久 Busy 不能结项为恢复完成。

同一个正向场景经过两轮有针对性的修复仍失败，就停止叠加行为补丁，触发聚焦设计复核，核对接口假设、状态归属和恢复边界；形成一个可证伪的假设与下一次运行，再交原实现者继续。两轮是设计复核触发点，不是放宽断言或无限重跑的许可；环境失败单独分类，不靠清理数据、测试 setter 或改变原正例预期消除产品失败。

文档原位随交付更新，复用已有计划、Handoff 和验收台账，不为同一事实新增同义交接。每天只报告：**新跑通的用户步骤、仍失败的步骤、当前第一阻塞、下一次运行要验证什么**，附对应原始证据；其他未关闭项留在台账，不将 PR 数、测试总数或文档数量计为产品完成度。

每个工作包拆成可独立审查的小 PR；同 PR 更新 plan、Handoff 与涉及的验收映射。新产品单元必须实际执行相关 unit 与真实入口 regression，最终 HEAD 对应的 local full quality、托管 CI、Codacy 和独立 Review 按 DEV 指南完成；文档调整不补造产品测试。未知、缺失、零匹配、取消、过期 SHA 和部分运行不得提升证据等级。

W0 未完成时，浏览器线先处理 native 基线；W1 未通过时停止新增调试规则/请求入口；W2 未通过时不承诺实时计量、严格额度或 Alpha 可用。只有直接解除当前闭环阻塞的设计/已授权服务实验继续推进，受阻状态和第一处失败归属写入 Handoff。若需要改冻结行为，另提带失败证据的规范修订；不在实现或本计划中静默放宽。

以精确产品 head/tree、Chromium/V8 patched tree、配置和二进制 hash、测试名/匹配数、退出码、原始日志、run/attempt 记录证据。基础 CI、native、真实服务、G0–G3 和分发分别报告。

本轮 Q 交付开发、测试、修复和可审查 develop PR。合并、晋升由协调者按当前真实授权和最终候选门槛判断；上述历史 Auto 描述不作为新的无条件授权。本轮不部署服务、不调用付费 API、不发布安装包。
