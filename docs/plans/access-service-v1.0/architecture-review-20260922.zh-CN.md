# Aegis 访问服务 V1.0：架构复核与实施技术方案

日期：2026-09-22。本次续接基线：`quinn521/aegis-browser:develop@c08b6321fe2878ba62c8d9757a3f4ae4e4f17470`，即 [#164](https://github.com/quinn521/aegis-browser/pull/164) 的合并提交。保留 #164 的架构决策，补齐并行实施合同与当前候选边界；拟新增能力仍需实现和运行验证。状态快照：2026-09-22 06:15 UTC，后续结果以对应候选的报告为准。

本文调整实施技术方案、风险验证顺序和首阶段部署规模，不修改[冻结修订 4](spec.zh-CN.md)的用户行为、A01–A118、PF01–PF13 或 G0–G3。`freeze.json` 及其保护文件保持原字节；本文不能成为降级冻结要求的豁免。若原型证明原合同不可实现，提交失败证据、明确行为差异和规范修订，再评审冻结；不能仅修改清单哈希或检查脚本放行。执行顺序见[开发计划](development-plan.zh-CN.md)，下一窗口见[Handoff](handoff-20260920.zh-CN.md)。

## 1. 复核结论与已有边界

保留 Chromium 原生集成、C++ 纯匹配热路径、Profile/StoragePartition 所有权、独立 Xray、REALITY/Vision 主出站、独立控制面和服务端权威计量。修正重点是请求级执行粒度、连接复用身份、计量执行点及先运行后扩展的顺序，不以增加协议替代接入验证。

| 事实 / 风险 | 复核结论 | 本轮决策 |
| --- | --- | --- |
| `AccessServiceCoordinator` 已有普通 DIRECT/PROXY 的 PREPARED、候选发布、精确 ACK、durable commit、回滚和幂等重试 | 不能继续写成“只有生命周期空壳”；也不代表可信 UI、身份/节点生产提交或完整 BLOCK/ALLOW 已接通 | 复用已有事务边界，补真实入口与恢复验证 |
| `AccessNetworkContextTransport::PartitionState` 只有一个 endpoint 和 exact-host 列表 | 规则可按顶层 SchemefulSite、目标 host、scheme/port、代理组区分，执行层无法完整表达并存路由 | 请求级路由能力是扩展规则和入口前的关键依赖 |
| PR #162 在 `682997a6974fe76966e82276d7611ba59da30c42` 拒绝相交 host 的异组候选，仍为 OPEN/Draft | 已更新到 #164 基线并将功能补丁重编号为 0161；这是保护性拒绝，未合入，也不提供完整按站点/代理组选路 | 先完成该候选的原生双目标和浏览器回归；保留保护直到新传输用真实正反路径证明可替代；不同 host/不同组仍需独立正路径 |
| runner #161 已合入 `f598ccd8792ec0fc30031a74595fe48a2d54db96`；GN 修复 #163 已合入 `dd53b6ec4827b2f8ce730a428a81278aefd05bc5`，两者合并后 CI 成功 | 旧候选原参数通过 GN，Ninja 曾遇 bundled LLD/macOS 27 SDK 兼容失败；当前切到 #162 的 H，单独记录 `use_lld=false` 参数，完整 GN 检查 exit 0，Coordinator 编译中，尚无测试执行结果 | 原参数和本机参数变体分别记录；两项代码交付、GN 成功和后台编译均不能标记 Phase 3/W0 完成 |
| Xray 用户统计存在，但持久账本和传输预算不是 Stats API 的同义词 | 某些 splice 路径统计延迟，适用性取决于固定版本、真实入站/出站和操作系统 | 将计量/截断/崩溃恢复提前为独立 P0 验证，与浏览器底座并行 |

源码依据：[传输状态](https://github.com/quinn521/aegis-browser/blob/c4ffb50a0d8efc684aa1ba0022daf5113def19a6/apps/browser/overlay/chrome/browser/aegis/access/access_network_context_transport.h)、[请求派发](https://github.com/quinn521/aegis-browser/blob/c4ffb50a0d8efc684aa1ba0022daf5113def19a6/apps/browser/overlay/chrome/browser/aegis/access/access_proxying_url_loader_factory.cc)、[协调器](https://github.com/quinn521/aegis-browser/blob/c4ffb50a0d8efc684aa1ba0022daf5113def19a6/apps/browser/overlay/chrome/browser/aegis/access/access_service_coordinator.cc)。这些是架构复核时的源码依据；当前 PR 身份与运行记录见 [Handoff](handoff-20260920.zh-CN.md)。本次回读了 #164 合并后 CI、#162 当前 PR 及 native JSON/日志；没有另起 Chromium 构建。旧 #162 的 `a7de699…`、旧 0160 编号和 #163 的 `988c509…` 构建属于历史候选，不能恢复为当前执行入口。

## 2. 请求级路由决策

### 2.1 主方案及替代方案

选择“浏览器可信请求归属 + NetworkContext 内只读快照/端点注册表 + 请求级路由结果传递”作为实施方向。扩展固定 Chromium 所需的最小原生接线，使具体请求的决策到达实际代理解析及连接选择，而不是在每次请求前切换 partition 的全局 CustomProxyConfig。

| 方案 | 判断 |
| --- | --- |
| partition 单 endpoint + host allowlist | 保留为已有受限实现/迁移保护；无法承载最终并存规则 |
| 只用 PAC、URL 或 NAK 推断 | 不选作授权方案。NAK 不是 browser-owned pageToken/document 身份，不能表达完整可信归属和操作版本 |
| 按规则新建 StoragePartition/NetworkContext | 不选作默认方案：会影响 cookie、缓存、Service Worker 与网页存储边界；不能用改变网页隔离语义来补路由缺口 |
| 可信请求上下文贯穿网络栈 | 选定方向；精确载体、原生接线、池键和成本必须由 W1 固定版本原型证明，当前仍为待实现设计 |

固定版本 `ProxyDelegate::OnResolveProxy` 只有 URL、NAK、method、retry map 和 ProxyInfo，同步返回，不能凭空获得完整 request identity，也不能等待 IPC/数据库/启动内核。必须先在 W1 交付接口清单，逐点证明 browser-owned metadata 如何经可信创建/派发入口进入 Network Service，再到实际代理解析/连接创建；若需要扩展内部 request/stream 参数，应列出准确文件、签名、序列和测试。本文不把假设的 `SetProxyForRequest` 一类 API 当成已有能力。[固定版本接口](https://raw.githubusercontent.com/chromium/chromium/ff37cfca210138f2a40b843b4a8195ab7e4fc7ff/net/base/proxy_delegate.h)

### 2.2 数据与信任边界

以下为拟新增内部合同，名称非已存在 API；复用现有 `OwnershipKey`、`GenerationTuple`、matcher 和注册端点类型，避免另造第二套可漂移状态。

| 内部对象 | 必需字段 / 约束 |
| --- | --- |
| 可信请求上下文 | channel、Profile/partition owner、browser-owned request/document 或 pending navigation 标识、顶层 SchemefulSite、规范化目标 host/scheme/有效 port；redirect 按实际新目标重新构造；不读取网页任意 header、活动标签页或 renderer 自报 Profile 作为权威 |
| 不可变路由决策 | preserve-native / proxy / reject / wait-fail、matched rule、完整五项 generation、proxy group、不可伪造的 endpoint registration 与路由隔离身份；受约束但身份缺失/过期时失败关闭 |
| 端点注册表 | owner + proxy group + selection generation + identity generation + network epoch 绑定的多个已验证 endpoint；凭据属于原生私有状态，网页/UI 不提供任意代理地址 |
| 路由复用身份 | 绑定 owner、代理组、身份、实际 endpoint/注册世代和与连接兼容的策略状态；变更可影响路线时必须使旧解析/连接不可被新请求复用，不能假定版本字段会自动进入 Chromium 池键 |

路由热路径只读取本地快照。异步身份、节点准备和有界等待发生在可暂停的可信派发入口。浏览器 UI 线程与网络热路径都不得同步等待 SQLite I/O；持久化交给有序后台执行单元，以明确回调与版本校验回到协调器，这一实现边界仍需核验。

Network Service 只保留可信上下文校验、匹配/执行和确认所需机制；账户登录、调度、账本及 UI 状态不下沉，`net`/`services/network` 不反向依赖 `chrome/browser`。[Chromium 分层原则](https://chromium.googlesource.com/chromium/src/+/main/services/network/README.md)

### 2.3 连接复用、取消与故障

同一 partition 内，网站 A 对 CDN 使用组 X、网站 B 对同一 CDN 使用组 Y，必须并发到达两个受控出口；不同目标 host 使用不同组也必须可并存。scheme/port 差异、DIRECT/PROXY/REJECT 混合、重定向均按最终 matcher 决策执行。普通网站开关继续按冻结合同生成同域协议组，不把调试精确目标权限暴露给普通 UI。

W1 必须核对 HTTP/1 连接池、HTTP/2 session/coalescing、CONNECT tunnel、proxy auth cache、proxy retry/bad-proxy cache 和预连接的复用边界。若原生键不包含所需身份，就补显式隔离或有针对性的失效机制；仅附加 metadata、换密码或重复 ACK 都不证明隔离。独立 loopback listener 可作为候选方案，但必须验证端口回收后的旧连接、凭据和缓存隔离以及资源上限，不能靠每规则常驻进程逃避问题。

QUIC/Alt-Svc/UDP 旁路按冻结协议覆盖明确阻止或受控降级到已验证路径；不得改变无关原生流量。BLOCK 仍在加载/派发与按流取消边界执行，覆盖缓存/Service Worker/BFCache/prerender 等适用入口；代理选择 hook 不能替代 REJECT 或防护例外检查。

首次 GET/POST/PATCH 必须使用正确路线，失败不拼入 DIRECT/原有代理备用，已发送业务不自动重放。DIRECT 恢复当前原生配置而非旧备份；管理限制仍优先。没有 Aegis 规则的正常原生流量不因新增代理功能被全面阻断；已提交 PROXY 或恢复中受约束作用域的未知状态不能当成无规则。

Network Service 重启必须使旧 registration、ACK 和 request capability 失效；新 context 先完成可信 owner、当前快照/端点注册及精确 ACK，再开放受约束新请求。Chromium 会重建断开的 factory，但这不等于 Aegis 自定义策略自动恢复。[重启机制](https://chromium.googlesource.com/chromium/src/+/main/services/network/README.md)

W1 还必须完成 P0/A78 的最小 HTTP/SOCKS5 Profile 认证与隔离原型，再进入 G0 判断。当前 adapter 仅支持 HTTP；Chromium 官方说明原生 SOCKSv5 不提供认证，因此本项目的 SOCKS5 需要在固定版本做浏览器认证适配，不能只配置 Xray 用户密码。正确凭据成功、错误/跨 Profile 凭据拒绝、仅 loopback、未登记代理不获凭据及 Profile 关闭后认证失效均须实际运行；失败时阻止 G0/G1。W5 才扩展完整两入站×两出站及临时上下文矩阵。[Chromium SOCKS5 边界](https://chromium.googlesource.com/chromium/src/+/HEAD/net/docs/proxy.md)

### 2.4 事务与迁移

继续使用 PREPARED journal → 完整候选发布 → 执行点精确 ACK → durable commit → finalize。区分 durable intent、候选 runtime、UI pending/committed；ACK 只证明接收和对应执行状态，不证明真实流量走对出口。

候选可能在 durable commit 前影响请求；网络副作用不可回滚。因此测试必须覆盖“候选已有请求、随后数据库提交失败/进程崩溃”：仅在精确身份仍匹配时回滚运行状态、恢复已提交意图，保留诊断，不声称已发送字节被撤销，不重放业务、不撤掉后续 BLOCK。重启前后不允许未初始化状态形成 DIRECT 窗口。版本变化/新 context/旧 ACK/撤销仍使旧提交失效。

迁移不改写已有规则为 host 全局规则，不丢失 top-level-site 或 scheme/port。先对同一规则集并行计算旧/新决策用于脱敏差异观察，只有一条实际执行路径；满足 W1 正反测试后逐入口启用新执行器。失败回退是可审查的实现回退并保留持久意图，不把新模型无法表达的 PROXY 降为 DIRECT。旧保护的删除与新能力证明在同一单元审查。

## 3. Vision、计量与额度的提前验证

保留固定 Xray + VLESS/RAW/REALITY/Vision。WS+TLS 仍仅为授权兼容类别，XHTTP 不进入本轮必需实现。不能为了通过计量测试悄悄去掉 Vision 或以另一协议结果替代它。

Xray Statistics 提供用户上下行累计量，但统计采集不是持久账本或逐块预算执行。[官方统计](https://xtls.github.io/en/config/stats.html)指出统计需启用对应用户配置；应使用服务端鉴权后的稳定主体映射，不把客户端可改字段作为账户。官方记录某些 Linux splice 路径会延迟统计至断开；这只构成风险证据，不能推断所有 REALITY 服务端拓扑都有相同问题。[Vision/splice](https://xtls.github.io/en/config/outbounds/vless.html)

W2 在实际 Linux 服务端适用路径及客户端适用快路径绑定 Xray commit/二进制哈希、OS/kernel、入站/出站/flow、配置哈希、计量位置和长连接负载；不把 macOS 客户端行为外推到 Linux 执行点。主张“未使用 splice”必须有固定代码/构建/运行证据，不臆造禁用参数。

| 实验 | 必需观察与决策 |
| --- | --- |
| 持续上传/下载和双向长连接 | 连接未关闭时持续产生可恢复权威计量；按冻结解封装目标字节口径对账，与外层网卡计数分开。实测记录延迟/误差；PF04 的完整样本仍按规范执行 |
| 小额度、多连接、同账户多 Profile | 预算在已鉴权数据面、实际字节转发前保留/扣减，耗尽停止，不等 UI/Stats 轮询。记录传输块、并发和系统缓冲导致的最大超额，限值须预先绑定部署合同，不能测后改线 |
| kill -9/掉电等价故障、重启、账本暂不可达 | durable 预算预留不重复发放，计量会话与单调序号抗重复/乱序；恢复后已结算与未结算预留不导致余额回涨。账户报告保留不可精确恢复的部分及 coverage，不以丢失量为零宣称对账通过 |
| 到期/吊销/周期切换/节点切换 fixture | 停止旧授权路径，旧租约完成可验证结算/失效前不再发放；旧周期/身份数据不覆盖新状态；两个逻辑节点 fixture 不等于真实多节点验收 |
| 快路径与可计量路径对照 | 优先选择能证明计量和预算执行的固定路径；若须内核适配，单独评审计数/截断 hook 和性能成本；无可靠实现则 W2 BLOCKED，不能仅用 Stats API 补表 |

账本以中心账户余额预留、节点有界字节租约、幂等累计结算构成闭环。耐久性必须同时解决“授权不超发”和“实际用量可恢复”：预留上限只能防止重发，不能冒充已经消费的精确字节。明确节点本地持久 journal/checkpoint 与中心结算策略；若存在未持久化字节窗口，列出故障上限和恢复方法，在冻结计量合同下验证，不承诺凭内存计数实现零丢账。

## 4. 首阶段控制面与资源规模

首个工程验证使用单执行节点、集中账本、有限测试账户、受控代理与 origin。部署仍需固定签名配置、每 Profile 独立短期凭据、过期/撤销、额度和物理资源上限；简单规模不是共享 UUID、关验签或不计量的理由。服务端仓库、负责人、合法受控环境及配置/密钥引用是 W2 输入，缺失时明确 BLOCKED，不编造地址或申请生产凭据。

首阶段允许测试账户预置，用于验证身份和 route 接口；安装访客自动登记、用户账户绑定、完整保持/切换、三策略调试与公平限制在 W4 补齐才可判 G1。单节点可以验证故障拒绝，但不能证明真实备用切换；G1 的切换必须用两个可控执行实例及真实日志完成，即使它们共享同一测试宿主，也不得声称独立故障域或双倍容量。

多节点余额/速率租约接口先保留，算法用多节点 fixture 验证；真实第二节点启用前必须通过跨节点计量、额度与速率联调。健康绑定不逐请求轮换，单容量组先退化为组内稳定顺序；不提前引入复杂跨区域运营。

每活跃 Profile 按需使用一个稳定 Xray，组到入口/outbound 的映射在同一进程内设计；若固定内核无法表达多组并存，W1/W3 记录阻塞而非偷偷每组启动常驻进程。全浏览器额外候选/排空最多 2，回收、闲置 CPU、1/3/5 Profile 和 50 次生命周期压力按 PF07/PF08 测试，总 RSS 在 Alpha 前绑定。共享进程仅作为未来独立设计，不先承担跨 Profile 凭据/生命周期耦合。

## 5. 验收映射与停止条件

下列是拟执行的工程实验，不是新的冻结 A/PF 编号，也不是既有测试已通过。逐项实现、测试名、执行与结果仍写入[验收追踪表](acceptance-tracker.zh-CN.md)，一个子实验不能使整个 A/PF 行 PASS。

| 工作包 | 最小证据 | 冻结关联 |
| --- | --- | --- |
| W0 固定 native 底座 | 同一候选下必要 unit/browser targets 实际编译运行；候选、工具、过滤器、匹配数、退出码与首个失败可追溯；已有必需入口矩阵不缩减 | P0，G0 部分证据 |
| W1 请求级路由 | 两顶层网站共用 CDN 的 X/Y、DIRECT/PROXY/REJECT；不同 host 异组；scheme/port/redirect；两个 Profile；旧连接/身份/配置与重启；首次 POST/PATCH 不重复不旁路；HTTP/SOCKS5 最小认证/隔离原型 | A10/A11/A15/A16/A53/A76/A78/A108/A113/A115，PF01–PF03；各行仅相应用例 |
| W2 计量可行性 | 固定真实拓扑长连接计量、耗尽、故障恢复和快路径对照；性能与误差原始数据 | A118、PF04/PF09；其他账本/额度行需继续逐项映射 |
| W3 最小纵向验证 | 可信网站开关 → 真实 HTTP→REALITY → 失败关闭 → Network Service 重启恢复 → 两 Profile；两个 UI 观察同一真实状态，持久化失败不显示成功 | P1/P2/P3/P5/P6 的子集，不单独等于 G0/G1 |
| W4–W6 扩展与交付 | 完整 G1；再补 P1–P7 全部适用项及 PF，最后最终包 | G1 → G2 → G3 原定义不变 |

W0 的全量既有必需回归 PASS 是后续浏览器产品能力扩展的前置条件；W1 接线原型只能在隔离候选中验证，不以 standalone 或 GN 成功宣告完成。W1 不通过时暂停新增调试规则和入口；W2 不通过时暂停额度/计量可用承诺及 Alpha 判定。两线可并行做独立实验，W3 联合结论必须等待它们的匹配证据。

保留正式 G0 的原有代理组合、BLOCK/缓存、认证/渠道、资源等全部要求；W0/W1/W2/W3 任一小里程碑均不自动升级 G0。G0 未通过不得对外把技术原型宣称 Alpha。仓库质量门、独立 Review、native、真实服务和分发证据分开记录。

## 6. 从架构决策到可评审增量

下表细化 #164 的实施合同，不增加冻结验收编号，也不表示表中接口已经存在。W0 期间可先完成 W1 接口盘点、实验设计及独立 fixture；依赖真实浏览器的新能力实现与运行按 W0 退出条件接续。W2 的独立服务端实验不等待 Chromium 构建。

| 增量 | 输入与交付边界 | 必需验证 / 不可替代项 |
| --- | --- | --- |
| W1a 可信上下文接线清单 | 为导航、redirect、子资源及后台入口逐一列出当前文件/签名/调用序列、owner 来源、跨进程序列化与失效点；标明既有能力和拟新增字段 | 每个载体都能追溯到 browser-owned owner；缺失/伪造/过期输入的失败路径；仅存在结构体不算真实接线 |
| W1b 多组路由最小执行器 | 使用当前 matcher 和版本合同，把不可变决定送到实际 proxy/stream；端点注册、准备等待和热路径分离；不得用请求前切换 partition 全局配置实现并发 | 同 CDN 异组及不同 host 异组同时到达对应受控出口；原生未命中流量不变，首次 POST/PATCH 无重放；#162 保护的移除需与替代能力证明同审 |
| W1c 复用/重启与最小认证 | 对连接池、HTTP/2、CONNECT、auth/retry cache、旧 registration 和重启逐项给出兼容/失效策略；完成 HTTP/SOCKS5 两种入口的最小 Profile 认证适配 | 正确凭据成功、跨 Profile/未登记/过期凭据拒绝，关闭 Profile 后失效；复用实际连接的隔离与重启正反控制；未通过不能判 W1 或 G0 |
| W2a 计量与预算实验协议 | 先绑定受控节点/执行人、Xray commit/二进制、OS/内核、flow/配置、权威计数点、耐久策略、误差及超额预算，再执行第 3 节矩阵 | 区分实际字节与预留余额；原始长连接/耗尽/kill-restart/splice 数据及覆盖；资源未绑定为 BLOCKED，不生成假运行数据 |
| W3 集成清单 | 只消费已验证的路由能力、实际身份/节点提交和计量预算接口；明确 Profile 创建/关闭、Network Service 重启、发布与持久化失败的状态转换 | 同一产品产物和匹配服务配置完成纵向路径；独立原型各自通过不能直接拼成集成 PASS |

Q 负责可复现构建与证据，F 负责产品行为与功能候选；Q 可代 F 在一个独占候选上执行重型 native 测试，此时产品身份仍是 F 的 H，不能变成 Q 旧 H 的结果。一次只允许一个所有者写入该源码/out，交接前核对进程、锁、来源和参数。完整工作顺序与停止条件以[开发计划](development-plan.zh-CN.md)为准。
