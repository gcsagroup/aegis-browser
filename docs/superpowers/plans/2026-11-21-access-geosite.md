# 网站加速的 TDD 实施计划

先交付可安装的 iOS DEV「国内加速」入口，在同页「网站加速」下提供「手动」和「智能」。未来「位置加速」与「网站加速」并列。随后完善 macOS DEV，最后接入 Android。Hysteria 2 有独立的实验、回执和退出条件。基线为 `develop@e18106b84c56589a69faa1b0965e696caea2cb8c`。每个后续任务先提交能暴露对应行为差异的测试，记录 RED，再做最小实现、重跑同一用例并回归；以下命令区分已存在的入口与拟增测试。[设计规格](../specs/2026-11-21-access-geosite-design.md) · [Superpowers 计划方法](https://github.com/obra/superpowers/blob/22f0b463e7a5e579904dd6211a520321035526f7/skills/writing-plans/SKILL.md) · [TDD 方法](https://github.com/obra/superpowers/blob/22f0b463e7a5e579904dd6211a520321035526f7/skills/test-driven-development/SKILL.md)

## 1. 已执行的 iOS 顶层导航试验

测试使用 `Aegis-Debug`、Xcode 27.2（27B52）、iPhone 17 模拟器、iOS 26.5（23F77）。产物使用仓库固定的 Xray 源和 `ci-rebuild` 模式构建。分类器与接线仅编入 XCTest。真实 `BrowserTab.loadFromAddressBar` 调用 prepare 回调，测试适配器根据完整 `DEBIAN` 的投影设置 exact-host 意图，生产协调器和 WebKit 自行选择出口。两个本地监听器记录 CONNECT 后终止，不向目标拨号。这样既可安全重现错路，也能用实际连接记录识别它。[测试源码](../../../apps/ios/Tests/AegisTests/AccessHostRecoveryWebKitTests.swift) · [运行时规则和数据摘要](../specs/2026-11-21-access-geosite-design.md#规则来源与准入)

| 用例 | 实际验证 |
|---|---|
| `testGeoSitePinnedDomainClassification` | 13 个离线 URL 向量，涵盖两条原始根域、多级子域、大小写与根点、空标签、相似字符串、伪子域、路径、userinfo 和非 HTTP(S) |
| `testGeoSiteTopLevelNavigationSelectsManagedOrOriginal` | 同一普通标签页 4 次独立地址输入。每次等候任一出口。最终试件还等候 WebKit 结束受控请求，再复核正确出口为正、错误出口为零，并保存所有 authority 的 XCTest 附件 |
| `testGeoSiteUnavailableEntryKeepsMatchedNavigationOffOriginal` | 受管入口准备失败时，命中导航出现可重试错误。独立未命中导航走原设置，确认见证有效，再核对命中域在原设置侧为零 |

下表为 GREEN 的原始 CONNECT 次数。WebKit 可重试，一个目标可有多条记录。复跑按正确侧大于零、禁止侧等于零验收，避免把某次运行的重试次数当作 API 合同。

| 实际导航主机 | 受管监听器 | 原设置监听器 |
|---|---:|---:|
| `debian.org.geosite.invalid` | 4 | 0 |
| `notdebian.org.geosite.invalid` | 0 | 4 |
| `packages.dotdeb.org.geosite.invalid` | 4 | 0 |
| `debian.org.attacker.geosite.invalid` | 0 | 4 |

冷失败独立用例中，`security.debian.org.geosite.invalid` 触发一次准备，原设置侧 0 次；随后 `control.geosite.invalid` 在同一原设置侧有 4 次。这里证明地址输入到 CONNECT 的选择，公网 TLS、页面内容、任意顶层重定向和真机验收仍须各自取证。

| 阶段 | 实际结果 |
|---|---|
| RED | 用精确匹配作为起点。3 个用例全部失败，0 跳过。子域 `packages.dotdeb.org.geosite.invalid` 在原设置侧出现 4 次，冷失败场景中的成员也误入原设置，准备次数为 0 |
| GREEN | 最小修正为 DNS 标签后缀匹配。3 个用例通过，0 失败、0 跳过。两份原始附件 SHA-256 分别为 `23c665de21ec9e1da4209c2e5186663fa4ac989382968535a0ef9259d9fc08ca`（双出口）和 `2f8130d480d5eb1d2fe551edbfa4d33ccc9e4cf2b8534559981c6267296af5e3`（冷失败） |
| 回归 | 上述 3 项与既有 8 项一起执行，11 项通过、0 失败、0 跳过；覆盖原设置、显式开关、store 绑定/隔离及现有页面资源行为。全量 iOS 套件与物理设备未运行 |

保留先前失败记录。首次准备时 SwiftPM 缓存包含旧绝对路径，构建在发现测试前退出；换成任务内缓存，核对 13 项固定依赖 revision 和 9 项二进制路径后重新构建。基线单跑 `testExplicitOnCannotSendToOriginWhilePreparationFails` 时，关闭代理后的正向 HTTP 回执超时；该用例在上述回归中原样通过，首次超时原因未定。RED 和 GREEN 完整测试文件 SHA-256 分别为 `4ddae91a8eee6b0781e9863288ba07bf39d18b261bc36e6a4ff36e3cde0a1a21` 和 `4a4cb87288c65c93e95091b424fbcb7d2c50a0496116e29648c9ad5cc560a75a`。

最终试件把每次受控 CONNECT 的观察延长至 WebKit 结束加载，停止最后一次导航后再核对禁止出口。该候选测试文件 SHA-256 为 `c789efb9f0c96e0e4d014b442fe8b63354f023d0fd374cc3f6995f14b205735b`。同一组 11 个测试再次全部通过，零跳过。表中四个目标各在正确侧观察到 8 次、错误侧 0 次；冷失败仍只准备 1 次，只有对照域到达原设置侧（8 次）。两份最终附件 SHA-256 为 `bb4861756b428e419b194fb7d5647472d4a4ab7386c5036da5c32082e3dbc4d7`、`d20b289ce44a95c75e780ad7e836e12b9833cd2a5e71ef4354911580fca3eb71`。

### 复跑

从仓库根目录运行，`RESULT_ROOT` 为新的绝对目录，`SIM_UDID` 为测试专用模拟器。工程依赖按已提交的 `Package.resolved` 解析；本机使用独立的包缓存和 DerivedData。通过条件是三个指定方法均实际执行、全部通过、零跳过，并能在两份附件中对齐出口。

```bash
: "${SIM_UDID:?set a dedicated iOS Simulator UDID}"
: "${RESULT_ROOT:?set a new absolute artifact directory}"
mkdir -p "$RESULT_ROOT"
bash scripts/release/prepare-ios-package-core.sh "$PWD" "$RESULT_ROOT/EmbeddedCore"
suite=AegisTests/AccessHostRecoveryWebKitTests
xcodebuild test -project apps/ios/Aegis.xcodeproj -scheme Aegis-Debug -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIM_UDID" \
  -derivedDataPath "$RESULT_ROOT/DerivedData" -clonedSourcePackagesDirPath "$RESULT_ROOT/SourcePackages" \
  -onlyUsePackageVersionsFromResolvedFile -parallel-testing-enabled NO -enableCodeCoverage NO \
  -resultBundlePath "$RESULT_ROOT/GeoSite.xcresult" "AEGIS_EMBEDDED_CORE_PRODUCTS=$RESULT_ROOT/EmbeddedCore" \
  "-only-testing:$suite/testGeoSitePinnedDomainClassification" \
  "-only-testing:$suite/testGeoSiteTopLevelNavigationSelectsManagedOrOriginal" \
  "-only-testing:$suite/testGeoSiteUnavailableEntryKeepsMatchedNavigationOffOriginal"
xcrun xcresulttool get test-results summary --path "$RESULT_ROOT/GeoSite.xcresult"
xcrun xcresulttool export attachments --path "$RESULT_ROOT/GeoSite.xcresult" \
  --output-path "$RESULT_ROOT/witnesses" --filter '*GeoSite*'
```

后续 iOS 产品决策需另测用户显式覆盖和清除、位置保护联动、私密会话终止、重启撤销、已提交页面与受信 landing；iframe、worker、下载依各自传输栈验收。该批次不占用 #208 的入站 Options 验收顺序。[iOS 跟踪](https://github.com/gcsagroup/aegis-browser/issues/208)

## 2. iOS DEV 的网站加速

| 步骤 | 失败测试与通过条件 |
|---|---|
| 设置入口 | 用真实「设置」打开「国内加速」。核对「网站加速」下的「手动」「智能」、默认选择、切换和重新进入；DEV 以外或私密会话沿用原设置 |
| 普通窗口策略 | 直接调用产品协调器。已有默认位置保护的普通窗口启用智能后，匹配域必须准备服务，未匹配域走原连接。测试显式服务、显式原连接、清除继承、重建偏好与禁用 |
| WebKit 实际出口 | 移除先行试件的决策适配器。沿真实 BrowserTab 入口，在同一标签页跨根域、子域、相似域和未命中域往返。两个互斥监听器记录 CONNECT；故障后用独立正对照验证原路径可观测 |
| 切换与生命周期 | 在受管准备未完成时切换模式或手动覆盖，注入迟到结果，观察零错误出口，保留其他标签独立授权。POST、同页资源、既有恢复和私密会话分别回归 |
| 安装与审查 | 构建并安装 DEV 模拟器 App。真机版本保留原 App Groups、扩展与 Apple Development 签名，逐项核对嵌入描述文件及受支持设备；记录安装包哈希。对最终代码、设计和原始回执运行独立只读审查，再提交 PR 验证最终 SHA 的 CI |

真机验收要求切换后页脚仅显示所选模式的短提示，服务未配置时两种模式均另显示「加速服务未配置。」，配置后仅保留模式提示。

### iOS DEV 产品回执与复跑

前置试件的回执保留在第 1 节。产品候选先在旧 App 上得到 3 个行为失败，分别是设置入口缺失、普通窗口智能目标未选择服务、非成员仍尝试全站默认服务。接线后的首轮 6 个 XCTest 全部通过。同一标签页四个受控 HTTPS 顶层目标各有 8 次 CONNECT 到达预期监听器，另一侧均为零；这里统计的是 WebKit 重试，样本为四个目标。服务准备失败时，仅独立对照域到达原设置侧。

第二轮 4 个 XCTest 覆盖了本站选择跨窗口与重建、操作中切换设置或离开、受管超时、可完成的 HTTP 重定向与跨域资源，以及切换存储时保护 POST。另有一项行为测试先复现无服务时无法为失败网站选择原连接，再验证用户可更改或清除该选择，原请求保持停止。独立审查还发现三个边界：失去服务代次后重开规范重定向页面、修改站点 A 时保留另一窗口站点 B 的进行中请求、切换智能后保留已提交页面从上级域继承的保护。三项用例在原候选逐项失败。修复后，关闭旧回环入口再重新加载，目标由新入口收到，另两项也通过。完整 iOS 回归、签名包摘要及最终提交的 CI 记录在[产品 PR](https://github.com/quinn521/aegis-browser/pull/402)。

在仓库根目录准备固定核心和新的绝对输出目录，使用专用模拟器。打开「设置 → 国内加速」，在「网站加速」下切换「手动／智能」，重启后核对选择。真机 Debug 构建需要匹配主 App 和两个扩展的开发描述文件。分享扩展与 App 共用现有 App Group。账户服务按原有 DEV 构建配置提供；无配置时，选中服务的顶层导航会报告不可用。[DEV 订阅与核心构建说明](../../development/ios-alpha-quota.zh-CN.md)

```bash
: "${RESULT_ROOT:?use a fresh absolute result directory}"
: "${SIM_UDID:?select a test simulator}"
: "${IOS_DEVELOPMENT_TEAM:?select the development team for this app}"
bash scripts/release/prepare-ios-package-core.sh "$PWD" "$RESULT_ROOT/EmbeddedCore"
ios_project=apps/ios/Aegis.xcodeproj
xcodebuild test -project "$ios_project" -scheme Aegis-Debug -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIM_UDID" -derivedDataPath "$RESULT_ROOT/SimulatorBuild" \
  -onlyUsePackageVersionsFromResolvedFile -parallel-testing-enabled NO \
  -resultBundlePath "$RESULT_ROOT/WebsiteAcceleration.xcresult" \
  "AEGIS_EMBEDDED_CORE_PRODUCTS=$RESULT_ROOT/EmbeddedCore" \
  -only-testing:AegisTests/AccessHostRecoveryWebKitTests \
  -only-testing:AegisTests/AccessHostWebKitRouteTests \
  -only-testing:AegisUITests/SettingsLayoutUITests/testWebsiteAccelerationModesInDevSettings
xcodebuild build -project "$ios_project" -scheme Aegis-Debug -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath "$RESULT_ROOT/DeviceBuild" \
  -onlyUsePackageVersionsFromResolvedFile "DEVELOPMENT_TEAM=$IOS_DEVELOPMENT_TEAM" \
  "AEGIS_EMBEDDED_CORE_PRODUCTS=$RESULT_ROOT/EmbeddedCore"
codesign --verify --deep --strict "$RESULT_ROOT/DeviceBuild/Build/Products/Debug-iphoneos/Aegis.app"
```

## 3. macOS DEV 的手动与智能模式

| 任务与落点 | RED 与最小实现 | GREEN 与回归 |
|---|---|---|
| M1 规则编译。拟在 `scripts/dev` 添加离线编译器及测试 | 构造 full、domain、兄弟标签、IDNA、根点、IP、PSL 通配/例外及 PRIVATE、属性/keyword/regexp、截断与超限输入。校验失败时整组拒绝。仅对明确准入且完整的组构建版本化索引 | 用固定 `dlc.dat` 重现 `DEBIAN` 的两个 typed rows 和清单摘要。`WIKIMEDIA` 整组拒绝。坏签名、错误源、过期、重启、并发替换均不能发布半个快照或恢复已撤销授权 |
| M2 后端策略与身份。扩展 `AccessPolicyEvaluatorTest` 和 Options 现有能力/服务测试 | 先写手动优先、清除后恢复类别、关闭后恢复原生、冲突不降级的失败用例。添加 macOS verified DEV 专属能力及先手动、后类别的求值层 | 对照功能关闭时旧 evaluator 的所有动作和冲突。覆盖显式 site/website/Profile、企业拒绝、登录、普通/OTR/Guest、分区与 generation 错配、Alpha/Beta/Stable/unknown/冲突经后端直接调用均拒绝 |
| M3 两个可操作入口与真实请求 | 浏览器测试先复现 UI/重启不能区分手动、显式原设置和自动继承。接入站点操作、Profile 开关、选择/确认组和原子 Apply。失败草稿不显示为已生效 | 在 DEV 实际打开两种入口，按同一目标测试启用、禁用、手动覆盖、清除、重启及撤销。HTTP(S)/WS(S)、子资源和重定向逐跳对齐两端证据，控制页/控制面/higher-priority 拒绝回归。原生 System/PAC/Fixed 和现有 Options Auto Switch 分别作对照 |
| M4 关闭、回退及性能 | 测发布中断、迟到 ACK、租约失效、身份切换及已选 Access 时原生出口为零。将编译验证移到发布阶段，热路径复用不可变索引 | PF01 用 10,000 规则、至少 100,000 次混合决策，含规范化、优先级与代际检查，平均 ≤50 µs、p95 ≤100 µs、p99 ≤500 µs。PF02 用同构建开/关、冷/热各至少 30 次；未命中 p95 TTFB/LCP 增量 ≤max(基线 5%, 20 ms)。记录原始分布、种子和环境 |

M2 从 `PrivatePslPreventsCrossTenantSuffix` 和 `WebsiteMainNavigationReevaluatesEachTrustedHop` 两个现有回归扩展；M3 同时检查按钮与 UI 之外的读取、写入、导入、恢复和激活。GN 测试目标为 `aegis_access_unittests`，再跑受影响的 Options 服务及浏览器测试。每一项在受控 DEV 构建上取证，并与 #209 既有 FIRST 协调。阶段状态为待实施。[求值测试](../../../apps/browser/overlay/components/aegis_access/access_policy_evaluator_unittest.cc) · [能力测试](../../../apps/browser/overlay/components/aegis_access/access_options_capability_test.cc) · [Options 服务测试](../../../apps/browser/overlay/chrome/browser/aegis/access/access_options_service_unittest.cc) · [真实浏览器入口测试](../../../apps/browser/overlay/chrome/browser/aegis/access/access_browser_request_adapter_browsertest.cc) · [性能合同](../../plans/access-service-v1.0/spec.zh-CN.md)

## 4. Android 的实施顺序

1. 复用已审核的分类向量和共同策略验收，在 Android 原生设置及后端先测 ordinary、Incognito、错误构建身份和手动覆盖。
2. 在真实 Chromium 顶层和请求入口接线，测试重定向、同页资源、账户或入口不可用、禁用后重新选路。由 Android 测试记录服务端、原连接侧及设备端证据。
3. 生成 Android DEV 的安装包，在匹配环境验证两个模式。记录 APK 哈希、运行设备和请求级回执，沿用 #210 已有所有权和环境前提。[Android 工作单](https://github.com/gcsagroup/aegis-browser/issues/210)

## 5. Hysteria 2 的受控验证

| 次序 | RED → GREEN | 留存证据 |
|---|---|---|
| H1 调度与故障分类 | 用可控时钟注入主传输故障、站点 403/429/5xx、坏证书、认证拒绝、锁定、离线、撤销和账户耗尽。只有已确认的主传输故障可进入同账户授权候选；每组一个恢复任务 | 两轮 suspect 总计约 6 秒，单候选 ≤4 秒，故障确认后 ≤15 秒、至多 5 个不同候选、每 Profile 并发 ≤2，全浏览器额外槽位最多 2。排队计时、不因换协议重置。冷却和两次健康复核后回候选池，不抢占健康绑定 |
| H2 回环实传 | 先要求目标双向回执失败，再接入受控 QUIC/UDP 端点并验证服务证书、HY2 身份、租约、真实 TCP CONNECT 到自有 marker。关闭 UDP、拒绝认证、撤销或耗尽时不得向 marker 发送业务 | 关联候选、用户、租约、generation、目标 marker 及两端网络字节。用服务端账户账本核对计量、关闭及迟到结算；无账户映射最多登记传输成功 |
| H3 代际切换与可选 iOS | 注入确认前、持久化前、提交后故障及 kill switch。仅已 ACK 且已持久化的新 generation 接新请求；旧流排空或明确失败。POST 和旧事务均不重放 | 主/备传输、旧/新流、原设置侧与账户账本同时取证，观察错误出口为零。专用 iOS 试件还须证明 singleton 不会因 Stop/Start 中断无关流；未满足前保持实验关闭 |

H2 的独立回环传输已验证。用固定的 Xray v26.11.9 在 macOS 上运行客户端与服务端，证书和认证通过时，自有 HTTP 目标收到一次请求并返回预期的 28 字节正文。阻断 UDP、认证拒绝、证书名称错误三个对照中，目标各收到零次请求。账户签名、租约、撤销和额度计量仍待验证，H1、H3 及可选 iOS 试件尚待实施。[四场实验与构建摘要](https://github.com/gcsagroup/aegis-browser/issues/213#issuecomment-7062599250)

进入产品评审前，需在同一候选上完成对应构建、集成与功能验证，提供完整 diff、源文件及回执摘要，运行独立只读 review。候选变化后按影响复核；本地结果、最终 SHA 的 CI、真机与发布各自登记。[Hysteria 2 协议](https://hysteria.network/docs/developers/Protocol/) · [现有桥接生命周期](../../../apps/ios/EmbeddedCore/bridge/bridge.go) · [计量实现](../../../services/access_account/xray_meter/xray.patch)
