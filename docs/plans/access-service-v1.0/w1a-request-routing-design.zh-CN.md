# W1a：请求级多组路由与认证接线设计

日期：2026-09-24。产品证据基线 **B=`7f74e0a4e971f91d08d90536e429aba7b82cf37d`**；工作分支 `codex/access-w1a-routing-contract-20260924`。本文是 W1a 设计与独立合同 fixture 的输入，所有标为“拟新增”的 API 均未实现。**W0 未完成，W1b/W1c 禁入，G0 仍 UNVERIFIED**；本文不授予生产接线、Chromium 构建、节点接入、收费 API 或发布权限。

本轮仅只读核对产品 overlay/patch，以及固定 Chromium checkout `/Volumes/ExternalSSD/repositories/aegis-chromium-phase3-20260922/pr23-088fc98/src` 中列明的文件。该 checkout 的观察 HEAD 为 `e4c4a82fffc2b8e804dd971e108a430a84a05747`，并非 B 的干净重放证明。没有修改 candidate、V8、out、锁或 GN 参数，也没有 sync/replay/reset/Ninja。源码存在不代表本候选编译、真实接线或运行通过。

## 1. 决策与冻结边界

保留 [冻结修订 4](spec.zh-CN.md)、[架构复核](architecture-review-20260922.zh-CN.md)第 2/6 节、[开发计划](development-plan.zh-CN.md)及[验收追踪](acceptance-tracker.zh-CN.md)的行为和阶段。旧 [Handoff](handoff-20260920.zh-CN.md)中 #162 OPEN/Draft、旧 H 和补丁编号是历史快照；B 已包含该保护性修复，不能重复实施，也不能把其相交 host 异组拒绝算作多组并存正路径。

选定方向为 **Browser 确认归属 → 专用浏览器私有 Mojo 路由入口 → NetworkContext 的不可变策略/端点注册表 → 每请求 net 路由决定 → 带显式隔离键的实际连接/流**。普通网页仍使用原有 Profile/StoragePartition，不用新增网页存储分区隔离代理组。原 `ProxyDelegate::OnResolveProxy` 不承担授权，也不等待 IPC、数据库或内核启动。

必须同时保持以下不变量：

1. URL、活动 tab、renderer initiator、NAK、网页 header 均不能独立授予本站权限。顶层 SchemefulSite、文档/待导航身份、Profile/partition 来自 Browser；NAK 保持 Chromium 原含义，不改造成能力令牌。
2. 同一 Profile 中 A→CDN→X 与 B→同 CDN→Y 必须并发成功；A→host-a→X 与 B→host-b→Y 也必须并发成功。拒绝其中一个、串行切 partition 配置、两个不同 Profile 分别成功，均不满足此前提。
3. `DIRECT`/未命中保留当前原生系统/扩展/PAC/企业结果，不保证物理直连；`PROXY` 仅一个已登记 Aegis 入口，不加入 DIRECT 或原生代理备用；`REJECT` 在加载/缓存/派发之前拒绝并按所有权取消相应在途流。
4. 管理限制和原生安全防护不被路由覆盖；网站开关不生成 ALLOW 防护例外。已提交 PROXY 遇身份、服务、网络或凭据故障继续等待/失败，不变成无规则。
5. request 验证完整 `GenerationTuple`：policy、identity、命中组 selection、network epoch、base proxy config。另加 NetworkContext incarnation；重启不是网络切换，不能借用旧 network epoch 来证明新 context 已安装。
6. 热路径读本地不可变状态，无同步 I/O；准备在可暂停入口有界完成。首次 POST/PATCH 也走所选代理；切换、故障、重启不重放已发送业务。
7. PREPARED → 完整候选安装/精确 ACK → durable commit → finalize 保留。发布半成品失败，旧 ACK 不能覆盖新 BLOCK。候选发送过的字节不可回滚，数据库失败不触发业务重放。
8. 普通 Profile、主要 OTR 实例分别持有 owner、注册、秘密和生命周期；关闭实例立即撤销本地认证与请求能力，远端撤销/截止单独证明。每活跃 Profile 一个稳定内核，全浏览器额外候选/排空最多 2，不因组数增加常驻进程。

## 2. 当前实际调用链与断点

以下路径相对 `apps/browser/overlay/`；行号以 B 为准，符号比行号更稳定。固定 Chromium 原生路径在第 4 节单列。

| 已核对位置 | 当前调用/行为 | W1 缺口 |
| --- | --- | --- |
| `chrome/browser/aegis/access/access_browser_request_adapter.h`：`BuildBrowserOwnedRequestMetadata(Profile*, wc_getter, FrameTreeNodeId, optional<int64_t>)` | 从 Browser Profile/WebContents/frame/partition 建立 document 或 pending-navigation 身份；pending navigation 优先于旧 document | 保留来源，不能让 renderer 提供新的可信字段 |
| 同文件：`BuildBrowserOwnedProfileRequestMetadata`、`BuildBrowserOwnedProfileOnlyRequestMetadata` | Browser partition 或 render process 映射到 Profile-only；不借活动 tab | 无唯一 client 的 Shared/Service Worker 不自动获得本站 scope |
| `access_proxying_url_loader_factory.cc:92`：`PrepareProxyDispatch` | 捕获按组五元组 → `CaptureSelectedProxyEndpoint(owner, group, exact_host)` → `EvaluatePublishedRequestForDispatch` 注册所有权 | 浏览器已经作出路由判断，但结果没有传到单请求实际 proxy 选择 |
| 同文件 `EvaluatePreparedMetadata`、`CreateLoaderAndStart`（574）、`ForwardNative`（643） | canonicalize → matcher → native/block/proxy；proxy tracked request 最终仍把原 `ResourceRequest` 交给 target factory | 没有携带 RoutePlan 的 per-request wire 字段/私有调用；native 分支不跟踪后续跨模式 redirect |
| `access_proxying_url_tracked_request.cc:109`：`FollowRedirect`、`:205`：`RebindOwnershipForRedirect` | 重评目标、保留 stable request ID、重绑 Browser registry；目前必须仍为 `kDispatchProxy` 才继续 | 仅 PROXY→PROXY 的 Browser gate；标准 FollowRedirect 没有新的可信路由上下文，不能证明下游改组选路 |
| `access_network_context_transport.h`：`PartitionState`、`PublishProxySelection`、`CaptureSelectedProxyEndpoint` | 每 partition 一个 optional endpoint、一份 exact-host 列表；Current/ReplaceSelection 亦单值 | 改为按组/registration 的注册表、完整 snapshot 发布；既有 config ACK 不能冒充新注册表/池键就绪 |
| `access_network_context_transport.cc:534`：`BuildConfig` | 使用 `ApplyRoutePlanToProxyInfo` 把一个 HTTP loopback endpoint 编成 CustomProxyConfig host 选择 | 即使 matcher 区分顶层站点/scheme/port，传输仍无法表达并存组 |
| `components/aegis_access/access_proxy_route_adapter.{h,cc}` | `RegisteredProxyTransport` 只有 `kHttp/kInvalid`；校验注册 ID、组、owner、完整 tuple、numeric loopback、非零 port；单代理无 DIRECT fallback | HTTP ProxyInfo 适配存在；凭据、SOCKS5 认证及实际请求贯穿尚未实现 |
| `access_network_context_transport.cc:395`：`PublishPolicyCandidateToClients` | `OnAegisAccessPolicyPublished` 发候选 metadata；回调结合当前 client generation/数量确认 | 不是完整 policy rules/endpoints 安装，也不是实际转发结果 |
| `chrome/browser/aegis/aegis_profile_support.cc`：`IsAegisProfileSupported` | 接纳 regular、primary OTR；拒绝 Guest/system | 不借新路由偷偷扩大 Guest 支持；OTR 秘密与退出矩阵仍待实际运行 |

入口盘点以现有 factory hooks 为起点，不声称 helper 覆盖整个生命周期：

| 入口 | Browser 来源与现有符号 | 新载体/失效规则 |
| --- | --- | --- |
| 主导航 | `ChromeContentBrowserClient::WillCreateURLLoaderFactory` 调 `MaybeProxyNavigation`；pending navigation ID、目标 SchemefulSite | hop 0 及每跳 Browser 重新确认目标；旧已提交页面权限不能继承 |
| document 子资源、iframe | `MaybeProxyDocumentSubresource` → frame-owned metadata | 顶层网站来自可信主文档；子资源 redirect 保留该归属，只重算目标；document replacement 销毁旧 factory lease |
| Worker 主资源/子资源 | `MaybeProxyWorkerMainResource`、`MaybeProxyWorkerSubResource`；有 frame 时 frame-owned，无 frame 时 Profile-only | dedicated Worker 只在确认唯一归属时使用 site scope；缺归属不推断活动页 |
| Service Worker 子资源/脚本 | `MaybeProxyServiceWorkerSubResource`、`MaybeProxyServiceWorkerScript` | 当前 Profile-only；本设计不把它升级成本站授权，也不宣称已覆盖 SW 内部缓存响应/update |
| frame prefetch | `MaybeProxyPrefetch` | 现有 frame helper；必须验证真实入口和配置 on/off |
| LoadingPredictor | `chrome/browser/predictors/prefetch_manager.cc` → `MaybeProxyBrowserProcessPrefetch`（运输补丁 0148） | 可信 partition 的 Profile-only；不是全部通用预取/preconnect 的覆盖证明 |
| WebSocket、BFCache/prerender、UDP/QUIC、下载后续阶段 | 本轮没有完成这些独立入口逐函数核对 | 进入 W1b/W1c 前列明受约束阻止/验证路径；不得由 URLLoader helper 外推完成 |

## 3. 数据合同与权威来源

拟新增字段和类型使用专门命名，不修改 `OwnershipKey` 的渠道/Profile/partition 定义，不重新解释 NAK。`components/aegis_access` 保留纯匹配类型；Mojo wire 类型放 `services/network/public/mojom`；`net` 类型仅包含 route/identity 的无 chrome 依赖值类型。

| 对象（拟新增） | 内容与生存期 |
| --- | --- |
| `AccessFactoryBinding` | Browser 创建并独占的网络工厂绑定 ID、owner、incarnation、可信归属来源、允许 attribution 类型；NetworkContext 在建立私有接收端时绑定，不采用请求自报 owner |
| `AegisAccessRequestContext` | binding ID、request token、hop、document/page 或 pending-navigation identity、attribution kind、可信 top-level SchemefulSite、canonical scheme/host/effective port、method、五元组、snapshot ID；不含密码/任意代理 URL |
| `AccessPublishedRouteSnapshot` | owner、incarnation、publication ID、policy/identity/network/base 代次、`selection_generation_by_group`、规则集合、registration map；完整校验后原子替换只读指针 |
| `AccessEndpointRegistration` | opaque registration ID、owner、group ID、selection/identity/network 绑定、transport、numeric loopback host/port、listener incarnation、credential handle、expiry/connection deadline；registration ID 永不复用 |
| `AccessResolvedRoute` | `native/proxy/reject/wait-fail`、matched rule、有效 scope、完整 tuple、incarnation、registration ID（proxy 必填）、不可变 `AccessRouteIsolationKey`；仅网络执行器能构造已验证实例 |
| `AccessRouteIsolationKey` | owner + group + registration ID + 五元组 + NetworkContext incarnation；首次实现保守使用完整 tuple，任何字段不同均禁止新请求复用旧传输 |

selection generation 已按组分离：组 X 更新不应把组 Y 的 selection 错写为 X。请求携带的是命中组对应的完整五元组；snapshot 使用 common generations 加 per-group selection 表。最小模型若只覆盖 equal-selection 情形，须明确其限制，不将该简化转入生产 API。

registration 以 owner/group 为索引，以不可复用 registration ID 作精确引用；一个 group 可有已准备候选和当前生效入口，但一个请求只选择一个当前入口。endpoint 改地址、身份或 listener 重建都产生新 registration。网页/renderer/UI 的字符串不是注册来源；浏览器可信 ProxyCoreController 才能提交经过 loopback/进程/租约验证的 endpoint。一个 Xray 内通过独立 inbound/outbound 映射区分组；是否支持动态配置和端口预算需 W1c 真实验证，不能先假定可行。

`proxy intent`/恢复中约束来自受信 snapshot 或正在恢复的 owner 状态。没有可信 attribution 时 site rule 不可命中；不能把缺失上下文简单等价于无规则。无规则且不存在受约束恢复范围才可走 native；已知受约束但缺 owner/tuple/registration 则在发送前 wait/fail。

**canonical 尾点边界（2026-09-24 Q 固定 Chromium 151 GURL 实验定界）：** 配置侧 `exactHost` 和本站 `topLevelSite` 是原始待准入值；拒绝尾点和其他非 canonical 拼写，不靠解析后丢失的原始拼写补救。请求侧使用可信 GURL/SchemefulSite 解析后的 canonical host/site 判定，不能自行检查或恢复原始 authority。Q 观察到 `https://127.0.0.1.`、`https://127.0.0.1%2e` 和 `https://127.1.` 均归一到 `https://127.0.0.1/`，SchemefulSite 同值；这些请求按 canonical IPv4 规则正常判路。DNS `target.example.` / `%2e` 保留尾点，IPv4 双尾点 `127.0.0.1..` 也保留且不作为 IP，故已有已发布快照时对解析后仍带尾点的目标或可信顶层网站 fail closed，即使无匹配规则；重启恢复中的已提交快照/约束同样适用。从未发布快照且无恢复约束的 factory 沿原生配置。`[::1].` 是无效 GURL。本 Node fixture 只固定上述对象边界；生产 Browser/Network Service 接线和真实流量仍须独立证明。

## 4. Browser → 实际 proxy/stream 的可实施 API 清单

固定 Chromium 只读核对表证明原有接口的形状，右列是拟新增改动，不是已有 API。

| 文件/现有 API | 精确观察 | 拟新增接线 |
| --- | --- | --- |
| `services/network/cors/cors_url_loader_factory.cc:633` | 非 trusted factory 收到 `request.trusted_params` 调 `mojo::ReportBadMessage` | 不把 renderer factory 整体设为 trusted，不把路由塞进现有 TrustedParams 后绕过检查 |
| `services/network/public/mojom/url_loader_factory.mojom`、`network_context.mojom` | 现有 URLLoaderFactory 接收 ResourceRequest；现有 Aegis publication metadata 不含请求级 route | 新 `aegis_access_route.mojom` 定义 Browser-only `AegisAccessURLLoaderFactory.CreateLoaderAndStartWithRoute(...)`，同时接 ResourceRequest 和独立可信 envelope；`NetworkContext.CreateAegisAccessURLLoaderFactory(...)` 只通过 Browser 的 NetworkContext 远端创建 |
| `services/network/cors/cors_url_loader_factory.{h,cc}`、`cors_url_loader.{h,cc}` | 原有 CORS、initiator、process、隔离和 load_flags 验证依赖原 factory params | 新受控 C++ 入口接受已验证 envelope，不修改原 params 的 process/is_trusted/origin-lock/CORS 语义；preflight/内部派生请求带明确 parent binding，不继承任意 body 重试权限 |
| `services/network/url_loader.{h,cc}`、`url_loader_factory.{h,cc}` | URLLoader 建立 `net::URLRequest`；现有 `OnReceivedRedirect/OnAuthRequired` 位于该层 | 在 URLRequest Start 和缓存命中前安装已验证 route context；普通公网 `Proxy-Authorization` 不充当可信载体；新增 loader 私有 route control 供 Browser 更新每跳上下文 |
| `net/url_request/url_request.{h,cc}`、`url_request_http_job.cc:451` | 后者把 URLRequest 的 URL/method/isolation/load flags 等复制进 `HttpRequestInfo` | 新 net-only `AccessRequestRouteContext` 只由可信网络 adapter 设置；显式拷贝到 `HttpRequestInfo`；新 hop 必须换决定，不能沿用旧 proxy_info |
| `net/http/http_request_info.h` | 有 NAK 等原生字段，无 Aegis route identity | 增加 optional 不可变 context/decision 引用；copy/move、websocket、preconnect 路径分别验证，避免默认构造意外降为 native |
| `net/http/http_stream_factory_job_controller.cc:833`：`DoResolveProxy` | 先处理 `LOAD_BYPASS_PROXY`，否则调用 `ResolveProxy(url, method, NAK, target_network, ...)` | Aegis 分支在 BYPASS 前验证约束；PROXY 直接应用已验证单入口，REJECT/缺失返回错误，native 才调用原解析器；不使用全局 mutable request side-channel |
| 同文件 `DoResolveProxyComplete`、`DoCreateJobs` | 支持 HTTP/HTTPS/SOCKS4/SOCKS5，过滤空代理后建 jobs；Alt-Svc/QUIC/备用 job 有独立分支 | 校验 tuple/incarnation 仍当前；禁止 Aegis 分支重新 fallback/re-resolve 到 DIRECT/原生代理；受约束 Alt-Svc/QUIC 在未有证明前不创建旁路 job |
| `net/base/proxy_delegate.h:41`：`OnResolveProxy(url, NAK, method, retry_map, ProxyInfo*)` | void 同步接口，没有 request identity、错误返回或可等待能力 | 保留原生语义；请求级路由通过 JobController 的新显式 context 到达选择点，而不是伪造不存在的 `SetProxyForRequest` |
| `net/http/http_stream_factory_job.cc:366`、`net/socket/client_socket_pool.h:130` | `GroupId(destination, privacy, NAK, secure_dns, cert_fetch, network)`；pool 外层另有 ProxyChain | 增加 isolation key 并贯穿 Job/socket 参数、pool lookup/creation、连接完成回调与预连接；保持 native key 空值兼容 |
| `net/spdy/spdy_session_key.h:33`、`CompareForAliasing` | key 含 ProxyChain/NAK 等，但无 owner/group/registration/generations | 增加 key 并比较 equality/order/alias eligibility；HTTP/2 proxy session 和目标 session 均不得跨 key coalesce |

专用私有入口的接线顺序：Browser wrapper 丢弃任何非权威路由输入、重新从 browser-owned 状态构造 envelope；NetworkContext 创建的私有 factory 持有固定 owner/binding；其 C++ adapter 在原 CorsURLLoaderFactory 验证前后保持原安全检查，再把 envelope 作为独立参数交给 URLLoader。新 Mojo receiver 绝不交 renderer、网页、WebUI 通用 mutation 或扩展。不能把原 renderer-facing URLLoaderFactory 的 `is_trusted` 改为 true 来省去接线。

本方案刻意不用每请求 Browser→NetworkService“先登记再普通 Create”的两条有竞态 IPC；单个私有 Create 调用原子携带请求和可信 envelope。快照/endpoint 预先安装并 ACK，请求入口只作本地检查。新 API 的 Mojo traits/序列化、receiver ownership、disconnect、clone、CORS preflight 和独立 origin-lock 拒绝测试属于 W1b 必需工作。

### Redirect 与非幂等请求

当前 `URLLoader.FollowRedirect(headers, optional new_url)` 没有可信上下文参数。拟新增私有 `AegisAccessURLLoaderControl.FollowRedirectWithRoute(headers, new_url, envelope)`：Browser 校验 renderer 的新目标后重新捕获归属/版本；Network Service 核对 pending redirect URL、request token、严格 hop+1、method 的 Chromium redirect 结果及当前快照，再更新 URLRequest 决定后继续。标准公共 FollowRedirect 不得直接推进受 Aegis 约束而未重授权的下一跳。

初始 native 请求也必须保留轻量 wrapper/control，否则 native→PROXY/REJECT 的 redirect 会漏检。主导航每跳以该 hop 目标 SchemefulSite 求值；子资源保留原 document 的可信顶层站点。PROXY→native 仅在新目标独立匹配 native 且无管理/防护阻断时允许，不是代理失败 fallback。所有六种模式转换有明确新请求行为；redirect 的 REJECT 是终止，不发送下一跳。

请求在准备态不消费 upload body；网络派发仅一次，等待预算耗尽明确失败。已经发送后选择/身份/Network Service 改变不触发自动重发。307/308 保留 method/body 的原生 redirect 是显式协议语义，测试按 `(request ID, hop)` 观察一次，不把合法下一跳误记成重复；故障恢复重放同 hop 则必须失败。HTTP proxy 407 认证需在业务转发前完成，并用受控代理日志证明错误凭据不会先转发 POST/PATCH。

## 5. 复用、缓存、凭据与重启

仅换端口或密码不足以隔离旧连接。首版保守把完整 tuple/incarnation 纳入 Aegis key；后续缩小 key 必须给出兼容证明和性能数据。key 不含明文凭据，不把 URL path/header 当身份，诊断只输出脱敏关联 ID。

| 资源 | 现有风险/核对点 | 选定处理与验证 |
| --- | --- | --- |
| HTTP/1 socket、CONNECT tunnel | ProxyChain/GroupId 没有注册代次；端口回收可能复用旧连接 | 显式 route key；旧 key 不向新请求出租，旧在途不迁移；撤销/关闭按期限终止。端口相同、新 registration 必须失败复用 |
| HTTP/2 session、coalescing | 原 `SpdySessionKey` 及 alias 比较缺 Aegis identity | 把 key 贯穿 destination/proxy session 与 alias 查找；BLOCK 按流取消，不无差别杀其他网站共享流 |
| 新旧 HttpStreamPool 路径 | 本轮只核对传统 JobController/ClientSocketPool 的关键点 | W1b 开始前枚举固定 feature defaults 与可达新 HttpStreamPool/GroupId 路径；同样加 key 或对 Aegis 明确禁入未验证路径，不能只补旧池后宣布隔离 |
| proxy auth cache | `net/http/http_auth_cache.h:247` 的 `EntryMapKey` 对 AUTH_PROXY 使用空 NAK | Aegis 凭据使用隔离的 registration-keyed provider/cache；不得向原生 proxy auth cache 无条件播种；若复用 HttpAuthController，必须扩展其 proxy cache key 与调用链而非仅添加 NAK |
| proxy retry/bad-proxy cache | `net/proxy_resolution/proxy_retry_info.h:29` 为 `map<ProxyChain, ProxyRetryInfo>` | Aegis 不把专用入口错误写入其他组/原生全局 bad cache；按 isolation key 保存受控失败状态且不产生 DIRECT fallback |
| HTTP cache | 同 URL 从缓存命中可能不经过选代理/建流 | 在命中前执行 REJECT/版本 gate；首版对 Aegis 受约束请求禁用 HTTP cache 复用或扩展隔离 key，二者须在 W1b 明确选择并测试；保留未命中原生缓存行为。此处选择首版禁用受约束请求 HTTP cache，性能记入 PF02/PF03 |
| SW cache、BFCache/prerender | 独立于 net HTTP cache | 沿冻结加载/激活 gate 执行；本 fixture 不证明这些入口，W0/W5 尚欠不能被本设计关闭 |
| preconnect/DNS/Alt-Svc/QUIC | speculative job 可能没有 Browser 请求身份 | 受约束 preconnect 仅接受相同可信 binding/key；没有归属的推测不创建受约束连接。未支持的 Aegis QUIC/UDP 明确阻止或已验证降级；native 无关流量原样 |

NetworkContext 状态机为 `RESTORING → INSTALLED(candidate) → READY(exact ACK)`，disconnect/restart/owner 销毁进入 `INVALIDATED`。Browser 生成新 incarnation；Network Service 初始化即知道此 owner 尚在恢复，不能把空表当无规则。恢复安装 owner、最新屏障、完整快照、端点/凭据引用及资源隔离配置后才 ACK。旧 capability、registration、pending redirect、ACK、池、auth/retry cache 均不可用于新 incarnation；新 registration 重新绑定实际 listener，不复制旧 ID。

网络变化提升 network epoch；identity 变化提升 identity generation；系统/扩展/企业代理变化提升 base proxy config generation。每次变化先撤销新派发权，再完成准备/原子安装；保留已提交 PROXY 意图。旧业务可按原连接生命周期完成，BLOCK/注销/到期按各自更严格截止终止；绝不迁移/重放 body。Profile 关闭丢弃私有 receivers、凭据/注册、等待者和临时 OTR 状态，迟到回调检查 owner lifetime/incarnation。

## 6. HTTP/SOCKS5 最小认证的真实适配缺口

HTTP 已能构造 ProxyInfo，不代表认证已接通。`ProxyDelegate::OnBeforeTunnelRequest(proxy_chain, proxy_index, callback)` 没有 request owner；仅凭该地址回调发密码不合格。拟新增 `AccessProxyCredentialProvider::LookupForRoute(owner, registration, isolation_key, transport)`，由网络执行器用已验证决定调用；返回进程内短期 secret handle/凭据，禁止 renderer 可见字段、URL、日志、NetLog 或 UI 任意代理地址获取。明文 HTTP forward proxy 与 HTTPS CONNECT 都须接到相同授权来源，Proxy-Authorization 不发给 origin，也不能跨 redirect 携带到另一代理。

SOCKS5 的缺口是确定的源码事实：`net/socket/socks5_client_socket.cc:254` greeting 为 `{0x05, 0x01, 0x00}`，只提议无认证；`:326` 拒绝非 0 方法。`net/socket/socks_connect_job.cc:174` 创建 SOCKS5ClientSocket 时只有 transport socket、destination、traffic annotation，没有用户名密码入口。

拟新增 `RegisteredProxyTransport::kSocks5`、`SOCKSSocketParams` 的受信认证引用及 route key，贯穿 ConnectJob 到 SOCKS5ClientSocket 的受控认证分支，实施 SOCKS5 username/password 子协商、长度/编码限制、部分读写、失败/取消/超时与秘密清理。**只对已登记 Aegis SOCKS5 使用该分支**；原生任意 SOCKS 代理不自动得到 Profile 密码。需要认证的入口不协商回无认证。具体 RFC 字节合同和固定 Xray 支持必须在 W1c 实施前再次核对；本设计不宣称已完成该协议适配。

W1c 最小真实实验输入为固定 Chromium 候选/二进制哈希、固定本地代理资产与配置哈希、两个普通 Profile、各自随机 session 凭据、IPv4/IPv6 loopback listener、受控 origin 与关联 ID。HTTP 和 SOCKS5 分别运行正确凭据成功、无/错/跨 Profile 凭据拒绝、未知 registration 不获 secret、地址相同但 listener/registration 更新、Profile 关闭后新连接和既有会话失效。外部非 loopback 连接必须拒绝；由健康控制证明代理/origin 日志可观测，不能以超时替代拒绝证据。

这些实验不需要生产节点或收费 API；完整 HTTP/SOCKS5 × REALITY/WS+TLS 与 OTR/Guest 临时上下文仍归 W5。fixture 只能模拟 credential lookup 的授权结果，不能报告 HTTP/SOCKS5 握手、Profile 认证、Xray READY 或 A78 PASS。

## 7. 替代方案取舍与迁移

| 替代方案 | 取舍 |
| --- | --- |
| 扩大 CustomProxyConfig exact-host allowlist | 不选：同 CDN 异站点不能分别到 X/Y，scheme/port/组同样丢失 |
| 每请求修改 partition 全局代理 | 不选：并发/redirect 时互相覆盖；ACK 不能消除竞争 |
| PAC/URL/NAK 推导组 | 不选：不是可信 document/navigation 授权；NAK 不能隔离 proxy auth cache |
| 每组新 StoragePartition/NetworkContext | 不选：改变网页 cookie/storage/SW 语义；仅为路由分组引入过重资源 |
| 每组独立 listener 作为唯一隔离 | 只作为端点区分辅助手段：同进程不同 inbound 可行性待测；端口复用、旧连接/认证 cache 仍需显式 registration key |
| 全局 URLRequest side map 供 ProxyDelegate 查 | 不选：同步回调缺 request token；同 URL 并发存在歧义，生命周期/线程竞争不可接受 |
| renderer factory 整体提升 `is_trusted` | 不选：信任面扩大到所有 TrustedParams，破坏现有 CORS/隔离边界 |
| 私有 factory/control + net 显式 context | 选定：接线面更大，但身份和失败点可逐层审查，保持现有网页分区与原生非 Aegis 路径 |

迁移先以相同输入离线比较旧/新决定，仅一条真实发送路径。新 executor 未完成正反运行前保留 #162 admission 保护；移除保护必须与正路径证明在同一可评审单元，不单独“解锁更多组”。回滚保留持久意图；旧执行器表达不了的新并存组应安全停止受约束请求，不能重写规则、删组或转为 DIRECT。

## 8. 最小验证矩阵与证据层级

以下均为待执行合同。模型断言只能标 `CONTRACT_MODEL_ONLY`；W1b/W1c 必须增加同候选真实 URLLoader/stream、代理出口和 origin 观测。

| 场景 | 模型必须断言 | 真实退出证据 |
| --- | --- | --- |
| 同 CDN 异组 | 同 owner 下 A→cdn→X、B→cdn→Y 同时已安装；两决定/registration/key 不同且都派发一次 | 两个受控代理出口关联到正确站点；并发重叠时间、无全局切换 |
| 不同 host 异组 | host-a→X 与 host-b→Y 同时存在且互不覆盖 | 两出口正路径，缺任一路不通过 |
| scheme/port | http/https/ws/wss、默认端口和 8443 精确输入不错误归并；普通网站协议组另按冻结 matcher | 目标实际协议/端口日志；helper URL 比较不足 |
| DIRECT/PROXY/REJECT 与六种转换 | native 使用当前 base generation；proxy 无 fallback；reject send=0；旧决定失效；BLOCK 不需要 proxy READY | native 原有代理组合、proxy 出口、拒绝的新流零发送、在途按流终止 |
| redirect | 主导航换顶层目标、子资源保留顶层；每 hop 重新求值；native→proxy/reject 不漏；旧 hop 不可复用 | 302 与 307/308、跨 host/组/模式；按 hop 记录实际 method/body/出口 |
| POST/PATCH | 等待前 send=0；ready 后当前 hop send=1；重复 dispatch、故障恢复不增加 | 受控 origin 唯一业务标记/计数，407 不预转发 body，无旁路 |
| 两 Profile/主要 OTR | owner/实例不同；交叉 registration/decision/credential lookup 拒绝；销毁后不复活 | 两普通 Profile 最小认证；OTR 实际矩阵独立记录，Guest 当前不假装支持 |
| 旧连接/凭据 | 同 endpoint 地址新 registration 或任一 tuple 字段改变，key 不同；旧决定不能新派发 | 先真实建连接，再轮换/回收端口，观察 socket/session ID、auth 与出口 |
| Network Service 重启 | 旧 incarnation 的 registration/ACK/hop/decision 拒绝；新 context READY 前受约束 send=0 | 真正停止/重建 Network Service，同 Profile 恢复，无 DIRECT 窗口、无业务重放 |
| 伪造/缺失上下文 | URL/activeTab/NAK 不构造授权；未知 issuer/token/binding、空代次或组不符拒绝 | Mojo 不可信 receiver、克隆/过期 factory、跨 process 参数真实拒绝 |
| 半发布/旧 ACK/后发 BLOCK | 完整 snapshot 原子检查；旧 candidate ACK 不覆盖新快照；即时 pre-ACK 屏障、持久提交及在途取消不在模型中 | Coordinator 即时屏障、durable commit 失败/崩溃、跨 context ACK 延迟、候选已有流量后回滚 |

真实负路径保留合法初始 hop 的代理计数；不能把 redirect 前的一次合法发送改写为零。代理真实转发本就会到 origin，“origin 非零”不能单独证明 DIRECT；需关联 ID、入口/出口、连接日志联合证明。性能 PF01–PF03、PF07/PF08/PF12 继续使用冻结规模/时序；本纯模型不产出任何网络性能或资源达标结论。

## 9. Sol/xhigh 的独立 executable contract fixture

允许在 `w1a-fixtures/` 新增 Node 模型、`node:test` 用例和 README；不导入生产 router，不修改 overlay/patch、native runner、GN、共享 plan/handoff/tracker。模型只是本设计的可执行 oracle，**不是生产组件、不是 Chromium 适配，也不是独立安全边界**。JavaScript 对象身份、private map 和 token 不证明 Mojo/跨进程不可伪造。

建议 API（可等价精简，README 必须明确实际差异）：

```text
registerEndpoint({owner, group, registrationId, endpointIdentity,
                  generations, incarnation})
publishSnapshot({owner, commonGenerations, selectionByGroup,
                 incarnation, rules, endpoints}) -> candidateIdentity
acknowledgeModelSnapshot(candidateIdentity) -> READY | STALE
issueRequest({trustedOwner, attribution, target, method, requestId, hop})
evaluate(issuedRequest) -> native | proxy | reject | wait-fail + key
dispatch(decision) -> sent-once | refused
redirect(issuedRequest, newTarget) -> newIssuedHop
restart(owner, newIncarnation) -> invalidated
lookupCredentialAuthorization(decision, registration) -> authorized | refused
```

registry 与 issueRequest 只暴露给模型中的可信调用侧；用伪造 plain object、旧 token、跨 owner 和 duplicate dispatch 作反例。规则可限于 exact host + scheme + effective port + site/profile scope，不另写第二套完整生产 matcher；不支持后缀/IDNA/完整策略优先级时明确 NOT_MODELED。`acknowledgeModelSnapshot` 仅表示模型状态转换，不等于 Chromium 的 publication ACK。

尾点反例分别覆盖原始配置 `exactHost`/本站 `topLevelSite` 准入，以及解析后仍带尾点的请求目标/顶层网站在首次、redirect、无匹配规则和重启恢复时拒绝且 send=0。IPv4 单尾点及等价拼写经 GURL 归一后应与 canonical IPv4 同路，不能因为原始文本尾点而误拒；双尾点与 DNS 尾点仍拒绝。从未发布且无恢复约束的输入保留 native 正对照。模型绿灯不替代实际 Browser/Network Service 准入和出口观测。

每个用例保留输入、预期 action/group/key、实际 send count、state transition；正常控制与拒绝反例成对。最低覆盖第 8 节模型列，独立测试规则错误、缺 endpoint、伪造 owner、组不符、五元组逐字段过期、旧 incarnation ACK、同地址换 registration、native 当前配置恢复。测试不能只比较实现自己生成的字符串；必须用手写 oracle 断言 X/Y 选择、send 次数和不得出现的 fallback。模型的报告写明未执行 browser/native/auth/network，并可由 `node --test` 在隔离目录运行，不需要安装服务或启动监听。

## 10. 后续最小 PR 切片与放行条件

| 切片 | 范围 | 前置/退出 |
| --- | --- | --- |
| W1a-D（本轮） | 本文 + 独立 executable contract fixture | 独立审查设计、模型 unit/regression；只证明合同可执行，不改冻结要求 |
| W1b-1 | 私有 factory/control Mojo、owner/binding/快照注册表、net context 贯穿；默认不放开多组 admission | **W0 全必需回归 PASS 后**；真实不可信 IPC 拒绝、CORS/原生路径回归、精确 ACK、失效与 no-send 证明 |
| W1b-2 | 真实请求级 proxy 选择、不同/同 host 多组、redirect/首次 POST/PATCH；基础安全隔离必须随执行器同交 | 同候选两种并存正路径、所有负路径及 unit/真实入口 regression；替代证明通过才同单元移除 #162 对应限制 |
| W1c-1 | 全实际池/HTTP2/cache/credential/restart 生命周期验证与余下隔离接线 | 不能把 W1b 未隔离版本对外启用；旧连接、端口复用、跨组/Profile、restart 正反证据 |
| W1c-2 | HTTP 与 SOCKS5 最小认证适配和本地受控握手 | 固定 Chromium 与代理二进制、两 Profile、正确/错误/过期/关闭矩阵；未通过 W1/G0 均不通过 |

W1b-2 和 W1c 是审查切片，不是允许带有已知复用/认证漏洞的过渡产品；未完成项保持实验门关闭。每项生产 PR 依照 [DEV CI 指南](../../development/ci.zh-CN.md)提供最终候选 unit、regression、独立 Review、本地/托管与 native 证据，各自绑定 SHA/产物。不存在“模型 PASS 即 W1 PASS”的捷径。

W2 在本阶段仅准备固定版本、拓扑、计量位置、预算和资源输入；没有受控资源不伪造节点或服务端实验结果。本文源码设计不提供托管 CI 结论，最终交付验证以 [W1a 交接](FEATURE-HANDOFF-W1a.zh-CN.md)指向的 PR 回执为准。本轮未运行任何 Chromium 测试、未验证真实代理认证/出口/性能、未生成最终包。共享追踪表的主行状态不由本文自动提升。
