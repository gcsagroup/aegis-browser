# iOS Alpha 额度联调

## 范围

本阶段仅接入 3X-UI 3.11.0 面板只读查询，经轻量中转返回当前测试账户额度；不接入新的服务端计量、幂等结算或硬停流实现，也不以面板余额驱动客户端断流。不是新计费账本、购买或自动发放凭据实现。面板管理凭据不得进入 iOS、仓库、日志或公开证据。

本次面板联调唯一允许的客户端为 `test-reality-vision`；不得查询或修改 `quentin-v2ray`。中转的 `--alpha-panel-client` 精确限制一个操作者批准的测试客户端。其他账户绑定在访问面板前拒绝。客户端显示总额、上下行、已用、剩余；无测量水位时如实显示未知/陈旧，接收时间不能冒充测量时间。

`expiryTime=0` 表示面板节点未设到期。Alpha 响应使用 `panelExpiryMode=none`、`panelExpiresAt=null`，有效查询周期仍有限；界面分别显示节点到期和查询授权截止。普通模式显示当前账户，私密模式不继承普通额度展示。

前台额度区块可见时每次查询结束后等待 5 秒再刷新；其他前台浏览等待 30 秒。多个窗口共享一次查询与刷新计划。后台暂停轮询，回到前台立即查询。手动刷新首击立即执行，1 秒内的连续点击以及进行中的查询合并，不排队补发。当前账户查询失败后依次等待 15、30 秒，连续失败保持 30 秒；成功后恢复当前界面的正常间隔。切换账户清除旧账户的退避与点击状态，迟到的旧响应不得影响新账户数据或刷新计划。

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

真机不能访问 Mac 的 `127.0.0.1`。实际真机额度接入需要独立受控 HTTPS 中转与原生账户绑定入口；没有该入口时保持未验收，不把面板管理 API/token 直接交给 App。

## 验收边界

- 源目录、编译资源和 Foundation 语言验证不替代视觉/VoiceOver验收。
- 模拟器原生查询、真实节点拨号和真机产品验收分别记录。
- 面板已有累计值不是本项目幂等账本证明；禁用用户也不能推定旧连接已断开。
- 后续专用服务端保持 iOS 查询模型边界，替换权威用量来源；严格计量、预留与账户级停流另行实证。
