# Aegis 访问服务 V1.0：当前开发计划

更新日期：2026-10-07。本次上游对齐冻结来源为 develop `12c2654a7374a387c5568319ecf564fcfc440774` 与 upstream/main `a4480b4ab0c04b8f486a01f7486ecdb15f2fed25`。个人 main 已通过受保护快进与上游 SHA 完全一致；develop 回流候选仍须独立审查、最终 HEAD 质量门及适用的 Chromium 153 验证。精确工程证据见 [Handoff](handoff-20260920.zh-CN.md)，分支与交付规则只引用 [DEV CI 指南](../../development/ci.zh-CN.md)。

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

## 当前执行板与基线选择（2026-10-07）

后续整合以 Chromium **153.0.8010.53** 为目标，固定提交以回流候选的 `CHROMIUM_COMMIT` 为准。F 现存 source/out 仍绑定 **151.0.7922.77**；停在 exact socket attempt-02，保留全部输入、失败和增量产物，不在该目录直接升级，也不自动开启第三次运行。上游对齐不等于 F 工作分支已经合入，151 的通过不能改称 153 的通过。

| 工作线 | 已验证或当前状态 | 下一成果与解除的阻塞 |
| --- | --- | --- |
| I / 上游对齐 | fork main 与 upstream/main 已精确一致。上游精确 S 的 push quality 为 PASS，机器 native 分类仍为 REQUIRED。隔离回流保留 develop 的独有提交，六处 README 冲突已解决；浏览器产品源码与上游 S 相同 | 完成回流候选的独立审查、最终 HEAD full quality、托管 CI 和适用 153 native/browser 门；通过后以 merge commit 回流，并核实际 develop S push。解除继续基于旧 Chromium 集成的基线偏差 |
| F / W1 | 151 trusted WS 有界单元五目标构建、68 项运行及独立审查 CLEAR。exact socket 新单元两次构建通过；最新 35 项为 21 SUCCESS、6 FAILURE、1 CRASH、7 NOTRUN，后续 90+4 未运行。生产 guard=false，原正向路由仍未关闭 | 保留完整未合并分支及实际 WIP，先做 153 接口与 patch/overlay 映射；在隔离新候选中处理已明确的夹具事件通知与合法 pause 序列，再验证同一撤销/继续使用单元。不得只搬最后一份补丁或借用旧运行结论 |
| Q / 历史补证 | 精确 #26 H 的 17 targets / 181 native PASS；browser 在枚举阶段失败，runtime NOT_RUN。修复 driver 的离线检查/审查已完成，历史 S 未运行 | 保留欠账与旧目录；若需要该历史身份的晋升证据，由 I 单独分配。它不自动成为 153/F 闭环的前置，也不自动占用下一重型槽 |
| M / W2 | #200 合成 SM-00 与本地 lease/relay 已交付；真实鉴权、selected 数据面 writer 与资源预算尚未绑定 | 等 F 同一条正向链路形成后，把可信账户/节点身份、真实双向计量和额度截断接入该链路；资源未授权时保持 BLOCKED，不扩展独立 TCP 夹具来替代产品接通 |

当前没有重型构建在运行。原 F claim/source/out 保留；任何新的 153 workspace、源码组合和构建时段都由 I 重新核验并明确分配，不能复活旧 continuation。主 checkout 用户修改及所有旧 source/out/快照/日志不自动清理。晋升自动化保持 `paused`。

## 接下来只按这些完成条件推进

1. **对齐集成基线。** 回流候选包含上游与 develop 两侧祖先，保留共享流程和现有计量原型；绑定新的 Chromium/V8 pin、ordered patches、overlay、GN args、实际枚举与输出。基础 quality 与 153 native/browser 分别判定；先核上游 #30 原始回执与本候选相同产品输入的对应范围，缺失部分补证，不将 PR 中的通过声明当作本次运行。缺少适用集成证据时回流保持待验收。
2. **完整迁移 F 的一个在制行为。** 依据 F 产品分支、实际未提交 diff、补丁/overlay 清单与源码 manifest 提取完整候选，而非只取最后的 0256。151 运输编号不是 153 的映射依据；若 API 或资源归属变化，先聚焦设计复核，再由原 F 实施最小兼容修改。一次只验证当前 exact socket 单元，不同时补全其他 send path。
3. **把当前失败变成可判定的一次运行。** 已确认的两项夹具缺陷是 pause 后使用同步事件，以及 server IO 线程更新状态却未唤醒测试线程。修复事件观察的任务生命周期与丢通知问题，保持原超时、真实 CONNECT/marker/双向字节、旧连接停止、撤一留一/新建、自然退役和重入销毁断言。保留 35→90→4 的完整场景；迁移导致名称/枚举变化须说明映射并审查，不能静默缩减。源码重新冻结后单任务、零重试；35 项全通过才接 90+4。正确事件接线下仍失败就停止重跑并定位执行器。
4. **进入真实产品入口。** 当前 primitive 通过后仍需可信 control/admission 接线、适用发送路径完整性和 barrier/context/epoch 聚合，才能验证 coordinator install/finalize、精确文档绑定及真实选定出口。每个前置必须说明解除链路的哪个阻塞；不得用测试 setter 打开生产 guard，或把永久 fence/Busy 当恢复。
5. **完成同一条用户链路，再接计量。** 同一产物、Profile、账户、授权节点完成上方五步及三端关联证据后，由 M 接真实计量和额度截断；原有认证、双 Profile、BLOCK、生命周期与 Alpha 范围继续保留。

E1 的四个 `OtherAndFreshInstancesStayUsable` 都是 NOTRUN；E2 的三个参数首次通过，代理 TLS 参数在关闭观测处首次失败。不能把两次构建/测试 attempt 记成同一正例两轮定向修复失败。聚焦复核已完成，但它不是运行通过或代码 CLEAR。下一次正确事件接线的实际结果决定后续动作。

## 依据、证据边界与历史

行为与完整门槛以[冻结修订 4](spec.zh-CN.md)为准；实施边界见[架构复核](architecture-review-20260922.zh-CN.md)，逐项事实见 [A/PF 台账](acceptance-tracker.zh-CN.md)，历史矩阵见 [QUALITY-HANDOFF](QUALITY-HANDOFF.md)。**W0 有界底座退出不等于 G0；G0 仍 UNVERIFIED，131 个 A/PF 主行不升级，当前没有完整 Alpha 验收证据。**

已有普通 DIRECT/PROXY coordinator、快照发布、执行 ACK、durable commit 与多个入口的局部回归，仍不等于可信 `SetSiteProxy`、生产身份/节点、故障恢复和计量链路已接通。host 单 endpoint 的拒绝冲突也不替代不同路由并存。

旧 #162/#177/#187、早期执行板及 2026-09-28 调度保留在[本次编辑前的精确版本](https://github.com/quinn521/aegis-browser/blob/12c2654a7374a387c5568319ecf564fcfc440774/docs/plans/access-service-v1.0/development-plan.zh-CN.md)。这些身份用于追溯，不再作为当前 owner、运行命令或新候选 PASS。

## 实施顺序与依赖

W0–W6 是本计划的工作包，不改变冻结 P0–P8 和 G0–G3 的定义。只读设计与直接解除上述闭环阻塞的准备可以并行；真实服务实验仍须资源和授权到位；依赖上一个代码单元的工作，按 DEV 指南在实际合并和精确 develop push CI 通过后接续。所有产品功能单元仍需同 PR 的 unit 与真实入口 regression，最终候选实际执行；原型不得用源码存在冒充运行通过。

| 工作包 | 对应冻结单元 | 工作与前置条件 | 退出证据 |
| --- | --- | --- | --- |
| W0 固定 Chromium 底座 | P0 | 复用已合入 runner/GN 修复和 #162 保护；在当前集成基线覆盖全部必需目标及真实入口，补适用的 LoadingPredictor fixture；核对 LLD/SDK 与独立参数变体，不修改其他任务的构建工作区 | 当前候选全部必需 Access unit、既有真实入口矩阵实际 PASS；零匹配/部分运行不算完成；保留全部目标、过滤器、日志、退出码和来源树 |
| W1 请求级路由原型 | P0/P1/P2 | 当前目标基线的适用 W0 门完成后，在隔离候选验证可信上下文从 Browser 到实际 proxy/stream 的载体、每组多端点注册与连接隔离；先交接口清单，再实现最小并发场景；同阶段完成固定 Chromium 的最小 HTTP/SOCKS5 Profile 认证与隔离原型 | A/B 同 CDN 异组、不同 host 异组、scheme/port、DIRECT/PROXY/REJECT、redirect、POST/PATCH、两 Profile、旧连接及 Network Service 重启的正反路径；A78 的两入口最小认证/隔离用例实际运行；接口和性能风险有明确结论 |
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

本轮先交付上游回流候选与更新后的执行计划；后续 F 仍由原实现者负责，I 统一签发源码与重型时段。Q 历史补证和 M 真实服务实验须有各自明确前置与授权。合并、晋升按最终候选门槛判断，历史 Auto、旧 claim 或旧通过记录不授予新运行、部署或发布权限。
