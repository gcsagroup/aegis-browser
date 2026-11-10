> **当前已按用户指令恢复：优先推进第2项边界验收；100站作为来源库分5组、每组20站，每轮只选一组做smoke。此前Computer Use网址限制保留。最终将#97拆为iOS/macOS独立PR并更新对应issue。**

# Aegis macOS Access #139/#140/#141 — SDD Implementation Plan / TODO

> 执行方式：单一实现负责人，沿用本文需求、设计和验收追踪逐项推进；不委派第二个实现者。早期计划中的 skill 名称不增加当前工具或审批门。本文件是本聊天当前范围的执行清单，不新增发布权限。

**Goal:** 网站无法访问（默认保留原有连接）→ 失败页点击「通过代理重试」→ 真实代理就绪 → 原标签原网址最多重试一次；以真实 Aegis 和授权节点验收。故障不回落，普通 Profile 重启后策略正确。

**Architecture:** Browser 持有请求归属和私有通道；NetworkContext 原子安装完整策略/端点快照，并独立校验每一跳。CORS、预检、URLLoader 和 net 共用受管请求状态；内核实际就绪和持久恢复完成后才能发布可用状态。

**Tech Stack:** Chromium C++ / Mojo / GN / Ninja、macOS arm64、Xray、现有 AccessRuleStore。

**Spec:** [阶段一验收清单](../access-product-phase1-acceptance.zh-CN.md)、[功能拆分](../access-product-phase1-feat-split.zh-CN.md)、[本站意图 API](../macos-access-site-intent-api-NOTES.md)，以及本聊天已授权的请求隔离、持久恢复和原标签页重试要求。本文不将旧文档的历史状态当作当前证据；冲突时沿用当前任务授权和当前 AGENTS.md。

**最新快照：** 2026-11-11 05:22 Asia/Shanghai。PR97当前混合头4a658ab，macOS已交付检查点0948保留。0425/0aba8071为测试候选：完整chrome/相关目标build和GN检查PASS；本轮core10、async-store5、coordinator35均实际SUCCESS零skip，新增11项边界；另229项按二进制完全一致复用，共14目标279项适用原生证据。5个生产二进制与0419一致，0419实际CUA封存主流程/冷启动/故障/隔离证据按原范围复用。单组20站smoke仍PARTIAL，GUI取消竞态受工具策略限制，最终质量/独立审查/双PR及issue交付未闭环。

## 1. 状态与证据规则

- `[x]` 仅表示该条明确描述的范围已完成；不向上推导整功能完成。
- `[ ]` 表示未完成、部分实现、运行中或未验收；具体状态写在条目中。
- `PASS` 必须附候选身份、执行范围和原始结果；编译、隔离测试、完整原生测试、真实浏览器、独立审查分别记录。
- `${TASK_ARTIFACTS}` 指本任务既有 `access-macos-139-141` 证据根目录；物理绑定见本地 `progress.json`。本文件仅引用脱敏文件名，不记录节点凭据。
- `progress.json` 中 `verified`、`pendingSource` 和 `nextSteps` 含历史快照；读者应结合最新 `lastHourlyRound`、0375/0376 条目和原始 receipt，不能照抄旧的 pending 状态。

## 2. 约束与完成定义

- 单一实现负责人；保留其他窗口工作、旧 P01/T90 暂停边界与失败记录。
- 原生构建累计 48 小时、100 GiB；继续使用 `resource-budget.json` 的 `startedEpoch=1794254695.128022`，不重置、不重复申请。
- 该预算的时间截止为 **2026-11-12 04:04:55 Asia/Shanghai**；2026-11-11 04:00 快照剩余约 **24.0 小时**。以账本及守护程序为准，不能将一周开发目标理解为额外构建授权。
- 最新生产验证候选0419（79eec0e7）：完整chrome/13正式目标263项PASS零skip；核心主流程和恢复/隔离实际CUA证据已封存PASS。0420–0423仅测试变更，新增边界仍在验证，生产二进制须按哈希对应后才复用0419适用证据。405为历史旧节点基线，当前单组smoke为PARTIAL。
- 当前受管产品执行先覆盖 HTTP 本机入站；SOCKS5 未产品验收，不能因独立核心测试通过而标成完成。
- 使用用户新提供并指定为Alpha内置测试的节点；私有引用见本地alpha-test-node-binding.json。旧V2Ray节点配置及证据保留，不自动回退或转移验收；凭据不进入文档、日志、补丁或PR。
- 最新用户授权最终将#97拆成iOS/macOS独立两份PR，并更新对应issue；此前先更新PR再扩展的0948检查点顺序已完成。保留#97历史、最新iOS提交与其他窗口工作，不强推。仍无独立评论、合并、签名、DMG或发行授权。
- **退出条件：** R1–R7 对应任务及必要测试完成，同候选真实 Aegis 浏览器验收通过，问题修复后对最终候选完成最新 AGENTS 要求的 fresh read-only 内置独立审查，无未解决阻断项（PR 自动审查须另外取得 PR 权限），再停用 `aegis-macos` 循环。

## 3. 需求 → 设计 → 验收追踪

| ID | 必须满足的行为 / 不变量 | 实现任务 | 验收条件 | 当前状态 |
| --- | --- | --- | --- | --- |
| R1 | Browser 私有权限不可由 renderer 字段伪造；保留原工厂安全参数 | T1 | 私有工厂接通；来源锁、非可信 TrustedParams、失效归属拒绝且零发送 | 0419 Browser终端/可信归属已连接；13目标263项正式原生测试PASS，真实普通/私密路径已验证；最终审查仍缺 |
| R2 | 每跳独立决定 native / proxy / reject；预检、连接池、认证和缓存不串用 | T1、T2 | 导航/子资源/重定向按当前策略；无 DIRECT 降级、旧代际复用或共享代理授权 | 私有factory/wire/CORS回归PASS；0419网站根域/www/CDN实际代理及独立CDN原生隔离有证据；100站仅部分，不扩称全协议验收 |
| R3 | NetworkContext 完整快照安装及精确 ACK；恢复期间先阻断再发送 | T2 | 重启/断连/乱序 ACK 不放行；新 incarnation 完整恢复后才发送 | 0419实际新Network进程暂停时已开气泡保持ALLOW但unavailable；恢复ACK后原页代理/ready，修复已实测PASS |
| R4 | 真实内核启动、认证入站和指定目标路径均就绪后才显示可用 | T3 | 启动失败、错凭据、进程退出均 fail-closed；实际目标经授权出口 | 0419实际Alpha内置/完整ACK/加载及退出恢复PASS；0425对应core10含6项故障与取消/25秒超时PASS；占端口与更多GUI故障范围仍未全验 |
| R5 | 普通 Profile 持久恢复；私密 Profile 不落盘且相互隔离 | T4 | 重启恢复已提交意图；损坏/未提交事务不误放行；首次请求不抢跑 | 0417迁移保留旧精确grant；0419普通冷启动/私密清理重开PASS；0425原生store43/async5及新Open失败/持久提交失败回滚恢复联合用例PASS，GUI故障范围另列 |
| R6 | 真实 ready 后，仅原失败标签页、原导航最多自动重试一次 | T5 | 新导航、关闭、停止、POST/TLS 错误均不误重试 | 0419受控DNS及自然Pinterest一次Retry原页加载PASS；helper15及0425新4项导航/持久提交联合用例PASS；实际GUI取消竞态仍缺 |
| R7 | 实际 macOS 浏览器完成开启→指定出口→故障→恢复→关闭 | T6、T7 | 同候选日志、关联 ID、界面证据与最终独立审查闭环 | 0419核心主流程/五步/普通和私密/Network故障PASS；100站20自然尝试、10最终页面观察、80未运行，CUA网址策略中止；最终审查未运行 |

### 审查与测试重点

- Network Service 重启恰逢导航/预检/重定向：旧引用不可再次发包（T1/T2）。
- Profile 关闭、标签页销毁与异步 ready 同时到达：不访问失效对象、不重试新页（T3/T5）。
- 同源重定向 URL 覆写、跨域跳转、方法改变：私有批准与实际发送一致，CORS 仍有效（T1）。
- 内核可监听但目标不可达，或认证失败：不得仅以端口可连接显示 ready（T3）。
- 存储中断、损坏、恢复期间首次导航：不把空/旧策略当成已完成恢复（T4）。

## 4. 已完成对象及证据边界

| 对象 | 已有证据 | 未被该证据覆盖 |
| --- | --- | --- |
| 0357 会话/气泡/存储 | 57 项原生测试（历史候选） | 当前完整产品路径 |
| 0367 原标签页 retry helper | 10 项原生测试；0367 依赖重建 31 项通过 | 产品 ready 回调、真实浏览器重试 |
| 0368 连接池/路由传播 | `route-integration-368-result.json`：32 项原生测试；实际 TCP 隔离 | 当前最终候选和 Browser 注入 |
| 0369–0370 HTTP/URLRequest | `url-request-route-green-result.json`：8 项实际 HTTP/URLRequest 测试 | Browser→Network 私有通道 |
| 0371 终端工厂钩子 | `terminal-factory-green-r4-receipt.json`：17 项隔离原生测试 | Browser 调用方改接 |
| 0372–0373 注册表/每跳状态 | `request-route-state-green-r2-receipt.json`：31 项隔离原生测试 | NetworkContext 安装和跨进程生命周期 |
| 0374 Network URLLoader | `network-url-loader-green-r5-receipt.json`：4 项实际网络测试 | 最终全依赖 ABI / 产品集成 |
| 0375 CORS 与预检缓存隔离 | 缓存回归先失败后修复；`cors-route-cache-green-receipt.json`：5 项通过 | 真正私有 IPC 请求 |
| 0376 独立 CORS owner 与 IPC 定义 | `cors-route-owner-green-receipt.json`：6 项通过；`private-mojo-compile-receipt.json`：4 个生成 C++ 单元编译通过 | 私有 factory/control 实现、GN 全目标构建 |
| 0377 私有 factory/control | `private-factory-registry-green-receipt.json`：15 项真实 IPC/CORS/HTTP 测试通过 | Browser terminal、NetworkContext 创建 API |
| 0378 快照/认证绑定 | `route-wire-literal-green-r2-receipt.json`：5 项通过；同 ID 换凭据及非规范 loopback 输入的失败记录保留；31 项既有回归通过 | 跨进程发布与 ACK |
| 0379 Context 状态容器 | `context-state-auth-negative-green-receipt.json`：19 项通过，含正确/错误本机认证、恢复、外来 Profile 和旧 incarnation | 真实 NetworkContext 接合、Browser 产品入口 |
| 0371–0376 补丁 | 分段 replay 精确字节匹配；`pending-375-replay-result.json`、`pending-376-replay-result.json`、`patch-format-r15.log` | 应用到运行中原生树、最终完整 lineage |
| 0380–0384 真实 NetworkContext 接合 | `native-private-context-384-tests-result.json`：8 个正式 GN 测试目标全部通过，含 21 项真实 Context IPC；完整依赖构建 PASS | Browser terminal 与发布调用、内核就绪、持久恢复和真实浏览器验收 |
| 0385–0387 Browser 私有 Context 客户端 | `native-browser-context-387-tests-result.json`：25 项 Browser 客户端、22 项 Context IPC、17 项终端回归通过；正式 GN 依赖构建 PASS | 现有 Browser wrapper/transport 与产品气泡尚未使用该客户端 |
| 0388 启动/恢复发布代际 | `native-publication-reserve-388-tests-result.json`：38 项正式原生存储测试通过；预留跨重启不复用，未提交事务阻断恢复 | 产品初始化/失败恢复调用尚未连接 |
| 0389/0390 恢复运行时与完整快照转换 | 运行时/新转换测试编译通过；389 正在构建，390 在输入外分阶段回放一致 | 运行测试 NOT_RUN；现有 wrapper/transport 调用未接 |
| 0391 异步存储 | `async-store-isolation-green-receipt.json`：5 项隔离测试通过，依赖元数据和 base/net/sql 库哈希稳定 | 尚未应用原生树；GN/产品 Profile/coordinator 接线 NOT_RUN |
| 0392 不可用代理组 | `request-route-state-unavailable-green-receipt.json`：34 项隔离注册表/每跳/策略回归；`route-wire-unavailable-392-green-receipt.json`：7 项解码测试通过；Browser/新 Mojo 编译通过 | 新增完整 GN/Context IPC NOT_RUN；混合新旧协议对象的 ACK 隔离运行 INVALID；产品内核与恢复接线未完成 |
| 0393 C++ 自有核心准备 | `local-core-real-node-r2-receipt.json`：3 项运行测试 PASS，含授权节点真实 HTTPS204、复查、停止后失败；基础库哈希稳定 | 产品注册、路由 ACK 与真实浏览器加载不由此证明 |
| 0394 失败页产品入口与重试接线 | Browser/renderer 错误页 IPC、按钮、controller/factory/helper 编译通过；`error-page-retry-helper-r5-receipt.json`：13 项 WebContents 测试 PASS；16 文件精确回放 | GN 依赖检查/一致原生构建/真实 IPC/按钮可见与 CUA NOT_RUN；普通 Profile 初始化/核心端点注册及完整私有发布仍缺 |
| 上游 Xray / 授权节点 | `xray-asset-manifest.json`；独立 HTTPS 成功、停止失败/恢复成功；正确/错误/缺失认证用例 | Aegis 产品内核管理和浏览器真实节点验收 |

测试数量存在包含关系：5 项 CORS 测试包含于后续 6 项；19 项 Context 测试包含多个私有 factory 用例，31/32 项也不可简单相加为“总覆盖率”。

## 5. 可执行 TODO

以下任务均按“先固定可复现失败/边界 → 实现 → 跑受影响测试 → 记录证据”执行。不在实现小步骤中增设审查门。旧版“取消提PR前review”的规则已被最新用户AGENTS覆盖：完成特性路径和必要验证后，代码交接前必须用fresh只读内置codex review；修复后复审最终候选。PR自动审查和操作权限另行记录。

**当前最高优先级：** 先接通上述可操作主流程，不能仅累计独立组件测试。失败页 Browser 入口与受影响持久恢复、真实核心注册/完整私有路由发布、就绪后原标签一次重试是同一退出路径；仅有按钮、LISTEN、ACK 或 curl 均不能勾选主流程。

### T1 — 接通私有 factory/control 与 Browser 终端（P0；R1/R2）

**现有入口：** `apps/browser/overlay/chrome/browser/aegis/access/access_proxying_url_loader_factory.cc`、`access_proxying_url_tracked_request.cc`；Mojo 定义在 `apps/browser/overlay/services/network/public/mojom/aegis_access_route*.mojom`。上游改动通过补丁维护，不直接改变正在构建的输入。

**接口：** 使用 `URLLoaderFactoryBuilder::SetTerminalFactoryInterceptor`、`AegisAccessURLLoaderFactory::CreateLoaderAndStartWithRoute`、`AegisAccessURLLoaderControl::FollowRedirectWithRoute`、`CorsURLLoaderFactory::CreateLoaderAndStartWithAccessRoute`。

- [x] 保留原工厂参数的终端钩子、CORS 私有状态传播、独立 owner 生命周期接口和 IPC 定义。
- [x] 0377 新增 `services/network/aegis/access_private_url_loader_factory.{h,cc}`，内含每请求 loader/control，直接拥有原 CORS 工厂；15 项真实 Mojo/CORS/HTTP 测试通过。此项不包括 NetworkContext 创建入口或 Browser 调用方。
- [ ] 固定 owner/document/navigation/top-site/incarnation 绑定；初次 envelope 的 URL、method、hop=0、request token 必须匹配真实请求。
- [x] 0377 接收端：公共 `URLLoader::FollowRedirect` 不得批准受管跳转；私有控制逐跳核验 token、incarnation、hop、URL、method 和新策略，再交给原 CORS/header 校验。
- [ ] Browser 从前置 Append 改接终端钩子；保留 pending-document 到真正 commit 后才绑定的语义；受控 native 请求也跟踪重定向。
- [ ] 单测/集成覆盖伪造与重放、断连、clone、销毁、native↔proxy↔reject、预检拒绝、同源 URL 覆写及跨域重定向；断言拒绝路径零发送。
- [x] 0377 接收端通过真实 Mojo 消息运行 15 项用例，包括 native→managed、公共跳转拒绝、同源 URL 不一致、clone 重放和控制通道断开；`private-factory-registry-green-receipt.json` 覆盖认证绑定修复后的注册表。Browser 端到端仍在 T6 未勾选。

### T2 — NetworkContext 完整快照和恢复屏障（P0；依赖 T1；R2/R3）

**文件：** `access_network_context_transport.{h,cc}`、`access_published_request_runtime.{h,cc}`、`access_service_coordinator.{h,cc}`；overlay `services/network/aegis/access_route_registry.*`；补丁内 `network_context.{h,cc}` / `network_context.mojom`。

- [x] 原子完整注册表、RESTORING、代际高水位及注册身份校验已实现并局部测试。
- [ ] 实现 Browser→Network 的完整 policy + 所有 group endpoint 快照转换与安装；精确 ACK 绑定 owner/incarnation/sequence/generations。
  - 0378 已完成严格解码/校验；0379 的 `AccessNetworkContextState` 已完成容器级原子安装、归属绑定与私有工厂创建；0380 已实现 Browser-only NetworkContext 安装/恢复/工厂创建入口及不含凭据的精确 ACK；0384 的正式 GN 构建和 21 项实际 IPC 测试通过。0387 的 Browser 客户端已通过发布/ACK/工厂创建联合测试，现有 wrapper/transport 调用仍未切换。
- [x] 0388 存储 API 可为已提交内容（含空策略）持久预留新发布代际，保留规则行；38 项原生存储测试通过。此项不代表产品启动/恢复调用完成。
- [ ] 用私有注册表替代本服务通过全局 `CustomProxyConfig` 选择代理的路径，保留用户原生连接配置语义。
- [x] 0378/0379：本机入站凭据写入对应 route 私有认证缓存；实际私有 IPC 的预检和请求经认证入站成功，错凭据实际请求零发送。同 registration ID 换凭据回归先失败后修复；Browser 创建 API 的权限边界仍待接通。
- [ ] Network Service 断连/重启时建立新 incarnation，先 RESTORING；完整恢复和 ACK 前不放行受控请求。空策略必须明确安装，不以“无数据”推断 native。
- [ ] 回归覆盖旧 ACK、旧注册、回滚/乱序、部分快照、同 ID 换端点、跨 Profile/partition、原生代理配置改变；记录 native/proxy/cache 隔离证据。

### T3 — 产品内核准备与真实目标就绪（P0；依赖 T2；R4）

**文件：** `access_site_proxy_bubble_controller.*`、`access_network_context_transport.*`、`access_service_coordinator.*`；建议新增独立 `access_local_core_manager.*` 管理进程和取消。

- [x] 从上游生成 macOS arm64 核心，独立授权节点与认证探测已有证据。
- [x] 产品开启与恢复命中请求均走真正异步核心准备/复核，endpoint检查仅用于准备后注册核验；0414/0419源码及cua-main-flow-419-pass-receipt.json。
- [x] 校验核心身份、受限本地配置、自有进程和认证TLS探测后注册发布；0419实际入口/核心与原页加载证据，0425 core10正式用例按范围验证；不把探测成功等同页面成功。
- [x] 原生取消/超时/退出/旧回调撤销及清理：0425适用core10、helper15、新导航4项PASS；0419实际自有核心退出/恢复和私密清理PASS。实际GUI取消竞态仍在T6开放，未动原V2Ray。
- [ ] 故障矩阵仍有占端口及GUI边界未全验；原生启动退出/无认证TLS/错认证/认证后目标不可达/挂起取消/25秒超时6项已PASS，0419真实core退出保留ALLOW/可读unavailable且无DIRECT回落PASS，不能由此全勾选此矩阵。
- [x] 受控Alpha/DEV产品身份在真实准备/注册路径提交，按Profile归属及构建输入绑定；正常产品未启用Alpha私有输入，不以测试调用替代产品来源。证据0419实际内置核心/原生coordinator测试。
- [ ] 覆盖“已保存代理规则但内核启动失败”的恢复：命中请求失败、未命中请求仍走原生；需要明确 unavailable group 表达，不能登记假 ready 端点、删除规则或让整个 Profile 静默永久阻断。
  - 历史0392引入显式unavailable group并保留组选择高水位；后续正式registry/wire/transport及0419实际核心退出、新请求恢复已验证。此项仍留开的范围是“已保存规则后实际启动失败”负例，不能把核心退出后的成功恢复自动扩大为全部启动故障验收。
- [x] 0419实际产品入口启动内置核心、完整私有快照ACK及原页加载后显示ready；cua-main-flow-419-pass-receipt.json，不以监听或独立curl替代。

### T4 — 普通 Profile 持久恢复（P0；依赖 T2/T3；R5）

**文件：** `access_site_proxy_bubble_controller.cc::OpenSessionStore`、`access_rule_store.*`、`access_site_intent.*`、coordinator/runtime 的 Profile 生命周期入口。

- [x] 存储层历史持久化/事务测试存在；不等于气泡产品已持久化。
- [x] 普通Profile使用可信持久绑定和后台SQLite事务；0417真实迁移、0419同普通Profile冷启动及正常退出后group/revision证据PASS。
- [x] coordinator已接后台存储及恢复屏障，正式原生store/coordinator测试PASS；0419保存网站授权的首个business请求走准备后的代理，没有先DIRECT。
  - 历史0391隔离证据保留；0423正式async-store目标5 SUCCESS、零skip，0425二进制哈希一致复用；coordinator已经接线，不再保留旧“尚未使用”的当前状态。
- [x] 只恢复已提交意图/规则并按命中请求重新准备核心/注册/当前ACK；0414/0419真实冷启动与新核心PID/端口证据，旧listener不持久恢复。
- [x] 私密保持ephemeral；0419普通授权不被私密继承，明确授权后独立核心/端口，最后私密关闭清理、重开DIRECT且正常数据库revision不增加；分区负例由正式ownership/store测试覆盖。
- [x] 原生层正常重启/事务中断/损坏与不兼容/关闭期间回调/普通私密隔离按对应范围PASS：store43、async5、coordinator35与helper15；新增实际Open失败不发布空DIRECT、ACK后commit失败回滚且原页不重载/明确再试只一次。真实GUI故障和取消仍在T6开放。

### T5 — ready 后原标签页一次重试（P0；依赖 T3/T4；R6）

**文件：** `access_navigation_retry_tab_helper.*`、`access_navigation_retry_state.*`、`access_site_proxy_bubble_controller.*`。

- [x] helper 的原 URL/history/tab 身份与一次性撤销机制：10 项原生测试通过。
- [x] 真实核心/精确ACK/持久提交与原绑定复查后触发helper；0419原生产品/15项helper测试及实际一次重试证据PASS。
- [x] 0419 helper15含关闭/换站/Stop/仅发起tab/一次重载/POST/TLS负例；0425新增4项经过正式controller/store/helper与真实Alpha核心、测试NetworkContext的Mojo ACK及NavigationSimulator，验证迟到ACK不误重载及commit失败恢复，只计原生联合测试，GUI竞态仍未完成。
- [x] 0419实际Aegis受控DNS失败与自然Pinterest超时，一次失败页Retry后原标签/原失败URL自动渲染；原始UI、主文档路由和retry票据记录保留。

### T6 — 最终候选构建与真实浏览器验收（P0；依赖 T1–T5；R7）

- [x] 0370 `chrome` 全构建于 2026-11-10 13:40 Asia/Shanghai PASS（16442 个 action），`native-chrome-370-build-result.json` 的 `inputsUnchanged=true`；该候选不包括后续私有通道。已复用原对象，不重复启动该构建。
- [ ] 对最终 overlay/补丁做完整有序回放、源码一致性和 GN 检查；尤其核验 0376 `url_loader_base` 的 Mojo 依赖，不能以手工生成成功替代。
- [x] 0419/79eec0e7完整chrome及13目标构建PASS，inputs/externalInputs稳定；native-network-ready-419-build-result.json完整sourceInputs哈希、GN args及cua-main-flow-419-identity.json二进制身份。
- [ ] 跑最终候选的相关单元/回归/浏览器测试和仓库必要质量门；变更 ABI 时重编译头文件消费者，避免旧对象产生假结果。
- [x] 0419同候选实际Alpha内置授权节点完成开启/绑定核心代理加载/仅停自有核心/新请求新核心恢复/OFF回原生五步；cua-main-flow-419-pass-receipt.json。
- [ ] 同候选补验 HTTPS、CORS/预检、导航/子资源、跨域跳转、Profile 隔离、普通 Profile 重启恢复、安全防护不解除及原标签页重试。
- [x] 用户新策略：100站来源库固定分5组×20，每轮只跑一组smoke；smoke-group-strategy.json验证100个唯一ID、每组20、maxGroupsPerRun=1。这仅是分组配置PASS。
- [ ] 本轮单组smoke完成门：默认group1，已有20站自然导航尝试、10站最终代理页面观察、11站主文档代理证据（第17站缺最终UI），仍PARTIAL；partial-run-sealed.json保留。其余80站NOT_RUN且不自动在本轮补跑。Computer Use当前网址策略仍有效、未披露禁用URL；不推断某域、不重置/换浏览器/换工具绕过。
- [x] 核心主流程的29项原始UI、5张截图、浏览器/核心SHA/子PID/端点/主文档路由及私有日志哈希已封存cua-main-flow-419-pass-receipt.json；百站部分证据另封存，不扩大通过范围。
- [x] 0419明确OFF后原失败URL走DIRECT并DNS失败；核心故障前/新请求恢复的business控制器均代理、端口变化，无故障降级DIRECT；无关百度原生可达单独记录。
- [ ] 管理页与 DEV 面板按阶段一 B1 单独核验：若未交付，保留缺口，不能宣称完整阶段一退出；SOCKS5 产品路径仍单列 PARTIAL/NOT_RUN。

### T7 — 修复、最终独立审查与收口（P0；依赖 T6）

- [ ] 汇总并修复功能/测试/真实验收发现的问题；修复影响的证据必须在最终候选重跑。
- [ ] 最新用户 AGENTS 恢复最终交接前的 fresh read-only built-in codex review；在相关验证、真实浏览器验收和修复后，对最终候选明确范围与哈希，在新进程执行；修复后重新审查。历史取消规则保留为已被替代的历史，不作为当前流程。
- [ ] 记录实际PR自动审查结果，缺失/失败不算通过；Auto-review操作权限单独处理。用户后续已授权本范围PR代码/说明更新，0948检查点已交付，Alpha/Website后续候选尚未更新；仍无评论、合并、签名或发行授权。
- [x] 证据范围分别记录；0419原生/核心实际验收PASS，百站PARTIAL_POLICY_STOP，最终独立审查/后续PR自动审查/签名发行保持NOT_RUN或原FAIL，不相互替代。
- [ ] 最终准备iOS #135–#138、macOS #139–#141两份独立PR并更新共同#98及对应issue，绑定各自候选/依赖/证据；未完成项不关闭。仅在本范围验收、审查及适用交付门闭环后停用小时循环；保留无独立评论、合并、签名或发布限制。

## 6. 一周目标与关键路径

以下为剩余工作的目标分配，不是完成承诺，也不重启原来的周目标或构建计时。

| 工作窗口 | 目标 | 退出条件 |
| --- | --- | --- |
| 最先 1–2 天 | T1/T2；长构建期间只改输入外的产品源码 | 真实私有 IPC + 完整快照/恢复屏障测试通过 |
| 随后 1–2 天 | T3/T4，联接 T5 | 产品核心 ready、持久恢复、一次重试联合测试通过 |
| 剩余窗口 | T6、修复和 T7 | 同候选真实验收、适用 PR 自动审查和修复闭环 |

**资源风险：** 当前构建预算先于一周目标到期。到限必须停止相关资源消耗，并记录已完成对象、所缺目标/测试、预计新增资源；不自动续期。尚未完成的源码工作不因构建到限而被标成通过。

每小时至少推进一个可核验实现、受影响测试、有效构建或真实验收/修复对象。不得只复制构建进度。建议顺序为 T1 → T2 → T3/T4 → T5 → T6 → T7；没有第二个实现负责人。

## 7. 历史候选及逐轮记录（当前以首部和末条为准）

- 产品工作区基线：`a4f8ad139e1ace782eba629183ec6057c0407ed8`；本轮实现为未提交差异，不能只用 HEAD 代表候选。
- 历史0394时点完整 `chrome` 候选：`86b2456a8e688c187df35c14152743abec8484ba`（0370）；原生树已应用至 0394（`814b0b2e2023d59ebdf086c76296f01abfe5f419`）；0395 精确回放完成、0396 调用端进行中，二者尚未应用原生树。371–387 的既有 49 文件证据继续保留。
- 历史0394时点观察：`native-chrome-370-build-result.json` 为 PASS（输入未变）；后续 381/382/383 构建失败记录保留；修复至 0384 后，`native-private-context-384-build-result.json` 为 PASS 且输入未变，`native-private-context-384-tests-result.json` 的 8 个正式 GN 测试目标全部通过。后续完整浏览器产品候选仍待构建/验收。
- 保留：旧 quality-full-r1 失败；旧 stale r2 二进制无效记录；CORS ABI 旧对象崩溃、测试上下文错误、缓存回归 RED；Mojo 初次生成/编译失败。后续绿色结果不能删除这些原始记录。
- **历史0394时点下一项（已由后续实现推进，不代表当前）：T1/T2 接合。** 私有 per-request loader/control 已由 0377 实现并测试；NetworkContext 完整快照安装/ACK/工厂创建接收端已通过正式 GN 原生测试；继续接 Browser terminal 和完整快照发布/ACK 比对调用方。当前 15 项私有 IPC 测试不能替代 Browser 产品接通。

### 小时循环更新约定

`aegis-macos` 每小时执行一轮；每轮实际推进工程后，必须更新本文件和本地 `progress.json` 的完成项、候选与证据、失败/未运行状态、剩余缺口和下一项。沿用同一构建预算和活动构建，不重置原目标。只有验收与适用的 PR 自动审查全部闭环后，才更新最终状态并删除循环。

### 每轮记录模板

```text
时间 / 负责人：
需求与任务 ID：
候选身份（base + scoped diff/file hashes / native SHA）：
实际修改：
执行命令或入口、原始日志 / receipt：
结果（PASS / FAIL / RUNNING / NOT_RUN / INVALID）：
失败是否修复、旧证据是否失效：
预算读取值与活动构建身份：
仍缺的验收与下一项：
```

### 本轮记录：真实 NetworkContext 原生接合

- 候选：原生 `3b307a8178cd67136abf2df5fe48480bda001e20`（至 0384）；`replay-through-384-result.json` 记录 45 个涉及文件的 SHA-256；产品基线仍为上列 a4f8ad，其他窗口差异保留。
- 实现：Browser-only 安装完整快照、恢复阻断、创建私有工厂及精确 ACK；Context reset 撤销已签发私有能力。
- 结果：`native-private-context-384-build-result.json` PASS；8 个正式 GN 测试目标全部 PASS，数量 21/19/15/5/6/17/31/4 存在重叠，不累计为独立覆盖率。
- 修复与失败：保留 GN 注释语法、原始数组索引编译检查、TestNetworkContext 新接口缺失和 inline virtual 风格失败；0381–0384 分别修复，没有放宽生产或编译安全检查。
- 下一项：将 Browser wrapper 改接 terminal 并创建私有 remote，发送完整快照并比对 ACK；继续 T3/T4/T5。未进行真实节点浏览器验收。

### 构建预算授权更新

用户将累计时限由 24 小时扩为 48 小时；原 `startedEpoch=1794254695.128022` 和 100 GiB 上限保持，截止时间为 2026-11-12 04:04:55 Asia/Shanghai。原授权及失败记录保留；此次不新增推送或发布权限。

### 本轮记录：48 小时授权及 Browser 私有 Context 客户端

- 预算：累计 48 小时，原起点和 100 GiB 保持；小时循环已同步相同额度，构建守护程序读取同一账本。
- 实现：0385 从原 NetworkContext 获取可保留的私有 Mojo 能力及原生 incarnation；0387 Browser 客户端只在初始化时使用原始 proxy 指针，之后经私有能力完成快照发布、精确 ACK 比对、工厂创建及恢复/断连撤销。
- 原生候选：`b3e3a004971cddb7738ec59d5369eb24bc20a19e`；`native-browser-context-387-build-result.json` PASS，输入未变；`native-browser-context-387-tests-result.json` 记录 25/22/17 项通过及二进制身份，测试有重叠。
- 新回归：14 种 ACK 身份字段不匹配、恢复后的晚到 ACK、断连后的旧 ready、原 Context 保留、来源锁和认证请求均有测试；不是实际浏览器节点验收。
- 集成约束：首个显式空策略也必须有活代际，不能与首次开启复用同一代际但改变内容；持久提交失败后的回退应保留阻断并以新保留代际发布旧内容，不能降低 Network 高水位。先在已有存储计数器/恢复流程明确这一映射，再接调用，不放宽现有代际校验。
- 下一项：将现有 Browser wrapper/transport 的 terminal、完整 policy/group 快照和延迟文档绑定接入此客户端，随后接核心准备和普通 Profile 持久恢复；产品链路仍未收敛。

### 本轮记录：空策略初始化和失败恢复的代际预留

- 0388：在现有 SQLite 事务/计数器中预留更高发布代际，读取并验证已提交内容；不迁移 schema、不改写规则行、不把 PREPARED 内容当成已提交恢复。38 项正式原生存储测试通过。
- 0389：Browser 内存发布接收新代际恢复候选，保留所有权/规范策略/单调性校验；新增 native 公共代际捕获（selection=0），缺少身份或发布来源时不伪造计数器。测试编译通过，运行验证在当前原生构建后进行。
- 0390：准备将完整 Browser 策略及全部 HTTP group/端点/本机凭据转换成私有快照；生产和新增测试编译通过。补丁尚未应用到正在运行的原生树，运行测试 NOT_RUN。
- 当前构建：`native-restored-runtime-389-build-result.json` / 同名 log，目标为 runtime、coordinator、transport 原生测试。复用完整 Content/Browser 依赖供后续最终 chrome 使用；不启动第二份 Ninja、不改变其输入。
- 剩余接线：现有 terminal、完整发布与 ACK、启动及提交失败恢复需真正调用上述 API；产品身份来源/核心准备、异步普通 Profile 恢复和 ready 后原标签页重试仍未完成。

### 本轮续记：异步 SQLite 后台实现

- 0391 后台序列持有 SQLite 完整生命周期，调用方只收到普通值结果；初始化恢复不会覆盖其他 partition 的待处理操作，也不会在同一实例重新初始化时清理活跃事务。
- `async-store-isolation-green-receipt.json`：5 项隔离运行测试 PASS，UI 阻止阻塞时可打开、读写和关闭；重启后只恢复已提交内容，失败 mutation 以新预留版本恢复，已提交操作不可被 supersede。依赖元数据和 base/net/sql 库哈希未变。
- 当前原生 0389 构建继续复用既有对象；0390、0391 和产品 args 的后续变更留在输入之外。Actor 的完整 GN 测试以及协调器/气泡/启动路径接线均未运行/未完成。
- 下一步优先把 actor、版本预留、真实身份来源与初始化屏障接进现有调用方，再将 terminal 与完整策略发布切到私有 Context；不把这些已测后端提升为完整产品恢复通过。


### 本轮记录：0392 不可用代理组与隔离验收边界

- 时间：2026-11-10 18:25 Asia/Shanghai；单一实现负责人，产品基线仍为 `a4f8ad139e1ace782eba629183ec6057c0407ed8`。0392 stage `b550409`，完整补丁及 10 文件 SHA-256 见 `pending-392-replay-result.json`；本轮产品源码身份见 `product-scoped-candidate-392.json`。
- 实现（T2/T3/T4）：完整快照允许每个 PROXY group 为实际 route 或显式 unavailable，两者不可重叠。不可用组命中返回 `ERR_PROXY_CONNECTION_FAILED`，未命中 native 及其他可用组不受影响。保存策略不被删除，不登记假监听端点；选择高水位及注册端点/本机凭据绑定跨 RESTORING 保留。私有 Mojo/严格解码、NetworkContext ACK 和 Browser 完整策略转换均传递不可用组并逐项核对 ACK。
- RED → GREEN：`request-route-state-unavailable-behavior-red-receipt.json` 的 3 项新增行为用例失败，既有 31 项通过；修复后 `request-route-state-unavailable-green-receipt.json` 的 34 项通过，libnet 哈希稳定。覆盖未命中 native、其他组、启动 selection=0、故障/恢复高水位、重叠及旧 registration 换端点拒绝。
- PASS：`route-wire-unavailable-392-green-receipt.json` 的 7 项隔离解码/注册表测试（有重叠）通过，记录依赖库稳定；新增不可用、缺失、重复/重叠和空组输入。`unavailable-392-source-compile-receipt.json` 记录四个新生成 Mojo C++ 单元及 Browser 客户端/扩展测试编译证据。`pending-392-replay-result.json` 精确 10 文件回放、`patch-format-r24.log` 和 `git diff --check` 通过。
- 保留失败：首次 sparse replay 误用需要 index 的 `git am`，`pending-392-replay.log` 保留；已撤销本次失败 am，以适用于原工作文件的 `git apply` 完成，不删除源文件。额外 ACK 隔离链接混用新生成类型与旧 GN 消费者，出现 `VALIDATION_ERROR_ILLEGAL_MEMORY_RANGE`；原始 `unavailable-392-ack-receipt.json`/log 及分类 `unavailable-392-ack-classification.json` 保留，整体 **INVALID_FOR_PRODUCT_ACCEPTANCE**。其中两个拒绝断言因消息被拒而显绿，也不计入通过。
- RUNNING：唯一 `native-restored-runtime-389-build` 仍构建 runtime/coordinator/transport 的完整依赖。`native-389-input-check-392-round.json` 验证原生 SHA `c4ef58a717c340e6eaa8d8b51636a6eb9bd0fe17`、已记录源输入及 args 未变；0390–0392 未应用到活动树，没有启动第二份 Ninja。该观察不替代最终 build receipt。
- 资源：累计 48 小时/100 GiB 原起点不变，剩余约 33.7 小时；本轮资源快照约 46.8 GiB，外盘剩余约 261 GiB。守护程序继续执行原累计截止。
- NOT_RUN / 仍缺：0392 的一致 GN/ABI 重建、实际 Context/client IPC 用例；Browser terminal/private control 与完整发布调用、后台 Store 的产品协调器接线、真实身份/核心准备、普通 Profile 自动恢复、真实 ready 后一次重试、最终 chrome/CUA 节点验收及适用 PR 自动审查均未收敛。
- 明确下一项：优先接 T1/T2 现有 Browser terminal、所有受控 native/proxy 的私有逐跳 envelope 和原 Context 能力，替换 CustomProxyConfig 发布调用；并将 T4 async actor/预留代际接入启动和失败恢复。活动 0389 构建结束后跑其目标测试，再一次应用 0390–0392，执行完整依赖重建及新增 IPC 用例；不拿本轮隔离证据替代它们。


### 主流程优先级更新及本轮实现（2026-11-10 19:05 Asia/Shanghai）

- 用户再次确认最高优先级为“失败页通过代理重试 → 真实就绪 → 原标签原网址一次重试”；已更新既有 `aegis-macos` 小时循环，未创建重复循环。仍沿用原累计资源起点、单一负责人和不推送/评论/合并/发布权限。
- **0393 实际实现：** `AccessLocalCoreManager` 由 Browser 持有，在独立 IO 线程读取授权 DEV 绑定、校验上游核心二进制 SHA-256、只读复制所选 V2Ray outbound，并创建自有 Xray 子进程。配置目录 0700、秘密文件写入前设置 0600；随机本机 HTTP 凭据不进入页面、命令行或日志；原 V2Ray 进程/配置不改动。通过 net 原生 URLRequest 验证认证代理及保留证书校验的固定 HTTPS204；准备/验证超时、进程退出、错误 pin、停止均不能 ready。后台回收子进程并关闭私有临时目录，UI 不等待进程结束。
- **0393 PASS：** `local-core-real-node-r2-receipt.json` 3 项通过（无 SKIP）：缺绑定拒绝、错误 pin 拒绝、授权节点真实 HTTPS204 → 同 registration 复查 → 停止后失败；base/net/crypto 库哈希稳定。原始代码编译 API 不匹配、后台线程 join 缺同步原语 task trait 的 r1 失败保留；修复使用后台适用 task trait，不放宽 UI 阻塞限制。
- **0394 实际实现：** neterror 页面新增“通过代理重试”及 connecting/失败状态；使用原 ErrorPageController / NetErrorPageSupport 通道，IPC 不接受 URL、host、节点或凭据。Browser 核对发送者为当前 primary error document；helper 只取真实失败导航 ticket。主导航工厂在默认原生失败之前安装 Browser handler → Profile controller → 真实核心准备。重复操作合并、准备失败可手动再试，只有成功回调才消费原标签一次性 ticket；新导航、停止、关闭、POST/TLS 拦截不自动重载。
- **0394 当前边界：** controller 不再以“发现已有 endpoint”启动代理，也不在 commit 时直接显示 ready；真实核心准备和提交后的再次验证已接入。尚未接通的普通 Profile 启动恢复及本次真实进程的 endpoint/本机凭据注册会返回明确失败，不制造 live generation 或复用测试 endpoint。因此新入口仍不能完成主流程，不能勾选 R4/R5/R6/R7。
- **验证：** `error-page-entry-compile-receipt.json` 记录 Browser/renderer 入口和生产接线编译；`error-page-retry-helper-r5-receipt.json` 同一新 helper 二进制执行 13 项 WebContents 用例通过（原 10 + 异步实际-ready/重复合并、准备失败不重载、新导航撤销 3 项）。r4 曾因隔离可执行文件旁缺 V8 snapshot 在测试开始前失败，保留；r5 仅补齐指向任务既有资源的私有 symlink，原生构建目录没有被修改。初始缺 Skia include、测试 capturing-lambda/旧 stage 头等编译失败保留，修复后重编。
- **补丁与候选：** `pending-393-replay-result.json`（4 文件）及 `pending-394-replay-result.json`（16 文件）记录 stage commit、完整补丁和源文件哈希，逐字节回放一致。产品基线仍为 `a4f8ad139e1ace782eba629183ec6057c0407ed8`；原生树仍至 0389，0390–0394 未应用至活动输入。
- **下一项必须接产品：** 将 0391 async actor、0388 预留版本和真实 signed-out 初始化接到 Profile 首次请求恢复屏障；用实际 core result 登记 owner/group/registration/本机凭据；将现有 Browser terminal/control 与完整 NetworkContext 私有快照发布接合。随后在同候选原生 Aegis 上完成失败页点击→真实出口→原标签重试，以及故障/恢复/关闭五步，不能只再次运行这些隔离测试。


### 主流程推进续记（2026-11-10 20:15 Asia/Shanghai）

- **PASS：** 0389 正式 GN 构建输入不变；runtime 12、coordinator 21、transport 32 项运行通过，原始 `native-restored-runtime-389-tests-result.json`。这些是旧调用端测试，不能替代 0395/0396 产品验收。
- **0395 实现：** 普通 Profile 的可信路径绑定与后台 SQLite actor 启动、恢复、事务提交/失败恢复接入；核心准备成功后登记本次进程真实 registration/loopback/私有凭据和实际代际，绝不制造测试端点。仅 5 个源单元编译 PASS（`profile-restoration-r4-compile-receipt.json`），10 文件补丁精确回放 PASS（`pending-395-replay-result.json`）；新增 Profile 测试运行 NOT_RUN。
- **0396 进行中：** Browser terminal 保留原 NetworkContext 能力及安全工厂参数，导航/子资源携带私有 envelope，native 跳转也用私有 control；完整快照按实际 Context incarnation 统一发布/精确 ACK，并将持久提交和重新认证 HTTPS 核验纳入 ready 门。首轮调用端编译 FAIL（ResourceRequest Mojo 构造 const 接口），已修源码，复编待执行。
- **原生失败如实保留：** 第一次 0394 构建因尚在应用补丁而提前启动，主动停止并标为 `INVALIDATED_INPUTS_CHANGED`（`native-main-flow-entry-394-premature-start.json`），不计通过；一次应用结束且 32 文件预检一致后才启动 r2。r2 输入始终不变，主要 chrome 依赖和链接已完成，但 core 测试 GN 目标缺直接 base 依赖，`partition_alloc/pointers/raw_ptr.h` 未找到，整体 FAIL（`native-main-flow-entry-394-r2-build-result.json`）。新增对象继续复用，GN 依赖修复在 0396，不掩盖原失败。
- **NOT_RUN：** 当前最终完整 native/GN、产品失败页 IPC/CUA、真实 Aegis 默认 DIRECT→点击→ready→原页一次重试、普通 Profile 重启/断连/核心故障恢复，以及适用 PR 自动审查。
- **明确下一项：** 完成 0396 调用端编译和受影响测试，修正发现的失败；395/396 一次应用后执行一致原生重建，随即用 task-owned Profile、授权节点和实际 Aegis 进行 computer use 验收。PR 尚无推送授权，不更新远端。


### 真实启动与原生回归（2026-11-10 20:33 Asia/Shanghai）

- 0396：Browser→Network 私有 terminal/full-policy/envelope/control 调用端落地；`browser-private-callers-r2-receipt.json` 6 单元编译 PASS，`pending-396-replay-result.json` 15 文件精确回放 PASS。原生 `f970dab8c05442999a6fd891df7867008b63ffc8` 对应 `native-browser-main-flow-396-build-result.json` 完整 chrome 与 9 目标构建 PASS、输入不变。真实核心 fresh-auth 复查及停止 3 测试 PASS。
- 0396 原生运行：transport 36（含新增 4 项真实 Mojo 共享 Context/迟到 ACK/断连恢复）、async store 5、真实 core 3、helper 13、wire 7、Context IPC 22、registry 34 项 PASS；coordinator 18 PASS / 5 FAIL，private client 28 PASS / 1 FAIL，**整体 FAIL**，原始 `native-browser-main-flow-396-tests-result.json` 保留。两项新增普通 Profile 初始化/跨重启代际测试已 PASS。
- 真实浏览器启动 FAIL：启动到非网络 WebUI 工厂时误装私有 terminal，触发 CHECK 退出，`cua-main-flow-396-browser.log` 保留。0397 修复 Chrome hooks 的 Network Service 前提及 document hook 适用范围；同时修复不可用组错误被 facade 错改为通用 blocked 的问题，保留真实 `ERR_PROXY_CONNECTION_FAILED`。
- 0397：候选 `cd1203172a52c7792275b7acf7d4982aee88977a`，5 文件精确回放，完整 chrome 受影响构建 PASS、输入不变；`native-main-flow-fixes-397-tests-result.json` 为 private client 29、registry 34、Context IPC 22、terminal 17 项正式 GN 运行全部 PASS。396 的 coor 5 失败未被覆盖。
- 0398 迁移中：旧气泡 5 测试依赖已取消的假端点同步 ready，不能作为产品证据。改为真实授权 core + 后台持久 store + 私有完整 ACK 的联合场景（on/off/on、失败 ACK/显式恢复、prepare 失败、端点不可用后关闭、按 host 保留失败）；源编译 PASS，补丁已形成，尚未应用/运行，不能算修复完成。
- CUA：实际 0397 浏览器进程正常运行，原生主线程采样为正常事件循环；computer use 获取 Aegis 时 macOS AppleEvent 超时，Finder 通道正常。直接启动与 LaunchServices 启动均保留；正在按仓库固定本机证书流程生成独立 component 验收副本重试界面连接。当前没有看到失败页按钮或代理成功页面，**A1–A6 仍 NOT_RUN**。无系统代理变化、无日常 Chrome 替代验收。
- 下一步：完成真实产品联合测试运行并修复；用已验证同候选实际 Aegis/CUA 点击一次重试，随后补冷启动自动核心恢复、故障/关闭/新导航取消及普通 Profile 重启验收。最新用户 AGENTS 再次要求最终代码交接前 fresh read-only built-in review，最终验证后按该最新规则执行；不自行推送或更新 PR。


### CUA 实际失败修复与产品联合测试（2026-11-10 20:53 Asia/Shanghai）

- **0398/0399 正式联合测试 PASS：** `native-real-product-399-tests-result.json` 共 23 项，含 5 项真实授权 Xray 的产品 controller→异步 Profile store→私有 Mojo 完整快照 ACK→持久提交→重新认证 HTTPS ready 路径。覆盖 on/off/on、失败 ACK/显式恢复、prepare 失败、端点不可用后关闭、按 host 保留失败；没有 SKIP。0398 初次 18 PASS / 5 FAIL 是 TestingProfile 默认关闭原生配置服务导致 C 缺失，原始 receipt 保留；0399 改用实际 ProfileNetworkContextService 与真实 DIRECT 配置事件，没有产品计数器降级。
- **CUA 已接通实际 Aegis：** 最终用同一 0397 二进制的 task-owned 内部 SSD component 副本，运行数据、日志和授权输入的私有精确副本均在私有本机 task 目录，原 V2Ray 不变。原外盘日志路径导致启动阻塞在 `InitChromeLogging→fopen`，采样保留；未授予 Full Disk Access、未改隐私设置。固定证书诊断副本的签名未完成且未使用，保留 `cua-component-397-sign.log`；没有改用临时签名。
- **真实产品 FAIL：** CUA AX 和屏幕显示原 `https://example.com/?aegis-main-flow=397` 及另一个原生控制网址都出现 `ERR_BLOCKED_BY_CLIENT`，无代理重试按钮。`cua-main-flow-397-failure-receipt.json` 绑定实际源码、原始日志/NetLog与二进制哈希。没有把“进程活着”提升为页面通过。通过原生菜单退出了本次实例。
- **0400 实现并构建中：** 根因是旧 Browser request ownership/barrier 将 selection=0 一律当无效，受控 native 请求合法的 S=0 被误挡。新增明确 native/proxy 归属类型；native 只接收 S=0，proxy 仍须 S>0，G/I/E/C 与归属、BLOCK 和取消条件保持核验，Network 仍独立判路由。补生命周期/错误代际/BLOCK/取消测试；4 文件精确回放 PASS。原生候选 `dd082ac144f5bff2f5e6010cbebbe749fa735c7a` 在唯一 `native-native-request-fix-400-build` 中，尚未运行 0400 目标和 CUA。
- **预算与循环：** 原 48 小时开始时间和100GiB不变；约1.1GiB内部验收副本纳入 `additionalAccountingRoots`，构建 guard 计入原总额度。自动化仍为原 aegis-macos 每小时一轮，已同步最新用户 AGENTS 的最终 fresh read-only built-in review 规则，未新增 PR 权限。
- **下一项：** 0400 一致原生测试通过后，用新候选再次 CUA 验证 DIRECT DNS 失败→重试按钮→真实 core/ACK/持久提交/复查→原标签原网址一次重载；随后补冷启动准备和真实故障/恢复/关闭/重启矩阵，再做最终独立审查。主流程尚未通过，T6/T7 保持未完成。


### 实际 Aegis 授权节点与 100 站点扩展（2026-11-10 21:45 Asia/Shanghai）

- **真实浏览器部分 PASS：** 一致 0400 runtime 已完整采用当前 GN standalone Framework，`resources.pak` 与 `gen/repack/resources.pak` SHA256 `1c8c9b54fac1695027500bc342cdf17e997285983fea917689acf12fffb1e6ac` 一致。Cua AX/屏幕证实原网址 DIRECT 为 DNS_PROBE_FINISHED_NXDOMAIN，失败页显示 Retry through proxy；独立本站开关实际 connecting→ready，随后手动刷新成功显示 Example Domain，原网址查询串不变、同一标签。`cua-main-flow-400-partial-proxy-receipt.json`、`cua-main-flow-400-route-proof.json` 绑定原始 UI、已关闭 NetLog、当前 runtime 全文件哈希和普通 Profile 数据库。实际 Main stream controller #485 使用 `[127.0.0.1:51075]`，授权 Xray 子进程 49317/父47044 已观测；原 DIRECT 控制流保留。**这是手动开启和手动刷新；自动主流程仍 FAIL。**
- **当前自动入口缺口已缩小：** 0401 的实际页面点击日志确认 Browser sender=当前 primary、error entry=true、helper=true、handler=true，但 FailureForRetry ticket=false，核心准备尚未进入。实际失败导航 #3/GET/-105/committederror 曾 recorded=true，随后出现未提交 abort 的导航 #4/#5；需要区分失败 ticket 被清除与 pending-entry guard，并处理真实 Chromium 错误页自动重载/未提交导航语义，不能放松发送者核验。
- **0401/0402：** 新增仅按 vmodule 启用的无 URL/凭据准入诊断；0401 chrome 构建及正式 helper13项 PASS，候选 `03efecaf402f6ca3a1e617bc1811d234cbff40f7` 已 CUA 复现；0402 区分 remembered ticket/pending entry，候选 `32579ae448b46c7ebdefd0ce312d9ed56894e1a2` 正在唯一 `native-retry-ticket-trace-402-build` 中。
- **用户本轮追加：** 使用 V2Ray 已授权节点，并增加 100 个被 GFW 封锁的主流网站验收。列入 T6 的必需交付：100 行唯一候选站点矩阵，记录公开封锁来源/日期、DIRECT、实际 Aegis 代理页面、最终网址/状态/路由证据/耗时/失败原因与候选身份。先修通自动主流程，再执行同候选批量；不以 curl 或站点名单替代实际浏览器结果，不将本机能直连或第三方拒绝访问自动标为 GFW 问题。来源使用 GreatFire/OONI 原始测量；当前只开始名单核验，**100站点测试 NOT_RUN**。
- **运行边界：** 内部 SSD task runtime 和独立 Profile 都计入原100GiB；采用 Chromium 官方测试 mock-keychain 参数避免真实系统钥匙串等待，真实节点/HTTPS校验/私有路由/持久规则不作假。系统钥匙串授权、固定证书签名、发行未通过，不据此关闭相应门。已优雅退出400实例并只读核对数据库六张表；其他 V2Ray/用户窗口不变。
- **立即下一项：** 402日志定位实际 ticket/pending guard，增加对应真实生命周期回归并修复，再以同一 coherent runtime 的 CUA 完成失败页点击→ready→原页自动一次重载。随后跑100站点、冷启动/故障/恢复/关闭矩阵和最终 fresh read-only codex review。仍未验收的 T1–T7 不勾选完成。


### 自动主流程首次实际通过与100站点执行开始（2026-11-10T22:05:21.854780+08:00）

- **0402真实FAIL保留：** `cua-main-flow-402-admission-receipt.json` 确认初始 GET error ticket生成，1秒/5秒Chromium背景重载未提交而清除ticket；点击时remembered_ticket=0、pending_entry=0。没有放松发送者/文档/一次性校验。
- **0403实现/PASS：** `NetErrorAutoReloader`增加当前Document范围的自动重载抑制；仅对Browser记下可安全代理重试的错误文档启用，新提交文档结束抑制。5文件精确回放、完整chrome/helper构建PASS输入不变；15项正式helper测试PASS，新增两种observer顺序、连接/可见性变化不重启旧错误页timer、替换文档恢复既有行为。`pending-403-replay-result.json`、`native-explicit-recovery-403-build-result.json`、`native-403-retry-helper-result.json`。
- **实际Aegis主流程PASS（限明确范围）：** 候选58bb19cc52bb3e062160fdad37846c66b430b116，完整runtime `cua-main-flow-403-identity.json`。原网址https://example.com/?aegis-main-flow=403 DIRECT DNS失败，CUA只点击一次Retry through proxy，显示Connecting，实际Xray55329/Browser54931准备后自动在同一单标签加载Example Domain；没有手动开关/刷新。原生trace只有原始失败nav3与ready后nav4成功。封存NetLog的main request194/controller195使用[127.0.0.1:52536]，原DIRECT controller73保留。`cua-main-flow-403-pass-receipt.json`。这是App受控DNS故障+真实外部HTTPS/node，不宣称本机自然GFW复现或整个T6通过。
- **平台失败保留：** 初次403启动卡dyld/fcntl，sample和direct-r1 receipt保留；仅停止本任务明确进程，使用同一二进制LaunchServices正常启动，未降级签名/系统权限。CUA曾额外启动无参数本任务实例，精确停止并保留记录，未计入验收。
- **100站点：** 主流公开访问域名100个矩阵已保存`gfw-100/acceptance-matrix.json`/CSV，GreatFire snapshot2026-11-10T05:15:23.927Z与Tranco947N2绑定。逐站API核验发现3个聚合与精确URL不同，替换后测试；原始数据保留。已用同0403 runtime启动全新普通Profile，取消受控DNS规则，按自然DIRECT→明确代理操作记录实际页面和路由，当前站点未完成不得勾选。既有小时循环已加100站点范围，无新预算/PR权限。
- **仍缺/下一项：** 完成100站点，修复真实失败；普通Profile冷启动自动core准备、core故障恢复/关闭/隔离矩阵仍未收敛。最终相关验证后按最新AGENTS fresh read-only codex review，未做不算通过。T6/T7保持未完成。


### 百站首站发现子域名契约缺陷并修复（2026-11-10 22:16 Asia/Shanghai）

- 100站点精确URL来源已逐站核验；97条初始列表为当前blocked，另3条聚合/精确URL不一致，保留v1数据并以gofundme.com、cbc.ca、abc.net.au替换，最终100条均有非stale的blocked原始JSON与日期。名单证据不算浏览器PASS。
- **0403百站首站FAIL：** 自然DIRECT打开Google首页，本机不构成自然GFW失败复现；当前站点实际为www.google.com。点击本站代理后connecting→unavailable，Failed to prepare Access candidate:5，规则未提交。`cua-sites100-403-google-failure.json`及封存浏览器/NetLog保留，其余99站尚未测。
- **0404/0405实际修复：** BuildOrdinarySiteGroupMutation改用net::SchemefulSite生成HTTP/HTTPS顶层站点，仍严格保留精确目标host/include_subdomains=false；取消selector从同一已校验mutation取规范site，避免www/多级公共后缀/私有suffix契约错位。0404 intent6项PASS但真实产品新回归1FAIL（暴露selector遗漏），原始`native-404-subdomain-result.json`保留。
- **0405 PASS：** 候选8d398cda6abadbea5d14177bec6edcf3177264b6；2文件补丁精确回放，加0404共6文件契约修复。完整chrome/3目标build PASS输入不变；正式intent6、session17、coordinator24（含6项真实核心产品路径，无SKIP）共47项PASS。原始`pending-404-replay-result.json`、`pending-405-replay-result.json`、`native-subdomain-selector-405-build-result.json`、`native-405-subdomain-result.json`。新coherent runtime完整哈希`cua-main-flow-405-identity.json`已生成。
- RUNNING：用全新普通Profile和相同授权节点在405真实Aegis重测首站再续100站点；尚未观测前不提升结果。无活动Ninja。普通Profile冷启动核心自动恢复、故障/关闭/CORS隔离矩阵及最终fresh内置独立审查仍缺。
- iOS节点同步不重复发送：本轮只读核对既有iOS交接文档已含原授权配置引用，其所有者/暂停和改动边界不变。


### 用户范围修订与 PR 更新顺序（2026-11-10 23:00 Asia/Shanghai）

- 用户明确选择“按可信网站上下文扩展代理范围”：同一 Browser 可信顶层网站的子域、页面资源和 CDN 可走本站代理，其他网站、标签归属和 Profile 仍隔离。当前0405仍是精确host＋可信顶层站点规则，不声称新范围已经实现。后续需更新设计、持久规则、Browser/Network共同校验及正反向隔离回归，再重测真实页面。
- 随后用户要求“先更新PR，再扩展”。当前暂停新增范围代码，先在上游PR97最新iOS头345c701796e14635dc41c4856752498909c829f6之上准备macOS阶段性更新；保留iOS内容和本地无关修改，先做当前候选必要门及fresh只读内置审查。此次PR更新授权不授予评论/合并/发行。
- **百站基线已封存：** 405实际Aegis15个自然DIRECT观察、14个代理主文档观察；封存NetLog证明14站主文档使用任务loopback链路。12站有页面内容/可视证据，Pinterest主HTML到达但CDN原生超时而空白，TikTok的完整渲染证据尚不足。`gfw-100/candidate405-baseline-sealed.json`、`candidate405-route-proof-summary.json`、`acceptance-matrix.json`及原始CUA观察/截图保留。不是100站完成或全功能PASS。
- **新增实际问题：** 根域pinterest.com代理后跳到未选中的www.pinterest.com，按旧精确host策略落到native并超时；显式www失败页再重试后主导航通过，但s.pinimg.com脚本/CSS仍native超时。用户授权的新网站上下文范围将覆盖这些页面资源；原失败不删除、不重分类为节点不可用。
- **下一项：** 当前精确host候选更新PR97并明确未验收项；随后实施新范围，补普通Profile真实自动core恢复/退出故障/关闭/隔离与100站点最终候选验收及复审。


### PR质量门回放与Alpha测试绑定续记（2026-11-10 23:16 Asia/Shanghai）

- 最新用户提供了用于Alpha内置测试的独立节点，已只写入本机0700目录内0600私有配置，脱敏身份见本地alpha-test-node-binding.json；URI与凭据不写入源码、PR或CI日志。当前仅完成协议解析和私有绑定，Alpha内置加载/打包/真实节点验收均NOT_RUN，旧节点结果不转移给新节点。依用户顺序，当前PR更新完成后再实施Alpha私有资源接线和网站上下文扩展。
- 当前阶段性候选f2f0afa6f30bc1a2309b5e50a0df4241f2df31de的完整质量门首次FAIL：merged-main-patch_test.py要求补丁完整Git blob索引，47个新增补丁使用了缩写。原始report/run-quality日志保留，不把前置通过项当完整门通过。
- 修复只展开补丁index元数据到实际Native Git blob的40位身份；47个稳定patch-id全部未变，Native源SHA8d398cda6abadbea5d14177bec6edcf3177264b6和已测源码/产物不变。patch-full-index-correction-receipt.json绑定每个补丁修复前后SHA256；随后重新跑对应回归、完整门和fresh独立review，尚未完成的不勾选。


### 新Alpha节点真实核心与原标签重试验证（2026-11-10 23:41 Asia/Shanghai）

- 新节点的私有配置语法校验PASS；既有0405原生产物运行6项真实核心产品用例全部PASS、无SKIP，原始证据`alpha-node-product-probe-result.json`。这些用例使用实际Xray准备和HTTPS可用性检查，NetworkContext ACK仍为测试对象，不代替实际浏览器。凭据只保留在本机私有配置。
- **实际Aegis受控主流程PASS：** 候选8d398cda6abadbea5d14177bec6edcf3177264b6，完整coherent405 runtime、全新普通测试Profile；本App内example.com受控DNS失败→一次点击Retry through proxy→Connecting→原标签原URL自动加载Example Domain。封存NetLog有原DIRECT和重试loopback代理两个主文档控制器；日志只有一次retry start，无手动刷新或开关。原始CUA观察/截图/日志哈希与路由在`cua-main-flow-405-alpha-pass-receipt.json`。随后菜单退出、无残留任务浏览器。
- 本次使用已有DEV私有配置入口；**Alpha内置资源接线、网站上下文扩展及对应新候选真实验收仍NOT_RUN**。自然GFW失败、系统Keychain/签名/发布不由此证明。旧V2Ray节点证据不转移为新节点百站结果。
- **PR检查点：** 5b141c2a701ce8dbeaeb2c46b6948941d34fb438完整本地质量门PASS、sourceStable=true，初次失败保留。fresh只读内置gpt-6-astra/xhigh审查仍RUNNING；共享PR的iOS分支已前进至12c999e0aa0862e631c6093d2376c676cd52be64，仅2个不重叠iOS文档。预备整合提交616c0b0accfc1dc85ecc0111f22cd19ecc40fc45保留其全部内容，141个macOS文件blob不变；尚未checkout/push，最终整合候选仍须检查与fresh复审。
- **下一项：** 收取独立审查、修复实际发现并绑定最终整合候选后更新PR97；随后实现用户已批准的网站上下文和Alpha内置加载、普通Profile真实冷启动核心恢复，继续受影响原生验证和100站点验收。


### PR检查点独立审查问题修复（2026-11-10 23:54 Asia/Shanghai）

- fresh内置只读独立审查5b141c2a701ce8dbeaeb2c46b6948941d34fb438进程正常完成，但发现2项P1和3项P2：内层控制管先关闭误发ERR_ABORTED、原标签网络epoch变化未先刷新私有快照、压缩字典跨路由共享、ignore_factory_reset豁免丢失、异步候选构造失败遗留durable PREPARED。原始pr97-macos-checkpoint-review.stdout保留；这不是review PASS。
- **0406实现：** 请求relay等待客户端终止事件并设超时；每次私有请求先完整发布当前G/I/E/C且等ACK后重新核验，旧epoch重定向fail-closed；管理路由禁用共享压缩字典读写；reset仅撤销非豁免factory；候选构造失败前保留PREPARED身份并执行恢复。新增控制管终止、native字典开关、epoch新ACK、豁免service-worker factory仍能发请求、同Profile候选I/O失败后再启用等回归。
- 当前源码e5d6bd2a87ff4c827713509f2cc81a0afe2dc6ee，20文件新补丁0406完整blob身份，review-fixes-406-source.json绑定。完整chrome与8个受影响GN测试目标构建RUNNING；新候选测试、原浏览器复验和fresh复审NOT_RUN。先前0405及5b141完整门证据保留，但不提升为0406 PASS。
- **新增真实FAIL：** 同一Alpha测试Profile重启后原URL显示ERR_PROXY_CONNECTION_FAILED，核心未自动准备，失败页没有代理重试动作。cua-main-flow-405-alpha-cold-failure.json记录原始日志、launch和哈希；下一阶段必须解决cold core bootstrap，不能只恢复规则和unavailable状态。
- **下一项：** 验证0406修复和当前PR检查点，收取fresh复审后保留最新iOS头更新PR97；再按用户顺序接入Alpha私有内置资源及可信网站上下文，完成冷启动和最终同候选验收。


### 0408审查修复原生验证（2026-11-11 00:02 Asia/Shanghai）

- **PASS：** d6bff7c302cab2c8f30ff54b5e18a1058b8a64ad完整chrome与8个受影响GN目标构建，source inputs unchanged。正式目标176项全部SUCCESS、无SKIP，其中coordinator25含7项使用新Alpha节点的真实核心产品用例，私有factory16、NetworkContext state19、private client30、URLLoader6、transport37、rule store38、async store5。证据native-independent-review-fixes-408-build-result.json、native-review-fixes-408-tests-result.json，绑定每个二进制SHA与测试summary。
- 0406/0407首次编译均FAIL（测试私有访问）；修复限定actor测试访问、改由真实网络通知器驱动，原始日志与输入身份保留。0406–0408新补丁从0405基线Git-index精确回放PASS，整树等于原生HEAD：pending-406-408-replay-result.json。未改动其他窗口v8脏状态。
- 当前候选实际Aegis复验RUNNING（新408 coherent runtime），完整本地质量门和fresh修复后独立审查NOT_RUN。176项测试不替代CORS隔离浏览器矩阵、Alpha内置加载、冷启动核心及百站最终验收。


### Alpha内置私有资源接线（2026-11-11 00:20 Asia/Shanghai）

- PR检查点0948ec1368c0fbbc7ddbe457b6b19e7efb829ede的完整本地质量门PASS，修复后fresh内置只读复审RUNNING；对应原生408完整构建、176项受影响测试与实际Aegis新节点自动一次重试均PASS。候选保持冻结，未push。先前44fbd完整门因0406–0408缺少format-patch身份头FAIL，补齐后3个稳定patch-id均未变；原失败日志与patch-format-406-408-correction.json保留。
- 最新用户节点的**Alpha内置源码已实现，尚未同步到原生树**：显式默认关闭的非official macOS Alpha构建flag；私有核心/节点/manifest三件资源通过GN action进入Framework；Browser在该测试构建使用Alpha归属并从资源路径选取输入，忽略DEV路径flags；核心IO线程复核核心和节点哈希。凭据只在0700私有目录、0600节点文件内；Git/PR没有URI或凭据。
- **资源打包5项PASS**：Alpha私有权限、其他channel拒绝且不创建资源、核心/节点篡改拒绝、manifest路径限制、已有不可变候选hardlink inode不被改写。alpha-resource-stager-tests-result.json记录范围；alpha-build-input-binding.json只含路径/哈希。
- Alpha原生编译、默认构建排除验证、无需DEV配置flags的真实Aegis验收均NOT_RUN。当前PR复审和更新完成后再做可信网站范围代码扩展；没有把资源打包测试提升为产品PASS。冷启动核心恢复与百站/隔离仍未完成。


### PR检查点已交付并接续Alpha（2026-11-11 00:37 Asia/Shanghai）

- [x] PR97代码和macOS专属说明已更新至0948ec1368c0fbbc7ddbe457b6b19e7efb829ede；lease以12c999e0aa0862e631c6093d2376c676cd52be64快进，保留全部iOS代码和原说明前缀；未评论/合并/发布。pr97-macos-updated-verification.json、push-object结果、完整候选144文件哈希/差异可核验。
- [x] 该检查点fresh只读内置复审确认5项已修复、无新增可操作回归；完整本地质量门PASS。此勾选只对应0948检查点，不覆盖后续Alpha/网站范围新代码或整个T7退出条件。
- exact-head远端观测：上游Codacy Static Code Analysis、标题合同成功；fork contracts成功。simulator/archive/dmg/access-tests等显示skipped，不视为本机/产品通过；未观测到该头的PR代码review记录，不发独立触发评论。原始检查URL/status保留。
- Alpha新源码已同步独立原生树ffdb084e70b2d2d72e5a3ebd3ea3002212297ac7，0409补丁以完整format-patch身份生成，节点字面量扫描PASS，12文件。开始正常默认关闭flag的GN/构建/受影响测试，再开启显式Alpha flag和私有资源目录做同源不同参数验证；不重用旧参数产物作为Alpha证据。
- 48小时/100GiB预算沿用原始起点；最近原生统计约58.2GB，新增私有资源输入计入既有local根。旧P01/T90保持暂停。hourly automation已更新已交付PR检查点，继续该范围，无新建循环。


### Alpha内置真实浏览器与正常构建边界（2026-11-11 01:21 Asia/Shanghai）

- **实际Alpha内置主流程PASS：** 5532ae7fe0dac0d38a17a909f4b9fb75b5c39ef3的完整原生构建和coherent412 runtime；启动参数没有DEV核心/节点路径。受控DIRECT DNS失败→一次点击→Connecting→原标签原URL加载成功，无手动刷新/开关。封存NetLog证明初始DIRECT、自动重试loopback链路；浏览器30765拥有的Xray31218实际执行app Framework内的内置核心，核心SHA与新节点配置pin吻合。cua-main-flow-412-alpha-builtin-pass-receipt.json含原始CUA/截图/实际子进程/路由/日志哈希；已菜单退出且无任务浏览器残留。
- **构建与资源PASS：** native-alpha-builtin-412-build-result.json的生产输入和3项外部私有输入前后一致；GN flag1，raw/standalone Framework/嵌套App三处资源字节和权限全部核验（node/manifest0600，core0700）。alpha-resource-bundles-412-result.json。普通默认关闭模式完整build与34项测试已PASS、flag0、资源依赖为空，证据410，不能说成正式Release签名验收。
- **测试保留FAIL：** Alpha412 coreManager4项中的1项仅因/var与/private/var规范化路径断言失败，其余3+adapter5+coordinator25成功；25中含7项无DEV参数的内置真实核心产品用例。0413已只规范测试fixture根路径，不改对应生产C++。该FAIL未抹去，final413测试仍NOT_RUN。
- **已修实际构建问题：** 0409依赖环、0410 Alpha资源生成依赖可见性、0411 Alpha常量条件的Clang不可达代码；各首次失败和后续修复分开保留。
- **新增边界检查：** 复用Alpha输出改为普通构建时，旧私有资源可能物理残留；0413添加只读资源缺席检查并阻断正常成功交付，不自动删除输出/历史。资源打包与边界7项Python测试PASS；正在同输出目录验证关闭Alpha时拒绝残留，再恢复Alpha完成413同候选验证。网站上下文扩展、冷启动核心、最终百站和最终特性复审仍缺。


### Alpha 最终受影响测试与节点同步（2026-11-11 01:48 Asia/Shanghai）

- [x] 0413 全 chrome 与三个 owning 目标构建 PASS；4+5+25=34 项全部 SUCCESS，无 SKIP，包含 7 项不带 DEV 路径参数的内置真实核心产品用例。native-alpha-builtin-413-build-result.json、native-alpha-builtin-413-tests-result.json，源码/参数/三个私有构建输入均未变化。0412 的路径别名断言失败保留。
- [x] 关闭 Alpha 时，同输出目录的残留私有资源被只读门正确拒绝；未删除产物。alpha-normal-boundary-413-result.json 为预期拒绝 PASS，之后恢复原 Alpha 参数完成 0413 构建。普通模式 0410 的独立默认关闭构建证据保留，不冒充 Release 验收。
- 0412 的真实 Alpha 浏览器主流程仍按原候选记录；已生成独立 0413 runtime 和完整字节对照 alpha-runtime-412-413-correspondence.json，不虚构新的 UI 执行。
- [x] 沿用用户的 iOS 节点同步授权，已有 iOS 窗口完成交接文档私有路径/哈希/权限登记；只同步引用，iOS 仍 NOT_RUN，未恢复其构建或暂停范围。
- 下一项：对保存的 PROXY 请求单独等待真实内核准备、全快照 ACK 与绑定复查；不重写已保存意图、不阻塞无关原生请求。随后实现获批网站上下文、实际冷启动/退出故障/100 站矩阵和最终 fresh 只读内置审查。

- **原始日志复核更正（2026-11-11 01:51）：** 上述0413的“34项无SKIP”撤回：Chromium launcher把result_parts.type=skip的测试报告成SUCCESS，实际33项通过、1项DEV输入核心测试跳过。0412同项也跳过，原始汇总备份并补记。产品7项与实际Alpha浏览器均真实运行，不受此统计更正影响。runner已增加result_parts跳过检查，下一补丁让核心测试使用构建选定的Alpha资源后实际执行；不能把跳过当通过。


### 0414 冷启动请求门与 Alpha 跳过修复（2026-11-11 01:59 Asia/Shanghai）

- **实现：** Browser仅为可信策略选中的自有本机PROXY组等待核心；合并同Profile并发准备，等待完整快照精确ACK和真实HTTPS复查；重新校验原归属与policy generation后发送。恢复不提交持久意图；核心退出撤销私有注册并保留选择高水位，ALLOW仍保留。设计补充在既有本站意图API文档。
- **原生PASS：** 24180145c897ba23c9804d4f0a1a738c55947668完整chrome及受影响目标，生产与外部输入稳定；正式core4/coordinator28/transport37共69项SUCCESS。runner现额外检查result_parts.skip，确认为零跳过。独立核心测试已改用构建选定的输入provider，Alpha真实执行，原0412/0413跳过历史未覆盖。
- **真实产品测试PASS：** 3个新增产品用例覆盖恢复等精确ACK/并发合并且规则不变、失败ACK后恢复、外来owner/group不启动核心；其中2个使用真实内置核心。原7个真实核心产品用例继续PASS，新增owner负例不计真实核心数。native-restored-core-414-tests-result.json保留各二进制SHA/原始日志。
- **实际浏览器RUNNING：** immutable414 runtime复用412原普通Profile和原URL，保留受控DIRECT DNS失败；已保存ALLOW的启动首请求必须走新准备核心，不能用按钮或手动刷新替代冷启动恢复。cua-main-flow-414-alpha-cold-launch.json，尚未观察不得判PASS。网站范围源码在overlay独立推进，尚未进入414原生输入，最终审查仍NOT_RUN。


### 0414 同候选真实冷启动、退出、恢复、关闭与重试 PASS（2026-11-11 02:08 Asia/Shanghai）

- **同普通Profile冷启动PASS：** 沿用412保存ALLOW的Profile与原网址，无点击/刷新前已显示Example Domain；首次业务控制器72直接使用新core的loopback60576，没有先发DIRECT。真实内置Xray37456属于Browser37105。
- **退出与隔离PASS（限此用例）：** 仅SIGKILL已核父PID/应用内路径/核心SHA的自有child。CUA气泡仍为ALLOW，显示Connection unavailable / local proxy stopped；同Profile另开百度页面成功，封存控制器182为DIRECT，现场核查无任务core，未被核心准备阻塞。
- **恢复/关闭/一次重试PASS：** 原标签明确发起新请求后新core37808准备，控制器849为新loopback60695，UI重新ready。明确OFF后同网址控制器872为DIRECT并报受控DNS失败；一次Retry按钮→Connecting→控制器906代理→原标签原URL内容成功，无第二次刷新或开关。
- **证据：** cua-main-flow-414-alpha-cold-pass-receipt.json、启动/真实core/故障原生无core记录、9条原始UI观察、1张截图、关闭后完整NetLog/Browser日志SHA、store-before/after。持久journal仅新增用户明确OFF/ALLOW两次revision，没有冷启动/故障恢复的额外意图提交。所有本任务Browser/core已菜单正常退出。
- 0414正式69项实际执行零跳过，其中真实产品核心用例是原7+新增2=9项，新增owner/group负例不计核心数。独立core准备/复查/停止用例也实际执行。上述不等于网站/CDN范围、全部私密/CORS/取消矩阵或百站完成。
- 下一项：完成typed website scope、旧精确host规则的事务迁移和原生测试，再在真实Aegis重测Pinterest子域/CDN及同候选完整矩阵；最终fresh内置只读审查仍NOT_RUN。


### 0415 可信网站范围实现与原生构建（2026-11-11 02:21 Asia/Shanghai）

- **SOURCE：** ee026d462e87c33083ea73982c4871823b75042f，25文件、完整format-patch0415、反向精确应用检查PASS，原生树仅保留既有无关v8脏状态。引入Website=4保留Invalid=3、Browser/Network typed私有传输、可信top-site资源/CDN匹配、private PSL和逐跳主导航边界，独立Site限制优先。
- **持久化：** schema2事务迁移旧库/旧日志为精确host，不在启动扩权；新明确网站开关才在单个候选/事务中合并同网站普通bubble旧别名。before-image绑定所有待替换别名，互斥跨范围PREPARED，失败回滚。网页资源取消按owner/可信网站匹配，不穿越其他网站或Profile。私有通道之外拒绝承载Website。
- **相关实际失败路径修复：** 核心退出后多个保存网站仍可独立OFF，无需丢弃其他ALLOW或让全局CustomProxyConfig接管网站范围。新增产品回归与迁移/别名/回滚/独立Network CDN匹配/可信归属负例/取消测试；未运行前均NOT_RUN。
- **唯一原生构建RUNNING：** native-trusted-website-415-build-result.json，full chrome及9个受影响目标。Mojo scope类型变更引发大量合法依赖重建，复用既有对象，不启动第二构建，不改活动输入。长构建期间只在输入外准备实际CUA矩阵与证据。预算原48h/100GiB起点不变。
- 下一项：修复必要编译或测试失败，实际Aegis验证Pinterest根域/www及pinimg资源与隔离，再续同候选百站和最终fresh内置只读审查。0414冷启动/故障/关闭/重试证据独立保留，不冒充0415或百站完成。

- **0416输入外工作：** 0415构建期间仅在overlay新增Website私有工厂真实Mojo/CORS/HTTP回归：允许的预检及业务、被CORS拒绝时零业务发送、异网站factory归属无法借用Website授权。未同步活动原生树，NOT_RUN，候选哈希见pending-416-website-cors-source.json。另建alpha-website/100行矩阵全部NOT_RUN，保留405基线不覆盖。


### 0415 编译失败修正与0416接续（2026-11-11 02:33 Asia/Shanghai）

- 0415在新增store测试编译处FAIL：GURL::host返回string_view，fixture错误保留临时对象视图且用于字符串相加；SupersedePreparedMutation测试误传sequence而非fingerprint。生产相关单元已编译，不能据此宣称完整构建通过。原始native-trusted-website-415-build.log/result保留。
- 0416修正上述fixture/API用法，合入活动构建输入之外预先准备的3项真实私有Mojo/CORS/HTTP Website回归，并为schema1未知scope ordinal补迁移拒绝与回归，确保旧的不可识别数据不被新Website解释为授权。候选22f28d2ac559a1062e54d2434c32e45486f78070，3文件，trusted-website-cors-416-source.json；完整0416补丁反向检查PASS。
- 0414、0415独立Git-index完整树回放均PASS，与对应原生commit tree精确一致：pending-414-415-replay-result.json；未改活动输入、HEAD或无关v8工作。
- 0416唯一原生构建RUNNING，复用415已经完成的合法依赖对象，未重跑旧P01/T90，也未启动重复候选构建。完成后运行正式受影响目标并修复实际失败，再进行同候选浏览器/百站与最终独立复审。


### 0417 网站范围正式原生验证 PASS（2026-11-11 02:44 Asia/Shanghai）

- **0416 FAIL/INVALID保留：** 正式测试252项SUCCESS、4项FAIL。两个新增fixture使用了不匹配的ephemeral owner；旧库迁移的ALTER ADD CHECK触发本版Chromium SQLite缺失pragma_quick_check。另查出copy2保留旧mtime，新增V1未知scope guard未重编译，所以0416完整候选证据标为INVALID，原始build/test/runtime身份仍保留且未启动实际浏览器。native-416-input-mtime-audit.json明确范围；不转用其“构建PASS”。
- **0417实际修复：** 迁移使用受支持的默认列ADD，读取group/journal仍严格拒绝0/1之外；V1未知scope拒绝实际编入。fixture与可信owner一致；同步改为copyfile并显式刷新mtime，三个0416同步输入都重建。日志首个动作明确CXX access_rule_store.o，而非仅根据源码哈希推断构建更新。
- **PASS：** d666016532963cd0641859dbf9d53158e2c6f3d6完整chrome及12个正式受影响目标；43+7+17+29+9+38+8+30+37+19+4+15=256项SUCCESS，零SKIP（含result_parts核验）。native-trusted-website-417-build-result.json、native-trusted-website-417-tests-result.json绑定源/参数/私有输入/二进制SHA；5个新增store用例、Website独立解码及真实私有Mojo/CORS/HTTP3用例均实际通过。
- **仍缺：** 同417实际Aegis旧库冷启动迁移、Pinterest root/www/CDN、异站/私密Profile、Network Service重启/取消及100站最终矩阵；最终fresh内置只读复审NOT_RUN。下一项优先真实浏览器，不把256测试提升为产品通过。

- **0417实际启动：** 原schema1普通Profile启动后，原保存ALLOW的网址无点击/刷新前已加载成功。活动数据库拒绝外部只读访问，未尝试破锁；cua-main-flow-417-live-schema-attempt.json记录，实际schema和旧grant字段待正常退出后核验，完整路由亦待封存。随后同原标签访问受控DIRECT失败的Pinterest根域，只点击一次Retry，当前Connecting，尚未观察结果不算通过。


### 0417真实网站与隔离、Network UI问题及0418修复（2026-11-11 03:11 Asia/Shanghai）

- **真实CUA：** 原普通Profile启动加载成功；Pinterest根域受控DIRECT DNS失败→一次Retry→root/www及75个脚本/样式控制器、图片CDN全部代理，完整页面与图像已渲染；独立顶层相同图片加无敏感缓存参数使用DIRECT并显示图片，未继承Pinterest授权。
- **私密隔离：** 普通Pinterest已ALLOW时，新Incognito仍DIRECT失败；私密明确Retry后独立核心/端口62758完成加载，普通核心/端口62209独立保留。两个实际app内Xray child45323/47050均核SHA；关闭最后私密窗口后47050停止，普通45323仍在。重开私密窗口同host又DIRECT失败，未持久恢复私密授权。原始CUA和private-owned-cores/private-core-stopped记录保留。
- **实际SQL升级PASS：** 正常退出后读取确认schema1→2，旧example.com仍website_context=0/revision3，只有普通窗口明确Retry的Pinterest为website_context=1/revision1；私密操作未增加普通revision。cua-main-flow-417-schema-migration-after-quit.json。活动库外部只读被锁的失败保留，未破锁。
- **发现并修复：** 精确终止本任务Network Service并暂停其新替代进程，在新ACK不可能完成时18:59:22.915Z原始UI仍显示ready，早于watchdog恢复时间18:59:44Z。cua-main-flow-417-network-ui-failure.json记录准确UTC时间。请求重新加载随后能恢复，但ready提示不满足当前ACK合同。0418/70068d2按当前Core及私有Context精确ACK派生ready，气泡轮询比较实际snapshot，使已打开气泡也更新；新增真实Mojo断连→held新ACK→ready回归。
- **证据缺口保留：** Network Service重启会重新打开同NetLog文件，0417故障前的原始事件被截断；原始UI/实时控制器计数在聊天记录内，但不能提升为完整封存网络证明。后续最终候选故障前先复制私有原始日志快照，再故障。主Bundle的只读codesign校验FAIL（GN原输出同样失败，dylib通过）；未重签或绕过，功能观察不充当签名/发行验收。
- 0418首次Ninja命令因model目标别名错误直接FAIL，未编译，原记录保留；读GN改为access_site_proxy_bubble_unittests后唯一r2构建RUNNING，保留原预算。0417全部task Browser/core已正常退出。下一项完成0418正式受影响验证并实际重测上述Network UI和主流程，然后同候选100站与最终fresh只读审查；尚未完成不关闭循环。

### 0419 原生验证完成并启动最终CUA（2026-11-11 03:28 Asia/Shanghai）

- **修改：** 0418的ready必须同时满足真实core与当前私有Context精确ACK；已打开气泡按实际snapshot更新。0419将断连提示改为用户可操作的重新加载说明。候选79eec0e7，补丁0418/0419保留完整lineage。
- **PASS：** native-network-ready-419-build-result.json完整chrome及13目标构建；native-network-ready-419-tests-result.json共263项SUCCESS且result_parts无SKIP，包括新增真实Mojo断连/held ACK/恢复就绪回归和6项气泡测试。cua-main-flow-419-identity.json绑定不可变运行时。
- **RUNNING：** cua-main-flow-419-website-flow-launch.json：实际已保存Website ALLOW的普通Profile，Alpha内置新节点，无DEV输入flags；启动后验证首个根域/www/资源请求及原标签一次重试。故障前必须复制私有原始NetLog，防止Network重启截断旧日志。
- **仍缺：** 0419实际Network故障UI、核心/关闭/私密同候选闭环、最终100站自然访问矩阵、最终fresh只读内置审查及后续PR更新。组件测试不提升为以上产品验收，循环继续。

### 0419 同候选真实主流程/故障/隔离 PASS（2026-11-11 03:40 Asia/Shanghai）

- **PASS，原始证据：** cua-main-flow-419-pass-receipt.json，29项原始UI观察、5张截图及完整关闭日志/故障前私有原始快照哈希。保存的Website授权启动首个根域/www请求均代理；149个s.pinimg和24个i.pinimg控制器走同代理。明确OFF后原标签DIRECT DNS失败，一次Retry经Connecting自动原失败URL完整渲染，未手动二次刷新。
- **修复实测PASS：** 新Network Service被暂停期间19:30:57–19:31:08Z，已开气泡保持ALLOW且显示unavailable及重新加载说明；新ACK不可能完成时未显示ready。恢复后原页重新加载且面板ready，故障前日志已先复制，无0417截断丢证。
- **核心/隔离PASS：** 仅终止SHA已核验的自有核心；UI保持授权并显示停止，零核心时百度DIRECT；原标签新请求启新核心，两个business控制器均代理、端口改变。私密首次DIRECT，明确Retry后独立核心/端口完整渲染；关闭最后私密窗口只清理其核心，重新打开再次DIRECT；正常Profile仅两次明确OFF/ON将Pinterest revision1→3，旧example精确grant维持不扩权。
- **PASS：** pending-409-419-replay-result.json全11补丁独立index全树精确回放；source-overlay-409-419-correspondence.json中43个变更overlay字节一致。
- **边界：** 独立CDN标签实际DIRECT请求但未等到图片加载即取消，不宣称独立图片渲染成功；上述主流程采用应用内受控DNS故障。组件GN原Bundle签名失败保留，功能观察不替代签名/发行。
- **RUNNING：** cua-419-sites100-launch.json为同0419、全新Profile、无DNS故障及无DEV路径输入，开始自然DIRECT→明确网站代理的100站CUA矩阵。取消/换页真实竞态、最终源码门和fresh独立审查及后续PR更新仍缺，循环继续。

### 百站部分封存与Computer Use策略中止（2026-11-11 04:00 Asia/Shanghai）

- **候选保持：** 0419/79eec0e7，完整chrome/263原生测试、主流程/冷启动/核心与Network故障/普通私密隔离已通过。新Alpha节点只在显式测试构建加载，native419-public-scope-secret-scan.json对本任务源码/补丁检查PASS，未写入节点凭据。
- **本轮实际推进：** 同候选全新Profile自然网络尝试20站，前10站最终代理页面有观察；10个主文档均有本机代理原始路由。Pinterest自然DIRECT出现ERR_CONNECTION_TIMED_OUT，一次失败页Retry后根域/www自动代理重载、页面及图片完整渲染。TikTok到达外部生日/注册门槛，不输入资料，不算视频功能验收。第17站Snapchat自然超时后一次Retry有主文档代理证据，但未观察最终页面，保持部分。
- **工具阻断：** Computer Use明确返回当前browser URL不允许操作并终止会话；工具未披露具体被禁URL，最后完成动作是17、下一请求18，不能据此推定被禁域名。已立即停止CUA，没有重置、重新启动或换工具绕过。computer-use-policy-stop.json保留原始拒绝；仅作任务资源清理，浏览器/自有核心全部停止，正常V2Ray未动。
- **证据封存：** gfw-100/alpha-website/partial-run-sealed.json、acceptance-matrix.json/CSV、82项v2观察和完整关闭NetLog哈希；初始harness闭包字段失效记录单列INVALID，不计成绩。批量等待期间的观察耗时不是页面加载延迟，已分别标注，不伪造网络耗时。
- **状态：** 20自然导航尝试、10最终代理UI观察、11主文档代理原始证据（含缺最终UI的17），80站NOT_RUN；百站整体INCOMPLETE_STOPPED_BY_COMPUTER_USE_URL_POLICY，非100站PASS。最终源码质量门、实际取消竞态、fresh只读内置独立审查及后续PR更新仍未闭环，不能停止循环或宣称完成。
- **下一项：** 不依赖CUA的最终scoped源码/补丁/质量验证与取消用例准备可继续；网页验收保持工具策略边界，不自动重试被禁URL、不重置或换工具绕过，允许恢复后再续接矩阵；相关验收和修复完成后做最终fresh审查。原48小时/100GiB起点、截止及历史失败全部保留。

### 用户暂停：本轮停在20站（2026-11-11 04:22 Asia/Shanghai）

- 用户明确“20够了，下次再继续”。本轮网站样本以20站为停止点，原100行来源矩阵及21–100的NOT_RUN保留，暂不继续，不将未完成页面或外部年龄/注册门槛改成PASS。aegis-macos已通过官方工具改为PAUSED，等用户明确恢复后再推进。
- **暂停前实际推进：** pending-356-419-ordered-replay-result.json：从实际原生父链连续应用64个本任务补丁，每一步完整tree均与原生commit一致，最终仍为0419/79eec0e7。原输送信封SHA不在本地对象库导致的验证器首次失败单列pending-356-419-header-lookup-failure.json保留；没有改Native源码、HEAD、旧P01/T90或活动构建输入。
- **质量门事实：** 169项本任务文件已在独立质量工作树0948上同步，其中57路径变化；native419-quality-scope-binding.json绑定。完整本地quality的工具链、单元/回归、coverage、冻结、预览、CI回归及workflow检查均PASS且sourceStable=true，但public-export使用当时stale upstream/main别名8f17、非0948祖先而FAIL，整体不得标PASS。native419-quality-full-r1-launch.json及原始report/log保留。
- **交付身份待续：** 只读回读PR97仍open，头为4a658ab5，比0948多一个并发iOS提交、六个文件；未覆盖这些工作、未快进质量工作树、未提交/推送或更新PR。已发出的远端读取在暂停记录前收尾：API所报PR base15726，当前远端main a34c且不是4a658祖先；恢复交付前重新绑定并解决基线身份，不能用错误base放行公开门。
- **保存状态：** 实现工作树仍以a4f8ad为HEAD并保留全部未提交改动，质量工作树仍0948加本任务57路径差异，Native0419及已验证浏览器产物不变。关键实际产品通过与百站部分原始证据均保留；Computer Use URL策略限制仍有效。没有在暂停后启动新的实现、测试、构建、审查或浏览器操作。
- **下次起点：** user-pause-20-sites-20261111.json；先明确恢复，再续精确base/head质量身份、20站样本未闭环项/实际取消矩阵和最终fresh只读内置审查。原累计48小时/100GiB起点及截止不重置；旧P01/T90、其他窗口、凭据和发布权限边界保持。

### 策略更新与恢复：5×20单组smoke，推进边界验收（2026-11-11 04:37 Asia/Shanghai）

- 用户明确恢复第2项：真实浏览器取消/晚到回调，以及核心启动、认证/目标失败和持久恢复边界。先在正式原生产品入口固定可复现回归并运行；CUA受限期间不以这些测试冒充真实GUI通过。
- 100站保留为稳定来源库，按ID1–20/21–40/41–60/61–80/81–100分5组；每次smoke最多一组，默认第1组，复用有效已完成证据，不自动串跑五组。gfw-100/alpha-website/smoke-group-strategy.json已绑定分组；分组完整性验证不等于网站验收。
- 原先的20站记录仍是部分结果，未变成20全PASS；其余组NOT_RUN。旧Computer Use网址策略中止仍有效，不重置、换浏览器/工具绕过。
- 用户追加最终交付安排：#97分为iOS和macOS两份可单独审查的PR，更新对应issue的范围、依赖、原始证据和待办。拆分前核对共用文件和最新iOS提交，保留其他窗口及#97历史；已有范围授权涵盖这两份PR与对应issue更新，尚未执行外部写入，仍无合并/签名/发行授权。
- 恢复原小时循环，原48h/100GiB开始时间及截止保持；单一实现负责人，旧P01/T90继续暂停。下一项实际实现并运行核心故障及真实core/私有ACK/原标签生命周期的原生联合回归。

### 0420 边界回归实现与原生构建（2026-11-11 04:46 Asia/Shanghai）

- 新增9个有实际失败条件的回归，源码候选d822b566，完整补丁0420；boundary-420-source.json记录四个输入哈希。测试专用loopback child不会连接外部目标、不记录请求头/生成凭据，模拟已启动退出、无认证响应、认证拒绝、已认证但目标不可达、挂起TLS取消与25秒真实超时。
- 新原生产品导航fixture经正式retry handler、真实Alpha内置核心、Profile事务及真正Mojo held ACK，再换站/关闭原tab并保留其他tab/调用WebContents Stop；不再仅用手工ready回调替代这一联合路径。测试代码已写入，但运行前不算PASS。
- 唯一构建native-boundary-420-build-result.json RUNNING，目标chrome及受影响core/coordinator/helper；原48h/100GiB起点不变，copyfile后刷新mtime，无活动输入期间才同步；原无关v8脏状态保留。产品路由和内核源码未修改，生产二进制是否与0419一致待构建后逐项核验，不能预先转移GUI证据。
- 下一项先解决真实编译/运行失败，记录原始FAIL并修复；再补验存储边界。Computer Use策略仍有效，native联合测试不当成GUI验收。最终双PR/issue交付在相关验收及fresh独立审查后进行。

### 0420 真实失败与0421夹具修复（2026-11-11 04:58 Asia/Shanghai）

- **0420 build PASS、tests FAIL、GN FAIL 均保留原始记录：** core为9 SUCCESS/1 FAILURE；coordinator为30 SUCCESS/1 CRASH/2 NOTRUN；helper15 SUCCESS，result_parts无skip。core取消用例跨进程状态文件不能唤醒空闲RunLoop，等到真实25秒超时后才执行Stop；新Chrome导航fixture因缺少全局VariationsIdsProvider在启动时崩溃。未把崩溃/NOTRUN或旧30项通过提升为新联合路径通过。GN指出两个缺失的直接依赖。
- **0421 SOURCE：** b7fcdfa88eef0c281dd21c61c2e40b2e134bf879；仅测试夹具/BUILD.gn修复，使用10ms定时观察真实child握手后立即Stop，仍严格断言cancel；增加ScopedVariationsIdsProvider及正式测试依赖。boundary-421-source.json和完整补丁0421绑定输入，取消/超时/其他标签不重载断言未放宽。
- **原生RUNNING：** native-boundary-421-build-result.json；复用原对象、唯一构建，原预算起点/额度不变。0420构建后5项生产二进制与0419一致；0421对应关系待完成后再核。Computer Use仍未恢复，原始工具限制不绕过。
- 下一项：421 GN检查与新增取消/导航定向执行，实际通过后运行受影响完整目标，随后核对存储失败边界与最终双PR/issue交付。

### 0421–0423 导航夹具及持久化联合边界（2026-11-11 05:04 Asia/Shanghai）

- **0421 部分PASS/FAIL：** build PASS、core取消定向1 SUCCESS、两个受影响GN依赖检查PASS；新导航fixture仍1 CRASH/2 NOTRUN。真实Profile网络服务在RVH默认NetworkContext创建前启用，进入TestingBrowserProcess故意为空的SystemNetworkContextManager；0422调整测试初始化顺序，私有ACK仍经真实Mojo的ProductAckContext，内置核心、正式retry handler、存储事务与导航断言保留。
- **新增两项SOURCE：** 真实核心及ACK已成功后，注入第一成员写入后的持久提交失败，原页不得重载、意图/规则回滚；解除故障后同页明确再试应只自动重载一次。真实Profile的access.db路径不可打开时，初始化失败不能发布空DIRECT策略或放行业务。均是native联合边界，不是新的GUI验收。
- **0422 build FAIL保留：** 新断言误用了StoredPolicySnapshot不存在的rules字段；0423更正为independent_rules，没有放宽断言。候选fd1e1cf9d9f727fa78be311860a2a54943dc6593，boundary-423-source.json及完整0423补丁绑定输入。423唯一构建RUNNING，增加正式async-store目标验证；未改生产实现。
- **交付拆分只读核验：** #97最新头4a658ab仍包含其他窗口新增iOS K脚本/工程提交；共同基线15726d与最新upstream/main a34c412分叉。两份新PR须从有效目标基线逐文件组成，各自核依赖与质量门，不能直接按混合提交拆cherry-pick，也不能覆盖该iOS提交。对应iOS #135–#138、macOS #139–#141、共同#98；旧#99–#104历史保持。尚无本轮GitHub写入。

### 0423 原生边界部分通过与0424接续（2026-11-11 05:12 Asia/Shanghai）

- **0423 build/GN PASS；core10 SUCCESS、async-store5 SUCCESS，零skip。** 核心六个故障边界现均实际运行：启动退出、无认证TLS、错认证、目标不可达、挂起隧道Stop取消、真实25秒超时。正式后台SQLite5项验证UI禁止阻塞、普通重启、未完成事务、分区保护和失败恢复，未重复隔离结果冒充原生目标。
- **产品Open失败1 SUCCESS；导航1 TIMEOUT/3 NOTRUN保留。** native-boundary-423-nav-diagnostic.log确认失败导航已记录，真实retry已发起且换站已提交；超时出在fixture以取消后UI必须ready作为排空条件。实际取消要求是不误重载，并允许绑定变更后unavailable。0424改为等待正式publication/core复查完成，再严格检查新网址/另一标签/Stop票据及零pending导航；既有正向ready断言不变。
- **0424 SOURCE/BUILD RUNNING：** 191e7a962b9c5618741a48f78ad1b82f0de5abd4，boundary-424-source.json及完整补丁绑定输入；只有测试变更，原始超时/编译/夹具崩溃不覆盖。下一项正式coordinator全部35项及证据对应，实际GUI取消仍待工具允许，不以native代替。

### 0424 teardown真实失败与0425修复（2026-11-11 05:16 Asia/Shanghai）

- **0424 build PASS，正式coordinator为31 SUCCESS/1 CRASH/3 NOTRUN，原始FAIL保留。** 新换站用例已执行到测试函数结束且未产生断言失败，但RVH TearDown先销毁其持有的BrowserTaskEnvironment，derived成员ScopedRunLoopTimeout仍在栈顶，触发Chromium生命周期DCHECK。函数结束不等于用例通过，仍按CRASH。
- **0425仅修测试生命周期：** 删除越过base环境寿命的额外90秒timeout，使用RVH既有超时；base销毁Profile前清理fixture非拥有引用及测试Context连接。候选0aba8071d29bdf194a2cd3294b6c2c3512acbd3b，boundary-425-source.json，唯一chrome/coordinator构建RUNNING；未修改产品实现或取消/持久化断言。
- **证据界线补充：** 新原生导航联合用例使用真实Alpha内置Xray与正式controller/store/helper，但导航由NavigationSimulator控制，ACK由测试NetworkContext经真实Mojo传输；不把它写成实际Network Service或GUI验收。0419实际Aegis证据仍独立。boundary-424-binary-correspondence.json已核5个生产二进制不变及244项适用测试二进制身份，425完成后再核最终对应。

### 0425 边界原生验证PASS与本轮收口（2026-11-11 05:22 Asia/Shanghai）

- **最终本轮候选：** 0aba8071d29bdf194a2cd3294b6c2c3512acbd3b。native-boundary-425-build-result.json（chrome/coordinator）及boundary-425-gn-check-result.json PASS、输入/Alpha私有pin稳定。正式coordinator35 SUCCESS、零skip；4项新导航联合用例定向与完整目标均通过。core10/async5在0423实际执行PASS后按相同二进制复用，合计本轮正式目标50项，新增11个回归，不累计重复执行次数。
- **复用范围：** boundary-425-validation-receipt.json逐目标校验14个正式二进制：另229项0419结果字节一致复用，总计279项适用原生证据。5项生产二进制与0419相同；0419实际Aegis证明仍限cua-main-flow-419-pass-receipt.json原29项UI/5截图的范围，不新增GUI通过。420–425只改5项测试/BUILD输入，产品实现没有变化。
- **补丁：** 420–423及424–425分别在独立Git index逐段回放，全tree与各原生commit精确一致；此前有效356–419前缀复用。新增helper为loopback-only故障child，不连接外网、不记录凭据。0420/421运行和GN失败、0422编译失败、0423超时、0424teardown崩溃均保留原始证据。
- **交付安排：** pr97-platform-split-plan.json登记当前407路径初步拆分（iOS197/macOS194/共用待逐文件核对16），不是已创建PR。保留4a658的iOS六文件提交和#97历史；最终从当时有效目标base组成独立两PR，各自验证/独立审查，更新#98与iOS#135–#138/macOS#139–#141。不得按混合提交直接cherry-pick，不覆盖其他owner的DMG/发行未提交工作。
- **仍缺：** 当前单组20站smoke为PARTIAL、实际GUI取消/晚到回调受Computer Use网址策略限制；占端口等更广故障未全验；有效目标base上的最终quality、fresh只读内置独立审查、双PR及issue更新仍NOT_RUN。旧public-export失败不改为通过，旧DMG/签名发行不升级。
- **下一项：** 先逐文件定界16个共用路径并准备有效目标base的独立交付候选，跑其必要质量门；不能通过重置CUA/新Browser/CLI网络探测替代受限GUI。当前无活动原生构建/测试，避免重跑有效425。原48h/100GiB起点不变；本轮观测累计约58.4GiB，截止2026-11-12 04:04:55 CST，不重置或自动续期。
