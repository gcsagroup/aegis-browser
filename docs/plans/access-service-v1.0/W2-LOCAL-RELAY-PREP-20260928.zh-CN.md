# W2 两进程 loopback 租约数据路径：设计与测试输入

日期：2026-09-28；基线：个人 `develop@b00ae459e3563d075a2ce7f1477e4e39eb3d9551`。本增量仅让已交付的中心 `LeaseLedger` 和节点 `NodeJournal` 驱动可执行本机 TCP 转发。它是 `LOCAL_FIXTURE`，不接账号、Xray、Vision、真实多 VPS 或图示 WS+TLS 候选。冻结行为仍见[规范第 8 节](spec.zh-CN.md)、[W2 实验交接](W2-EXPERIMENT-HANDOFF.zh-CN.md)及[双逻辑节点设计](W2-MULTINODE-PREP-20260928.zh-CN.md)。旧 61 项测试和原 `relay.py` 语义保留。

## 最小拓扑与所有权

- 测试进程显式创建一个临时中心 SQLite 库、两个分别属于 `A/B` 的节点 journal，启动两个独立 relay 子进程和两个独立 loopback origin 子进程；所有端点只绑定 `127.0.0.1`，路径只在测试临时目录。两个 origin 将收/发累计原子写入各自测试计数文件，供连接尚未关闭时观察。两个 relay 用同一个中心库的 `BEGIN IMMEDIATE` 串行授权，各自只打开自己的 journal。该共享文件只是本机中心服务的替身，不证明网络中心可用性、鉴权或独立 VPS。
- 每次 relay 进程启动先重开既有 journal；用 journal 中有限的 lease ID 重发持久 `COMPLETE` 累计及待确认报告，再用新的 boot 请求键取得中心新 session，持久激活对应 epoch，再以新 grant 键取得**一个**有限 lease 并持久记住。旧 boot/grant 键重试仍由原有中心 API 保证。中心暂不可达或额度为 0 时不能凭本地旧 session 重新开放转发。运行中若中心故障，只能消耗该进程已持久记住、仍有效且未被围栏的 lease；报告留在 journal 待重试。
- 两方向共享同一 lease。每个 relay 同时只处理一个客户端连接，两个 relay 进程可并发；单次转发块 ≤16 KiB。新进程不开旧会话，也不重发旧 `PREPARED/SENDING`。保留旧库与未决预算；不通过进程重启、断连或到期自动释放。

## 发送、短写和锁边界

1. 从客户端或 origin 读取最多一个块后，节点 `prepare(lease,direction,len(data))` 在 journal 中持久写入完整预留，然后才允许写目的 socket。无 lease、到期、已知围栏、容量耗尽或超预算，关闭该连接且不转发已读块。
2. 保留原 `send()` 的同步模拟 sink 语义供旧单测。另加仅用于该夹具的 `send_socket_once(chunk_id, nonblocking_socket, data)`：在短事务内把块从 `PREPARED` 改为 `SENDING` 并提交；随后在同一节点进程锁及第二个短 `BEGIN IMMEDIATE` 内重新校验 lease、时钟和持久围栏，调用**恰好一次**非阻塞 `socket.send`，立即结束事务。该锁覆盖一个有界系统调用，不覆盖 `select`、`connect`、`recv`、等待可写、`sendall`、回调或任何 `await`。其他 journal 句柄的围栏事务不能在复核与该次 syscall 之间提交；同进程采用相同锁。一次调用可能返回 `0..size` 或 `BlockingIOError`，绝不重试该 chunk。
3. 返回 `n>0` 时，仅以本进程内 `chunk_id→n` 发送证明执行 `complete()`：在同一事务将块置 `COMPLETE` 并把对应方向累计加 `n`。`size` 始终是完整预留，即使 `n<size`；未发的 `size-n` 不重新进入可用 lease 预算。短写后关闭两个 socket，防止发送同一块剩余部分或下一块。`n=0`、异常、崩溃或 COMPLETE 落盘失败时，仍保留全块预留；存活进程仅可用原发送证明重试 COMPLETE，不得重发网络字节。重开进程没有该证明，旧块不可补写。
4. 完成后，节点先持久生成累计双向报告；中心 `report()` 返回 ACK/STALE，节点再持久 ACK。中心不可达时继续保存同一 pending 记录，不能凭失败响应推高累计。恢复时先重发旧记录，再生成后续累计；中心 `actual/held/uncertain` 只由已接受报告和已知换代/显式到期改变。`socket.send` 成功仅证明本地 OS 接受了 `n` 字节；origin 收到量和客户端收到量独立观测，断连/崩溃窗口允许差异，不能用全 lease 预留冒充实际消费。

## 有界终止与故障注入

每个子进程及 socket 都有就绪、连接、空闲、marker 和回收超时；`finally` 关闭客户端、origin、监听器并等待子进程退出。数据面/节点 journal 错误、短写、超时、期限/围栏拒绝或额度耗尽关闭受影响连接，不转 DIRECT、不回退到旧 lease。**只有**测试失联 marker 在中心调用前抛出的专属 `CenterTemporarilyUnavailable` 属可继续的控制面错误：已有有效 lease 的进程保留原 pending 水位、不补造 ACK，继续处理下一个有界块；真实 `LeaseError`、身份/水位冲突、数据库损坏与节点 ACK 错误均锁住该 relay 的后续发送并关闭连接，不能按异常文字猜测为暂时失联。启动旧报告冲洗或新 boot/grant 时即使是该专属失联，也不开监听器。

中心恢复后，在**下一块 PREPARE 之前**先重报 pending，再生成后续累计；若连接空闲，按至少 100 ms 的间隔尝试。每进程最多 32 次实际重报：本进程新生成的每条 pending 首次上报不计，之后同一条 pending 的每次再报都计入（包括成功的再报）；重启时重放旧 journal 的 pending 也计入。计数在成功后不清零，达到上限就停止新发送；若该次仍失败则保留 pending 与 held。连接空闲截止和进程终止也会停止轮询。重试不持有 journal 事务、发送锁或 socket I/O 等待。一个 lease 同时最多有一条 pending；重报失败仍保留原记录。测试专用 marker 只在事务外暂停四处：`PREPARE` 提交后、单次 send 返回后、`COMPLETE` 提交后而中心报告前、中心报告已提交后而节点 ACK 前；各 marker 都在对应提交后、下一动作前，已释放 SQLite 事务和发送锁。测试可在 marker 时 kill/restart，或原子改写临时整数时钟文件/写入新围栏再释放。测试专用中心失联开关只拒绝中心调用，属于故障注入，不模拟真实网络分区。所有 marker 路径由测试创建、等待有上限；不读取订阅或外部 URL。

## 先写的测试输入和期望

| 输入（每例新临时库） | 必需观察 |
| --- | --- |
| `quota=10`，先 A 请求 `7`、再 B 请求 `7`（实得 `7+3`），两个 origin 独立且禁用 echo；A 上行 4、B 上行 3 | 中心总 grant=10；origin A/B 分别收到 4/3，正常报告后 `actual=7, held=3, remaining=0`（A 未用的 3 仍 held）；两节点 journal 累计与中心一致，第三节点不能借未用预留。另做 A/B 并发启动变体，只断言总 grant≤10，不固定谁先取得 7。 |
| `quota=16, lease=16`，独立 echo origin，上行 4 并收回下行 4，连接仍打开时观察累计 | journal 的 `up=4,down=4`；中心确认后 `actual=8,held=8`；origin 收/发各 4，客户端收到 4。连接关闭前可观察到水位，不能等断连才计量。 |
| `quota=8, lease=8, PREPARE=4`，测试将单次非阻塞写切片限制为 `2` | origin 最多收 2；节点完整预留 4、只累计/报告 2；中心 `actual=2, held=6, remaining=0`，后续该块剩余 2 不重发、不重新授权；客户端连接关闭。 |
| PREPARE 后将时钟推进到 `expires_at`，或持久学习同作用域更高 epoch，再释放暂停点 | 目的 socket 收 0；原块仍 held；到期或已知换代后不能开启新块。旧周期的围栏不误伤另一周期。 |
| PREPARE 后 kill relay；另例单次 send 返回并由 origin 确认收到后、COMPLETE 前 kill | 重开原 journal 不重发旧块；中心在获知新 boot 前 `actual=0,held=lease,uncertain=0`，新 boot 后旧未报告余额成为 uncertain；第二例 origin 可大于中心 actual，保留不确定量。 |
| COMPLETE 后、中心报告前 kill；另例中心报告后、节点 ACK 前 kill | 重开重报旧 lease 的持久累计；中心最终只计一次，`actual` 不倒退、`held` 不回涨；origin 不再接收重复块。 |
| 已获 lease 后启用中心失联，再传剩余合法块；重启时仍失联，随后恢复 | 在本地 lease/期限/围栏内可继续，报告 pending；无新授权或旧 session 复活。中心恢复后重报一次；超出已获预算的输入关闭，余额守恒。 |
| 与上一项相同数据，但中心返回报告身份/水位冲突（非专属失联异常） | 锁住 relay 的后续发送并关闭连接；下次连接不再发 origin byte，pending 保留供诊断。不能把该错误归为可重试失联。 |

断言除 `actual/held/uncertain/remaining` 外，还记录两个 origin 的收/发 byte、节点 `up/down/reserved`、chunk 状态、进程退出码和时间/阶段。模拟短写通过测试专用单次发送上限实现；正常路径仍调用真实非阻塞 socket syscall。若原设计无法在不持有网络等待锁的条件下实现上述复核和保守预留，先返回设计评审，不静默改成 `sock_sendall`。本批不做 RateLease、PF04/PF09 采样器或真实服务验收；截图 WS+TLS 回测仍为开发完成后的 TODO。
