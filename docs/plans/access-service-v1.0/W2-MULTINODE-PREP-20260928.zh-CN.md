# W2 双逻辑节点计量准备（设计候选）

核对日期：2026-09-28（Asia/Shanghai）；基线：个人 `develop@5689833c57a292e348c39ac512a223545b80fb1c`。本文供 W2 服务端接口评审和本地夹具实施使用，不冻结生产 API、租约数值或真实实验结论。冻结行为以[规范第 8 节](spec.zh-CN.md)、[技术方案第 3 节](architecture-review-20260922.zh-CN.md)及[W2 实验交接](W2-EXPERIMENT-HANDOFF.zh-CN.md)为准。

## 当前证据与缺口

`prototypes/access-metering/` 的 SQLite 账本与 loopback relay 已验证单账本、多连接共享额度：转发前持久 `PREPARE`、转发后 `COMPLETE`、每许可最多 16 KiB、全库最多 8 个未决许可；崩溃后的许可保留为 `held/uncertain`。现有测试覆盖连接未结束时的累计、双向耗尽、两个进程终止窗口和周期拒绝。该 relay 假定一个数据库 owner；`prepare` 不携带 node/lease/epoch，`complete` 不接受节点累计水位，`recover` 只处理单进程待结许可。它不能证明跨节点不超发、重复/乱序节点上报、节点换代、租约失联或跨节点速率。

本地只读资源登记中的 `TEST-PAGES-20260926` 是 VLESS + WS + TLS 候选，未显示 Vision `flow`、Linux/Xray 部署或权威字节计数点。该节点按用户要求保留为**相关开发完成后回测的 TODO**，此阶段不发测试流量；它不承担 W2 REALITY/Vision 计量验收。资源原图和脱敏记录保留在本机，不能进入公开仓库。

## 本地状态机合同（修订候选）

仅使用有限测试账户、两个逻辑 `nodeId`、各自独立的 SQLite journal、一个中心 SQLite 账本和注入的可控时钟。账户/Profile/node 名称只是 fixture 标签，不等于服务端鉴权。使用代理解封装后目标连接的双向整数 byte 作为**模拟**计量口径；现有单 relay 保持独立。`accountingVersion` 在本夹具固定为 `fixture-target-bytes-v1`，真实部署的版本和计数点仍待绑定。

### 1. 身份、重试与预留

`start_session(accountId, periodId, nodeId, bootRequestId)` 的幂等键是操作类型加**全库唯一**的 `bootRequestId`；`grant(accountId, periodId, nodeId, counterSessionId, epoch, grantRequestId, requestedBytes)` 同理使用全库唯一的 `grantRequestId`。键和全部参数的规范化摘要、返回结果、生成的 epoch/session 或 lease/部分授权 byte，以及中心状态变更，均在同一个 `BEGIN IMMEDIATE` 事务提交。先查已有键并核对摘要：同参数直接返回原结果，即使已到期、已换代、已切周期或存储达到上限，也不续 TTL、不恢复旧 epoch、不重复预留；同键异参数拒绝。**仅对新键**在同一事务中检查 `periodId == account.currentPeriod`，旧周期的新 boot/grant 均拒绝。`requestedBytes` 为正且不超过 fixture 上限；额度仅剩一部分时保存实际部分授权，余额为 0 时保存明确拒绝结果。客户端丢失响应后必须重试原键，新请求要使用新键。

中心对稳定主体 `(accountId, periodId, nodeId)` 持久保存最新 epoch。新 boot 键创建更高 epoch，并将该节点旧会话的未报告租约余额标为不确定；重试旧 boot 键只返回历史 epoch，不能改回当前值。授予新租约只接受当前 epoch/session。新 grant 的原子准入式为 `actual + held + granted ≤ quota`；不同节点请求在中心事务中串行，没有预设谁先得到完整额度。节点只有持久保存返回的 lease 后才能使用它。中心提交成功但响应或节点本地保存丢失，原 lease 仍占余额；重试原键可恢复同一结果。

### 2. 旧节点、截止与本地 journal

中心换代不能即时通知失联旧节点。旧节点若未获知围栏，在原租约截止前仍可能消耗**已经持久获准**的预算；中心继续保留该旧租约的 `held`，新会话只能申请账户余量。节点先验证围栏通知绑定的 `(accountId, periodId, nodeId)`，然后在该**相同作用域**内把 `maxSeenEpoch` 持久写入本地 journal，再拒绝旧 epoch 的新 PREPARE；若通知验证或落盘失败，停止该作用域的发送。它仍可报告旧租约已有的累计值供结算，不能用旧 epoch 再申请 grant。晚到的旧 grant 响应只包含原结果，不能降低相应作用域的 `maxSeenEpoch` 或清除已知围栏；p1/e3 的值不会拒绝 p2/e1 或另一账户的合法授权。需要立即停旧流的产品主张另需在线确认或数据面强制断连证据，本夹具不作该主张。

节点在每次模拟发送前，先确认本地租约尚未截止且没有**已知**围栏，把 chunk 的方向和 byte 作为 PREPARE 持久写入本地 journal；紧接模拟发送前再检查时钟、围栏和预算。第二次检查失败时不发送，已预留 chunk 留在 journal 作为不确定量，不能自行返还或重用。发送后的本地 `COMPLETE` 与节点双向累计值在同一事务提交；只有该持久累计值能上报中心。重启打开原 journal：旧 PREPARE 不重发，已完成未上报的累计可以重报；没有中心确认的新 epoch/lease 时不继续发送。中心暂不可用但节点未重启时，只能在本地有效、未过期且 journal 证明尚有余额的旧租约内继续。截止时刻及之后停止新增 PREPARE/发送；截止、失联或换代绝不自动释放中心旧预留。

### 3. 累计报告、边界与不确定量

每条报告绑定 `leaseId/accountId/periodId/nodeId/counterSessionId/epoch/accountingVersion`，再带 `sequence/cumulativeUplink/cumulativeDownlink`。中心**先验证全部身份绑定和旧租约存在性**，再比较序号；历史旧 lease 不因 `account.currentPeriod` 前移而丢失身份验证。每租约持久保存最后接受的序号、两向累计和最后记录摘要，存储为 O(1)：最新同序号同内容返回 ACK 和当前水位；最新同序号异内容拒绝；更旧序号一律返回 STALE 和当前水位，绝不增加用量，也不承诺检测其历史内容冲突。更高序号可跳号，但两向累计各自不得下降、合计不得超过该 lease 的授予额。节点把待发序号及其本地持久 `COMPLETE` 累计写入 journal，丢 ACK 后重报同一内容；ACK/STALE 中的水位不能补造本地消费、回退本地累计或释放本地 PREPARE。若中心水位高于节点持久累计，节点停止而不推断补账。

中心在同一事务中保存水位、`actual` 增量、`held` 减量、`uncertain` 减量和报告结果；事务失败全部不变。`actual` 仅是中心已接受的节点持久 `COMPLETE` 累计，并非 origin 收到的权威字节。有效 lease 尚未上报的预算是 `held`，其中被中心明确获知为无法完整证明的剩余部分是 `uncertain`。中心仅在处理**已知换代**或显式 `expire_leases(now)` 时，把该 lease 未报告的余额标成 `uncertain`；普通只读 snapshot 不推断节点已崩溃，也不改变状态。节点崩溃但中心尚未获知时，余额仍为 `held`、`uncertain` 可为 0；重启换代或到期标记后成为不确定。后续合法旧租约累计报告按增量同时降低 `held` 和对应 `uncertain`。始终满足 `0 ≤ uncertain ≤ held`、`actual + held ≤ quota`。未报告余额没有自动失效回收路径。

### 4. 周期与固定容量

`rollover(accountId, oldPeriodId, newPeriodId, quota)` 与 grant 用同一中心事务锁串行，先要求 `oldPeriodId == account.currentPeriod`；旧周期只要 `held > 0` 就拒绝。全部结算使 `held = 0` 后可切新周期；历史 `periodId` 永不复用。切换后，旧周期**新键**的 boot/grant 仍被当前周期检查拒绝，旧键同参数仅返回历史结果。绑定旧租约的最新完全相同报告仍可得到 ACK，较旧报告得到 STALE，同号异内容拒绝；更高序号统一拒绝 `CLOSED_PERIOD`，以上均不能更改新周期余额。用量和权益增加只能由中心显式操作，切节点不重置。

本夹具冻结上限：账户数 8、每账户周期数 8、会话 64、租约 64、boot/grant 键各 64、每节点 journal 记录 64、中心持久审计记录 256；所有外部 ID 的 UTF-8 长度最多 128 byte，单 chunk 最多 16 KiB，单 lease 最多 64 KiB，TTL 为正且在测试中固定。没有无界历史上报表；每租约仅保留最后水位/摘要。到任一上限时拒绝**新**会话、授权、PREPARE 或需新审计记录的状态变更，保留旧状态与已有请求键的只读幂等返回；不得为了腾位删除尚有效的键或未决租约。`MAX_*` 数值仅是可测试的 fixture 防护，不代表产品或 VPS 容量；持久审计满时不能把未完成结算冒充成功。

### 5. 崩溃与事务窗口的明确观察

下表每行从新的 `quota=4 B, lease=4 B` 数据库开始；先记录崩溃瞬间，再重开中心与节点数据库。中心尚未收到重启/到期通知时 `uncertain=0`；成功处理新 boot 后旧 lease 的未报告余额才转为 `uncertain=4`。`held` 在两个时点均不回涨或释放。

| 注入位置 | 崩溃瞬间中心 `actual/held/uncertain` | 重开节点 journal 与后续动作 |
| --- | --- | --- |
| 中心 grant 已提交、节点保存 lease 前 | `0/4/0` | 无本地 lease；原 boot 下用相同 grant 键重试得原 lease；若改新 boot，旧 4 B 变不确定，不能重发旧预算 |
| 本地 PREPARE 提交、模拟发送前 | `0/4/0` | 有未完成 PREPARE 4 B；不重发，受控 origin 收 0 B；新 boot 后中心 `0/4/4` |
| 模拟发送后、本地 COMPLETE 提交前 | `0/4/0` | journal 仍只有 PREPARE；origin 可能收 4 B，无法精确恢复；新 boot 后中心 `0/4/4` |
| 本地 COMPLETE 提交后、中心报告前 | `0/4/0` | journal 有已完成累计 4 B；新 boot 后先为 `0/4/4`，重报旧 lease 累计后为 `4/0/0` |
| 中心累计结算提交后、ACK 到节点前 | `4/0/0` | journal 有已完成累计和待确认报告；重发同序号同内容仅获 ACK，中心仍 `4/0/0` |

中心 grant/session/报告事务任一中途失败，在重开数据库后必须呈现全旧状态或全新状态；若失败发生在提交前，键、水位、审计与余额均无部分写入。节点 PREPARE/COMPLETE 事务失败也不能产生半条 journal 或半个累计；若发送已发生而 COMPLETE 失败，按上表第三行保留不确定量。普通只读 snapshot 不触发恢复或修改 `uncertain`。

## 最小实施与验证边界

第一单元实现中心授权与有界幂等；第二单元实现节点 journal、可控时钟和围栏；第三单元实现累计上报、崩溃/重启与周期。建议分别放入 `prototypes/access-metering/lease_ledger.py`、`lease_node.py` 和 `test_lease_metering.py`，不改现有 relay 的计量语义。每项先用临时 SQLite 文件写失败单元测试，再实现；同一代码提交还需旧 relay 的额度/崩溃回归。初始测试独立新建数据库；串联测试明确继承前一步状态。两个并发 7 B 授权共享 10 B 账户时，只断言总授权 ≤10 B 和所有余额守恒，不硬编码哪个节点先拿 7 B。

必须覆盖：boot/grant 响应丢失、并发同键重试、中心重启、部分授权旧键在到期/换代后的重试与异参数；离线旧节点与新 epoch 并存、重连、发送前到期和晚到旧响应；p1/e3 到 p2/e1 的合法切换、迟到 p1 通知不影响 p2、同作用域低 epoch 不覆盖高值、围栏落盘失败停止发送；上表**五个**崩溃窗口全部重开数据库核对中心与节点状态，以及事务中途失败；错误 session 的旧序号、方向回退、乱序 STALE、越额；所有固定条数/长度上限到达并重启后仍 fail closed；`held > 0` 拒 rollover、全部结算后允许、旧报告不影响新周期，以及 rollover 与 grant 并发。另用独立数据库测试 p1 额度 10 B、唯一 4 B lease 已全结算后切 p2：p1 的新 boot/grant 拒绝，原键重试只返回旧结果；grant 先于 rollover 提交则新增 held 阻止切换，rollover 先提交则 p1 的新 grant 拒绝。每例记录输入、预期拒绝码和 `actual/held/uncertain/remaining`。这些仅是本地状态机证据，不把 A36/A37/A118、PF04/PF09 或 G0–G3 写成真实 PASS。

本单元暂不实现 RateLease、物理速率/突发、公平性、多 VPS、自动回收、网络/掉电等价、真实鉴权、Xray 数据面截断或 UI 推送。它们需要实际服务端适配、受控资源与冻结预算；PF09 不能从字节额度守恒推断。

原草案曾写“实现前由服务端/账本负责人审查”，这是草案自行提出的生产接口建议；现有本地夹具不接服务端、没有可绑定的服务端 owner，冻结规范及 DEV CI 指南也未把未指名的人类审批设为本地实验准入。用户本轮要求从最新 develop 继续本地迭代；因此本地实现按设计明确、同一独立 reviewer 复审和最终 HEAD 测试/交付门推进，不把模型 review 冒充服务端 owner 批准。未来接真实中心/节点、选定生产字段与耐久策略前，仍需绑定具体服务端负责人、受控资源和相应审批；缺少这些只阻止真实服务验收，不阻止此处纯本地 fixture。

## 真实实验仍缺的绑定

仍需获授权的受控 Linux 服务端与执行人、独立 origin、测试账户/Profile 到 `nodeId → deployment → capacityGroup → trafficPool/failureDomain` 的映射；固定 Xray commit、二进制/配置 SHA-256、OS/kernel、REALITY/Vision `flow`、实际 splice/逐块路径及代理解封装后目标连接的权威双向计数点；中心账本和节点 journal 的耐久边界；预先冻结的账户与物理池额度、速率、误差、未结算上限、总流量、并发和时长。未绑定前，真实 W2 继续 `BLOCKED_RESOURCE` / `NOT_RUN`。
