# iOS WebKit 保护实施方案

日期：2026-10-11。适用项目：`apps/ios` 的 SwiftUI / WKWebView 浏览器，最低 iOS 18.4。本文保留 10 月 11 日批准的实施方案；10 月 12 日实现范围与验证以[交付说明](../ios-webkit-protection.zh-CN.md)及[验收记录](../audit/ios-webkit-protection-2026-10-12.zh-CN.md)为准。安全规则首版随 App 分发，不提供远程订阅；未知行为仅作提示，严格指纹仍为默认关闭的附加限制。

## 建议结论

采用“系统安全能力、请求规则、本地页面检查”三层保护。先落地钓鱼拦截和已知挖矿/指纹资源阻断，再接入可选的系统强化模式，最后验证未知脚本的行为识别。所有保护都应显示具体原因、当前系统可用范围和按网站恢复方式。

不采用私有 API、HTTPS 中间人代理或对整个页面任意改写的方式。系统 WebKit 的网络和执行层能力与 Chromium 不同，但已有公开接口可以实现有效的原生保护。

## 现有代码与缺口

- `BrowserKit/NavigationPolicy.swift` 在导航前运行 `PhishingScorer.scoreURL`，并拒绝账号密码网址和不支持的协议。
- `AegisPolicyKit/PhishingScorer.swift` 已有表单、仿冒品牌和跨站提交评分；当前浏览器只调用网址评分，页面结构评分尚未接入。
- `TrackingProtection.swift` 与 `ContentFilterCompiler.swift` 已能编译 WebKit 内容规则，更新成功后替换，失败保留旧规则；可复用编译和存储流程，但安全规则要有独立分类及例外，避免“暂停广告过滤”同时放行恶意站点。
- `BrowserSession.swift` 尚未显式设置系统欺诈警告、HTTPS 导航策略或系统安全限制。系统欺诈警告默认开启，应显式保持；这不能替代 Aegis 自身规则。
- 现有 `PageSnapshot` 为阅读和模型用途，会拒绝敏感表单；防钓鱼要新增只提取结构的检查器，不能为此放开阅读接口对密码页面的限制。

## 1. 指纹保护

### 标准保护

1. 保留 WKWebView 默认的 ITP、私密数据存储隔离和现有链接参数清理。WebKit 官方说明 ITP 自 iOS 14 起默认用于 WKWebView；不能据此宣称 Safari 的全部高级指纹保护都已开放给本 App。[WebKit 说明](https://webkit.org/blog/10882/app-bound-domains/)
2. 增加经过审核的指纹采集域名和脚本资源规则，编译为独立 `WKContentRuleList`。请求在加载阶段阻断；规则中保留分类、来源、版本、有效期和匹配依据。[内容规则机制](https://webkit.org/blog/3476/content-blockers-first-look/)
3. 用本地观察器记录 Canvas、WebGL、Audio 等组合探测信号，仅保留次数和类别。单个接口调用不判定为追踪；绘图、地图、音视频和游戏都有正常用途。

### 可选严格保护

先做限范围原型：对高风险网站限制图像像素、渲染器详情或音频结果读取，并给出按网站恢复入口。默认不做每次调用都变更的随机噪声或伪造大量硬件属性，避免增加独特指纹和破坏页面。

原型必须检验顶层页面、跨来源 iframe、Worker、OffscreenCanvas 和提前缓存原始函数的绕过路径。修改页面 API 需要进入页面脚本世界；隔离世界只能保护观察器自己的变量，不能自动覆盖网站的 API。注入措施存在竞态和绕过，只能标为附加保护，不承诺引擎级不可绕过。[WKContentWorld](https://developer.apple.com/documentation/webkit/wkcontentworld) · [页面世界注意事项](https://developer.apple.com/documentation/webkit/wkcontentworld/page)

本次检查当前 SDK 的公开头文件，没有找到与 Safari“高级跟踪和指纹保护”等价的通用 WKWebView 开关。这是当前公开接口核对结论，不把私有接口当成可发行方案。

## 2. 深层保护

优先使用公开的系统加固能力：

- **iOS 26.4 及以上**：可选 `WKWebpagePreferences.securityRestrictionMode = .maximizeCompatibility`。官方接口说明其关闭 JavaScript JIT，并扩大 WebContent 进程的 MTE 内存标记覆盖；保护等级使用独立的 WebContent 进程。主框架选择后，子框架和新开窗口继承等级。MTE 的实际效果仍受设备支持限制。[Apple 接口说明](https://developer.apple.com/documentation/webkit/wkwebpagepreferences/securityrestrictionmode)
- **iOS 18.4–26.3**：保留系统默认保护；可单独提供严格网页模式，使用公开的 Lockdown 网页设置，或按网站关闭页面 JavaScript。界面必须说明兼容性、功能和性能代价，不能把它标成与 26.4 加固模式相同。尊重系统已开启的 Lockdown，不主动降级。[Lockdown 网页设置](https://developer.apple.com/documentation/webkit/wkwebpagepreferences/islockdownmodeenabled)
- 开启已知站点 HTTPS 升级，并使用 `preferredHTTPSNavigationPolicy = .userMediatedFallbackToHTTP`；升级失败由用户决定，不静默降级。系统可能覆盖该偏好，需分别验证本地 HTTP、重定向和错误页面。[HTTPS 导航策略](https://developer.apple.com/documentation/webkit/wkwebpagepreferences/preferredhttpsnavigationpolicy)

继续保留来源检查、权限询问、弹窗限制、私密隔离和自带扩展的受限能力。WebKit/JSC 字节码插桩、任意引擎漏洞拦截和完整 DNS/CNAME 链检查不在公开 WKWebView 接口保证内；不能将新的加固选项称为 Chromium 字节码模块已移植。

## 3. 钓鱼防护

### 导航前

- 明确保留 `isFraudulentWebsiteWarningEnabled = true`。系统默认开启，但效果依赖系统服务；本地无网络时仍由 Aegis 本地规则工作。[Apple 欺诈警告接口](https://developer.apple.com/documentation/webkit/wkpreferences/isfraudulentwebsitewarningenabled)
- 在现有网址评分前增加本地恶意域名/网址库；经过校验的高置信命中直接显示原生阻止页。未知或仅有弱线索时提示风险，不根据单一后缀或 Punycode 就封禁。
- 用 Public Suffix List 计算实际注册域，按 IDNA 规范处理国际化域名，再检查仿冒品牌、凭据网址及跳转目的地。现有简单域名拆分不能直接承担正式的跨站身份判断。
- 覆盖地址栏输入、链接、重定向、弹窗和表单导航；不要只在 `load` 入口检查。返回与重新打开也需保持范围绑定。

### 页面加载后

- 在隔离内容世界读取限量的标题/品牌线索、密码框数量、表单目标域、HTTP 状态及 iframe 来源等结构；不读取输入值、密码、验证码或完整表单正文，不发送模型或远程评分服务。
- 接入既有 `PhishingScorer.assess`，给出具体命中原因。动态表单变化采用有上限、可取消的观察，回调必须匹配当前标签、模式、来源和导航版本。
- 跨站登录、支付跳转可能合法，应结合品牌/域名信誉评分，并为用户的单站点临时例外保留范围与有效期。
- 页面扫描只能在页面存在后发现风险，不能保证“扫描前零数据发送”。高置信恶意网址和已知外传端点应在导航/资源加载前阻断；发现后卸载风险页面并显示原生说明。单纯覆盖页面或调用 `stopLoading()` 不等于停止其全部脚本。未知 `fetch`、XHR、WebSocket 外传不能靠表单提交监听完整防住。

## 4. 挖矿脚本检测

### 首批可确定实现的部分

给已知矿池地址、挖矿脚本来源和稳定资源特征建立独立内容规则。先在本地合成脚本、Worker 和连接端点上核对真实请求计数，证明规则生效，再纳入生产规则。规则应带来源、审核状态和更新校验；不要把“域名列表命中”显示成“已解析脚本内容”。

### 未知脚本识别原型

组合 Worker 创建、WASM 使用、可观察的资源/连接目标、持续活动等信号；单独使用 WASM、WebSocket、页面卡顿或高耗电不判定挖矿。用正常游戏、PDF、视频、地图和本地计算任务作为负样本，先评估误报率。

公开 WKWebView 接口不提供可依赖的逐脚本 CPU 计量或所有网络响应正文。因此不能承诺抓取任意 HTTPS 脚本并做完整静态扫描；`WKURLSchemeHandler` 不能注册接管 WebKit 已处理的 HTTPS。[Apple scheme handler 限制](https://developer.apple.com/documentation/webkit/wkwebviewconfiguration/seturlschemehandler(_:forurlscheme:))

弱信号先显示提示。高置信规则命中可直接阻断；需要停止可疑计算时，应释放/替换该页的 WebView，重新加载前先装入规则或禁用该站页面脚本。仅停止加载不会终止已运行的 Worker。JS 注入和页面上报都按可绕过、可伪造的数据处理，不允许触发任意原生动作。

## 5. 实施顺序与验证门槛

1. **规则与钓鱼闭环**：独立的安全规则分类、原生风险页、导航全过程和页面结构评分。验证安全样本/攻击样本、重定向、国际化域名、合法跨站登录、规则更新失败保留及私密不落盘。
2. **系统加固与标准指纹保护**：公开 API 按版本启用、资源阻断、网站例外。验证 18.4 降级、26.5 实际运行、系统 Lockdown 保留、子框架/新窗口继承，以及阅读、翻译、下载、视频、支付站点的兼容性。
3. **行为检测与严格指纹原型**：设定可接受的检测率、误报率和性能预算后再决定是否默认开启。验证 Worker/WASM 绕过、伪造消息、导航后的陈旧回调、标签释放和多窗口隔离；不能只凭几条自制网页通过就宣称未知攻击检测有效。

规则库的供应来源、许可、更新时间和维护方式需在接入前选定。更新应使用签名清单和内容摘要，限制大小/数量/有效期，编译成功后原子替换；拒绝损坏和回退版本，失败保留上一份可用数据。第三方数据可用性不能成为浏览器无限等待的原因。

双端模拟器用于功能与回归；正式宣称耗电、性能、MTE 或实际威胁检测效果前，还需真机和独立样本集。云端模型和远程实时 URL 查询不是首批依赖。

## 本轮方案核验

已核对 Xcode 27 的公开 WebKit 头文件及 Apple/WebKit 官方资料。使用最低部署目标 iOS 18.4 对欺诈警告、HTTPS 策略、隔离脚本和带版本保护的 26.4 安全限制进行编译接口检查。接口存在和检查通过仅证明方案能调用相应公开 API，不代表上述保护已经接入 App 或通过效果验收。
