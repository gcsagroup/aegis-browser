# W2 计量实验交接

资源核对日期：2026-09-26。开发起点为 `origin/develop@0dd641b3fe776899effe5f56388a8b7490f561e7`。W2 是 Vision 计量可行性实验，不能由浏览器质量门或纯本地模型判为通过。冻结合同见 [规范第 8 节](spec.zh-CN.md)、[技术方案第 3 节](architecture-review-20260922.zh-CN.md)和[开发计划 W2](development-plan.zh-CN.md)。

## 资源登记与执行边界

| 输入 | 当前核对结果 | 对真实 W2 的影响 |
| --- | --- | --- |
| R1–R3 既有候选资源 | [资源登记](test-resources-and-workflow.zh-CN.md)只记录历史登录/公开 UI 与本地存储；账号、部署、协议、容量关系未验证。此次独立工作树没有 `.local/access-service/`。 | 不能由管理页推断 REALITY/Vision 节点、真实额度或授权流量池。 |
| 受控 Linux 服务端、执行人、Xray 二进制/commit、配置、内核、计数 hook | 尚未绑定。当前主机没有可执行的 `xray`；Docker/Colima daemon 未连接。 | 真实长连接、splice、崩溃/掉电、PF04/PF09 均待运行。 |
| 代理与 origin 受控端点 | 本地实验仅使用 `127.0.0.1` 临时端口，由测试进程创建；不读取账号、订阅或外部 URL。 | 只能验证预算状态机及 loopback 转发行为。 |
| 流量预算 | 本地 fixture 使用测试指定的整数 byte 限额，无外部流量。真实资源的账户、测试租户、物理池字节/速率预算、并发及时长未绑定。 | 不运行付费端点或无界测速。 |

## 真实实验的前置记录

先在未跟踪的证据目录记录以下身份，再执行每个场景；配置只保存脱敏摘要和秘密引用。

1. `nodeId`、部署归属、`capacityGroup`、`trafficPool`、`failureDomain`、测试账户与 Profile 映射、授权执行人，以及独立受控 origin。
2. Xray commit、二进制 SHA-256、服务端发行版与 kernel、入站/出站/flow、配置 SHA-256、Vision/splice 实际执行路径及计数 hook。客户端产物、网络与实验时间窗口另记。
3. `accountingVersion` 的双向目标连接 byte 边界、中心账本与节点 journal/checkpoint 的耐久策略。明确预留、已确认转发与崩溃不确定 byte 的不同字段。
4. 在测量前冻结有限账户额度、租约上限、传输块/缓冲上限、计量延迟上限、允许的最大超额与实际计数对账误差；不知道的限值标 `BLOCKED`，不测后调整。
5. 限定总流量、并发、时长及自动停止条件。对上传、下载、双向长连接在未断开时采样；额度耗尽检查执行点截断；分别注入 kill/restart、账本失联、周期切换，并对适用快路径与逐块路径取同口径原始数据。

每项保留原始服务端计数、origin 收/发 byte、租约/journal、进程退出与恢复日志、命令退出码、时间戳和覆盖率。中心预留可阻止重复授权，但不是实际消费量；若崩溃窗口无法精确恢复，应报告上下界和未结算状态，不能将其记成 0 或已消费。重复/乱序上报、旧周期覆盖、跨 Profile 共用账户仍需单独回归。

| 场景 | 本地 fixture 可检验 | 真实 W2 仍需证据 |
| --- | --- | --- |
| 长连接上传/下载 | 连接未结束时用量变化；独立 loopback origin 的收发计数 | 适用 Xray Vision/splice 路径与权威解封装计数点、秒级延迟及 PF04 全样本 |
| 有限额度截断 | 同账户多连接的持久预留上限与 fixture 转发前的 byte 许可 | 真实数据面截断、各缓冲中的超额上限、速率/物理容量及 PF09 |
| 崩溃/重启 | 已确认用量不倒退，未确认许可不自动重发 | Linux 节点/中心账本故障、掉电等价故障、旧租约结算或可验证失效回收 |
| 周期与上报 | 旧周期/重复/乱序的账本单元回归（若 fixture 实现） | 跨节点/账户/Profile/设备的真实结算与身份鉴权 |

## 当前结论

本地实验入口为 [`prototypes/access-metering/README.md`](../../../prototypes/access-metering/README.md)，可用 `pnpm run test:access-metering` 执行；它接入 `quality:fast`。SQLite 账本记录 `actual_bytes`、`held_bytes`、`uncertain_bytes`，loopback relay 在转发前取得有限许可；测试包含连接未关闭时的用量、独立 origin 字节、双向共享额度截断和两个 kill/restart 窗口。fixture 没有未确认 byte 的自动结算机制，旧许可会继续占用额度。

本地 fixture 通过时只给 `LOCAL_FIXTURE_PASS`，精确结果绑定对应提交与测试报告。真实 W2 的 A118、PF04/PF09、适用 Vision/splice 快路径、权威字节对账、生产额度执行和恢复仍为 `BLOCKED_RESOURCE` / `NOT_RUN`；G0–G3 不因本记录改变。
