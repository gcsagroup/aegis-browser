# 网站加速 Beta 分类与官方更新实施计划

主负责人先发布[本次设计](../specs/2026-11-21-geosite-updates-design.md)和本计划，再开始产品代码。代码参考基线 `24c3b9a1d4ff80c16966883de43976bc780f1afc`；[d046ab4e](https://github.com/quinn521/aegis-browser/commit/d046ab4e454919f52de1a828639e0983a0282e3d)仅为已替换的历史计划，不再准备团队信封、URL、密钥或发布服务。iOS #402、macOS #403 的既有 V2Fly 证据保持原身份。

按 **U1a 可用分类 → U1b 官方准入 → U2 冷恢复 → U3 原生 HTTPS → U4 联合切换 → U5 交付** 执行。每步保存能暴露行为差异的 RED，再最小实现并重跑同一用例为 GREEN；构建失败／未发现测试不算 RED。新增单元与历史回归均须实际执行，保留失败、预算、owner 和 FIRST，不借其他平台成绩验收。

## U1a：先交付真正可选的 Beta 分类

**RED**：在现有 [SettingsLayoutUITests](../../../apps/ios/Tests/AegisUITests/SettingsLayoutUITests.swift) 与 [AccessHostRecoveryWebKitTests](../../../apps/ios/Tests/AegisTests/AccessHostRecoveryWebKitTests.swift) 新增行为用例。实际打开「设置 → 国内加速 → 网站加速」，智能下能进入「加速分类 Beta」，看到 Debian／豆瓣／美团并增删选择；核对导航、Beta 只读一次、名称／值／selected trait、大字体换行、非空／未选择提示。记录旧 App 缺入口及新增分类不影响路由的失败。

**RED**：拟增 AccessGeoSiteSelectionTests，覆盖首次手动+DEBIAN、已有手动／智能迁移、exact 保留、显式空集合与缺字段不同、最后一项可取消、重启仍为空、手动保留选择、双普通窗口同步、重叠 OR。private／Guest／非 DEV／unknown／其他 owner 从 UI 与原生直接调用均不能读写／触发；候选在列表打开后变化，旧勾选不能授权。

**GREEN**：从设计固定的官方 raw DAT 提取完整 DEBIAN 2、DOUBAN 3、MEITUAN 19 条，校对三个 typed SHA 与真实 iOS PSL；只捆绑三组小快照、来源清单及继承 MIT／XTLS 元数据。新增最小 GeoSiteCatalogue／选择模型，在 [BrowserSettings](../../../apps/ios/AegisApp/BrowserSettings.swift)、[路由策略](../../../apps/ios/AccessKit/AccessHostRoutingPolicy.swift)与[协调器](../../../apps/ios/AegisApp/AccessHostStoreCoordinator.swift)接线，复用既有模式／exact／lease，加入首次使用的本机初始化与原子选择保存；U2 再扩展官方版本账本。此阶段无更新网络，不能以空页面或无动作勾选交付。

**GREEN**：列表保留名称和勾选状态，美团注明含大众点评；展开详情可查看版本、条数、含子域说明和完整范围。用户新增选择即绑定当前完整分类，不另弹重复初始确认。用实际控件启用／取消后，真实 BrowserTab 输入标准 URL `https://debian.org/`、`https://www.douban.com/`、`https://www.meituan.com/`、`https://www.dianping.com/`；不得只靠改写为 `.geosite.invalid` 的域名证明产品接线。受控双出口记录目标 authority，正确侧 >0、错误侧 0；每轮用独立未命中 URL 正对照证明原路径确实可观测，取消唯一分类后的新导航与 exact service/original/clear 分别核对。

**完成条件**：可安装普通 DEV 中三组确实改变路由，空选择与跨窗／重启生效，未选的豆瓣／美团不贡献规则；UI、数据模型、路由测试和受影响回归全绿。U1a 仅证明签名内置分类，不登记为官方热更新完成；验证未更新的新安装在离线时可用 App 签名的内置分类；已采用远端版本的分类按七天期限与退休状态恢复。

**U1a 模拟器回执。** iPhone 17（iOS 26.5）上，初次界面测试找不到分类入口，初次分流测试记录到豆瓣发往原连接。实现后同一组受影响测试 90 项通过，失败和跳过均为零。普通窗口实测只选豆瓣、清空、切换手动后恢复选择以及重启保留空选；最大辅助字号下分类行可操作，私密设置中无此入口。两个真实 WebKit 窗口分别观察所选豆瓣、Debian、美团、大众点评的 CONNECT 及独立原连接对照。测试使用本机监听器，公网加载耗时和吞吐量另行测量。复跑 `WebKitProtectionTests` 时需启动仓库的 `apps/ios/scripts/simulator-fixture-server.py --port 8768`，并将被测页面挂到真实测试窗口再加载。

在两个普通窗口中，已打开的豆瓣页面可在 Debian 新导航等待服务期间被另一窗口选中。回归测试先在真实 HTTPS 页面观察请求，再分别验证放行 Debian 和取消 Debian 后的迟到回调。修复前两种场景均失败。修复后覆盖两个场景及既有回归的 17 项原生测试通过，未跳过。测试证书在构建 XCTest 时临时生成。

## U1b：官方 wire 与严格准入

**RED**：拟增 AccessGeoSiteAdmissionTests／SourceTests，输入真实 7,750,066 字节 DAT 及同 tag API／checksum 回执，检查完整 1,572 组和三组精确摘要；同时覆盖 full/domain、标签混淆、IDNA、根点、实际 PSL 的 ICANN/PRIVATE／通配／例外、共享后缀和不明租户。构造属性／regexp／未知类型、重复目标、坏行、截断／部分文件、恶意 varint／长度／深度／计数／16 MiB 超限；非菜单组含不支持语义可安全跳过，所选目标任一坏行必须整候选失败。

**RED**：校验同 tag 两资产、唯一名称、API SHA 与 checksum 一致；错库／错 URL／缺 SHA／低 tag／同 tag 异字节或修改发布时间拒绝。14 位 ASCII tag 的非法日期、Unicode 数字、future published_at、超七天均失败。较高 tag 重发旧内容可准入；完整新版缺组／空组产生持久移除，坏组不等同移除，404／门禁／未知 schema 不撤回有效 active。

**GREEN**：在 AegisPolicyKit 增加有界 raw protobuf 读取、官方回执与 immutable typed index；扩展 RegisteredDomain 的严格失败查询，保留旧调用语义。所有上限、canonical digest、固定来源及时间条件以设计为唯一合同。应用仍只展示已批准三组，不把整个官方 registry 当作可选菜单；不增加 gzip、远端自定义来源或新规则种类。

**完成条件**：真实官方输入和敌对 fixture 均得到预期结果，全部字节校验先于切换；三组原始行／摘要／许可与 bundle 清单可重现。原始下载解析成功只登记来源准入，不替代原生网络或产品行为。

## U2：离线启动与可崩溃的原子安全持久化

**RED**：拟增 AccessGeoSiteCacheTests／PublicationTests，覆盖首次初始化、旧偏好迁移、主动空选、离线重启、待确认 H 高于有效 active、较高官方 tag 重发旧内容。分别在临时写、fsync、rename、账本提交前后终止进程；注入磁盘失败、Keychain 锁定／写失败、偏好回滚、账本冲突、active 丢失／损坏且目录残留旧包、时钟回拨与到期后调回。

**RED**：完整新版删除／清空一个已选组，同时另一组扩围待确认；移除必须立即持久，另一组旧有效授权保留。删除缓存、重启、切手动再回智能不能复活被移除／退休的内置或已到期的远端版本；失效或不能恢复不能变成 original 放行。关闭持久化失败须显示未保存，不宣布重启仍关闭；普通恢复不能读取别的 owner 选择。

**GREEN**：在 AegisApp 增加最小 GeoSiteCache／SecurityLedger／UpdateCoordinator，使用同目录原子聚合文件与本机不可同步 Keychain 单条提交记录；存模式、选择、每组 scope／版本／状态、H、文件 hash、clockFloor 和退避。一次 DAT 抽取多个组，按版本／授权范围聚合保存；不按组重复下载或保存整份 DAT。账本提交串行化于现有生命周期入口，冷启动只读当前已提交快照、不等待 HTTP。

**完成条件**：真实文件与原生安全存储经过进程终止／重启，而非仅内存 fake；每个断点可判断恢复旧提交或精确新提交，决不出现半快照、旧包扫描回退或重复安装续期。继续有效 active 可抗坏更新；范围不明和已知保护路径封闭，其他独立授权仍可用。

## iOS 已验证的官方准入与冷恢复

在 iPhone 17（iOS 26.5）模拟器中，准入测试先用真实发布和异常输入复现 9 项失败。实现后，17 项规定用例全部通过。原生解析器读取标准版完整的 7,750,066 字节，检查到 1,572 个分类。Debian、豆瓣、美团的规则和两份资产摘要均符合发布记录。[Xray 官方版本 20261120235103](https://github.com/XTLS/Xray-rules-dat/releases/tag/20261120235103)

冷启动测试先有 8 项失败。实现后，66 项用例通过，覆盖 Keychain 与本地文件恢复、写入中断、文件损坏、规则到期、时钟回拨、旧版本及取消选择。普通用户可以保留空选。收窄或撤回旧范围会立即生效，扩围保留待确认状态。真实设置界面在清除一般偏好后重新启动，仍从独立缓存还原所选分类。

双窗口回归还覆盖从豆瓣返回浏览器内置首页，再从另一窗口勾选豆瓣。首页必须保持可用，仍停留在豆瓣的文档则按新策略退场。在修复前复现首页被误停，修复后 240 项模拟器回归通过。补齐分类品牌的本地化清单后，再跑 25 项针对性用例，失败和跳过均为零。官方前台 HTTPS 刷新及其与真实页面的联合切换见后续 U3、U4。

## U3：普通 DEV 的真实官方 HTTPS

**RED**：拟增 AccessGeoSiteUpdateTransportTests／EligibilityTests，让产品同一 URLSession 实现访问固定官方 latest、同 tag checksum 与 raw DAT；保存 HTTP 状态／主机跳转／字节／摘要回执。覆盖真实 200、强／弱 ETag、有效 304、丢回执／过期 active 后 304，以及退避后的无条件恢复；连续 304 不能改变官方发布时间和到期点。

**RED**：以隔离 HTTP/TLS fixtures 测错证书／host、元数据重定向、资产错误 CDN／二次跳转、206、压缩、慢流、错误长度、分块超限、404、限流和取消迟到回调。测试信任只限 fixture session，不改全局 ATS、信任库、DNS 或代理；这些失败夹具不是产品发布服务，不需要上游私钥。

**GREEN**：GeoSiteUpdateTransport 固定官方 API／资产构造与受限 GitHub→release-assets 跳转；无 cookie、credentials、Referer、跟踪或页面信息，使用系统 TLS／网络策略。流式有界哈希、单次在途、24h 刷新、持久退避与七天有效期进入普通 DEV 产品配置；不依赖账户节点，不借 mock fetch 宣称接通。

**完成条件**：三个已选组只有一份 DAT 下载；手动／零选／private／非 DEV／unknown／其他 owner 的触发网络为零。两个普通窗口合并请求，关一个不误停另一个，最后普通窗口离开／切手动／取消最后分类后无新请求且旧回调不能发布。原生记录核对启用时仅 api.github.com、github.com 和预期 CDN 控制面流量，禁用后无新增；浏览器服务出口不承载更新。真实官方 happy path 与受控失败 fixture 分开登记。

## U4：候选同意、全窗口与实际 WebKit 联合切换

**RED**：拟增 AccessGeoSiteSwitchingTests 并扩展真实 WebKit 回归：下载与取消／空选交错、列表打开后候选变化、确认与下一版本交错、exact 编辑 A 与窗口 B 准备、共享域多组授权、缺／空组与另一组扩围、同 scope 新版本、到期／坏缓存后的离线恢复。确认只批准展示的候选和新增 typed 覆盖，超过 32 条、拒绝或旧令牌保留仍有效旧范围；取消一组不能撤掉另一组或独立 landing 的 grant。

**GREEN**：在 changeWebsitePolicy／policyEpoch 上一次提交共享快照，按依赖取消／复核，不新建平行路由状态机。接入 [store registry](../../../apps/ios/AccessKit/AccessHostDataStoreRegistry.swift) 与 [BrowserSession](../../../apps/ios/BrowserKit/BrowserSession.swift)的文档退场：封发送、保持代理和 lease 至 inert 回执、再释放自己的 consumer；等价更新不批量 reload，POST／下载／长连接不自动重放。更新状态仅用简短用户提示，保留真实分类与本站 exact 控件。

**必须保留的 #402 回归**（在 AccessHostRecoveryWebKitTests 原样复跑，再增加更新交错版本）：

- `testGeoSiteReviewReloadRepreparesAuthorizedLanding`：失去入口后 landing reload 重新准备。
- `testGeoSiteReviewSiteChoicePreservesUnrelatedPreparation`：编辑 A 不取消 B。
- `testGeoSiteReviewSmartPreservesCommittedLegacyLanding`：切智能保留已提交 legacy，冷标签不继承。
- 后续 P2 新增：独立有效的已提交 landing 跨 exact service／clear 保留，清除 exact 不清独立 grant，也不授权同 host 冷文档。

**完成条件**：由真实设置与分类／本站控件驱动 U1a 的标准 host 流量，覆盖多窗口、重启、选／取消／空选及服务故障。受控 HTTP(S) 页面返回唯一 marker，双出口观察至真实文档／worker 退场；每场有独立正向见证，错误出口为零。检查重定向、子资源、准备暂停、共享 transport 与 POST 无重放；仅 CONNECT、reducer 或 stopLoading() 不能验收全部行为。

## iOS 前台更新与分类切换回执

普通 DEV 的智能模式已有前台刷新。成功后 24 小时内复用本地状态，多个普通窗口共用一次更新。手动、空选、私密窗口和非 DEV 的静默行为有原生测试。模拟器用产品下载器和系统 TLS 实际访问 Xray 官方发布，收到元数据、标准 DAT 及配对校验文件的 HTTP 200。标准文件为 7,750,066 字节，原生准入解析到 1,572 个分类，下一次条件请求返回 304。到期日仍从发布时间计算。[实际发布 20261120235103](https://github.com/XTLS/Xray-rules-dat/releases/tag/20261120235103)

设置里的「分类范围」可查看每组版本、域名和官方规则的到期时间。收到新增域名时先显示具体范围，批准后才启用。原生界面验证了豆瓣测试域名的批准和重启恢复。两个受控出口同时观测到文档、子资源、脚本和 worker。批准或撤回后，受影响文档的旧出口停止发送，另一已授权页面继续发送，受管侧只收到一次 POST。

最初的前台用例观察到零次发布请求。接入更新器后同一用例通过。首次大范围回归通过 249／251，两项失败涉及分块响应与异常编码的处理。修正后 11 项针对性回归通过。实际公网加载速度、物理设备、最终签名候选和托管 CI 各自验收。

## U5：证据、DEV 产物与交付

完整闭环为：普通 DEV 实际启用／选分类 → 官方 HTTPS → 全文件准入／必要范围同意 → 原子保存 → 多窗口真实 WebKit → 304 → 离线重启 → 官方缺／空组或到期后不复活；手动和空选另证零更新网络。按同一候选完成相应功能、构建、集成及功能测试后，才运行最终独立只读内置 codex review；交原需求、本设计、完整精确 diff、文件 hash 与原始回执，不依赖实现聊天。修复／rebase 后携带旧发现复审最终候选；未完成审查仍是开放门。

后续新增类均注册到 apps/ios/project.yml／生成工程；用现有 Aegis-Debug 入口逐类 RED/GREEN，输出至新任务目录。实施者核定 SIM_UDID、RESULT_ROOT、CORE_PRODUCTS、RUN_ID、TEST_CLASS，先按[既有 DEV 构建入口](2026-11-21-access-geosite.md#2-ios-dev-的网站加速)准备固定核心：

```sh
xcodebuild test -project apps/ios/Aegis.xcodeproj -scheme Aegis-Debug \
  -configuration Debug -destination "platform=iOS Simulator,id=$SIM_UDID" \
  -derivedDataPath "$RESULT_ROOT/DerivedData" -parallel-testing-enabled NO \
  -onlyUsePackageVersionsFromResolvedFile "AEGIS_EMBEDDED_CORE_PRODUCTS=$CORE_PRODUCTS" \
  -resultBundlePath "$RESULT_ROOT/$RUN_ID.xcresult" -only-testing:"AegisTests/$TEST_CLASS"
```

复跑所有新增类、AccessHostRecoveryWebKitTests、AccessHostWebKitRouteTests、AccessHostStorePolicyTests、受影响 PSL／WebKitProtectionTests 及设置 UI；UI 用对应 AegisUITests 选择。核对预期用例实际执行、零跳过；保存命令、退出码、xcresult 与网络附件。DEV 包检查三组清单、raw 来源 digest、PSL、许可、非 DEV 身份门，无测试 trust；保留既有 App Groups／扩展／开发签名，签名产物记录 App hash，真机安装验证按 exact build 单列。

分别报告：原始来源／完整集成／模拟器／签名 DEV 产物／真机／最终 SHA CI／发布。缺任何所需证据不能借其他栏通过；来源核验不代表产品通过。后续交付时刷新并遵循 [origin/develop 的 CI 指南](../../development/ci.zh-CN.md)，普通功能 PR squash 到 develop；合并与发布维持原授权。

在同一模拟器串行复跑同意流程：用仓库默认合成 HTTPS runner 写入待确认范围，中间跑 Beta 勾选／清空回归，再验证批准和重启。核对三项实际执行且零跳过。

```sh
python3 apps/ios/scripts/geosite-https-fixture.py --receipt "$RESULT_ROOT/$RUN_ID-geosite-https.json" -- \
  xcodebuild test -project apps/ios/Aegis.xcodeproj -scheme Aegis-Debug \
  -configuration Debug -destination "platform=iOS Simulator,id=$SIM_UDID" \
  -derivedDataPath "$RESULT_ROOT/DerivedData" -parallel-testing-enabled NO \
  -onlyUsePackageVersionsFromResolvedFile "AEGIS_EMBEDDED_CORE_PRODUCTS=$CORE_PRODUCTS" \
  -resultBundlePath "$RESULT_ROOT/$RUN_ID.xcresult" \
  -only-testing:AegisTests/AccessGeoSiteSettingsFixtureTests/testPrepareVerifiedStagedScopeForSettings \
  -only-testing:AegisUITests/SettingsLayoutUITests/testWebsiteAccelerationBetaSelectionAndPersistence \
  -only-testing:AegisUITests/SettingsLayoutUITests/testWebsiteAccelerationConsentAndRelaunch
```

## 后续平台

macOS 在 #403 已验证 V2Fly 静态实现上另做 Xray 来源迁移：真实 standard DAT 7.75 MB 已超过 scripts/dev/compile-geosite.mjs 的旧 4 MiB 上限，先为实际文件与超限攻击做 RED，再有界调整并核对三组、来源／许可／链接测试及平台 PSL；随后接相同分类、更新、范围同意与持久化合同。按 #209 原 owner／FIRST／预算安排 GN、编译、链接和浏览器证据，不能把 iOS 摘要或 JS 通过当作 Mac 编译成功。

Android 随后按 #210 原 owner、环境与预算接原生 Profile／Incognito、分类 UI、官方传输和安全存储，并取自己的构建／设备出口证据。HY2 的传输、账户计量与切换仍独立，不并入此功能。
