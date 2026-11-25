# iOS SDD · 网页绑定无认证本地代理

2026-11-20 · 面向 Aegis WKWebView、最低 iOS 18.4。以 [fork main `c5b4257a`](https://github.com/quinn521/aegis-browser/tree/c5b4257a221b7d4434a113d2c13d870139b8d6fa) 为设计基线。应用级双无认证、准备期回退及撤销语义见 [共同合同](app-inbound-contract.zh-CN.md)。

## 用户结果与源码起点

“始终保护”的精确入口打开前先准备连接。主文档和其跨源图片、脚本、API 随该文档的专用 DataStore 走同一实际出口。另开同一 CDN 为顶层导航时重新判定。内部 Options 的 Apply 显示当前实际协议和采用 HTTP 的原因。已有显式保护失效时页面等待或显示失败。已批准的可选原连接工作流继续按其原授权与安全方法运行。[网站路由 SDD](ios-exact-host-store-sdd.zh-CN.md) · [Options 原始需求](https://github.com/gcsagroup/aegis-browser/issues/183)

| 组件 | 基线事实 | 实施增量 |
| --- | --- | --- |
| [产品入口工厂](../../../apps/ios/AccessKit/AccessEmbeddedProxyEntryFactory.swift)、[入口发布器](../../../apps/ios/AccessKit/AccessProxyEntryPublisher.swift) | 工厂启动内嵌核心和 HTTP listener，健康实例可由多个登记键引用 | 在授权、普通/私密作用域和 Profile 版本兼容且退役范围相同时复用。为两种协议分别创建、持有、检查和退役真实监听 |
| [DataStore registry](../../../apps/ios/AccessKit/AccessHostDataStoreRegistry.swift) | 生产端点无协议字段。setEndpoint 与 attach 可向已有 store 应用就绪端点，apply 固定产生 HTTP CONNECT | 端点增加实际运输及归属。首次绑定原子安装一项配置。同一有效绑定可重用，协议、监听实例、授权或代次变化时创建新 store 并退役旧文档 |
| [SOCKS 会话](../../../apps/ios/AccessKit/AccessSOCKS5InboundSession.swift)、[HTTP listener](../../../apps/ios/AccessKit/AccessHTTPInboundListener.swift) | SOCKS 夹具可以完成握手；现有 HTTP 产品入口可以向受控上游打开隧道 | SOCKS CONNECT 复用经过授权的核心拨号和双向流生命周期，拨号成功后才回成功，保留已收到的业务字节。两种入口分别覆盖取消、半关闭和内核退出 |
| [Fixture builder](../../../apps/ios/AccessKit/AccessProxyConfigurationBuilder.swift)、[账户下载](../../../apps/ios/AegisApp/AccessAccountSession.swift) | builder 主动拒绝 SOCKS，独立下载通路有 TLS 和租约凭据 | 不把 fixture 错误计作 OS 拒绝。网页路径使用 `ProxyConfiguration(socksv5Proxy:)` 或 `httpCONNECTProxy:`，均设 `allowFailover = false`。下载租约按原有授权单验。[Apple 接口](https://developer.apple.com/documentation/network/proxyconfiguration) |

独立候选 `043e5651` 曾在模拟器完成真实内核和转发 5/5，包含两种入站的 HTTP/HTTPS 页面及带标记的跨源响应。该候选默认使用应用级 10808 端口。复审记录了 5 项 P1、8 项 P2、2 项 P3，其中包括旧文档结束前的端口所有权。历史回执保留其候选身份。当前 SDD 采用持有有效监听并完成退役的规则，多作用域并发不能以固定端口作为身份。10808 仅属该历史候选；现行规则为系统分配 SOCKS5 端口，内部准入夹具固定使用 DEV 端口 10806。[流量回执](https://github.com/gcsagroup/aegis-browser/issues/138#issuecomment-6968029114) · [复审与恢复记录](https://github.com/gcsagroup/aegis-browser/issues/183#issuecomment-6968024379)

## iOS 原生 Options

在原生“设置 → 隐私保护”提供 Access Options 入口，并从内部构建的当前网站面板进入所选 Profile。现有“隐藏地理位置服务”继续呈现订阅用量。iPhone 采用列表到详情的导航，iPad 的窗口各持一份草稿。Profile 详情提供本地协议选择器、端口模式、按需显示的指定端口输入、只读本次连接和 Apply/Discard。站点页面按精确顶层入口展示规则，打开单独顶层页时重新读取自己的规则。[原生设置入口](../../../apps/ios/AegisApp/BrowserSettings.swift) · [三端 Options 合同](app-access-options-sdd.zh-CN.md)

DEV / 内部 Alpha 在普通 Profile 的“测试节点”提供文本输入和“扫描节点二维码”。用户主动打开相机后才请求权限，返回页面显示脱敏草稿。拒绝授权或取消可继续用文本输入。文本与扫码复用分享链接校验，显式 Apply 后由网页发布器按该测试 Profile 的身份准备 DataStore。iPhone/iPad 验收同一合成节点的两种输入、取消时旧文档继续使用原绑定、换 Profile 后迟到的扫码结果被丢弃。Beta / Release 对深链、恢复的旧引用和直接命令均拒绝手动节点激活。托管账户联调等待服务端同事交付。[分享链接实现](../../../apps/ios/AccessKit/AccessLocalV2RayConfigLoader.swift) · [签入构建订阅的网页入口](../../../apps/ios/AegisApp/AccessThreeXUIWebEntry.swift)

Apply 在更换活动文档的 DataStore 前显示受影响标签和表单状态，让用户确认。取消或 Discard 不退役文档。普通与私密的草稿、显示状态、备份各有作用域。私密 v1 沿用已有文件导入/导出限制。两窗同时提交时只有一个 baseRevision 可以生效。冷启动和恢复导航均显示已提交选择及真实绑定结果。[完整 Options 合同与执行工单](https://github.com/gcsagroup/aegis-browser/issues/208)

验收从真实设置入口开始，分别覆盖 iPhone、iPad 两窗、VoiceOver 和最大字体。验证直接命令、导入文件、恢复旧内部配置在受限包均无法激活。模拟器上的控件选中和已保存文本只验设置行为；协议成功需 O3 的两路收件和 O6 的适用真机记录。

## 绑定与退役

1. 协调器冻结 tab、导航、顶层 host、普通/私密 scope、Profile 版本和授权 epoch，持有原操作时限。publisher 仅针对该快照准备候选。SOCKS 专属的不兼容可在绑定前触发独立 HTTP 准备。取消、授权失效和过期回调使操作作废。
2. 监听持有实际回环 socket，完成受控上游流量验证后才产生 ready 端点。registry 核对快照与代次，创建专用非持久 DataStore，安装恰好一项配置，然后允许新 WKWebView 发起导航。准备失败的强制保护导航不得把空配置或 nil store 当作原连接继续。
3. 协议或代次变更时阻止受影响文档的新派发，停止旧 WebView 工作。需要独立退役的 DataStore 绑定各用独立监听，按该绑定持有的监听实例终止流。退役范围相同的兼容绑定可共享监听，释放单个引用时保留其余有效消费者的流。旧 store 保留原配置，待 WebKit 确认旧文档无法再派发后才清空配置并释放相应引用。该监听的旧绑定均确认退役、旧流终止且最后一个引用释放后，才关闭 socket、释放端口。其他仍有效的文档和窗口保持其已绑定路线。退出私密会话、额度撤销、前后台切换或核心重启后按相同规则处理。
4. Apply 失败时保留持久的强制保护意图。旧授权仍有效且旧绑定尚未撤销时可继续该绑定；其余情形等待新的有效登记。切换 DataStore 按现有 UX 说明表单和登录状态的影响，自动恢复只使用已授权的单次 GET/HEAD。

## 交付切片与验收

| 切片 | 正向回执 | 拒绝与关闭条件 |
| --- | --- | --- |
| I-F1 · 协议探测和真实拨号 | 最低支持 OS 和当前支持 OS 分列 SDK、系统/build、WebKit 实际页面、指定出口及独立标记。HTTP 和 SOCKS 各形成独立收据 | 仅 API 构造或 CONNECT 计数保持待验。密码法专用、BIND、UDP 拒绝。某 OS 的 SOCKS 未准入只限制该行 |
| I-F3 · 端点和文档所有权 | 普通/私密、两个不同 Profile、同域两窗口、共享合法消费者分别绑定；记录端点实例和引用释放。单独退役一个绑定时，另一有效绑定的在途流继续完成 | 占用端口、同端口新代、旧文档回调、后台回返、退出私密及内核重启均不得串流或直连。旧文档退役确认延迟时，旧端口仍由原 socket 持有 |
| I-F4 · 固定 HTTP / O3 | 从内部 Options 点 Apply，经无认证 HTTP 取得主文档与跨源资源标记，另开选原连接的顶层页取得独立对照 | 失效后强制路径原出口新增为零。本地无 407 或代理密码弹窗。上游 TLS/认证另验 |
| I-F2 · 自动绑定 | 在已准入系统优先 SOCKS；仅协议能力不足时在绑定前选择已独立准入且通过准备检查的 HTTP，诊断显示实际结果 | 绑定后的断流、取消、超时和额度撤销均不切协议。显式锁定协议失败可见，POST/PATCH 无重放 |
| I-F5 · O6 真机 | 同一候选包分别测 Wi-Fi、蜂窝、网络切换、前后台和私密结束。记录设备 OS、入口、上游和两个独立标记 | HTTP 与适用上游认证持续验收。SOCKS 长期未准入的平台可交付经真机验证的 HTTP-only 状态，不借另一协议或模拟器签字 |

I-F0 对齐共同合同的冻结修订，规范层已由修订 5 落地。默认自动选择须在该平台候选的监听退役、HTTP 回退与适用真机行有回执后开放。

O1 渠道与原生入口、O2 规则/文件/并发、O4 导航/退役/下载、O5 账户与诊断仍按原完整 Options 合同执行。O3 与 O6 采用上表细化后的本地协议口径。继承原 issue 的全部复选范围、既有失败与候选证据；文档交付不勾选实现项。[执行与验收 #208](https://github.com/gcsagroup/aegis-browser/issues/208) · [O1–O6 原始验收](https://github.com/gcsagroup/aegis-browser/issues/183) · [内核与私密隔离](https://github.com/gcsagroup/aegis-browser/issues/136) · [原标签重试](https://github.com/gcsagroup/aegis-browser/issues/137) · [真流量和设备](https://github.com/gcsagroup/aegis-browser/issues/138)
