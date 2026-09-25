# Aegis 访问服务 V1.0：逐项验收追踪表

创建于 2026-09-20（Asia/Shanghai），来源是[冻结规范修订 4](spec.zh-CN.md)第 11、14 节的全部 **A01–A118 与 PF01–PF13，共 131 个主行**。下表场景列逐字摘取冻结表的场景/指标列，判定条件仍以规范原文为准。此表是当前映射、执行与证据的唯一台账；[开发计划](development-plan.zh-CN.md)给出推进顺序，[交接](handoff-20260920.zh-CN.md)给出来源快照。新增产品功能须同 PR 交付并在最终 HEAD 实际执行 unit 与真实入口 regression；文档改动不需要补造产品测试。

## 2026-09-24 W0 当前执行证据

Q 冻结起点 `7f74e0a4e971f91d08d90536e429aba7b82cf37d`。#162 最终 H13=`4670c4dd…` 已合并为 S=`ca4e1b24…`；已回读其三目标 96 tests 的 `PARTIAL_PASS` 与三组 browser fixture PASS 原始记录。它们属于历史 H13，不为新候选或下表 131 个主行补造 PASS。完整测试名、原始报告路径/哈希、当前执行结果与缺口类别集中于 [QUALITY-HANDOFF](QUALITY-HANDOFF.md)。

第一候选 Hcf2329a 实际完成前 10 个 unit targets 共 81 tests 后遇第 11 个 adapter 启动崩溃；browser 实际枚举 41 项，1 项通过后因 favicon 计数污染失败。两次整体为 FAIL/sourceStable=true，**当时**后续候选尚未运行。本轮新增的 3 个真实 LoadingPredictor `PrefetchManager::Start` 入口 fixture 已在 #177 最终 H 的浏览器矩阵中实际枚举和执行；最终 H 的 17/181 原生、56 Chrome browser、6 Content browser 结果见页尾和 [QUALITY-HANDOFF](QUALITY-HANDOFF.md)。S04 的 helper 边界仍有效。旧 #162 Draft/BUILDING 状态仅属于下节注明的历史时间点。本轮不修改 131 个主行的判定或冻结规范。

## 历史：2026-09-22 架构复核后的待执行映射

#164 合并后续接：基线 `c08b632…`；#162 候选已更新到 `682997a…` / 补丁 0161。06:15 UTC 快照确认 Q 正代 F 编译 Coordinator，所选双目标与单一 browser fixture 尚无 runtime 结果。该窄范围交付与 W0 全矩阵分别判定；本次只更新[技术方案的增量合同](architecture-review-20260922.zh-CN.md)、[计划的双窗口执行板](development-plan.zh-CN.md)和[Handoff 身份/接续入口](handoff-20260920.zh-CN.md)，以下 131 个主行状态与既有 S01–S12 证据不变。

[实施技术方案](architecture-review-20260922.zh-CN.md)及[开发计划 W0–W6](development-plan.zh-CN.md)调整执行顺序，未新增本候选 native/service PASS。下面只是计划实验与冻结主行的关联，不是测试源码 ID，也不升级主行。原 S01–S12 保留原 SHA/执行范围；131 行中的 UNVERIFIED 不等于未实现，须在新候选逐场景复核。

| 工作包 | 待补实际测试与证据 | 关联主行 / 边界 |
| --- | --- | --- |
| W0 | 固定候选全部必需 Access unit 与既有真实入口矩阵，实际目标/匹配数/退出码 | G0 部分证据；17-target runner 不替代 browser_tests |
| W1 | 同 CDN/不同 host 的异组并发，精确 scope 与 scheme/port，旧连接/凭据/重启，POST/PATCH 首次发送及原生配置组合；G0 前执行 HTTP/SOCKS5 Profile 最小认证/隔离原型 | A10/A11/A15/A16/A53/A76/A78/A108/A113/A115、PF01–PF03 的子场景；其余主行条件仍须执行 |
| W2 | 实际适用 Vision/splice 长连接计量、数据面额度截断、崩溃/重启/失联恢复、预先绑定误差与对账 | A118、PF04/PF09；账本/账户的其他主行在实验落地时补完整映射，不能只覆盖 A118 就判计量完成 |
| W3 | 可信网站开关→真实 HTTP→REALITY→失败不直连→Network Service 恢复→两 Profile，保存失败与取消 | 纵向工程验证；不等于 G0/G1，按实际测试继续细分映射 |
| W4–W6 | 完整 Alpha、全功能和最终包矩阵 | 仍按冻结 G1/G2/G3；单节点/受限账户/部分入口不使完整主行 PASS |

每个实验实施后补实际测试名、产品/Chromium/Xray/配置身份、原始日志及 unit/browser/service 的执行结果；新增预期场景不得复用历史 S 项的局部 PASS。

## 状态与证据约定

一行分别跟踪**实现、测试映射、执行、结果、覆盖与证据**，不得把任一列当成其他列。`UNVERIFIED` 表示尚未逐场景盘点，**不表示没有代码**；`NOT_MAPPED` 表示尚未找到可追溯测试，**不表示没有测试**；`NOT_RUN` 表示没有绑定该固定候选的实际执行记录；`NOT_EVALUATED` 表示主行尚未按冻结断言判定。`PARTIAL_SOURCE` 只说明下面列明的源码存在；`DOC_ONLY` 只说明文档预览；`EXECUTED_BOUNDED` 仅记录明确的局部合同或预览执行。覆盖的 `PARTIAL` 不能使主行变成 `PASS`。未映射行的“待盘点”不得计入已覆盖或未实现数量。若某场景不适用，先按规范第 14 节记录原因与版本，不能自行删行。

`SRC-287`：2026-09-20 盘点的产品基线 `develop@287aa54c678e8c174b6b286e387a1457cf3a218f`、源码树 `e3a26d4083a23625fad000ea56df8ca449474483`；只证明测试定义/实现源码存在。`L-F699`：文档提交 `f6992ecc9a41196450965e7566021be1f937cb55` 的本地完整质量报告 `.artifacts/ci/local-f6992ec/report.json` 记录 `PASS`、`sourceStable=true`；其中 standalone native 为 834 checks，离线交互预览为 13 项 DOM 检查。该本地报告仅支持下文 S11/S12 的有限执行，不是 Chromium/browser/service/G0 证据。后续新证据用独立 key 记录**产品 head/tree、Chromium 基线/patched tree、patch series、GN args、渠道/配置、run/attempt 或本地命令与退出码、准确测试过滤器、原始日志及受控流量关联 ID**；任一身份变化要重新判定，不复用旧 PASS。

## 已映射的有限子场景

下列测试名是可追溯的源码定义或明确的历史局部执行，均不使所列 A 主行通过。`SRC-287` 对应 Chromium GTest **尚无本候选运行证据**；S04 调用 prefetch helper，不能证明真实 `PrefetchManager::Start` 接线。S11/S12 是本地局部执行，测试范围见最后一列。

| 子项 | 映射主行 | 测试 ID / 来源 | 执行与实际范围 | 主行剩余缺口 |
| --- | --- | --- | --- | --- |
| S01 | A01 | `AccessProxyingURLLoaderFactoryBrowserTest.NoPublishedPolicyPreservesNativePath` | `SRC-287`，Chromium `NOT_RUN`；无已发布策略时原生路径源码用例 | 原有代理组合、真实网络与两种子场景尚未验收 |
| S02 | A10 | `AccessPublishedRequestRuntimeTest.CrossProfileOwnerIsRejected`；`AccessRequestDispatchStateTest.ProfilesAreIsolated` | `SRC-287`，Chromium `NOT_RUN`；所有权/dispatch 局部隔离 | 两个 Profile 同站真实流量、凭据和事件隔离未证实 |
| S03 | A14、A77 | `AccessProxyingURLLoaderFactoryBrowserTest.ProxyPolicyWithoutSelectedEndpointFailsClosed` | `SRC-287`，Chromium `NOT_RUN`；缺 endpoint 子场景 | 内核运行中退出、完整路由等待与性能仍未验收 |
| S04 | A17 | `AccessProxyingURLLoaderFactoryBrowserTest.BrowserProcessPrefetchWithoutEndpointFailsClosed`；`BrowserProcessPrefetchRedirectToUnselectedHostFailsClosed` | `SRC-287`，Chromium `NOT_RUN`；直接调用 `MaybeProxyBrowserProcessPrefetch` helper；源码断言分别为 `origin_delta=0, proxy_delta=0` 与 `origin_delta=0, proxy_delta=1`（合法初始代理请求） | 真实 prefetch 入口 feature on/off、DNS/preconnect/IPv4/IPv6 均未验收 |
| S05 | A18 | `AccessProxyingURLLoaderFactoryBrowserTest.WorkerMainResourceUsesSelectedProxy`；`WorkerMainResourceWithoutEndpointFailsClosed` | `SRC-287`，Chromium `NOT_RUN`；Worker 主资源局部 | HTTPS/ws/wss 和页面归属完整矩阵未验收 |
| S06 | A53 | `AccessNetworkContextTransportTest.NetworkChangeAdvancesEpochAndRejectsStaleEndpoint`；`CaptureRejectsEndpointAfterNetworkEpochChanges` | `SRC-287`，Chromium `NOT_RUN`；旧 network epoch/endpoint 局部 | 旧 ACK/探测、多标签页重试及并发预算未验收 |
| S07 | A76 | `AccessProxyingURLLoaderFactoryBrowserTest.MainNavigationUsesPendingNavigationProxy`；`MainNavigationRedirectReevaluatesThroughProxy` | `SRC-287`，Chromium `NOT_RUN`；源码调用 `ui_test_utils::NavigateToURL`，导航与重定向子场景 | POST/PATCH 首次发送、唯一服务端标记、企业/系统/扩展代理矩阵未验收 |
| S08 | A96、PF13（仅功能子场景） | `AccessProxyingURLLoaderFactoryBrowserTest.BlockBarrierTerminatesInFlightProxyRequest` | `SRC-287`，Chromium `NOT_RUN`；单个 pending fetch 局部 | 上传/下载/媒体/SSE/ws/wss、共享流和 PF13 时间预算未验收 |
| S09 | A97、PF13（仅旧 ACK 子场景） | `AccessRequestDispatchStateTest.LateAckCannotReleaseNewerBlockBarrier` | `SRC-287`，Chromium `NOT_RUN`；旧 ACK 与新 BLOCK barrier 局部 | 旧探测/身份/提交、其他目标继续与 UI 结果；PF13 并发与 2 秒/5 秒实测未验收 |
| S10 | A108 | `AccessProxyingURLLoaderFactoryBrowserTest.MainNavigationRedirectReevaluatesThroughProxy` | `SRC-287`，Chromium `NOT_RUN`；HTTP 导航重定向局部 | HTTPS/WS/WSS、端口、CDN/iframe/子域和无 pageToken 矩阵未验收 |
| S11 | A113 | `RunSiteProxyRuleGroupContractTests`，`access_route_planner_contract_test.h`；standalone runner | `L-F699`，**仅纯 C++ 网站协议组完整性合同局部 PASS**，包含成员缺失；无 Chromium runtime | 崩溃恢复、乱序 ACK、真实导航、调试覆盖和 UI unknown 未验收 |
| S12 | A114 | `verify-preview.cjs` + `preview-checks.json`，13 项离线 DOM 检查 | `L-F699`，**仅文档交互预览局部 PASS**；不是产品浏览器运行 | 独立打开与真实渲染/渠道原生接口隔离未验收 |

对 S03 与 S04 的缺 endpoint 请求，在有界窗口内按目标断言代理和 origin 均无派发；S04 的不受选重定向用例允许初始合法代理请求一次，拒绝的是后续目标，不得把 `proxy_delta=1` 当成失败或抹成零。BLOCK 前在途请求同样保留已发生的代理计数，只观察屏障生效后的新命中派发与终止时序。零增量断言须由同配置健康控制证明两端日志可观测；真实转发代理会合法到达 origin，必须用关联 ID、代理出口与连接日志证明没有 DIRECT 旁路。超时或页面无响应不能单独判 PASS；日志不得包含凭据。源码用例和历史局部 PASS 不转成下面主行 PASS。

## 131 个冻结主行

| ID | 冻结场景 / 指标 | 实现 | 测试映射 | 执行 | 主行结果 | 覆盖 / 未闭合 | 证据 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A01 | 无 Aegis 规则访问普通站点，无原有代理/有原有代理两个子场景 | PARTIAL_SOURCE | S01 | NOT_RUN | NOT_EVALUATED | PARTIAL；见 S01 | SRC-287 |
| A02 | 后台配置已就绪或 DEV/Alpha 只导入订阅，未添加规则 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A03 | 单域名 Aegis 拦截 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A04 | 100 个不同子域被拦 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A05 | 超过采集预算 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A06 | 主文档 DNS 失败、无已提交网页 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A07 | 跨域 iframe 发起资源请求 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A08 | 同页脚本放行后出现新域名 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A09 | 用户在处理期间导航或关闭标签页 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A10 | 两个 Profile 同时访问同一网站 | PARTIAL_SOURCE | S02 | NOT_RUN | NOT_EVALUATED | PARTIAL；见 S02 | SRC-287 |
| A11 | 同一 Profile 两个网站共用 CDN | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A12 | OTR/Guest 与普通 Profile 并存 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A13 | 节点参数错误、端口占用 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A14 | 核心启动前、运行中、更新中退出 | PARTIAL_SOURCE | S03 | NOT_RUN | NOT_EVALUATED | PARTIAL；见 S03 | SRC-287 |
| A15 | Network Service 或 Renderer 重启 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A16 | HTTP2、Alt-Svc、QUIC、旧连接池 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A17 | DNS 预取、preconnect、IPv4/IPv6 | PARTIAL_SOURCE | S04 | NOT_RUN | NOT_EVALUATED | PARTIAL；见 S04 | SRC-287 |
| A18 | HTTPS/ws/wss 与 Worker | PARTIAL_SOURCE | S05 | NOT_RUN | NOT_EVALUATED | PARTIAL；见 S05 | SRC-287 |
| A19 | 证书错误、钓鱼页、CSP/CORS | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A20 | POST/提交/既有下载 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A21 | 重复点击、重复候选、并发编辑 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A22 | 撤销与后续手动编辑冲突 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A23 | 数据库写满、损坏、事务中断 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A24 | 托管/DEV/Alpha 配置中的 REALITY 与 EdgeTunnel WS+TLS | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A25 | DEV/Alpha 订阅失效、更新与节点删除 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A26 | 最终补丁与二进制身份 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A27 | 全新安装及同安装新普通 Profile，首次开启网站代理 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A28 | 配置签名错误、过期、版本回退、租约归属错误 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A29 | bootstrap 故障，有/无有效缓存 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A30 | 租约到期、续租失败、服务端撤销 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A31 | 当前节点故障、备用成功或全部失败 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A32 | OTR 首次使用与退出 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A33 | Beta/Release 尝试调试 URL/Pref/内部接口 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A34 | DEV/Alpha 订阅新增、刷新、删除、切换来源 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A35 | 已知大小上传、下载和实际重试的计量 fixture | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A36 | 同账户多 Profile、多节点、多设备并发 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A37 | 重复/乱序上报、节点重启、旧周期快照 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A38 | 大文件传输中耗尽、套餐到期 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A39 | 周期重置或服务端增加额度 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A40 | 用量接口断网/延迟、账户越权查询 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A41 | DEV/Alpha 订阅附带全局分流、DNS、策略组或未知格式 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A42 | DEV/Alpha 同时存在平台请求数与用户流量额度 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A43 | 同一订阅生成多个优选入口 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A44 | 四渠道管理页/气泡、宽/窄窗口、浅/深主题与屏幕阅读器 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A45 | DEV/Alpha 分区编辑、保存失败、取消、切换简单/高级视图 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A46 | 无额度、无重置、数据延迟、时区变化及不同单位分项 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A47 | 多入口、共享容量组和一批合成 Profile 初始分配 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A48 | 健康会话中刷新订阅、调整权重或备用变快 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A49 | 主入口确认失败，第四/第五候选可用 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A50 | 准备预算耗尽，部分候选未尝试 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A51 | 单站 403/429/5xx、CSP/CORS、证书错误或验证站自身故障 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A52 | 本机断网、休眠、本地内核退出 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A53 | 网络切换后旧探测/旧 ACK 晚到，或多标签页同时重试 | PARTIAL_SOURCE | S06 | NOT_RUN | NOT_EVALUATED | PARTIAL；见 S06 | SRC-287 |
| A54 | 已知共享部署故障与独立域名故障分别注入 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A55 | 原入口恢复、冷却到期及反复抖动 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A56 | 健康入口续租、维护排空及撤销截止 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A57 | 新入口发布前后各阶段崩溃、跨 NetworkContext ACK 延迟 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A58 | 一个标签页取消批次，同时其他标签页等待恢复 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A59 | 候选满载与账户额度耗尽分别发生 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A60 | 多请求和非幂等业务在切换时处于不同阶段 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A61 | 固定入口但服务端动态出口，以及具备出口保持的受控服务 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A62 | DEV/Alpha 手动固定、自动模式恢复、普通版尝试调用调试接口 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A63 | 四渠道分别构建，包含 DEV 的优化编译和 Beta 的发布编译 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A64 | 伪造渠道 Pref/URL/启动参数、自报服务端渠道或远程开关 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A65 | 四渠道并存、打开 Profile、读取 Keychain/凭据及更新包不匹配 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A66 | 渠道缺失/未知、晋级重构建与改名旧包 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A67 | 在共用域名/集群上交换环境令牌、租约或用量查询参数 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A68 | 用量卡/气泡、MB/GB/TB 与 MiB/GiB 来源、零/微量、跨单位边界及小数显示 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A69 | 仅固定 Mbps、明确未设流量额度 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A70 | 额度未知、额度为 0、统计延迟或实际超额 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A71 | 只有 VPS 总量、多个 HOST 或多个用户共用 VPS | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A72 | 可见用量卡持续上传/下载、多设备同时消费 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A73 | 推送心跳正常但统计源停更、部分节点失联、系统时间跳变 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A74 | 多个气泡/管理页、界面隐藏后再打开、推送中断或限流 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A75 | 周期切换、旧消息重放及传输中额度耗尽 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A76 | GET/POST/PATCH 等首次发送、企业/系统/扩展代理组合 | PARTIAL_SOURCE | S07 | NOT_RUN | NOT_EVALUATED | PARTIAL；见 S07 | SRC-287 |
| A77 | 无内核/过期快照时解析路由、高频命中与发布等待 | PARTIAL_SOURCE | S03 | NOT_RUN | NOT_EVALUATED | PARTIAL；见 S03 | SRC-287 |
| A78 | HTTP/SOCKS5 入站认证、错误 Profile 凭据与外部连接 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A79 | scheme/port、精确子域、私有后缀、IDNA/IPv6 与边界冲突 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A80 | Shared/Service Worker 无唯一客户端、prerender/BFCache、受代理约束的 UDP | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A81 | 重装、多建 Profile、临时会话、身份恢复及窃取其他主体引用 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A82 | 多连接/设备/节点并发、RateLease 重放/过期、切换和中心失联 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A83 | 等权账户竞争、一个账户大量连接且混合网页/长下载 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A84 | 计数落盘/上报前后崩溃、未结算租约失联、旧预留回收与跨周期 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A85 | 多 Renderer 错误风暴、1/3/5 Profile、候选排空与 50 次生命周期循环 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A86 | 同步到秒、重置到分钟、跨年/时区变化、倒计时不足一分钟 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A87 | 升级数据库/密钥命名空间、旧版本回退、规则库损坏 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A88 | 内核资产损坏/替换、未知版本、不同架构与更新失败 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A89 | HTTP/SOCKS5 × REALITY/WS+TLS 的完整链路及真实部署关系 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A90 | 最终候选头、干净补丁重放、四渠道产物、全新安装/升级/回滚及发布门禁 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A91 | DIRECT/PROXY/REJECT 的全部六种有向转换与重复操作 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A92 | 离线、无内核、欠额、退出身份时执行 BLOCK | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A93 | 两 Profile、两顶层网站、同一 CDN 及选择主导航目标 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A94 | 批量 ALLOW 与有界补充遇到有效手动 REJECT；随后单项 ALLOW | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A95 | 本站/Profile、精确/后缀、scheme/port、管理限制及冲突数据 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A96 | BLOCK 时正在上传、下载、媒体、SSE、ws/wss 与共享传输 | PARTIAL_SOURCE | S08 | NOT_RUN | NOT_EVALUATED | PARTIAL；见 S08 | SRC-287 |
| A97 | ALLOW 准备中执行 BLOCK，旧 ACK/探测/身份响应和提交随后到达 | PARTIAL_SOURCE | S09 | NOT_RUN | NOT_EVALUATED | PARTIAL；见 S09 | SRC-287 |
| A98 | REJECT 命中主导航、HTTP 缓存、Service Worker、BFCache/prerender | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A99 | BLOCK 后撤销、删除、显式 DIRECT 和后续并发编辑 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A100 | PROXY 断网、节点故障、欠额、退出身份后恢复与重试 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A101 | 只有 DIRECT/REJECT 规则、无代理业务/准备且显示界面隐藏 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A102 | 每秒微量字节增长、跨单位舍入、BLOCK 后在途迟到结算 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A103 | 安装访客、多 Profile、显式登录/切换失败、退出、继续访客及删除 Profile | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A104 | persistent/profile_session/until、截止时继承 PROXY、进程重启及恢复日志 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A105 | Beta/Release 的管理页、气泡、已保存网站、阻断页与错误状态 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A106 | DEV/Alpha 简洁视图与调试视图切换 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A107 | Beta/Release 中伪造 URL/Pref/启动参数、修改 DOM、直接调用通用 mutation | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A108 | 同域 HTTP/HTTPS/WS/WSS、HTTP→HTTPS 跳转、8443 等非默认端口，以及 CDN/iframe/子域和无 pageToken | PARTIAL_SOURCE | S10 | NOT_RUN | NOT_EVALUATED | PARTIAL；见 S10 | SRC-287 |
| A109 | 在被安全拦截或受管理的网站开启/关闭代理 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A110 | 已开启后离线/欠额/退出身份，再关闭；存在较宽 PROXY 继承 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A111 | 首次开启准备中关闭/取消、晚到 ACK、多标签页及重复点击 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A112 | 网站开关已生效后节点故障、额度耗尽、重启与渠道晋级 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A113 | 协议组发布一半时崩溃、成员缺失、乱序 ACK、同域导航与调试覆盖冲突 | PARTIAL_SOURCE | S11 | EXECUTED_BOUNDED | NOT_EVALUATED | PARTIAL；见 S11 | L-F699 |
| A114 | 离线直接打开独立交互示例，无宿主/Tweak/CDN；切换四渠道和服务状态 | DOC_ONLY | S12 | EXECUTED_BOUNDED | NOT_EVALUATED | PARTIAL；见 S12 | L-F699 |
| A115 | 原有代理为 DIRECT、系统静态代理、PAC、扩展代理、企业强制代理/强制 DIRECT，以及运行时修改 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A116 | 网站开启→调试精确 BLOCK→简洁界面→离线关闭；以及单目标 ALLOW/删除/撤销和乱序准备 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A117 | 固定 REALITY/Vision 与 WS+TLS 配置，实际网络握手、受控探测、连通性和跨协议故障恢复 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| A118 | Linux 服务端长连接及客户端适用的 Vision/splice 快路径，有限额度、秒级用量与节点故障 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| PF01 | 10,000 条规则纯匹配：平均 ≤50 µs，p95 ≤100 µs，p99 ≤500 µs；热路径无磁盘/网络/UI 往返 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| PF02 | 未命中规则的直连 p95 TTFB/LCP 增量不超过 max(基线 5%,20 ms) | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| PF03 | 同一代理路径下，Aegis 路由吞吐不低于固定本地代理基线的 95%；p95 TTFB 增量不超过 max(基线 5%,20 ms) | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| PF04 | 用量有效变更约 1 秒更新；节点计入字节到可见 UI 的 p95 ≤3 秒、p99 ≤5 秒 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| PF05 | 首次准备 ≤15 秒；故障复核 ≤6 秒、确认后切换 ≤15 秒；超过预算停止并明确失败 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| PF06 | 每文档 2,048 host；每 Profile 收集器 ≤8 MiB；诊断待处理最多 4 MiB 且最多 4,096 条，任一先到即限流；全浏览器该诊断队列 ≤16 MiB | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| PF07 | 稳定内核每活跃 Profile 最多 1；全浏览器额外候选/排空资源最多 2；所有进程及峰值 RSS 有总预算 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| PF08 | 无代理使用/准备需求且界面隐藏时，本功能内核为 0、用量显示订阅为 0；包含有大量 DIRECT/REJECT 规则的情况；新增后台 CPU 5 分钟均值 ≤单逻辑核 0.5% | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| PF09 | 声明的 VPS/账户速率和突发包络不能被多连接、多 Profile 或多设备突破 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| PF10 | 一个等权饱和账户不能靠连接数取得额外份额；等权账户稳定吞吐与公平目标偏差 ≤10% | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| PF11 | 同一 Profile 多 UI 只有一份有效用量订阅；隐藏后无秒级显示请求；无查询堆积 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| PF12 | 1/10/30 标签页混合资源、下载和 ws/wss 时无无限队列或请求饥饿；连接池生效参数可追溯 | UNVERIFIED | NOT_MAPPED | NOT_RUN | NOT_EVALUATED | 待盘点 | — |
| PF13 | BLOCK 本地屏障在接收协调任务内安装；发布后的拒绝确认/在途本地终止 ≤2 秒；总操作预算 5 秒 | PARTIAL_SOURCE | S08、S09（仅功能） | NOT_RUN | NOT_EVALUATED | PARTIAL；无并发/2 秒/5 秒实测 | SRC-287 |

更新某一主行前，逐个列出冻结断言的适用子场景与实际观察，分别给出 `PASS`、`FAIL`、`BLOCKED` 或 `NOT_RUN`；局部结果需保持 `PARTIAL` 并注明剩余项。PF 指标还要记录规范规定的样本、规模、分布、计时起止及设备/网络条件。A90 的最终包证据与 A114 的文档预览独立登记，不能从源码或本地质量门推断发布就绪。

Q 第二候选 H745bf3c 执行补记：11 targets/86 tests 通过后 dispatch_state 测试 raw_ptr 编译失败；browser 固定 API 编译失败、0 runtime。保留整体 FAIL/sourceStable 和未运行范围，131 主行不变，第三候选重验待执行。

Q 第三候选 Hceb6ead：设施编译修复已过，但 transport 尾点 host 接纳及 frame prefetch 缺 endpoint 直连暴露产品缺陷。NetLog 已证实后者 DIRECT/HTTP200；native 总门和 browser 总门均 FAIL/sourceStable。尾点按保守拒绝设计修复，保无 snapshot 的 native 边界；prefetch 另定位实际入口。局部通过与剩余目标补充诊断不升级 W0/G0 或131主行，详见 QUALITY-HANDOFF 第三候选记录。

Q 历史候选状态：0175–0186 的局部源码/编译/browser 证据与失败归档见 QUALITY-HANDOFF。Hc6f14c2 的 browser 构建主动中断、0 runtime；独立预审发现 HTTP URL 的 MHTML 子帧原禁网 default 可被 prefetch 重建为网络 factory。0187 补 RFHI 可信资格与真实 MHTML 子帧回归，pending Clone 测试设施也已修正；H882c354 当时仅六关键对象编译 PASS/sourceStable，完整链接和 runtime 未验。这些均为旧头部快照，不转用于最终 H。

Q #177 最终证据（2026-09-24）：B42f48b5/H1f86a6e/M547ed2a/S43e4e55 的身份和原始路径见 [QUALITY-HANDOFF](QUALITY-HANDOFF.md)。同一 H 的固定 Chromium 17 个原生目标/181 项、Chrome browser 56 项、Content browser 6 项均 PASS/sourceStable；独立 Review CLEAR，PR 托管检查及 S push CI 通过。该结果关闭所列选定矩阵和 #177 代码审查，不等于完整缓存/BFCache/prerender BLOCK、性能、发布或 131 个冻结主行的逐场景验收；W0/G0 不升级，131 个主行判定保持原状。
