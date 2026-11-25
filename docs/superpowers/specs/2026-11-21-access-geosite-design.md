# 国内加速中的网站加速设计

设置中的统一入口暂名「国内加速」。点开后直接看到「网站加速」的「手动」和「智能」两种模式。未来的「位置加速」与「网站加速」在同一页并列。本期界面只显示已能使用的功能。首个可安装交付为 iOS DEV，随后完善 macOS DEV，最后接入 Android。Hysteria 2（HY2）另行验证传输故障恢复。[TDD 实施计划](../plans/2026-11-21-access-geosite.md)

设计基线为 `quinn521/aegis-browser:develop@e18106b84c56589a69faa1b0965e696caea2cb8c`。产品决策建立在 iOS WebKit 顶层导航试件之上。

## 规则来源与准入

GeoSite 提供域名集合，用户所选模式和浏览器策略决定动作。首期使用预编译、可审计的小分组。订阅仍按 A41 只导入节点，第三方列表名称无法授予访问、放宽防护或直接生成 REJECT。[Access 产品合同](../../plans/access-service-v1.0/spec.zh-CN.md)

| 用途 | 核对结果 | 处理 |
|---|---|---|
| 运行时格式候选、iOS 试件 | V2Fly `dlc.dat`，版本 `20261121064510`，2,408,868 字节，1,557 组。完整 `DEBIAN` 只有 `domain:debian.org` 和 `domain:dotdeb.org`，均无属性 | 两条均通过固定 Chromium 的 ICANN 与 PRIVATE 后缀检查。作为 iOS DEV 的首组，供后续平台复用 |
| 被否决的候选 | `WIKIMEDIA` 的 18 条中含 `toolforge.org`、`wmcloud.org`、`wmflabs.org`，三者本身都是该版本的私有公共后缀 | 拒绝整组，防止自动覆盖其他租户 |
| 已有能力测试语料 | 上游 #98 的 XTLS **标准版** `20261117015116`，`blocked-in-cn` 有 4,389 条唯一规则、4,376 个字面主机候选 | 沿用现有顺序，架构和界面就绪后先进行 iPhone 真机及原 100 站冒烟，再单独评估此语料。保留受限样本及分母；该标签不表示广告拦截 |

V2Fly 输入 SHA-256 为 `b1e803c6b8d02def0865b1b4953ee391c562478d8ff7ee3e8b621a2d15fb7ed2`。Chromium `155.0.8059.80`，提交 `43a195105613ac83c21d3f14de279f4a045c7da0` 的 PSL 文件 SHA-256 为 `4155611645690529d1bbea0cfe653b0c45f63b028e0ba039de29a97edc3204ca`。两条 `DEBIAN` 规则按字符排序，每条写作 `domain:<host>` 并以 LF 结尾，36 字节的 SHA-256 为 `d865d67c829d0f13bf508e152ef402d5d9634227ed12a8b49434d231baf5a643`。这个摘要标识本次提取，打包时另计资产摘要并保留 MIT 声明。[V2Fly 发行版](https://github.com/v2fly/domain-list-community/releases/tag/20261121064510) · [分组源文件](https://github.com/v2fly/domain-list-community/blob/ffb513217b9cb22835eb74a39a907d77742ce68f/data/debian) · [许可证](https://github.com/v2fly/domain-list-community/blob/ffb513217b9cb22835eb74a39a907d77742ce68f/LICENSE) · [Chromium PSL](https://chromium.googlesource.com/chromium/src/+/43a195105613ac83c21d3f14de279f4a045c7da0/net/base/registry_controlled_domains/effective_tld_names.dat) · [#98 语料记录](https://github.com/gcsagroup/aegis-browser/issues/98#issuecomment-6947679716)

离线编译器读取已展开 DAT，以平台 URL 解析器生成的规范主机比较。`full` 仅命中精确主机，`domain` 命中主机及 DNS 标签边界上的子域。比较忽略 ASCII 大小写和单个末尾根点，IDNA 使用规范化 ASCII 主机。首期分类只接受受支持网络 scheme 的 DNS 名，排除 IP、环回、本地域、空标签及公共后缀。属性、keyword、regexp、未知类型、截断、超限或完整性失败均拒绝整组。输入文件、来源、许可、版本、编译器、PSL、规则数量及输出摘要写入清单。首版随 DEV 构建装入明确获准的清单，浏览器请求路径只读不可变索引。

今后更新先在暂存区完整验证签名、允许的来源、范围、数量和大小，再编译并原子发布。坏包保留仍获授权的有效旧版。关闭自动分流或回退有效旧内容时发布新的 generation；撤销、过期或授权变化使旧决定失效。保留手动设置和用户已同意的范围，新增域名超出已同意快照时需确认后采用。诊断记录模式、组、版本、决策来源、generation 和脱敏原因，常规日志不采集完整浏览历史。

## iOS 先行试件与证据边界

最初的 XCTest 试件通过适配器把分类器接到 `BrowserTab.prepareProxyNavigation`。产品版已移除该适配器，测试和普通 DEV 窗口都由同一协调器求值，只在测试内把固定规则投影到保留域名。生产 `AccessHostStoreCoordinator` 负责准备、租用及选择 store，`AccessHostDataStoreRegistry` 绑定实际 `WKWebsiteDataStore`。同一标签页通过 `loadFromAddressBar` 依次访问四个 `.geosite.invalid` 镜像。原设置 store 和受管 store 各连一个不可故障转移的回环 CONNECT 监听器，监听器记录 authority 后终止。对同一目标要求预期出口有记录、另一出口为零。镜像保留标签关系，真实域名只做离线分类。[浏览器入口](../../../apps/ios/BrowserKit/BrowserSession.swift) · [协调器](../../../apps/ios/AegisApp/AccessHostStoreCoordinator.swift) · [store 注册表](../../../apps/ios/AccessKit/AccessHostDataStoreRegistry.swift) · [Apple 的 store 代理 API](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/proxyconfigurations-cdc1)

模拟器已验证用户发起的顶层 GET 分类和 CONNECT 选择，也覆盖了命中组但入口准备失败时回原设置的次数为零。原设置可包含用户的系统代理。产品版另有真实设置页回归。受控 HTTP 页面完成重定向后，跨域资源随已绑定的 store，跨 store 提交的 POST 也没有发往另一出口。受信 landing 仍须核对来源与 generation。iframe、worker、独立下载、公网 TLS、物理 iPhone 和真实网站速度各需另行取证。[iOS 精确主机设计](../../plans/access-service-v1.0/ios-exact-host-store-sdd.zh-CN.md) · [模拟器测试](../../../apps/ios/Tests/AegisTests/AccessHostRecoveryWebKitTests.swift)

## iOS DEV 产品合同

设置页标题为「国内加速」，在「网站加速」下直接显示两个模式；「隐藏地理位置服务」继续展示既有服务用量。选择「智能」即开启类别选路，选择「手动」即关闭它。普通窗口共享偏好。新装、旧版本升级、无法识别的模式均使用「手动」和原有隐私策略，保留独立的用户选择。入口展示和路由执行均核对受信任 DEV 渠道及普通窗口身份。私密会话继续使用自身的路由与存储。

页脚仅提示所选模式（「自行选择要加速的网站。」或「当前仅自动加速 Debian 相关网站。」），服务未配置时另显示「加速服务未配置。」。

| 普通窗口的顶层导航 | 生效行为 |
|---|---|
| 用户显式指定本站 | 用户可以为地址栏显示的已提交页面或本次失败的安全顶层导航选择连接。使用服务或使用原连接优先。清除后重新按当前模式求值。使用原连接仍可能经过系统代理 |
| 手动，未指定本站 | 沿用既有位置保护、手动站点与恢复授权。切回手动不批量重载已打开的页面 |
| 智能，命中已启用的固定组 | 由同一账户下可用的服务准备、保留并绑定该主机的 WebKit 存储。入口不可用或准备超时则显示失败，原连接收到该请求的次数须为零 |
| 智能，未命中，且无独立授权 | 使用原连接，跳过原先可选的全站首次准备。明确选择「智能」会改变旧的默认首次尝试；界面需在选择时说明 |
| 底层导航仍在准备时改变选择 | 重新验证当前标签、导航、站点和授权代际；先前已失效的结果不能绑定、重发或开启手动选项。只在既有安全规则允许时处理无正文的 GET/HEAD，其他请求需用户重新提交 |

分类器只读已审核的两个根域。真实 App、准备入口、store 选择和测试使用同一套判断。类别命中不写入手动授权。一个已加载文档内的子资源共用该文档的 WebKit 出口。不同顶层站点可使用不同出口。「国内加速」是统一入口的暂定名称；首组覆盖 Debian 项目及相关软件源，可验证连接选择，公开网站访问成功率和速度需独立测量。[WebKit API](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/proxyconfigurations-cdc1) · [固定分组原文](https://github.com/v2fly/domain-list-community/blob/ffb513217b9cb22835eb74a39a907d77742ce68f/data/debian)

## macOS DEV 的手动与智能模式

| 入口 | 用户动作 | 浏览器行为 |
|---|---|---|
| 手动，默认 | 当前网站「使用服务」「使用原设置」「清除并继承」 | 按既有 site、website、Profile 所有权处理显式决定；显式使用原设置能覆盖更宽的类别，清除后恢复继承 |
| 自动分流，按 Profile 主动启用 | 选择准入组并确认覆盖范围，可随时关闭 | 无显式覆盖时按当前请求目标 host 命中组选用已授权 Access；未命中保留原生代理配置。空分组、初次安装及旧版本迁移默认手动 |

企业和浏览器安全决策先行。保留 `EvaluateAccessPolicy` 现有 site → website → Profile 优先级、冲突及失败语义，显式 Profile 同样高于类别。只在手动层确实未作决定时查分类索引，类别的 `ProtectionOverride` 固定为 `kNone`。命中需要可用的同 owner 入口；准备、验证或授权失败时有界等待或明确失败。每个请求、重定向逐跳按可信请求所有者、目标、Profile 和 partition 重判，不能由渲染端指定 owner。普通与 OTR/Guest 配置、generation 和连接池遵守既有隔离。发布使用既有准备、精确 ACK、持久提交、完成顺序；迟到 ACK、重启和回滚不可扩大访问。[现有求值器](../../../apps/browser/overlay/components/aegis_access/access_policy_evaluator.cc) · [请求与发布合同](../../plans/access-service-v1.0/w1a-request-routing-design.zh-CN.md)

GeoSite 决定是否使用 Access。若结果为 `preserve_native`，原生 Options 的 Auto Switch 才能选 System、PAC 或 Fixed 基础代理；“使用原设置”因此可能经过原有代理。本地 HTTP/SOCKS 入站选择和远端节点健康轮换分别发生在各自层。后端须从可信构建身份确认 macOS Debug/DEV、无冲突、Internal Options 已授权，再绑定实际 BrowserContext、实例与分区。现有 Options 也接受 Alpha，新能力须分别保护展示、读取、写入、导入、恢复及激活。Alpha、Beta、Stable、unknown、冲突身份均不可启用。#209 的现有 owner、FIRST、预算及当前 Options 交付顺序继续生效。[构建能力](../../../apps/browser/overlay/components/aegis_access/access_options_capability.h) · [Options 设计](../../plans/access-service-v1.0/macos-access-options-sdd.zh-CN.md) · [#209](https://github.com/gcsagroup/aegis-browser/issues/209) · [独立 Options PR](https://github.com/quinn521/aegis-browser/pull/400) · [后期公共管理入口 #142](https://github.com/gcsagroup/aegis-browser/issues/142)

## Android 接续

macOS 完成后，在 Android Chromium 的原生设置接入同一「国内加速 → 网站加速」界面。可信 Profile、Incognito 隔离、站点覆盖、请求优先级及固定目录与 macOS 对齐。用 Android 自己的浏览器和设备验证实际出口、重定向、撤销与非 DEV 拒绝。独立的原生 Options 工作有既定 owner 和 ARM 构建前提。[Android 原生工作单](https://github.com/gcsagroup/aegis-browser/issues/210)

## Hysteria 2 的独立受控实验

HY2 可以经客户端至节点的 QUIC/UDP 承载浏览器 TCP CONNECT。它不改变 GeoSite 决策，也不授予页面通用 UDP。固定 Xray `v26.11.9` 注册了 hysteria v2；Aegis iOS 的出站类型目前只接受 `reality_vision`，Go 桥按 TCP 目的地址 dial，单实例 `Stop` 会关闭已有流。macOS 的 `SelectedOutbound` 和控制协议当前构造 VLESS/REALITY，服务计量补丁的身份绑定在 VLESS 入站。原生支持该协议只解决了可行性的一部分。[协议](https://hysteria.network/docs/developers/Protocol/) · [固定 Xray 配置](https://github.com/XTLS/Xray-core/blob/676eaf66f8f05d4d558ee7a74b4736623d3feeb9/infra/conf/hysteria.go) · [iOS 出站](../../../apps/ios/AccessKit/AccessOutboundProfile.swift) · [Go 桥](../../../apps/ios/EmbeddedCore/bridge/bridge.go) · [macOS 选择器](../../../apps/browser/overlay/chrome/browser/aegis/access/access_local_core_manager.cc) · [控制协议](../../../apps/browser/overlay/chrome/browser/aegis/proxy/access_core_control.proto) · [计量补丁](../../../services/access_account/xray_meter/xray.patch)

实验默认关闭。先用可控时钟和回环端点验证调度，再用自有 QUIC 服务、同账户签名候选、可追踪租约和自有 marker 验证实传。可复用浏览器既有入口。仅主传输故障经既有两轮确认后允许尝试 HY2，单纯网站 403/429/5xx、证书、认证、配额、撤销、本机离线或用户锁定不能触发跨协议切换。沿用单候选、Profile 与浏览器共享预算及冷却。新 generation 经确认并持久化后，只接管新连接，旧流排空或明确失败，不重放请求。可选 iOS 试件要证明旧流生命周期独立；单实例全局 Stop/Start 无法提供这种保证。只有 QUIC 往返、目标 marker、双向字节与账户额度/撤销都能对应，才能评价服务 fallback。独立的回环试件已通过正向 TCP CONNECT 及三组负对照。账户计量、自动切换、旧流排空及 iOS 端仍须分别取证。[受控传输回执](https://github.com/gcsagroup/aegis-browser/issues/213#issuecomment-7062599250)
