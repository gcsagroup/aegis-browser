# Aegis macOS Access #139/#140/#141 — SDD Implementation Plan / TODO

> 执行方式：单一实现负责人，使用 `superpowers:executing-plans` 逐项推进；不委派第二个实现者。本文件是本聊天当前范围的执行清单，不新增发布权限。

**Goal:** 网站无法访问（默认保留原有连接）→ 失败页点击「通过代理重试」→ 真实代理就绪 → 原标签原网址最多重试一次；以真实 Aegis 和授权节点验收。故障不回落，普通 Profile 重启后策略正确。

**Architecture:** Browser 持有请求归属和私有通道；NetworkContext 原子安装完整策略/端点快照，并独立校验每一跳。CORS、预检、URLLoader 和 net 共用受管请求状态；内核实际就绪和持久恢复完成后才能发布可用状态。

**Tech Stack:** Chromium C++ / Mojo / GN / Ninja、macOS arm64、Xray、现有 AccessRuleStore。

**Spec:** [阶段一验收清单](../access-product-phase1-acceptance.zh-CN.md)、[功能拆分](../access-product-phase1-feat-split.zh-CN.md)、[本站意图 API](../macos-access-site-intent-api-NOTES.md)，以及本聊天已授权的请求隔离、持久恢复和原标签页重试要求。本文不将旧文档的历史状态当作当前证据；冲突时沿用当前任务授权和当前 AGENTS.md。

**快照时间：** 2026-11-10 23:00 Asia/Shanghai。**总状态：0405 原生构建与相关回归通过，真实单站自动重试通过；百站基线仅15站自然连接、14站代理主文档，完整验收未完成。按用户新指令先更新 PR，再实施已授权的网站上下文扩展。

## 1. 状态与证据规则

- `[x]` 仅表示该条明确描述的范围已完成；不向上推导整功能完成。
- `[ ]` 表示未完成、部分实现、运行中或未验收；具体状态写在条目中。
- `PASS` 必须附候选身份、执行范围和原始结果；编译、隔离测试、完整原生测试、真实浏览器、独立审查分别记录。
- `${TASK_ARTIFACTS}` 指本任务既有 `access-macos-139-141` 证据根目录；物理绑定见本地 `progress.json`。本文件仅引用脱敏文件名，不记录节点凭据。
- `progress.json` 中 `verified`、`pendingSource` 和 `nextSteps` 含历史快照；读者应结合最新 `lastHourlyRound`、0375/0376 条目和原始 receipt，不能照抄旧的 pending 状态。

## 2. 约束与完成定义

- 单一实现负责人；保留其他窗口工作、旧 P01/T90 暂停边界与失败记录。
- 原生构建累计 48 小时、100 GiB；继续使用 `resource-budget.json` 的 `startedEpoch=1794254695.128022`，不重置、不重复申请。
- 该预算的时间截止为 **2026-11-12 04:04:55 Asia/Shanghai**；本快照剩余约 **29.1 小时**。以账本及守护程序为准，不能将一周开发目标理解为额外构建授权。
- 原生树已应用到 0405，当前无活动 Ninja。完整 chrome/受影响目标构建及 intent6/session17/coordinator24 项通过；0403 helper15和真实单站自动重试证据保留。网站上下文扩展尚未实施，不把百站基线提升为最终验收。
- 当前受管产品执行先覆盖 HTTP 本机入站；SOCKS5 未产品验收，不能因独立核心测试通过而标成完成。
- 使用已授权 V2Ray 配置对应节点；凭据只在授权本地配置中使用，不进入文档、日志、补丁或聊天。
- 最新用户明确授权先更新关联 PR #97，再扩展：允许本次 macOS 当前候选的提交/推送和 PR 说明更新。仍无评论、合并、签名、DMG 或发行授权；不覆盖 iOS 和其他窗口工作。
- **退出条件：** R1–R7 对应任务及必要测试完成，同候选真实 Aegis 浏览器验收通过，问题修复后对最终候选完成最新 AGENTS 要求的 fresh read-only 内置独立审查，无未解决阻断项（PR 自动审查须另外取得 PR 权限），再停用 `aegis-macos` 循环。

## 3. 需求 → 设计 → 验收追踪

| ID | 必须满足的行为 / 不变量 | 实现任务 | 验收条件 | 当前状态 |
| --- | --- | --- | --- | --- |
| R1 | Browser 私有权限不可由 renderer 字段伪造；保留原工厂安全参数 | T1 | 私有工厂接通；来源锁、非可信 TrustedParams、失效归属拒绝且零发送 | 0396/0397 Browser 调用已接通；实际主导航走私有代理，完整 CORS/隔离矩阵仍缺 |
| R2 | 每跳独立决定 native / proxy / reject；预检、连接池、认证和缓存不串用 | T1、T2 | 导航/子资源/重定向按当前策略；无 DIRECT 降级、旧代际复用或共享代理授权 | 分层测试通过，整链路未验收 |
| R3 | NetworkContext 完整快照安装及精确 ACK；恢复期间先阻断再发送 | T2 | 重启/断连/乱序 ACK 不放行；新 incarnation 完整恢复后才发送 | 完整 Browser 发布/精确 ACK 已接通并通过36项transport回归；真实重启/断连矩阵仍缺 |
| R4 | 真实内核启动、认证入站和指定目标路径均就绪后才显示可用 | T3 | 启动失败、错凭据、进程退出均 fail-closed；实际目标经授权出口 | 0403实际Aegis失败页→真实core/TLS/ACK→自动原页加载通过；故障矩阵仍缺 |
| R5 | 普通 Profile 持久恢复；私密 Profile 不落盘且相互隔离 | T4 | 重启恢复已提交意图；损坏/未提交事务不误放行；首次请求不抢跑 | 0395普通Profile异步持久启动/跨重启代际2测试PASS，0399真实core联合23项PASS；冷启动自动core准备仍缺 |
| R6 | 真实 ready 后，仅原失败标签页、原导航最多自动重试一次 | T5 | 新导航、关闭、停止、POST/TLS 错误均不误重试 | 0403正式helper15项PASS；真实Aegis一次点击自动原页/原标签重试PASS（受控DNS故障）；更多浏览器取消用例仍缺 |
| R7 | 实际 macOS 浏览器完成开启→指定出口→故障→恢复→关闭 | T6、T7 | 同候选日志、关联 ID、界面证据与最终独立审查闭环 | 单站自动流程PASS；五步/100站点/最终审查未完成 |

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

以下任务均按“先固定可复现失败/边界 → 实现 → 跑受影响测试 → 记录证据”执行。不在小任务或提交 PR 前增设独立 review；按后续统一规则，先验证，授权提交后以 Codex 内置 PR 自动审查的实际结果为准（T7）。

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
- [ ] 将 `EnsureLocalProxyReady` 从检查已有 endpoint 改为真正的异步准备流程；当前 `(void)host` 不能证明目标就绪。
- [ ] 校验核心身份、创建受限本地配置、启动自有进程、验证认证入站、通过指定 route 探测实际目标，再注册/发布 endpoint。
- [ ] 定义取消、超时、退出、旧回调撤销和清理；不停止原 V2Ray 进程，不修改原节点配置。
- [ ] 回归覆盖占端口、启动失败、错凭据、目标不可达、进程中途退出；故障不得回落 DIRECT/其他代理，UI 保留可读错误。
- [ ] 产品初始化提交真实的 signed-out/受控 DEV 身份来源，准备成功后再提交相应身份转换；当前身份代际提交仍主要来自测试，不能填常量绕过来源门。
- [ ] 覆盖“已保存代理规则但内核启动失败”的恢复：命中请求失败、未命中请求仍走原生；需要明确 unavailable group 表达，不能登记假 ready 端点、删除规则或让整个 Profile 静默永久阻断。
  - 0392 已加入显式 unavailable group，组内选择高水位和注册/凭据绑定在故障与恢复间保留；隔离注册表/解码回归通过。完整 GN、实际 IPC 和产品恢复入口仍未验收，不能勾选本项。
- [ ] 产品入口真实启动核心、发布策略和显示 ready 的证据齐备；端口监听或独立 curl 成功不能单独完成本任务。

### T4 — 普通 Profile 持久恢复（P0；依赖 T2/T3；R5）

**文件：** `access_site_proxy_bubble_controller.cc::OpenSessionStore`、`access_rule_store.*`、`access_site_intent.*`、coordinator/runtime 的 Profile 生命周期入口。

- [x] 存储层历史持久化/事务测试存在；不等于气泡产品已持久化。
- [ ] 普通 Profile 使用可信持久绑定和现有存储事务；当前 `CreateEphemeral` 路径不能满足重启恢复。
- [ ] 磁盘打开/读取放到适当序列；恢复完成前维持 R3 屏障，避免 UI 线程阻塞及首次导航抢跑。
  - 0391 后台存储实现已通过 5 项隔离 SQLite 测试（UI 禁止阻塞、重启、PREPARED、分区保护）；现有 coordinator/气泡尚未使用，完整原生 GN 测试 NOT_RUN。
- [ ] 仅恢复已提交意图/规则，重新准备核心及注册代际；不恢复旧 listener/registration/连接就绪假象。
- [ ] 私密 Profile 保持 ephemeral；Profile 之间和 storage partition 之间不共享持久状态。
- [ ] 测试正常重启、事务中断、损坏/不兼容存储、关闭期间回调、普通/私密隔离；真实浏览器重启验收另在 T6。

### T5 — ready 后原标签页一次重试（P0；依赖 T3/T4；R6）

**文件：** `access_navigation_retry_tab_helper.*`、`access_navigation_retry_state.*`、`access_site_proxy_bubble_controller.*`。

- [x] helper 的原 URL/history/tab 身份与一次性撤销机制：10 项原生测试通过。
- [ ] 在真实核心就绪、当前快照 ACK 与 session 生效后调用 helper，失败/过期回调不得触发。
- [ ] 联合测试新导航、停止、关闭、其他标签页、重复 ready、POST、证书错误和晚到回调；证明不重放非安全请求。
- [ ] 用真实浏览器复现原失败页开启代理后只重试一次，记录 tab/navigation 关联证据。

### T6 — 最终候选构建与真实浏览器验收（P0；依赖 T1–T5；R7）

- [x] 0370 `chrome` 全构建于 2026-11-10 13:40 Asia/Shanghai PASS（16442 个 action），`native-chrome-370-build-result.json` 的 `inputsUnchanged=true`；该候选不包括后续私有通道。已复用原对象，不重复启动该构建。
- [ ] 对最终 overlay/补丁做完整有序回放、源码一致性和 GN 检查；尤其核验 0376 `url_loader_base` 的 Mojo 依赖，不能以手工生成成功替代。
- [ ] 在既有预算内应用后续补丁并增量重建所有受影响依赖及浏览器；记录候选 base + 完整 diff/file hashes、原生 SHA、args 和二进制身份。
- [ ] 跑最终候选的相关单元/回归/浏览器测试和仓库必要质量门；变更 ABI 时重编译头文件消费者，避免旧对象产生假结果。
- [ ] 通过 computer use 操作真正的 Aegis 构建，用授权节点完成开启、指定出口加载、停自有核心故障、恢复、关闭五步。
- [ ] 同候选补验 HTTPS、CORS/预检、导航/子资源、跨域跳转、Profile 隔离、普通 Profile 重启恢复、安全防护不解除及原标签页重试。
- [ ] 新增100个公开测量确认封锁的主流网站真实Aegis矩阵：精确URL来源/日期、自然DIRECT、产品代理、页面/最终URL/路由/耗时/失败原因；目前Google DIRECT可达但www规则prepare失败，其余99站NOT_RUN，先修再续测。
- [ ] 保存脱敏操作记录、页面截图、浏览器/核心/目标关联证据；缺少出口证明时标 UNKNOWN，不能只凭页面打开认定代理成功。
- [ ] 验证 OFF 恢复浏览器原有配置，而非宣称“直连成功”；故障时新请求零降级。
- [ ] 管理页与 DEV 面板按阶段一 B1 单独核验：若未交付，保留缺口，不能宣称完整阶段一退出；SOCKS5 产品路径仍单列 PARTIAL/NOT_RUN。

### T7 — 修复、最终独立审查与收口（P0；依赖 T6）

- [ ] 汇总并修复功能/测试/真实验收发现的问题；修复影响的证据必须在最终候选重跑。
- [ ] 最新用户 AGENTS 恢复最终交接前的 fresh read-only built-in codex review；在相关验证、真实浏览器验收和修复后，对最终候选明确范围与哈希，在新进程执行；修复后重新审查。历史取消规则保留为已被替代的历史，不作为当前流程。
- [ ] 记录实际 PR 自动审查结果，按发现修复并等待最终候选的后续审查；缺失/失败不算通过。操作权限 Auto-review 单独处理。本聊天原有限制仍禁止推送/评论/合并/发布，统一规则同步未扩大 PR 授权；到此步骤再记录并处理权限缺口。
- [ ] 分别记录本地质量门、原生构建、真实验收、PR 自动审查、CI、签名/发布状态；未执行项保持 NOT_RUN。
- [ ] 仅在本范围验收与审查闭环后停用小时循环；本清单不授权推送、评论、合并或发布。

## 6. 一周目标与关键路径

以下为剩余工作的目标分配，不是完成承诺，也不重启原来的周目标或构建计时。

| 工作窗口 | 目标 | 退出条件 |
| --- | --- | --- |
| 最先 1–2 天 | T1/T2；长构建期间只改输入外的产品源码 | 真实私有 IPC + 完整快照/恢复屏障测试通过 |
| 随后 1–2 天 | T3/T4，联接 T5 | 产品核心 ready、持久恢复、一次重试联合测试通过 |
| 剩余窗口 | T6、修复和 T7 | 同候选真实验收、适用 PR 自动审查和修复闭环 |

**资源风险：** 当前构建预算先于一周目标到期。到限必须停止相关资源消耗，并记录已完成对象、所缺目标/测试、预计新增资源；不自动续期。尚未完成的源码工作不因构建到限而被标成通过。

每小时至少推进一个可核验实现、受影响测试、有效构建或真实验收/修复对象。不得只复制构建进度。建议顺序为 T1 → T2 → T3/T4 → T5 → T6 → T7；没有第二个实现负责人。

## 7. 当前候选、失败记录与下一步

- 产品工作区基线：`a4f8ad139e1ace782eba629183ec6057c0407ed8`；本轮实现为未提交差异，不能只用 HEAD 代表候选。
- 历史完整 `chrome` 候选：`86b2456a8e688c187df35c14152743abec8484ba`（0370）；原生树已应用至 0394（`814b0b2e2023d59ebdf086c76296f01abfe5f419`）；0395 精确回放完成、0396 调用端进行中，二者尚未应用原生树。371–387 的既有 49 文件证据继续保留。
- 快照观察：`native-chrome-370-build-result.json` 为 PASS（输入未变）；后续 381/382/383 构建失败记录保留；修复至 0384 后，`native-private-context-384-build-result.json` 为 PASS 且输入未变，`native-private-context-384-tests-result.json` 的 8 个正式 GN 测试目标全部通过。后续完整浏览器产品候选仍待构建/验收。
- 保留：旧 quality-full-r1 失败；旧 stale r2 二进制无效记录；CORS ABI 旧对象崩溃、测试上下文错误、缓存回归 RED；Mojo 初次生成/编译失败。后续绿色结果不能删除这些原始记录。
- **立即下一项：T1/T2 接合。** 私有 per-request loader/control 已由 0377 实现并测试；NetworkContext 完整快照安装/ACK/工厂创建接收端已通过正式 GN 原生测试；继续接 Browser terminal 和完整快照发布/ACK 比对调用方。当前 15 项私有 IPC 测试不能替代 Browser 产品接通。

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
