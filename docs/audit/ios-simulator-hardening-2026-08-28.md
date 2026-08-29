# GCSA-aegis iOS Simulator 硬化验收记录

- 日期：2026-08-28
- 当前结论：`SIMULATOR_QUALIFIED_HARDENED`
- 安全结论：仅在本记录冻结的本地离线/Simulator 范围内通过
- 项目发布状态：`release No-Go`
- 历史基线：[iOS Simulator 资格验收记录](./ios-simulator-qualification-2026-08-28.md)

## 1. 本轮目标与完成标准

本轮在既有原生 SwiftUI/WKWebView iOS 工程与 Aegis Agent v1 基线上，直接完成以下硬化，
不恢复“WebKit 浏览器 + 同源 WebExtension”真机垂直切片作为前置门：

1. 主浏览器导航必须在实际 `WKWebView` 主框架加载前经过 URL 清理和钓鱼策略。
2. Safari 只读授权必须绑定真实文档身份与导航代次，授权前保持零 DOM/location 读取。
3. 收藏整理与撤销必须使用加密、认证、防回滚的跨重启日志，崩溃窗口安全失败。
4. Agent 原生写操作必须经过任务授权、独立动作批准、Store 回执核对和 Broker 提交；恢复状态
   不得被普通工作流或生命周期切换静默清除。
5. Debug 测试入口不能进入 Release 可执行文件；iPhone/iPad 全量 Simulator 测试、定向安全
   测试和代表性可见操作必须全部通过。

这里的“完成”只代表上述源码与 Simulator 验收目标。真机、Safari/Share 系统权限、真实远程
模型、PII 出站、默认浏览器 entitlement、Archive、正式签名和分发仍是独立门禁。

## 2. 已完成实现

### 2.1 主浏览器实时导航策略

- 新增 `BrowserKit/NavigationPolicy.swift`，并由 `BrowserSession` 的主框架导航 delegate 在网络
  加载前调用。
- 只允许精确内部 `aegis` 路由与 `about:blank`；用户信息 URL、其他顶层 scheme、高风险钓鱼
  URL 和需要清理的非幂等 POST 均安全拒绝。
- HTTP(S) GET 在需要时先删除追踪参数再加载，界面明确显示“已清理”或“已阻止”。
- 单元与 UI 测试覆盖清理、阻断、credentials、未知 scheme、内部 fixture 和 POST fail-closed。

### 2.2 Safari 文档与导航身份

- `SafariReadOnlyGate` 的租约加入 isolated-world `documentToken` 与 `navigationEpoch`，并继续绑定
  profile、tab、frame、origin、route、worker instance、gesture nonce 与短租约。
- background worker 的预授权阶段不读取 DOM/location；授权后的单次注入脚本在同一快照中取得
  URL、文档身份和有界 DOM，再由 native host 精确消费。
- 文档、导航、URL 或快照身份不一致会先烧毁租约再拒绝；history state 变化会主动推进代次。
- Swift 测试与独立 Node harness 均覆盖正常消费、身份切换、缺字段和租约烧毁。

### 2.3 加密跨重启收藏事务

- 收藏 payload/journal 使用 Keychain 32-byte 密钥与 AES-256-GCM；文件采用 complete file
  protection，并限制 payload、envelope 和解密明文大小。
- Keychain 认证 head 覆盖 epoch、完整历史、收藏树、revision/mutation 与逻辑 journal；
  `record`、`clear`、`toggle`、`apply`、`undo` 均进入 `pending → 落盘 → committed`。
- 重启只接受 head 描述的 previous/target 合法崩溃窗口；旧 payload+journal、旧空 journal、
  ABA/state drift、重复撤销和篡改均 fail-closed。
- replace 或 File Protection 后置失败会冻结后续写入，不发布歧义状态；12 项 journal 测试全部通过。

### 2.4 Agent 授权、提交与恢复

- native capability marker 绑定完整授权和 cancellation epoch；验证先烧毁 marker，再核对当前资源。
- 原生写操作只能走 ticket 路径；Store 返回后立即进入 `nativeWriteAwaitingCommit`，核对回执、
  摘要与 journal 后才允许 Broker commit。
- 任一写后校验或提交错误都会保留持久恢复状态；普通任务准备、App 生命周期和模型重建不能
  清除，只有成功恢复或用户明确接管可以解除。
- 同进程与跨重启撤销都需要三个独立手势：选择意图、任务授权、R1 动作确认。
- 通用验证入口被收窄为只读 grant 与空 registry，不能绕过 native 写操作 broker。

### 2.5 Release 与测试基础设施

- 所有 UI 测试参数、测试收藏与持久化重置均受 `#if DEBUG` 约束；另修复了 Agent 恢复注入参数
  残留到 Release 的问题。
- Release 通用 Simulator 构建后扫描 App、三个 Framework 与两个 Extension 可执行文件，
  `--ui-testing`、测试持久化路径和恢复注入标记均不存在。
- `run-simulator-tests.sh` 现会先跑 Safari Node 文档身份测试，并要求 iPhone/iPad 两份
  `.xcresult` 摘要存在、可解析、结果为 `Passed` 且测试数大于 0；摘要失败不再被静默忽略。

## 3. 验证结果

### 3.1 工具链与源码身份

- 分支：`codex/aegis-local-dev`
- HEAD：`659891a8291019c006c54968bed2f4e0b61c1c20`
- 工作树：dirty，本记录绑定本地文件清单，不是干净提交或发布源码身份。
- Xcode 26.6（Build 17F113），iOS Simulator 26.5（23F77），Swift 6 严格并发。
- iOS 源码/工程清单：87 个文件；详细 SHA-256 见证据目录的 `source-files.sha256`。

### 3.2 静态、共享合同与脚本门

- `pnpm run quality:fast`：最终通过；Core 25 个测试文件、163 项测试全部通过，浏览器脚本
  自测、仓库合同和 Core build 同时通过。
- `swiftc -parse`：当前 Swift 源码与测试通过。
- `git diff --check`：通过。
- fixture：22 个文件通过，研究来源 10 个，最终提交保持禁止。
- Safari navigation identity Node harness：通过。

### 3.3 定向与全量 Simulator 测试

- 安全定向单元/集成：70/70 通过，0 失败、0 跳过。
- 安全定向 UI：4/4 通过，覆盖导航阻断、参数清理、同进程撤销和跨重启撤销。
- iPhone 17：113 项，112 通过、0 失败、1 跳过、0 expected failure；跳过项仅适用于 iPad 分栏。
- iPad Air 11-inch (M4)：113/113 通过，0 失败、0 跳过、0 expected failure。
- 两端构建链同时覆盖 Aegis、BrowserKit、AegisPolicyKit、AgentKit、SafariWebExtension 与
  ShareExtension；两个 Extension 仍没有独立真实系统宿主测试。

### 3.4 Release 隔离

- `Release` + generic iOS Simulator + `CODE_SIGNING_ALLOWED=NO`：构建通过。
- 产物架构：arm64 + x86_64。
- 六个可执行文件的测试标记扫描：0 命中。
- 这只是未签名 Simulator Release 构建，不是设备 Release、Archive 或分发产物。

### 3.5 Computer Use 可见验收

使用 Computer Use 实际操作 `Aegis QA iPhone 17` Simulator：

1. 输入高风险 URL 后，界面显示本地评分 85 与“请求未加载”，原有页面仍可见。
2. 输入带 `utm_source` 的 URL 后，地址变为 `https://example.com/?keep=1`，界面显示已移除参数。
3. 浏览器管家经任务授权和独立 R1 确认，将 4 条收藏整理为 3 条；远程请求显示 0。
4. App 重启后只出现“检查并撤销”入口；再次完成任务授权和独立 R1 确认后恢复 4 条收藏。
5. 再次重启，恢复入口消失，证明该撤销未被可见重放。

截图位于证据目录的 `visual-acceptance/`。

## 4. 证据目录

最新证据位于 Git 忽略的本地目录：

`<repo>/.artifacts/ios-simulator-hardening-2026-08-28-v5`

其中包含：

- iPhone/iPad 全量 `.xcresult`、摘要、日志与 run metadata；
- 70 项定向安全单元和 4 项定向安全 UI `.xcresult`；
- Release 隔离、Computer Use、源码身份与工具链记录；
- 四张可见验收截图及最终 `SHA256SUMS`。

未复制 DerivedData，也没有创建签名或可分发包。

## 5. 剩余风险与发布门禁

### 5.1 真实页面与 Safari 发布阻断项

- 当前四个 Agent 工作流仍是离线确定性流程；页面工作流尚未把字符串级 read authorization
  接到实际 DocumentLease/navigation。现有 origin 归一化对非默认端口和 IPv6 也需要发布前修正。
  在接入真实页面读取或远程模型前，这些属于 P1 发布门。
- Safari native messaging、Private Browsing 上下文、worker 回收/轮换和权限生命周期未在真实
  Safari/真机验证；当前 Node mock 不能证明 native application ID 投递，缺失/不支持的 incognito
  API 也需改成未知即拒绝或取得真机证据。当前源码不能替代系统宿主证明。
- 授权后形成的旧文档不可变快照在导航竞态下仍可能被消费，但不能读取新文档；发布前需决定
  是否增加消费时的宿主级当前文档再确认。

### 5.2 导航、存储与网络边界

- 导航测试证明 delegate 决策与可见结果，但尚无网络层“零请求”仪器，也未覆盖真实站点的
  全部重定向逐跳、认证挑战、下载切换和进程恢复矩阵。
- Keychain `ThisDeviceOnly` 密钥在新设备恢复时会 fail-closed，目前没有 Release 迁移/恢复产品
  流程；anti-rollback 仍是首次锚定、同容器路径和完整 Keychain 的边界，认证 head 可进一步做
  HKDF 域分离，并补 journal post-replace 故障注入。
- 当前 Extension 不写收藏；若未来增加多进程 writer，必须先加入跨进程文件锁与冲突协议。
- Safari gesture nonce 累计 4096 次后会在当前 native host 进程生命周期内永久拒绝新授权；这是
  长时间运行可用性边界，不是当前权限绕过。
- 收藏标题与 URL path 尚无单条显式长度上限；整体 envelope 上限能限制总量，但发布前仍应补
  单条约束与局部 DoS 验证。

### 5.3 未完成的平台与发布工作

- PII Scanner 尚未接入真实出站或模型网络链；没有生产远程 AI/provider 路径。
- Share inbox 尚未在消费导航前接完整 PolicyKit 扫描。
- 最低系统、多 runtime、真实站点、性能、完整无障碍、隐私和真机生命周期矩阵未完成。
- 真机安装、Safari/Share 权限与 App Group、默认浏览器 entitlement、Privacy Manifest、正式
  provisioning/signing、Archive、TestFlight、App Store、升级与回滚全部为 `NOT_RUN`。

## 6. 最终结论

本轮指定的原生 iOS + Agent Simulator 开发目标已经实现并通过双端全量测试、Release 测试入口
隔离和实际界面验收，可以作为后续真机与发布硬化的代码基线。由于真实页面 Agent、真机系统
扩展、出站 DLP、签名和分发门仍未关闭，项目整体继续保持 **release No-Go**。
