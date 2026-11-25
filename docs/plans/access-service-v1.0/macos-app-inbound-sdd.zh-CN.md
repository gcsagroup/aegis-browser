# macOS SDD · Chromium 请求的应用级无认证入站

2026-11-20 · 设计基线为 [fork main `c5b4257a`](https://github.com/quinn521/aegis-browser/tree/c5b4257a221b7d4434a113d2c13d870139b8d6fa)，当时的桌面 Chromium 为 155.0.8059.80。本候选的桌面 [Chromium pin](../../../apps/browser/CHROMIUM_VERSION) 为 158.0.8127.37。本设计覆盖浏览器管理的本地入站、登记和 Network Service 派发。共同的选择与撤销条件见 [应用级回环入站合同](app-inbound-contract.zh-CN.md)。

## 从用户操作到实际请求

用户在原标签开启保护后，浏览器为该 Profile 和路由组准备核心及回环监听，按下文的发布条件确认对应版本可派发后，才放行受保护的首个请求。UI 读取实际登记的协议、状态和失败原因。只有原有可信导航票据仍有效时才执行一次安全重试。更新端点不会触发额外的业务请求。[现有 Options 规格](macos-access-options-sdd.zh-CN.md) · [原标签发布与重试 #140](https://github.com/gcsagroup/aegis-browser/issues/140)

| 接线位置 | 基线事实 | 新合同的实施责任 |
| --- | --- | --- |
| [ProxyInfo adapter](../../../apps/browser/overlay/components/aegis_access/access_proxy_route_adapter.cc)、[SOCKS parser](../../../apps/browser/overlay/components/aegis_access/access_socks5_inbound_parser.cc) | 已有 `kSocks5 → SCHEME_SOCKS5`、数值回环检查和单一 proxy chain。parser 支持无认证 CONNECT | 沿用源码并在固定 Chromium 上执行正反回归。浏览器的 SOCKSv5 仅承诺准入的 TCP URL 路径，拒绝 BIND 和 UDP。[Chromium 协议说明](https://chromium.googlesource.com/chromium/src/+/refs/heads/lkgr/net/docs/proxy.md) |
| [本地 core manager](../../../apps/browser/overlay/chrome/browser/aegis/access/access_local_core_manager.cc)、[网站入口](../../../apps/browser/overlay/chrome/browser/aegis/access/access_site_proxy_bubble_controller.cc) | HTTP readiness 依赖经 407 取得的本地认证及 204。准备成功时产品登记写入 `kHttp` 和本地凭据 | 由本应用持有的核心启动指定协议监听，确认实际地址和监听实例。使用指定出口的受控探测关联本代，分别证明 HTTP forward/CONNECT 与 SOCKS CONNECT。裸 204 或仅能连端口不能发布 |
| [登记与 BuildConfig](../../../apps/browser/overlay/chrome/browser/aegis/access/access_network_context_transport.cc)、[私有发布客户端](../../../apps/browser/overlay/chrome/browser/aegis/access/access_private_context_client.cc) | RegisterPreparedProxy 要求 HTTP 与非空本地凭据，私有发布也只编码 HTTP。BuildConfig 有独立的 account_config 及 private_routing 分支 | 登记按实际 transport、owner、partition、route group、registration、监听实例与代次校验。私有发布按同一字段编码。账户专用远端代理的 TLS、代理头和授权继续由账户路径持有 |
| [Mojo 快照](../../../apps/browser/overlay/services/network/public/mojom/aegis_access_route_types.mojom)、[wire 解码](../../../apps/browser/overlay/services/network/aegis/access_route_wire.cc)、[登记表](../../../apps/browser/overlay/services/network/aegis/access_route_registry.cc) | wire 端点名为 AegisAccessHttpEndpoint，解码固定生成 HTTP scheme | 发布带明确协议和监听实例的受信端点，只认可目标合同的回环端点，未知版本/枚举拒绝。替换原本依赖本地凭据的复用判断，将协议与监听实例纳入不可变登记和连接隔离。renderer 不能自报路由所有者 |

## macOS Access Options

沿用内部 Debug/Alpha 的当前网站工具栏入口与受信页面 `chrome://aegis/access-options`。在“Profile → 本地入站”增加协议和端口偏好；常规、主题、Profile/自动切换、导入导出、日志及账号页面沿用 M5–M10。当前网站面板显示使用该规则的实际 Profile 和运输，Options 同时显示草稿、提交版本和当前发布状态。[既有 WebUI 与渠道设计](macos-access-options-sdd.zh-CN.md) · [三端 Options 合同](app-access-options-sdd.zh-CN.md)

DEV / 内部 Alpha 的“测试节点”支持文本输入和扫描节点二维码。Mac 可选择本机二维码图片，也可主动打开可用相机扫码。Browser 侧检查渠道和目标 Profile，本机解码后只更新发起窗口的草稿。没有待完成的 Apply 时，按受保护站点的规则所引用测试 Profile 的已提交版本准备和登记上游。Apply 将活跃绑定的上游从 A 改为 B 时，Browser 按该 Profile 校验通过的候选版本准备、登记并安装 B 的回环端点，期间保持派发屏障。按下文的发布条件取得精确安装 ACK 后，只有该候选版本已持久提交并在仍匹配的上下文中完成激活，且 `activeRevision` 与本次 `committedRevision` 一致、`dispatchPermitted` 为 true，才解除屏障。验收同一合成链接经文本和扫码预览一致、取消选择图片或拒绝相机后可继续输入文本、关闭窗口后迟到结果作废。Beta / Release 直接打开 WebUI、发送导入消息或恢复旧 Profile 均不能激活手动节点。托管账户联调等待服务端同事交付。[测试节点与阶段交接](app-access-options-sdd.zh-CN.md)

WebUI 消息携带草稿版本和操作 ID，Browser 侧的 Profile 服务逐操作检查 page/read/write/import/activate 权限，并将提交结果写回当前窗口。界面不能直接创建监听或恢复旧 endpoint。受限渠道通过直接 URL、消息或导入调用也必须遵循原生能力门。一个窗口 Apply 后另一个窗口的旧版本提交须显示冲突；重新打开可读取新版本，失败提交不得显示成功。[Profile 服务](../../../apps/browser/overlay/chrome/browser/aegis/access/access_options_service.cc) · [版本化存储](../../../apps/browser/overlay/chrome/browser/aegis/access/access_options_store.cc) · [已知冲突回执问题 #195](https://github.com/gcsagroup/aegis-browser/issues/195)

验收从真实工具栏和直接 WebUI 两个入口进入，使用键盘及 VoiceOver 操作。分别验证自动、固定 HTTP、固定 SOCKS、指定端口被占用、Discard、重新打开及两窗口竞争。Apply 的实际成功同时关联浏览器选路和源站标记，配置已保存但端点不可用时显示具体原因。[平台 Options 执行工单 #209](https://github.com/gcsagroup/aegis-browser/issues/209)

## 发布、并发与失败

1. Browser 捕获 Profile、StoragePartition、组、规则/身份/选路代次及 NetworkContext 实例。准备期按共同合同选择协议。监听所有权和授权状态无法确认时结束准备，保护意图继续生效。
2. 原子发布完整快照。目标 NetworkContext 对相同实例、发布序列和代次的 ACK 确认安装（`INSTALLED_ACKED`）。改变路由的 Apply 随后持久提交（`DURABLE`），并在仍匹配的上下文中完成激活（`FINALIZED`）。只有 `activeRevision` 与本次 `committedRevision` 一致且 `dispatchPermitted` 为 true，才解除该 Apply 的派发屏障并显示 ready。此前受保护请求在首次发包前有界等待或失败。版本冲突、部分安装、迟到 ACK、持久化失败或上下文失配均不放行。已提交但未能激活时按现有合同显示已保存但不可用。
3. 每个受保护请求在首次发送及重定向时重验顶层归属、目标、method 和路由组。选中一条代理链且无 DIRECT 候选。无关请求保留原生代理语义。W1 用两个顶层站点共用 CDN、不同组并发验证。只观察 partition 级 BuildConfig 或 ProxyInfo 不能关闭 W1。
4. 连接、预连接、池化流和既有认证/重试状态沿用 W1c 的完整复用键，包括 owner、组、registration ID、listener incarnation、命中组五元组（策略代次、身份代次、组选择代次、网络 epoch、基础代理配置代次）和 NetworkContext incarnation，并加入实际 transport。撤销时拦住新派发，只终止命中该撤销范围的流，等待旧实例退役后才可重用地址。Network Service 重建须恢复持久保护意图再发布新快照。失败不允许改投 HTTP、直连或再次发送已提交的业务请求。

## 交付切片与验收

| 切片 | 可执行的完成条件 |
| --- | --- |
| M-F2 · 双无认证的实际监听和可用性 | 两种入站分别向已授权上游真实转发。HTTP forward 和 CONNECT 无本地凭据或弹窗，SOCKS 仅无认证 CONNECT。非回环、端口冲突、监听者身份不明、上游失效均保持受保护路径不可用 |
| M-F1 · 注册、快照与单链 | 在固定构建通过产品入口到私有 Mojo 和实际请求。覆盖普通及私密 owner、错 partition、未知协议、重建、延迟 ACK、同端口新实例、两种协议均不可用。精确 ACK 后注入持久化失败或 NetworkContext 变更，确认屏障继续阻止首包。UI 显示实际选中运输 |
| M-F3 · HTTP 与 SOCKS 两条真流量 | 按协议分别取得 HTTP 和 HTTPS 标记、上游出口与独立原连接对照。故障时原出口新增为零。HTTP 回退只在准备期发生且保持同一授权范围 |
| W1 · 请求级隔离和原标签行为 | 同 CDN 异组并发、重定向、复用连接、冷启动、Stop/关闭、POST/PATCH 首次发送及原标签安全重试分别有 browser 回执。验证一个 Profile 撤销不会中断另一个 Profile 的合法流量 |
| M-F5 · HTTP 回退 | 单独验证能力关闭及 SOCKS 专属探测失败。原候选释放并确认后，在同一授权范围准备已准入的无认证 HTTP 监听，通过准备检查才发布，UI 与 NetLog 指向实际 HTTP。HTTP 未准入时保持阻断。通用故障、上游拒绝和误绑均不进入回退。 |
| M-F4 · 默认准入与回滚 | 在正式冻结修订、两入站本地隔离、受控出口及产品路径通过后按平台和渠道开启 Auto。禁用 SOCKS 后新登记独立选择已准入的 HTTP。旧代只有在完成退役后才可换端点 |

M-F0 交付共同合同的正式冻结修订，规范层已由修订 5 落地。A78 的两种入站分别取证。M-F6 对应 A89，A89 的 REALITY、WS+TLS 四个入出站组合保留各自的部署、认证与流量条件。完整浏览器验证记录成品身份、产品 SHA、Chromium 补丁树和本次 NetLog/源站标记。首标签白屏、崩溃、账户及百站工作沿用各自工单和失败历史。[浏览器验收 #141](https://github.com/gcsagroup/aegis-browser/issues/141) · [产品阶段一 #98](https://github.com/gcsagroup/aegis-browser/issues/98)
