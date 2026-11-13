# iOS Alpha 额度联调

## 范围

Dev/Alpha/Beta 内置测试节点现在直接查询 3X-UI 3.11.0 的 HTTPS 订阅信息入口 `GET ?format=info`。响应中的 `uploadByte`、`downloadByte`、`totalByte` 为精确字节整数，`expire` 为 Unix 秒（0 表示未设到期），`enabled` 为面板状态。App 不访问面板管理 API，也不下载或应用订阅中的代理配置。既有 Aegis 账户查询与轻量中转仍是独立的账户服务路径，不作为本测试节点额度的依赖。

直读使用私有构建输入 `AEGIS_PRIVATE_TEST_SUBSCRIPTION_FILE`，默认 `/dev/null`；描述文件与实际内置节点的 SHA-256 绑定，仅在 Dev/Alpha/Beta 注入，其他渠道清除生成资源，运行时也检查渠道和绑定。描述文件包含 `subscriptionInfoURL`、`allowedTestClient`、`expectedQuotaBytes`（本测试合同为 10,000,000,000）、`trafficReset`（daily）。订阅 URL 具有凭据作用，不进入源码或日志；响应虽无 `links` 字段，仍包含订阅 URL，因此只解码所需字段，不记录或持久化响应体。面板管理凭据始终留在服务端。

读取拒绝重定向和非 HTTPS，使用系统 TLS 校验、独立无缓存无 Cookie 会话、有限请求时长和 64 KiB 响应上限。只有订阅身份、唯一批准客户端和预期总额度一致时才显示数值；缺失字段、整数溢出、身份不符或网络错误不能变成零余额。上次查询时间不是服务端测量时间；没有水位时标记未知。后台取消传输，迟到响应失效；普通窗口展示节点额度，私密窗口不继承此展示。额度只是观察，不授权代理、不触发直连回退。

每日重置、真实计量和耗尽停流仍由 3X-UI/节点执行，须分别留下真实验收证据；订阅计数不是幂等账本，`enabled=false` 也不是存量连接已断开的证明。本次不实现购买、账本或自动发放凭据。

本次面板联调唯一允许的客户端为 `test-reality-vision`；不得查询或修改其他客户端。服务端须确认专属订阅的绑定范围；仅凭可见响应中一个客户端，不能证明面板全局不存在停用或隐藏的同 SubID 记录。既有中转的 `--alpha-panel-client` 精确限制批准客户端，其他账户绑定在访问面板前拒绝。客户端显示总额、上下行、已用、剩余。

`expiryTime=0` 表示面板节点未设到期。Alpha 响应使用 `panelExpiryMode=none`、`panelExpiresAt=null`，有效查询周期仍有限；界面分别显示节点到期和查询授权截止。普通模式显示当前账户，私密模式不继承普通额度展示。

前台额度区块可见时每次查询结束后等待 5 秒再刷新；其他前台浏览等待 30 秒。多个窗口共享一次查询与刷新计划。后台暂停轮询，回到前台立即查询。手动刷新首击立即执行，1 秒内的连续点击以及进行中的查询合并，不排队补发。当前账户查询失败后依次等待 15、30 秒，连续失败保持 30 秒；成功后恢复当前界面的正常间隔。切换账户清除旧账户的退避与点击状态，迟到的旧响应不得影响新账户数据或刷新计划。

## TestFlight Beta 内置测试节点

本轮测试包允许 Beta 使用同一个私有节点与只读额度描述；Release/正式版仍清除资源并在运行时拒绝读取。节点与订阅 URL 不进入 Git，构建默认输入仍为空。Beta 打包必须同时显式传入 `AEGIS_PRIVATE_TEST_NODE_FILE` 与 `AEGIS_PRIVATE_TEST_SUBSCRIPTION_FILE`，并使用 `AEGIS_ACCESS_RELEASE_CHANNEL=beta`、匹配的 `AegisReleaseProfile=beta`。私有签名归档入口 `scripts/release/ios-private-test-node-archive.sh beta` 支持该渠道；节点通过受保护环境变量读入临时文件，额度描述通过文件路径构建参数传入。打包后核对两份资源、节点 SHA-256 绑定及各 bundle 的 Beta profile，再导出用于 TestFlight 的签名包。

默认云端无凭据归档不会自动取得本机私有配置，不能将默认空节点归档当作该测试 Beta。发布负责人必须使用上述私有输入归档；本 PR 不上传 TestFlight，也不修改现有云端无凭据归档的信任边界。

## 本机原生联调

先完成 Xcode 工程生成，提供已经验证的 EmbeddedCore products 和依赖缓存。私有 token 文件须为当前用户所有的普通非符号链接文件、权限 0600，父目录权限 0700。不要把 token 本文放进命令参数。

```bash
python3 -B apps/ios/scripts/alpha-entitlement-runner.py \
  --panel-url "$PANEL_URL" \
  --panel-token-file "$PANEL_TOKEN_FILE" \
  --client-email "$TEST_CLIENT" \
  --account-id "$TEST_ACCOUNT" \
  --output-receipt "$NEW_RECEIPT" \
  -- xcodebuild test <显式工程、模拟器和缓存参数> \
     -only-testing:AegisTests/AccessAccountAlphaLiveTests \
     -resultBundlePath "$NEW_XCRESULT"
```

runner 先通过实际适配器只读预检，再启动临时 loopback 中转和独立有限期 Aegis 会话；数据库仅保存会话摘要。只有该独立会话传入测试进程，面板管理 token 不透传。子进程输出被抑制，检查退出码、receipt 和 xcresult，不把启动成功当作联调通过。退出后清理服务和临时数据库。

`AccessAccountAlphaLiveTests` 是明确 opt-in 的受控 TEST 合同（每天 10 GB，即 10,000,000,000 B，上下行合计、面板无到期）。每日重置由面板按其服务器时区执行；测试按真实总额度校验剩余字节，不以查询时间替代测量水位。它不是通用用户数据测试，不能改用主账户执行。

上述 runner 用于模拟器的 loopback 中转。真机测试须在隔离签名变体中配置手机可达的受信任 HTTPS origin，并由可信原生测试启动器传入同名 `AEGIS_ALPHA_*` 临时 Aegis 会话。测试核对其与签名 origin 一致后调用正常的原生 `bind`，使用独立测试 Keychain；不放宽产品的模拟器环境入口或 TLS 校验。

## 隔离真机变体

`prepare-alpha-device-project.py` 在全新目录生成隔离测试工程与少量身份 overlay，不改原源码。独立 Bundle ID、App Group 和外部 URL scheme 必须一起隔离；保留原扩展与权限，Firebase 仅在该变体使用 disabled 模式。生成回执记录原始及 overlay 哈希，不能把变体称为未经修改的正式产品。

该脚本不构建、不签名、不安装、不修改 Apple 账号。需要先获得开发团队/设备授权，实际签名后核对 App 和扩展的 entitlement、组标识、包内节点选择及源码来源。不得用移除 App Group 权限的方式绕过配置失败，也不得覆盖设备现有商店 App。

真机不能访问 Mac 的 `127.0.0.1`。当前直读路径需要手机可达的受信任 HTTPS 订阅信息入口；历史账户中转路径仍需要受控 HTTPS origin 和原生账户绑定。两条路径不能互相冒充验证结果，也不把面板管理 API/token 交给 App。

## 验收边界

- 源目录、编译资源和 Foundation 语言验证不替代视觉/VoiceOver验收。
- 模拟器原生查询、真实节点拨号和真机产品验收分别记录。
- 面板已有累计值不是本项目幂等账本证明；禁用用户也不能推定旧连接已断开。
- 后续专用服务端保持 iOS 查询模型边界，替换权威用量来源；严格计量、预留与账户级停流另行实证。

### CI Beta 私有输入

本轮 TestFlight Beta 1.0.3 使用上游现有 `aegis-ios-signing` 受保护环境和显式 `manual` 签名。在派发时选择 `private_beta=yes` 开启注入。签名环境的 `AEGIS_IOS_TEST_NODE_BASE64` 和 `AEGIS_IOS_TEST_SUBSCRIPTION_BASE64` 分别保存已有私有节点文件和额度描述符的 Base64。真实值不得写入仓库、PR、workflow 输入或日志。

Simple/Full 仅为 Beta manual 包加载这两项 secret。打包器先消费并移除进程环境中的私有值，写入任务专属临时目录，沿用产品校验器验证输入，再向 Xcode 传文件路径。导出的 IPA 必须包含与输入逐字节一致的节点及绑定后的额度描述符；遗漏或不匹配直接失败，不产生成功交付收据。临时输入在成功或失败后清除。内置私有输入的 IPA 在同一个受保护的签名任务中直接交给 TestFlight。清除签名材料后才加载 ASC 上传凭据。公开 Actions 工件只保留构建身份与上传状态 JSON。任务结束时清理该次打包目录。

选择私有 Beta 时，准入只接受 Beta / manual / Package and upload。缺少任一签名环境 secret 时打包失败。Release 不加载这些 secret，产品打包脚本继续排除测试资源。默认 `private_beta=no` 使用普通打包方式。若上传响应丢失，使用版本及构建号执行 `Status`，对照永久 `upload-start` 和 `upload-result` 记录核对 Apple 结果。私有 Beta 没有公开 IPA 或 Full 恢复令牌。同一构建号不可重跑；确认结果后，若需重建，另选未分配构建号。
