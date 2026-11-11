# iOS 精确主机恢复 — 实现方案

日期：2026-11-10。状态：U1–U5 模拟器主路径已接通；K0 已冻结 Xray-core/libXray `v26.11.9` 并构建/链入 `AegisEmbeddedCore.xcframework`（slice 摘要已写入 lock）；模拟器 K live（本地 Reality 节点）已跑通。D 仍 NOT_RUN。公网站点回归见 [受阻站点回归方案](ios-access-blocked-site-regression.zh-CN.md)（opt-in，不替代 U/K/D）。体验下一台阶（本站精确 host 组，非全局拦截）见 [Site Rule Group TODO 草案](ios-access-site-rule-group-TODO.zh-CN.md)（未实施）。无节点时应用默认失败关闭。

**行为依据：** [精确主机存储 SDD](ios-exact-host-store-sdd.zh-CN.md)。SDD 决定行为，本文件确定接线、接口和验证顺序。  
**目标：** 一次用户操作准备本应用入口，只恢复点击时原标签的原失败请求，保持范围隔离、一次额度和失败关闭。  
**基线：** PR [#97](https://github.com/gcsagroup/aegis-browser/pull/97) 的 `a4f8ad139e1ace782eba629183ec6057c0407ed8`，以及该候选工作树内尚未提交的 iOS 路由改动。执行前核对实际源码，不把本地改动记到该提交上。  
**技术范围：** Swift 6、SwiftUI、WebKit、Network；沿用 iOS 18.4 最低版本。按 U1–U5、K/D 六步执行，每步完成相应检查后再推进。本文件不增加逐步审批或多代理要求。

## 1. 已核对的入口与文件职责

以下路径相对仓库根。新增类型均为待实现接口。

| 入口 | 现状与本次落点 |
| --- | --- |
| `apps/ios/AegisApp/AegisRootView.swift` / `ActiveTabView` | 已有 loadingError 和「重试」；增加代理恢复动作 |
| `apps/ios/BrowserKit/BrowserSession.swift` / `BrowserTab` | 实际导航与失败回调；增加恢复导航归属，保留方法并清理旧错误显示 |
| `apps/ios/AegisApp/AccessHostStoreCoordinator.swift` | 票据、路由意图和发送入口；增加操作状态、定向发送及异步准备 |
| `apps/ios/AccessKit/AccessNavigationRetryPolicy.swift` | 保留资格判断；消费状态必须贯穿实际恢复导航 |
| `apps/ios/AccessKit/AccessHostDataStoreRegistry.swift` | switchGeneration、专用存储、setEndpoint；不承担内核启动或就绪推断 |
| `apps/ios/AegisApp/AccessSiteProxySessionStore.swift`、`AccessSiteProxyToggleView.swift`、`AccessSiteProxyToggleModel.swift` | 开关显式携带原标签，产品状态接到同一协调器 |
| `apps/ios/AegisApp/AegisApp.swift`、`AccessSiteProxyStoreRegistry.swift`、`WebsiteEnhancementsView.swift` | 注入唯一发布器/协调器，不按窗口或设置页创建入口 |
| `apps/ios/AccessKit/AccessHTTPInboundListener.swift`、`AccessHTTPConnectSession.swift` | CONNECT 200 后目前没有数据转发；增加持有到连接结束的桥 |
| `apps/ios/AccessKit/AccessRealityPathDialing.swift`、`AccessHTTPRealityPath.swift` | 流目前只有 isOpen/close；增加可取消的异步拨号、读写 |
| `apps/ios/AccessKit/AccessXrayRuntime.swift`、`AccessXrayAssetPins.swift` | 当前是可执行文件/进程控制模型；K 使用独立身份的进程内库 |
| `apps/ios/project.yml`、`apps/ios/Aegis.xcodeproj/project.pbxproj` | project.yml 已声明 `AegisEmbeddedCore.xcframework` 搜索路径/链接/嵌入与 lock 资源；生成前需本地 `EmbeddedCore/Products`。手改 pbxproj 仍须与 yml 对齐 |
| `scripts/release/ios-access-tests.sh`、`ios_access_test_gate.py` | 类实际属于 AegisTests；补齐新增类的过滤、发现及真实运行数量核验 |
| `scripts/release/ios-access-core-tests.sh` | Opt-in K：预检 lock/节点/xcframework，跑 EmbeddedCore 相关测试，写脱敏 `k-receipt.json`；缺输入 `NOT_RUN` |

操作文档：[CI 与交付](../../development/ci.zh-CN.md)、[工作区入口](../../../WORKSPACES.zh-CN.md)、[iOS 构建入口](../../../apps/ios/README.md#build-and-test)。旧 I0 反例、冻结规格和历史收据保留原意，不改写成新范围已经通过。

## 2. 保持的行为与实现选择

- 存储键仍是浏览作用域加规范化精确 host；普通窗口共享、同一次私密会话共享，子域名和不同私密会话分别隔离。
- 标签返回自己的 originalWebsiteDataStore。专用存储不设置 matchDomains，allowFailover=false。
- 未绑定且入口不可用时保持原存储；绑定后故障保留专用存储及代理配置，仅关闭代理或结束私密会话解除绑定。
- 跨 host 主导航重建 WebView，不迁移 Cookie、DOM、表单或前进后退历史。GET/HEAD 保留实际方法；POST/PATCH 不自动重发。
- 新导航、手动刷新、停止、关标签、关代理、结束私密会话作废待发票据；切换标签/模式或进入后台不等于结束私密会话。
- 从点击起计时，包含排队，总预算 15 秒；用单调时钟读取时间和调度超时。Date 只继续用于已有租约。
- 全应用一个供 WebKit 使用的入口。采用现有 Swift 监听器加进程内拨号桥；内核不再另开 HTTP 入站。
- 默认失败关闭；测试发布器、直拨本机测试源站的 dialer、固定页面仅编入测试目标。

五个审查缺口分别由 U1（额度）、U5（真实字节流）、U2/U3（版本复用）、U4（原标签身份）、K（新资产身份）关闭。

## 3. 共同状态与接口

### 3.1 身份分工

| 身份 | 持有者与变化时机 | 校验用途 |
| --- | --- | --- |
| failureID、navigationID | BrowserTab 从真实导航记录产生；同一导航的重复失败通知沿用记录 | 哪一次失败、哪一个 URL/方法 |
| operationID: UUID | 协调器为一次自动恢复或明确用户操作产生；等待中重复点击复用 | 消费、取消、回调归属 |
| switchGeneration: UInt64 | 沿用 registry 的开关/撤销递增规则 | 票据是否有效；只允许自身开启改写本张票据 |
| endpoint.identity/generation | 全局发布器在实际准备新入口实例时分配 | 绑定监听、内核、转发资源；复用健康入口不变 |

协调器为每个 HostStoreKey 保存 `hostRevision`，只在该 host 意图变更或其私密会话结束时递增，阻止关闭后的旧结果重新发布。全局 switchGeneration 继续决定票据有效性，不作为共享监听的版本。

准备操作保存 `operationID、HostStoreKey、hostRevision、tabID、failureID?、navigationID?、deadline、state`。状态为 `preparing → sent | failed | cancelled`；无导航票据的开启操作另以 `completed` 结束。终态不能被迟到回调复活。同一 host 可有多个明确点击的等待者，每个标签最多一个未完成恢复操作。

### 3.2 恢复导航与票据

在 AccessNavigationRetryTicket 保留已有字段，增加 `failureID: UUID`、`operationID: UUID`、`trigger: AccessNavigationRetryTrigger`；trigger 为 automatic/userRetry/userToggle。消费字段仍为 retryConsumed。

BrowserKit 新增 `BrowserMainFrameFailure`，字段为 `failureID: UUID、navigationID: String、url: URL、method: String、recoveryOperationID: UUID?`。BrowserTab 以 `public private(set) var lastMainFrameFailure: BrowserMainFrameFailure?` 暴露当前快照。URL 和实际方法来自对应 WKNavigation 的可信记录，包含已允许的重定向和既有安全清洗结果；不取地址栏草稿或最后成功页面。

```swift
// BrowserHostStoreCoordinating：替换旧失败回调，增加作废通知。
func mainFrameFailed(tab: BrowserTab, failure: BrowserMainFrameFailure, error: NSError)
func pendingRecoveryInvalidated(tab: BrowserTab)

// BrowserTab：返回 false 表示目标已失效，没有发出请求。
@discardableResult
public func retryFailedNavigation(
    _ request: URLRequest,
    expectedNavigationID: String,
    recoveryOperationID: UUID
) -> Bool

// AccessHostStoreCoordinator；MainActor，同步捕获点击身份/时间，再启动 Task。
@discardableResult
func retryViaProxy(tab: BrowserTab) -> UUID?
func setProxyEnabled(_ enabled: Bool, for tab: BrowserTab)
func retryReadyTabs(operationID: UUID)
func snapshot(for tab: BrowserTab) -> AccessSiteProxyToggleSnapshot
```

retryReadyTabs 改成定向入口，只查该 operation 保存的 tabID/票据，不再无参数遍历全部标签。跨窗口可以按已捕获 tabID 查询 BrowserSession.openTabs()，不能猜“此刻活动标签”。

发送前先消费票据。BrowserTab 将 recoveryOperationID 关联到实际返回的 WKNavigation；重建 WebView、didStartProvisionalNavigation 抬高 epoch、重定向都必须保留关联。epoch 继续服务既有页面授权失效，不能因为 epoch 改变就产生新自动额度。

任何带 recoveryOperationID 的再次失败都不创建自动票据，只更新可读失败快照。用户再次明确点击才从新快照创建新 operation/ticket，不把旧消费位改回 false。重复回调沿用 failureID；未知/过时恢复操作也不得补发自动额度。用户新导航、原「重试」、停止和关闭作废旧等待；仅当前 WKNavigation 可更新快照。

### 3.3 发布器与时钟

新增 AccessKit 下的 `AccessProxyEntryPublishing.swift`、`AccessProxyEntryPublisher.swift`、`AccessPreparationClock.swift`。省略初始化器，以下字段/签名为实施约定：

```swift
@MainActor
public protocol AccessPreparationClock: AnyObject {
    var now: Duration { get }
    func sleep(until deadline: Duration) async throws
}
public struct AccessProxyEntryPrepareRequest: Sendable, Equatable {
    public let operationID: UUID
    public let deadline: Duration
}
public struct AccessProxyEntryPrepareResult: Sendable, Equatable {
    public let operationID: UUID
    public let endpoint: AccessManagedProxyEndpoint
}
@MainActor
public protocol AccessProxyEntryPublishing: AnyObject {
    var currentEndpoint: AccessManagedProxyEndpoint? { get }
    var stateChanges: AsyncStream<AccessManagedProxyEndpoint> { get }
    func prepare(_ request: AccessProxyEntryPrepareRequest) async throws
        -> AccessProxyEntryPrepareResult
    func cancel(operationID: UUID)
    func validateReady(_ result: AccessProxyEntryPrepareResult) -> Bool
    func retain(_ endpoint: AccessManagedProxyEndpoint, for key: AccessHostStoreKey) -> Bool
    func release(for key: AccessHostStoreKey)
}
```

生产时钟用 ContinuousClock 的同一原点计算 Duration；测试时钟 advance(by:) 唤醒到期等待者，取消也必须恢复 continuation。所有截止时间来自同一注入实例。

发布器串行管理 unavailable/preparing/ready/failed，资源准备在非 MainActor 执行器运行。首次准备分配 prepareID 和新 endpoint generation；不同 host、普通和私密等待者共享同一次实际准备。已有健康入口时返回新的 operationID 加原 endpoint，不把点击次数写成入口版本。

validateReady 同步检查：operation 仍登记、身份/版本等于当前 ready 实例、监听实际 ready 且属于该实例、运行时健康、桥工厂已安装、地址为 127.0.0.1、端口非零。不能仅信任调用方填入的 bridgeAttached=true。U 的替身提供等价可控状态，生产构建不能选择它。

prepare 返回后保留该 operation 的登记，直到协调器消费结果或取消；不能在返回前删除，导致 validateReady 必然失败。retain 仅接受当前健康实例，按 HostStoreKey 幂等登记资源消费者；发布期间以当前实例替换该 key 的旧引用。release 由关闭 host、私密结束或存储淘汰调用。

第一次实际准备的 deadline 不因后来点击延长；每个等待者另受自己从点击起的 15 秒限制。取消一个等待者不停止其他等待者或已登记 host 使用的入口；没有等待者和消费者时才回收无主资源。成功提交后也调用 cancel(operationID:) 移除等待登记，它只移除等待者，不撤销 retain 的引用。

### 3.4 同次开启不能作废自己的票据

以下步骤在同一次 MainActor 状态变更中完成，中间不 await：

1. 捕获点击标签的 scope、精确 host、failure/navigation 身份；同标签同失败已有 preparing 操作则复用，不续时、不新增额度。
2. 建立 operation/ticket，记录点击时刻和 `deadline = clock.now + .seconds(15)`。
3. 若意图尚未开启，调用协调器已有开启路径一次，由它调用 registry.setProxyEnabled(true)；已开启则不重复递增。
4. **仅把本次 operation 拥有的未发出票据的 switchGeneration 改为这次开启后的值。** 不修改 URL/方法/navigation，不复活已取消票据，不批量改写其他标签。
5. 登记等待、启动发布器。意图可以开启，未 ready 时不能创建专用存储或发出恢复请求。

返回后复核 operation 非终态、scope 存活、hostRevision 未变、意图开启、deadline 未到及 validateReady。全部成立且 retain 成功，才由协调器调用 setEndpoint，再由 retryReadyTabs(operationID:) 复核 tab/failure/navigation、开关版本和消费位，先消费后发送。校验、retain、发布与消费之间不 await，随后移除等待登记；取消/终态失败不修改其他仍有效消费者的 endpoint。

其他开关操作再次改变版本时，不允许第二次“修补”旧票据。host 意图仍有效时可发布入口，但过时票据不发送；无失败票据的普通开启只准备入口，不主动刷新。自动恢复仅使用已经就绪且意图开启的入口，不开启代理或启动准备。

## 4. 六步实施

### 第一步 U1：失败页与贯穿导航的一次额度

修改 BrowserSession.swift、AegisRootView.swift、AccessHostStoreCoordinator.swift、AccessNavigationRetryPolicy.swift。新增 `Tests/AegisTests/AccessNavigationRecoveryTests.swift`、`AccessProxyRecoveryViewTests.swift`。

- [ ] 先写实际 BrowserTab/协调器回归：首次失败 → 自动恢复 → 再次失败，发送计数仍为 1；用户再点一次变 2，再失败不能变 3。原纯策略测试不能替代这条回调链。
- [ ] 实现 3.2 的导航关联、作废通知与定向发送。恢复使用 URLRequest，HEAD 保持 HEAD；只接受当前 WebView 和对应 WKNavigation 回调。
- [ ] 增加 `@Published public private(set) var loadingErrorAllowsProxyRetry = false`。要求可信 HTTP(S) 主导航、可恢复网络失败及 GET/HEAD；POST/PATCH 只提示重新提交。复用并检查 BrowserNavigationFailure 的分类，固定取消、证书和策略拒绝反例。
- [ ] 两个 load 重载、停止、新导航和成功路径处理错误文案及按钮标志；不能让成功页继续显示旧失败。恢复再次失败时可重新显示代理按钮。
- [ ] 在现有「重试」旁增加 `page-load-proxy-retry`，捕获该 tab 调 retryViaProxy(tab:)。原「重试」仍调用 tab.reload()。测试以 SwiftUI hosting 注入动作；无发布器时产品入口返回失败关闭结果。
- [ ] 测同 host 新路径、HEAD、POST/PATCH、重复回调、停止、旧 WebView 回调和等待中重复点击；重复点击得到同一 operationID。
- [ ] 按第 5 节补齐测试过滤与预期用例清单，再执行 `AccessNavigationRecoveryTests,AccessProxyRecoveryViewTests,AccessHostStorePolicyTests`，确认新增回调链实际运行。

### 第二步 U2：应用级唯一发布器与入口复用

新增 3.3 的文件、`AccessKit/AccessFailClosedProxyEntryPublisher.swift`、`Tests/AccessKitTests/AccessProxyEntryPublisherTests.swift`；修改 AegisApp.swift 和协调器。替身放 `Tests/AegisTests/Support/AccessProxyEntryTestSupport.swift`。

- [ ] App 只构造一个发布器并注入唯一协调器；无内核资产时使用立即抛 AccessSiteSessionError.nodeUnavailable 的实现。
- [ ] 实现单次实际准备和多等待者；缓存健康资源及 endpoint，不缓存上次用户操作的整个返回值。
- [ ] 测 A host 返回 operation=A、generation=G，B host 返回 operation=B、generation=G；分别发布各自 HostStoreKey，监听启动次数仍为 1。
- [ ] 测错误 operationID、空身份、错误地址/端口、旧版本、监听失效、内核退出、桥未安装；均不能发布 ready。
- [ ] 协调器唯一订阅 stateChanges；故障只影响使用相同身份/版本的 host，保留已应用代理配置。旧代次延迟故障不能覆盖新入口。
- [ ] 测跨窗口/普通/私密共享物理入口但独立存储和取消；结束一个 scope 不停止其他消费者。
- [ ] 执行 `AccessProxyEntryPublisherTests,AccessHostStorePolicyTests`。测试 ready 仅指 U 入口。

### 第三步 U3：15 秒、终态和票据版本

修改发布器、协调器；新增 `Tests/AegisTests/AccessProxyRecoveryCoordinatorTests.swift`，扩展 U2 测试。

- [ ] 实现 3.4。UI 在启动 Task 前捕获点击时间，排队消耗相同预算。
- [ ] 每个等待者有时钟到期任务，共享准备另有截止任务；不能只在 prepare 返回后比较时间。发布器永不返回也必须在 15 秒产生失败结果。
- [ ] 超时先提交终态再取消底层工作。UI 返回不能等待不合作的底层调用；迟到结果按 prepareID 回收自身资源，不能关闭后来创建的实例。
- [ ] preparing 进入 failed/cancelled 后，同 generation 成功也不能变回 ready；新实际准备使用更大 generation。registry 目前仅拒绝更小版本，不足以代替这一终态检查。
- [ ] 关闭 host 时先提高 hostRevision、作废票据，再解除绑定和取消等待；私密结束按 scope 处理。新导航/停止/关标签只取消其等待者，不误伤其他 scope。
- [ ] 测试时钟验证：14.999 秒成功、达到 15 秒超时、排队 10 秒仅余 5 秒、重复点击不续时、超时/关闭后迟到成功、旧失败晚于新 ready。
- [ ] 固定版本反例：自身开启 g→g+1 只更新本张票据；其他票据保留旧版本；等待中另一次开关再递增则本票据被拒绝。
- [ ] 执行 `AccessProxyRecoveryCoordinatorTests,AccessProxyEntryPublisherTests,AccessNavigationRecoveryTests`；断言无额外重载、无未就绪存储创建、已绑定配置不被清空。

### 第四步 U4：开关携带原标签、显示同一产品状态

修改 AccessSiteProxySessionStore.swift、AccessSiteProxyToggleView.swift、AccessSiteProxyToggleModel.swift、AccessSiteProxyStoreRegistry.swift、WebsiteEnhancementsView.swift 及 App 注入处。

```swift
// AccessSiteProxySessionStore 产品接口
func setProxyEnabled(_ enabled: Bool, for tab: BrowserTab)
func snapshot(for tab: BrowserTab) -> AccessSiteProxyToggleSnapshot
```

- [ ] Toggle setter 传该视图保存的 tab，无 tab 时禁用；移除产品路径仅凭 URL/scope 猜标签的重载。首次失败未提交 URL 时从该 tab 可信失败快照解析 host。
- [ ] SessionStore 作为产品协调器的 UI 适配器；按钮和开关读取同一 HostStoreKey 意图、准备结果、附件状态。协调器发布 revision，跨窗口及同私密 scope 的适配器均订阅，不等设置页 onAppear 才建立依赖。
- [ ] 产品开启不再走旧 applyToggle → controller.enable 完整同步准备链后又调用发布器。旧控制器及 AccessSiteProxyFailClosedOrchestrator 保留供原组件/DEV 路径；其 ready 无权发布新入口。新产品默认发布器仍失败关闭。
- [ ] 开启且有可恢复失败时以 userToggle 复用 3.4；无失败票据则只准备入口、不刷新。关闭由同一协调器撤销 host，各标签回到自己的原存储。
- [ ] 意图与连接分开：未接入使用“尚未接入代理，当前页面仍使用原连接”；已绑定后失效说明代理不可用且保持绑定，不误报回退。文案进入现有本地化流程。
- [ ] 测同 host 两标签、两个窗口、点击后换活动标签/同 host 路径、关原标签、结束私密会话。只有原操作仍有效的 tab 发请求；未点击标签重载计数为 0；失败页按钮和开关显示相同意图。
- [ ] 执行 `AccessSiteProxyToggleModelTests,AccessProxyRecoveryCoordinatorTests,AccessNavigationRecoveryTests`。

### 第五步 U5：CONNECT 后的真实字节转发

修改 AccessRealityPathDialing.swift、AccessHTTPRealityPath.swift、AccessHTTPInboundListener.swift、AccessHTTPConnectSession.swift、AccessHTTPConnectParser.swift；新增 `AccessKit/AccessHTTPTunnelBridge.swift`。同步 AccessHTTPSRealityPath.swift 及已有测试，避免共享协议变更留下不可编译调用。

```swift
public protocol AccessRealityPathStream: AnyObject, Sendable {
    var isOpen: Bool { get }
    func read(maxBytes: Int) async throws -> Data? // nil=EOF，非 EOF 不返回空块
    func write(_ data: Data) async throws        // 返回表示整个块已接收
    func close()                               // 幂等，唤醒待完成读写
}
public protocol AccessRealityPathDialing: AnyObject, Sendable {
    func dial(host: String, port: UInt16) async throws -> any AccessRealityPathStream
}
```

AccessHTTPRealityPath.open 保留原参数，改成 `async throws -> (Handle, any AccessRealityPathStream)`；HTTPS 同步异步化。注册、租约、运行状态及拒绝 direct 的校验保留；fake 实现可读写队列，不能只返回 isOpen=true。

- [ ] 新增 `Tests/AccessKitTests/AccessHTTPTunnelBridgeTests.swift`：分片读写、慢写、拨号失败、EOF、取消、listener stop、内核退出；失败关闭双方，不切系统连接。
- [ ] CONNECT 解析结果携带头结束后的剩余 payload，限制只计算 header；不丢弃与头同批到达的首段隧道字节。
- [ ] 200 成功写出后调用 open。listener 在 `bridges[ObjectIdentifier(connection)]` 持有 bridge 至结束，不在 established 回调删除唯一持有者。
- [ ] 两方向各一条串行泵，每方向最多一个 32 KiB 在途块；写完才读下一块，先转发剩余 payload。EOF 排空已接收块后关闭双方；错误/取消立即幂等关闭，不宣称未实现的长期半关闭支持。
- [ ] listener 构造要求转发依赖，旧准入测试显式注入测试桥；默认生产路径不能留下 200 后空隧道。
- [ ] AccessHostWebKitRouteTests 使用实际 BrowserTab、协调器和该 listener；dialer 只接本机可控源站。HTTPS 使用限定于测试的信任配置，不修改应用证书校验。
- [ ] HTTP 与 HTTPS 分别记录实际请求形态。若 WebKit 对 HTTP 使用 absolute-form，同一 listener 新增 `AccessHTTPForwardSession` 分流，经同一 dialer 转发；保留方法/体、校验 authority 与 Host、移除逐跳代理头，按 Content-Length/chunked 边界处理单请求后关闭，不把另一 authority 的请求当隧道 payload。新增 `AccessHTTPForwardSessionTests` 覆盖边界、方法和请求走私反例；缺失时 HTTP 行为记 FAIL，不改 URL 为 HTTPS 绕过。
- [ ] S1/S5/S6 用真实请求断言：原 URL 一次、跨域资源到同入口、其他 host 标签不进入、未就绪新标签保留原存储、故障后保留代理配置且原连接源站计数不增加。用随机 nonce 排除缓存/旧请求。
- [ ] 执行 `AccessHTTPTunnelBridgeTests,AccessHTTPConnectTests,AccessHTTPInboundListenerTests,AccessHTTPRealityPathTests,AccessHTTPSRealityPathTests,AccessHostWebKitRouteTests`，以及实际需要的 AccessHTTPForwardSessionTests。替身和固定页面仅编入测试目标。

U5 通过仍只完成 U，不能证明 VLESS 出口。

### 第六步 K/D：进程内固定资产与设备记录

#### K0：先建立可核验资产来源

旧 realityVisionCoreBinaryIOSArm64DigestHex 对应 core_binary/ios-arm64，不用于新库。2026-11-10 查询 XTLS/Xray-core 的 Contents API 时，旧源码 pin `db72a9c96f3c3ea1b6f592d66b7bb396d1cb1ed4` 返回“找不到该 ref”。这仅说明该仓库无法解析此输入，不能据此虚构新摘要或声称已具备可构建来源。

新增 `apps/ios/EmbeddedCore/` 存桥源码和依赖锁，`apps/ios/EmbeddedCore/embedded-core-lock.json` 存资产身份，`AccessKit/AccessEmbeddedCoreManifest.swift` 校验，`scripts/release/build-ios-access-core.sh` 构建。选择自有薄桥调用 Xray-core 的 StartInstance、Dial 和实例关闭；当前官方 [core/functions.go](https://github.com/XTLS/Xray-core/blob/main/core/functions.go) 仅作接口调查依据，main 不是构建 pin。JSON 加载模块必须显式注册。

- [ ] 核实旧提交的真实来源，或提出新的可解析源码候选并冻结完整 SHA；记录桥源码 tree、go.mod/go.sum、Go/绑定工具/Xcode/SDK。来源无法核实则 K0 BLOCKED、K NOT_RUN，U 继续。
- [ ] 构建 AegisEmbeddedCore.xcframework，含 ios-arm64 和 ios-arm64-simulator；两个 slice 分别记录 SHA-256，App 只链接一次 Go runtime。
- [ ] 构建脚本接口为 `--lock <锁文件> --output <独立产物目录>`；拒绝无 SHA、未解析 ref、缺依赖锁或校验不匹配，不跟随 latest/main、不覆盖旧 pin。先记录实际构建摘要，再冻结新资产清单。
- [ ] 链接前校验对应 slice。静态链接后不再查找旧 executable；桥编入只读 ABI/source/slice 身份，与随包 manifest 核对。最终 App Mach-O/包摘要另列收据，不冒充预链接库摘要。
- [ ] 更新 project.yml 可选内核装配并生成工程；无已核验资产仍可构建失败关闭版本，未核验库不得参与链接。

#### K1：运行时与流适配

新增 `AccessKit/AccessEmbeddedCoreControlling.swift`、`AccessEmbeddedCoreAdapter.swift`、`AccessEmbeddedRealityDialer.swift`；修改 AccessXrayRuntime、配置 builder 及发布器装配。

```swift
public protocol AccessEmbeddedCoreControlling: AnyObject, Sendable {
    var isRunning: Bool { get }
    func start(configData: Data) async throws
    func dial(host: String, port: UInt16) async throws -> any AccessRealityPathStream
    func stop() async
}
```

- [ ] 桥 ABI 提供 start/status/stop、带拨号 ID 的 dial/cancelDial、流 ID 的 read/write/close。Task 取消传至拨号 context 或关闭流；阻塞读写在工作执行器，不能占 MainActor 或阻止取消执行。
- [ ] Runtime 注入进程内实现，异步 start/stop，健康状态反映实际生命周期。停止后新建实例，不假定已关闭实例可再次 Start。进程控制替身留测试支持，更新 Runtime/RealityPath 调用；应用不启动子进程。
- [ ] 使用唯一 reality_vision 出站，无 DIRECT/freedom 备用、无第二个 HTTP 入站；Swift dialer 经 core.Dial 取得流。域名交给内核，不用 URLSession 获取目标内容，不放宽目标 TLS。
- [ ] readiness 联合检查 manifest、实例、监听、桥及当前代次；监听或内核故障立即发 failed，保留已绑定代理配置。
- [ ] 节点来自运行环境的私有输入，无节点/无资产/身份不符保持失败关闭。凭据、Cookie、节点原文不入库、不打印；DEV 节点验证不代表正式托管接入。
- [ ] 单元测试新增 `Tests/AccessKitTests/AccessEmbeddedCoreAdapterTests.swift`；真实节点测试放 `Tests/AccessIntegrationTests/AccessEmbeddedCoreIntegrationTests.swift` 和独立 `AegisAccessIntegrationTests` target，不进入默认 U 发现列表。

K 收据必须同时包含本次 CONNECT host、内核 slice 摘要、出口/源站关联 nonce 和真实响应字节摘要。端口可连、CONNECT 200 或 stub 内容不能单独通过。

#### D：同一候选的设备请求

- [ ] 正式 K/D 使用同一设备 App 构建、设备 slice 和进程内入口实例：先取得 K 的出口观测，再由失败页动作重复同一目标作为 D；不重启入口，identity/generation 相同，各次 nonce 分别记录。
- [ ] 先做模拟器 K 时仅记模拟器 K；设备必须重新取得设备 slice 的配套 K。不能合并不同 slice 摘要，也不能把两个进程里碰巧相同的 generation 当同一入口。
- [ ] 缺节点记 K NOT_RUN，缺真机记 D NOT_RUN；换包/重启入口后重新建立配套记录，旧收据不改写。
- [ ] 设备复测超时、关闭取消、故障不直连及私密结束。使用现有设备签名/安装入口；上传、TestFlight、商店和公开发行不在本方案内。

## 5. 执行命令和测试门

编写文档不运行原生构建。实施前按工作区/iOS 文档核对真实路径、容量、锁、已有构建进程；使用独立 run/DerivedData 目录，不清理共享输出。可先执行已有 `bash apps/ios/scripts/run-simulator-tests.sh --dry-run` 检查入口，它不是测试通过证据。

U1 先补齐现有测试脚本，再使用下列命令：

- 新增 `AEGIS_IOS_ACCESS_TEST_CLASSES` 逗号分隔过滤；为空仍跑既有 U/组件套件，未知类或零匹配非零退出。
- discovery 与 ios_access_test_gate.py 共用被选测试文件清单；新增恢复、UI hosting 和 WebKit 类全部进入预期集合，不能只增加 -only-testing。
- 独立真实节点目标不进入默认发现列表。扩展现有 test_ios_access_test_gate.py，验证缺失、失败、跳过和零匹配的拒绝。

```bash
# 在实际候选仓库根运行，先替换 UDID 与独立证据目录。
AEGIS_IOS_DESTINATION='platform=iOS Simulator,id=<已核对的UDID>' \
AEGIS_IOS_ACCESS_RUN_ROOT='<本次独立证据目录>' \
AEGIS_IOS_ACCESS_TEST_CLASSES='AccessNavigationRecoveryTests,AccessProxyRecoveryViewTests,AccessHostStorePolicyTests' \
bash scripts/release/ios-access-tests.sh

python3 -m unittest discover -s scripts/release -p 'test_ios_access_test_gate.py'
```

后续替换为各步所列类名。真实过滤格式是 `AegisTests/<类名>`，不存在 AccessKitTests 产品目标。每步先确认新增用例能揭示缺口，再实现和验证实际执行结果；输入未变时复用结果。

K 新增显式脚本 `scripts/release/ios-access-core-tests.sh --destination <设备destination> --lock <内核锁文件> --node-file <私有文件> --output <证据目录>`：预检权限/身份，选择 AegisAccessIntegrationTests/AccessEmbeddedCoreIntegrationTests，保存 xcresult 和脱敏收据；缺输入输出 NOT_RUN 且非零退出。不打印节点、不自动签名上传、不把模拟器结果标成设备结果。

| 规格/场景 | 必须执行的证据 |
| --- | --- |
| R1 | U1：按钮与网络失败正例，取消/证书/策略/POST/PATCH 反例 |
| R3、S2/S3/S4 | U1/U3：重复失败、再次明确点击、同 host 新导航、HEAD、旧回调 |
| R2/R6/R8、S8 | U2/U3：缓存复用、终态、无返回超时、排队、取消、自身票据更新 |
| R4/R5、S7 | U4：两标签/跨窗口、意图与连接区分、各自原存储、私密结束 |
| S1/S5/S6 | U5：原 URL 一次、子资源、其他 host、新标签、故障无原连接请求 |
| R7 | K/D 独立记录，同一候选及可核对的设备 slice、入口身份/版本 |

## 6. 收据、完成界限与当前状态

U/K/D 分别写入本次独立 `.artifacts/ios-access-recovery/<候选标识>/U/`、`K/`、`D/`。提交脱敏索引时沿用 `docs/audit/evidence/ios-access-product-phase1/`，不提交节点、凭据和完整敏感 URL。

记录源码 SHA/tree；有本地修改时增加 tracked diff 与未跟踪源码清单摘要；App 构建/包摘要；目标、OS、设备；实际用例和数量；xcresult；入口 identity/generation；operationID/nonce；内核 manifest 及实际 slice 摘要。只写 HEAD 不足以标识当前有未提交源码的候选。

| 阶段 | 完成含义 | 当前工作树（2026-11-10） |
| --- | --- | --- |
| U1–U5 | 页面经指定本机入口恢复，范围/额度/失败关闭得到验证 | 模拟器 Access 套件绿（含恢复/WebKit）；证据在 `.artifacts/ios-access-k-final/` |
| K0 | 可解析来源、锁定构建与进程内资产身份齐全 | `embedded-core-lock.json` 为 `verified_build`，双 slice SHA 已冻结；Products 为本地构建产物（gitignore） |
| K | 本次响应来自进程内固定内核对应的 VLESS 出口 | 模拟器 live 绿（`.artifacts/ios-access-live/`）；正式脱敏 K 索引仍待按审计目录落盘 |
| D | 与配套 K 同一候选、设备内核和入口实例的真机请求 | NOT_RUN |
| R | 受阻公网站点 opt-in 回归（Gold/Full） | 仅有[设计稿](ios-access-blocked-site-regression.zh-CN.md)；未接线，不进默认测试门 |
| G | 本站规则组 / 本站自动连接 | 见[自动连接设计](ios-access-site-auto-connect.zh-CN.md)。导航身份、错误白名单、渠道容量、单等待者取消、规则发布、无人值守主导航恢复，以及组内代理/组外源站正向回执已在模拟器通过（2026-11-11）。同页分流不在首版；探测只生成建议、不在导航里执行。工作树未提交 |

U 与模拟器 K 通过后可更新 PR #97 说明与代码；D 未跑不得宣称设备闭环。R/G 通过不能写成 U/K/D。更新 PR 不等于独立审查、required checks、合并或发行通过，继续遵守 CI 指南及当时任务授权。

不修改 SDD、冻结 spec.zh-CN.md、macOS/Android，不恢复其他暂停平台或清理历史产物。
