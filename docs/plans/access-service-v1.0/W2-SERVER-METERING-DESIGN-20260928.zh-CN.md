# P3c/A118 单执行点服务端计量适配设计

日期：2026-09-28。取证基线：`develop@93b0deb4c6ecdd8009755cda02fb627d5eff6cea`。状态：**设计候选；服务端适配未实现，真实实验 BLOCKED_RESOURCE / NOT_RUN**。

本设计为一个受控 Linux 执行点、一个集中账本、有限预置测试账户准备计量适配边界与实验输入。冻结依据为[规范第 4、8、13 节及 A118](spec.zh-CN.md)、[架构评审第 3、4 节](architecture-review-20260922.zh-CN.md)、[W2 实验交接](W2-EXPERIMENT-HANDOFF.zh-CN.md)。本批只交付文档，不创建真实服务、不确定运营数值。RateLease、物理速率/PF09 实现、PF04 UI 采样与浏览器接线分别后续交付；它们仍是完整 A118 的适用依赖。本设计通过审查也不能将 A118 或 G0–G3 改为 PASS。WS+TLS 候选继续为相关开发完成后回测 TODO。

## 1. 已有实现及不能直接复用的边界

下列符号均在上述基线中可核查；表内“拟议”内容尚无生产实现。

| 仓库证据 | 已有行为 | 对服务端适配的限制 |
| --- | --- | --- |
| [`AccessIdentityGenerationSource::CommitIdentity`](../../../apps/browser/overlay/chrome/browser/aegis/access/access_identity_generation_source.h)、[`AccessIdentityBinding`](../../../apps/browser/overlay/components/aegis_access/access_identity_generation_state.h) | Browser/Profile 持有身份代次及 `principal_id`、`entitlement_account_id`、环境/realm；头文件明确调用前已完成鉴权 | 不是服务端凭据验证器，不给网络对端提供身份背书 |
| [`LeaseRelay.boot/_transfer/_flush_lease/_client`](../../../prototypes/access-metering/lease_relay.py) | 直接打开中心 SQLite 与本节点 journal；单个客户端、一个有限 lease；临时文件注入时钟/失联；真实 loopback socket | `--account/--node` 是测试标签；没有远程中心协议、服务端用户映射、Xray 或真实故障分类。boot/grant 请求键只在进程内生成，不能直接承担远程响应丢失后的持久重试 |
| [`NodeJournal.prepare/send_socket_once/complete`](../../../prototypes/access-metering/lease_node.py) | PREPARE 完整预留 → 持久 SENDING → 第二次到期/围栏复验 → 一次非阻塞 socket send → 持久 COMPLETE；短写只累计返回的 n，全块仍预留 | Python socket 的 n 是本机 OS 接受量；不能转称 Xray 编码 writer 的目标字节、origin 收到量或真实用户消费。第二个短 SQLite 事务内 syscall 的证明不能套到阻塞 writer 或网络 RPC |
| [`LeaseLedger.start_session/grant/report/expire_leases/rollover`](../../../prototypes/access-metering/lease_ledger.py) | boot/grant 幂等键、epoch、累计双向结算；`actual + held + remaining = quota`；到期标 uncertain，旧余额不自动返还；held 非零拒绝周期切换 | 身份参数由本地调用者提供；`UsageRecord` 尚无真实 principal、issuer/realm 证明；无生产鉴权 API、可验证回收或正常周期切换服务 |
| [`test_lease_metering.py`](../../../prototypes/access-metering/test_lease_metering.py)、[`test_lease_relay.py`](../../../prototypes/access-metering/test_lease_relay.py) | 本地账本与 socket 故障窗口回归 | 共享本机 SQLite、kill/restart 和故障 marker 不等同于远程服务、掉电、Vision/splice 或生产持久化 |

真实的现有调用顺序是 `LeaseRelay._client → _transfer → NodeJournal.prepare → send_socket_once → complete → _flush_lease → LeaseLedger.report → NodeJournal.ack`。中心与节点逻辑可作适配的合同参照，不能作为已存在的服务端部署。

本次在 `packages`、`apps/browser/config`、`apps/browser/scripts` 及本地计量目录查找 Xray 资产、计量类型与调用者，未找到可绑定的服务端 Xray 源码/二进制清单或鉴权后计量 adapter。`packages/core/src/access` 当前为策略/路由向量测试。后续必须登记服务端仓库和固定源提交；这里不命名未经取证的 Xray 函数、补丁点或“禁用 splice”配置项。

## 2. 拟议数据路径与身份入口

以下名称是**待实现的适配合同**，不是本仓库或 Xray 的现成 API。具体语言、序列化版本及代码落点由服务端实现负责人在固定源码上绑定并复审。

```text
服务端验证入站凭据 → AuthenticatedFlow（不可由请求字段覆盖）
  → AccountPermitOwner（双向/多连接共享账户预算）
  → DurablePrepare → WriteAttempt（实际目标字节执行点）
  → DurableComplete 或 Uncertain → DurableUsageOutbox
  → 经认证的中心累计结算 → 持久 ACK
```

`AuthenticatedFlow` 至少绑定 `serviceEnvironment/realm`、服务端解析出的 `principalId`、`entitlementAccountId`、不含秘密的 credential 引用/修订、有效截止、服务端 `connectionId`、`nodeId`、部署身份和已选 `accountingVersion`。principal 到账户的映射来源是受信签发/账户系统的已验证记录，不能来自 HTTP header、客户端提交的 accountId、外部 IP、浏览器 identityGeneration 或随意填写的 Xray 统计标签。一个凭据只能落入一个明确的环境/realm/账户映射；歧义、失效、未知或无法验证时，在转发前拒绝。

同账户的两个 Profile 使用不同凭据和 principal，汇入同一账户/周期预算；不同账户和测试/生产租户不可共享许可。连接在鉴权成功后固定绑定，切换身份必须停止旧流并建立新的已授权流，不能把旧连接改记到新账户。凭据过期、已知吊销或新围栏阻止新 write attempt；已在执行的写入按第 4 节有界收尾。离线远端吊销最迟受有效截止约束，不能承诺即时远程失效。

为保留规范 `NodeUsageRecord.principalId` 的准确归属，本候选的生产 lease/session/report 还要绑定 principal；不同 principal 分别持有 lease，中心从同一账户 Q 中统一预留，不能每个 principal 各领一份 Q。相同 principal 的多连接共享其许可所有者。账户级聚合发生在校验这些归属后的中心账本；不能在混合了多个 principal 的累计报告上随意填一个 principal。现有夹具的 session scope 尚无该维度，这是后续协议与 schema 的明确增量。

节点到中心的通信也须认证，中心核对该节点是否获准为该账户/环境/周期申请及结算，并绑定完整 lease/session/epoch 身份。TLS/认证机制、密钥轮换、持久请求格式和服务端负责人尚待指定；缺一项即不开放网络 API。日志只记录关联 ID、版本与秘密引用，不记录 UUID、口令、授权头、完整订阅、用户目标 URL 或正文。

## 3. 双向字节口径及 writer 的可行性条件

沿用规范的“代理解封装后目标连接双向转发 byte”：包含目标 TLS 字节；不含 VLESS/Vision/REALITY 外层封装、专用控制面及独立运维探测。真实业务重试产生的新流量计入；缓存命中、DIRECT 和未转发的读入数据不计。`accountingVersion` 必须绑定两方向具体代码位置、目标字节到 writer 进度的映射及构建摘要，不能继续使用 `fixture-target-bytes-v1` 冒充生产版本。

| 方向 | 拟议许可与计数位置 | 不能作权威 actual 的值 |
| --- | --- | --- |
| 上行 | 已完成身份归属及代理解封装，向目标连接实际写入前取得 durable 许可；以该执行点确认接收的目标字节 n 记录完成 | 外层 socket RX、读入/排队字节、请求 Content-Length、origin 应用正文 |
| 下行 | 从目标连接取得的目标字节，在首次不可撤销地向客户端转发前取得 durable 许可；writer 必须给出同一目标字节流的准确已执行前缀 n | 目标 socket 的 recv 返回量本身、编码队列接受量、含外层加密/填充的 socket write 返回量 |

下行是主要待验证点：协议编码 writer 可能缓冲、合并、部分失败或绕开普通复制循环。只有固定源码证明其完成结果能对应到准确的目标字节前缀，且所有出口均受许可控制，才允许 `DurableComplete(n)`。如果只知道密文字节或整块交接给内部队列，则本设计的 actual 条件不成立；必须评审内核适配，或记录 `BLOCKED_ADAPTER`。不能把估算比例、整块预留或 `WriteMultiBuffer` 一类未审接口的成功返回当成已证明的目标字节数。

Stats API 仅作交叉观测。2026-09-28 查阅的[上游统计说明](https://xtls.github.io/en/config/stats.html)描述按配置用户统计上下行数据；该页面不提供本项目的 durable 许可、身份账本或截断合同。这里不把统计名称中的 email 当作可信账户身份。正文所需逻辑由适配实现证明。

## 4. PREPARE、实际 write、截断与缓冲上界

单执行点中的 `AccountPermitOwner` 为同账户的所有连接与两方向串行决定许可；数据写入可以并发，但每个许可只有一个写入所有者和一次 attempt。账本/许可锁不得跨网络 RPC、等待可写、阻塞编码或无限循环。生产 writer 的类型尚未选定，不能复用本地 Python 夹具在事务内执行一个非阻塞 syscall 的证明。

1. 已归属的目标字节进入有界暂存区；按冻结的块上限选择 `q`，并校验连接数、待写数、journal/outbox 容量、凭据有效性、lease 期限与围栏。在实际转发前持久写入 PREPARE（完整 q、方向、流/账户/周期/session/lease、attempt ID）。预算不足时拒绝该块并关闭受影响流；本设计允许保守提前截断，不承诺把最后不足一块的余额全部花完。
2. 持久记录 SENDING，再由写入所有者复验授权并线性化为 IN_FLIGHT；许可所有权不可复制给另一任务。等待网络就绪发生在锁/数据库事务外，等待后需重新复验。截止/围栏处理与 IN_FLIGHT 的入场在同一执行点串行排序：处理截止后不能再开启新 attempt；此前已进入的 attempt 仍占预留，受冻结的写超时和最多 q 的限制。不能把检查与随后无限制的异步 write 分开。
3. writer 对同一 attempt 至多放行 q 个目标字节，不自动重放未确认字节。能证明准确 `0≤n≤q` 时持久 COMPLETE(n) 并更新双向累计；短写后关闭流，未写尾部继续占预留。若只有异常或不确定进度，持久标记/恢复为 uncertain，不伪造 n。已知 n 但 COMPLETE 落盘失败时停发；存活所有者可用原证明重试持久化，不能重发网络数据。
4. 若 writer 要分多次系统调用，适配设计必须给出每个可中断执行步骤的许可覆盖、授权复验、进度累计和取消界限；没有这份证明时不可选用该 writer。TCP 半关闭、取消、连接关闭和下游重试都不能为同一 attempt 再发数据。队列/容量满、期限不可信或存储错误均阻止新的发送。
5. 额度耗尽或拒绝时，执行点关闭相关数据流并停止读入/排空可继续输出的应用队列。底层已接受的数据可能在稍后才到达对端；记录 cutoff 与最后一次许可/执行事件，不能用关闭调用的时间声称对端瞬间停止。

冻结预算使用不同字段，避免把预算、用量和观测滞后混合：

| 符号 | 定义与必须证明的约束 |
| --- | --- |
| `Q, L, C, K` | 账户 byte 额度、单 lease byte 上限、单 attempt 目标 byte 上限、全执行点最大在途 attempt 数；每一目标 byte 在转发前必须被唯一 PREPARE 覆盖，双向合计预留不得超过有效 lease，中心累计授权不得超过 Q |
| `U` | 已可能写出但尚无 durable COMPLETE 的 byte 上界；至少按所有在途/故障未决 attempt 的完整预留求上界。还须冻结账户全局未决预留上限，达到即停发；`K×C` 只是同时在途部分，不能掩盖历次重启累积的 held |
| `E_quota` | 同口径权威写入累计超过 Q 的允许误差（待冻结）。若所有出口均有唯一完整预留，可推导计量执行点的超额为 0；该推导依赖适配与快路径的实证，不代填部署验收数值 |
| `E_after_stop` | 截止/已知吊销线性化后还可能执行或交付的目标 byte 上界；按在途 attempt 剩余量与各下游缓冲的**字节区间并集**计算，避免重复相加，也不能漏掉编码器、TLS、内核、splice pipe 和异步队列 |
| `E_reconcile` | 节点完成量、中心确认量与独立目标字节观察间允许的误差；比较同一方向、流、区间及排空状态。TLS 正文和密文不可直接相减；断连/崩溃样本需用已知区间与 coverage 表达 |

缓冲在许可前必须可丢弃且有全局容量限额；许可后可继续输出的每个字节必须已有预留。为每层登记单位（目标或外层 byte）、上限、归属、取消/排空行为、是否已计入 n，以及转换方法；无法映射的外层缓冲不能填成 0。`socket.send` 成功与 origin 接收分别记录，不能用单方日志证明物理交付。byte 额度守恒没有证明 Mbps、burst 或公平性。

## 5. journal、中心与重启

节点 journal 与中心数据库分别定义耐久提交/恢复点和存储故障模型。SQLite FULL/fsync 的本地试验是实现输入；真实文件系统、磁盘写缓存、同步与备份策略必须绑定，`kill -9` 不代替掉电试验。损坏/丢失旧库或未知 schema 时停止，不能创建空库并重新领取额度。

拟议远程协议应持久记录 boot/grant 请求键与参数摘要，再首次发出请求；超时或响应丢失用原键重试，同键异参拒绝。回复校验环境/账户/周期/节点/session/epoch/版本/期限后才能持久采纳。中心预留先提交再回复。中心重启必须保留请求去重与额度状态；不能把一次不确定超时当成“未授权”并换键重复申请。新请求、grant 数、等待队列和重试均有冻结上限。

恢复前取得单执行点的独占所有权并证明旧进程已退出或不再能使用同一发送入口；部署/锁机制待绑定。若不能证明，中心必须继续保留旧授权，且新进程不能宣称旧执行点已即时撤销。重开 journal 后按以下矩阵处理：

| 崩溃位置 | 恢复动作与证据 |
| --- | --- |
| PREPARE 前或其提交失败 | 无新 durable 许可，禁止写；证明无目标字节越过执行点 |
| PREPARE 后、实际 write 前 | 不重发该块，保留完整预留；可证明未执行也不自动释放，回收需另有可审计协议 |
| SENDING/write 中或 write 返回后、COMPLETE 前 | 无准确持久完成证明则可能已写 `0..q`；保留 q，报告不确定区间；进程重启不能继承内存 n |
| COMPLETE 后、中心接受前 | 重发持久累计和原 pending 身份/序号/摘要；重复和乱序不得推高累计 |
| 中心提交后、节点 ACK 前 | 中心返回同一结算结果，节点再持久 ACK；不能重复计费或返还 held |
| ACK 后、下一 session/lease 前 | 确认旧报告处理完毕后申请新 session/epoch；旧 PREPARED/SENDING 不可恢复发送，新预算只来自中心剩余额度 |

`DurableUsageOutbox` 保存至多一个每 lease 的待确认累计，以及未发布的 durable 完成水位；中心按完整身份、单调序号和内容摘要幂等确认，节点验证响应后推进 ACK。node actual、center confirmed、held/uncertain 和观察时间分别输出。晚到的旧 lease 报告可用于结算该旧授权，不能恢复其发送权或覆盖新周期。

只有明确分类的临时中心不可达允许已有有效 lease 内的有界转发；新授权依赖中心。认证/版本/身份/水位冲突、journal 完整性错误或不可验证 ACK 锁住该执行点后续发送。网络超时、中心不可用及连接重置的分类须由协议/transport 返回结构化原因，不能匹配错误文字。重试次数、最大时长、退避及 outbox 容量必须冻结；达到任一上限停发并保留 pending/held。

截止使用经校准且保守的服务端期限与本机单调时间，扣除冻结的时钟不确定性；重启、暂停/恢复或时钟异常后重新验证，无法验证则不发送。当前夹具的整数文件时钟不是生产时钟合同。旧预留没有可验证结算/失效证据时不返还；本候选采用保守停发，周期切换可能被 held 阻塞。自动回收、正常跨周期可用性与存储压缩需后续独立协议，不能从本设计推断已经解决。

## 6. Vision/splice 的取证与决策

2026-09-28 查阅的[上游 VLESS/Vision 说明](https://xtls.github.io/en/config/outbounds/vless.html)描述特定 Linux 路径可能使用 splice，并提示统计显示可能延后到断连。它是需要调查的风险说明，不是本项目固定服务端拓扑的运行结论。当前未绑定 Xray 源码版本，因此这里没有声称存在可直接接入的 hook 或可用的关闭参数。

后续按固定 Xray commit、补丁、构建参数和运行配置，为**服务端两方向及客户端适用路径**建立调用图：鉴权对象产生位置 → 目标字节产生/转换位置 → 普通 writer → 自动优化选择 → 零拷贝/其他旁路。每条边列真实符号、源文件、代码版本、所持 byte 单位与身份载体，并用测试确认路径确实被执行。仅记录配置 `flow=xtls-rprx-vision` 不能证明走了哪条数据路径。

| 路径结果 | 准入决定 |
| --- | --- |
| 保留 Vision 的逐块路径，证明每个执行出口可预留、截断、取得准确逻辑 n，所有隐藏缓冲有界 | 可进入已冻结预算的受控单执行点实验；仍须运行下节矩阵 |
| 优化路径绕开许可/计数，固定源码有已验证的选择或适配方案 | 先交内核适配差异、协议互操作与取消/计量回归，证明实际二进制不会进入未经验证的旁路；之后重新评审 |
| 只在关闭连接时得到总数，或缺少逐块预算执行/准确目标字节映射 | `BLOCKED_ADAPTER`，不能以更快 Stats 轮询补齐 |
| 无法证明保留 Vision 的可计量路径，或者不能枚举/控制全部适用快路径 | W2 保持 BLOCKED；不得删除 Vision 或改用 WS+TLS 来替代结果 |

## 7. 实验清单与冻结输入

公开设计只定义字段。具体宿主、账号、执行人身份、配置与秘密引用放在访问受控的私有索引，公开证据只保留合成 ID、脱敏摘要和必要 hash。下面所有部署值和责任人当前均为**待定**，不是从本地夹具默认值继承。

| 字段组 | 必填输入及绑定责任 |
| --- | --- |
| 资源与责任 | 服务端仓库/源提交，服务端适配、账本、运维和实验执行负责人；获授权的 Linux 执行点/客户端/origin；部署、capacityGroup、trafficPool、failureDomain、测试账户/Profile/凭据映射；测试网络与时间窗口 |
| 构建与路径 | Xray commit、二进制/补丁/config SHA-256、构建来源、Linux/kernel/架构、服务端和客户端 flow/transport/security、计数/截断真实符号、Vision/优化路径证据、origin 计数方法及观测有效性对照 |
| 额度与容量 | 有限 Q、L、TTL、C、K、账户/连接/队列/缓冲/outbox/journal 上限；U、E_quota、E_after_stop、E_reconcile；中心重试次数/时长、写超时、关闭/恢复超时与自动停发机制 |
| 实验预算 | 总真实网络流量上限及双向统计方式（含外层/控制/重传）、最大并发、总时长、故障次数、持久化/日志容量、自动停止阈值、实验进程/连接清理方式。账户目标 byte Q 不是物理流量预算 |
| 耐久与时间 | journal/中心事务、同步与恢复策略、磁盘/虚拟机故障模型、独占执行点证明、时钟偏差及暂停检测、事件时间分辨率、采样间隔和计量延迟限值 |
| 证据身份 | 产品 B/H、Xray/config/adapter/origin hash、场景与重复次数、随机种子/确定性负载、命令 argv 脱敏记录、退出码、run/attempt、原始日志及 hash、coverage、阈值版本和冻结时间 |

实验清单逐字段要求类型/单位/范围，额度与 byte 使用可精确表示的非负整数，ID/序号/集合有硬上限；`unknown/null/TBD` 不转换为无限或零。运行前由负责人确认并冻结清单的摘要。缺值、修改阈值、源码/配置变化或观测不完整时阻止或作废对应运行，不在看到结果后放宽阈值。

## 8. 验收执行方案与交付判定

当前可实际执行的仅是仓库已有本地夹具命令，用于防止合同准备过程中误改已交付行为：

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s prototypes/access-metering -p 'test_*.py' -q
```

以下 `SM-*` 是**待实现验收 harness 的场景 ID**，不是已经存在的命令或已执行结果。后续实现必须交付 manifest 校验器、受控负载/故障 runner、独立计数采集与对账程序，暴露每场景单独执行与全矩阵入口，命令/退出码登记到同一证据索引。校验器在连接任何端点前检查第 7 节全字段及授权范围；采集器/看门狗失效即停止负载。正常完成必须清理本次创建的进程和连接，不删除 journal/账本/故障证据。

| 场景 | 可复现步骤 | 判定及必需原始证据 |
| --- | --- | --- |
| SM-00 运行准入 | 冻结清单，核对所有 hash/路径；先发送独立有界健康负载证明两方向观察有效，再试缺字段/版本不符输入 | 不合格输入在拨号前拒绝；健康对照可观察；记录实际调用路径、预算/watchdog 和退出清理回执 |
| SM-01 身份隔离 | 两 Profile 独立凭据映射同账户并发，再加入第二账户；试伪造账户 header/统计标签、错 realm、过期、吊销、切换身份 | 只按服务端映射计量；同账户合并额度，不同账户隔离；拒绝分支无新的未许可目标转发；旧已发请求不重放 |
| SM-02 连续双向 | 单上行、单下行、双向及空闲后续传；TLS 目标与已知非 TLS 对照；在连接仍开启时采集 node/center/origin 计数和时序 | durable 累计持续推进，不依赖断连；两方向逐流对齐同一口径、覆盖与误差阈值；记录 delay 分布但不据此宣称 PF04 UI 通过 |
| SM-03 额度截断 | 有限 Q，多连接/两 Profile 同账户，输入超过 Q；覆盖剩余额度小于 C、边界相等、短写、零进度、已知及未知部分失败 | 许可守恒，执行点 byte 超额不超 E_quota；截止后的在途/缓冲量不超 E_after_stop；尾块不重发，held 不凭连接关闭返还 |
| SM-04 持久化窗口 | 分别在第 5 节六个持久边界暂停并 kill/restart；磁盘满/提交失败/库损坏；在另获授权的可销毁环境做掉电等价故障 | 保存故障前后 node/center/独立端点与持久化证明；已确认累计不回退，未知量有上下界；重开不重复授权/重发；仅 kill 的结果不得填掉电覆盖 |
| SM-05 中心故障 | 已获 lease 后断开受控中心通路；boot/grant/report/ACK 各自丢响应；恢复后重复/乱序/同键异参/错误身份响应 | 原键重试、原 pending 保留；只用已有有效预算；超过 TTL/重试/U/容量上限停发；语义/认证/存储错误锁住后续发送；中心记录不重复累计 |
| SM-06 截止与恢复 | PREPARE 后推进到期限或学习新围栏；并发截止与写入入场；暂停/恢复及时钟偏差；有 held 时试周期切换 | 区分截止前已入场与截止后新 attempt；后者禁止，前者有界；重启不复活旧 lease；旧报告只结算原周期；保守阻塞明确记录 |
| SM-07 路径覆盖 | 对冻结调用图逐条触发普通/适用优化路径，服务端上下行分别采集；保留 Vision，并记录客户端适用路径 | 每条实际启用路径都有授权、实时计量和截断证据；无法触发记 NOT_RUN，无法控制记 BLOCKED；不能拿另一条路径的 PASS 补齐 |

每场景在运行前固定重复次数、数据规模与故障注入点，runner 记录开始/终止条件和全部重复结果，不能选择性丢弃失败。对负向零增量断言使用同配置的健康正向对照；超时、无页面响应或缺日志不能算截断成功。无故障排空后的同口径流量用于精确对账；中断样本保留已确认下界和未决上界，报告 `coverage=partial/uncertain`，不能把 unknown 计为 0。长连接持续计量/耗尽截止的最大延迟待冻结；20 分钟/1,000 次 UI 更新等 PF04 条件仍属于独立工作包。

结果词汇：设计审查只给 DESIGN_REVIEW；本地旧命令只给 LOCAL_FIXTURE；后续 SM 场景成功只给对应服务端子场景 PASS，并记录 A36/A37（账户/上报）、A84（故障/恢复）、A118 的具体覆盖。A118 包含真实 Linux、适用客户端/服务端路径和 PF04/PF09 依赖，在这些证据齐备前整行保持 NOT_RUN/未完成，不提升 G0–G3。

## 9. 进入实现前的未决项

1. 服务端/账本/实验负责人、真实资源与有限预算未绑定，状态 `BLOCKED_RESOURCE`。
2. 固定 Xray 代码、真实鉴权对象及下行目标 byte 完成语义未知；全部 writer/优化路径的接入可行性待取证，状态 `BLOCKED_ADAPTER`。
3. 生产计量版本、持久请求/上报协议、独占执行点、期限与耐久策略未定；U/误差/延迟/容量阈值待冻结。现有本地常量不可直接转成运营参数。
4. 自动回收、跨周期可用性与长期存储维护不在本候选完成范围；采用保守 held/停发策略会影响可用性，需明确后续方案。
5. RateLease/PF09、PF04 UI 采样和服务端实际实现分别立项。独立设计 review 不替代服务端负责人确认，不构成资源或真实流量授权。

交付本设计候选及精确 B/H 供独立审查，修复后由同一 reviewer 复核。只有后续资源、预算与代码落点可审查且实施范围得到明确安排，才进入实现阶段。
