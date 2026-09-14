**Aegis Browser 内置访问服务：V1.0 技术方案与验收标准（冻结稿）**

文档索引：[English](../../README.md) · [简体中文](../../README.zh-CN.md) · [繁體中文](../../README.zh-TW.md)。本文件为简体中文设计基线；[冻结清单](freeze.json)记录版本及校验值，[交互示例](interaction-example.html)为可直接在浏览器打开的独立 HTML，内置渠道、入口和故障状态预览控件，不依赖外部脚本或宿主。GitHub 文件页仅显示源码，下载后打开即可预览。[离线预览检查](verify-preview.cjs)使用 Node 20+ 与 jsdom 26.1.0；从已安装依赖的环境运行 `node docs/plans/access-service-v1.0/verify-preview.cjs`，非本地依赖可通过 `NODE_PATH` 指向其 node_modules。检查不请求网络、不验证真实代理。示例默认展示 Beta 简洁界面，所有操作和数字均为本地虚构数据；渠道预览不代表真实构建已通过隔离验收。

日期：2026-09-13。文档状态：V1.0 冻结修订 4；产品实现及运行验收尚未执行。

本文合并此前设计、完整性复评与渠道交互修订，作为 V1.0 开发和验收的唯一行为基线。修订 2 明确：Beta/Release 只向用户提供当前网站的代理开关；DEV/Alpha 可以在调试界面暴露策略、操作、节点和脱敏诊断。三策略/两动作继续作为底层执行与调试合同，不再作为 Beta/Release 的产品操作。此前快照与评估稿均为过程草稿，不作为已发布版本。本文中的“必须”是验收条件；标为初始预算的数值也是本版本的测试目标，并非已有性能。真实 VPS 参数、内核版本与构建环境按第 13 节绑定，不能用示例替代。

冻结意味着实现者无需再猜测网站开关、调试操作、冲突、撤销和故障的含义；不意味着实现已经证明可行、性能已达标或获准发布。P0 如发现无法满足合同，必须登记失败证据和明确的修订差异，递增规范修订号后重审；不得静默缩小范围、改变语义或放宽指标。具体地址、秘密、负责人和实测容量属于部署绑定项，不是未决的用户行为。当前产品方案版本为 V1.0，冻结修订号为 4。修订 4 固定已有代理配置的组合规则，分开网站协议组与调试精确目标，更新实施接入基线，并登记出站协议的抗 DPI 评估边界。

**1. 目标、范围与完成含义**

Beta/Release 用户路径固定为：默认直连 → 开启“当前网站使用代理” → 后台准备并应用本站代理选择 → 显示“已使用代理”或明确失败。关闭同一开关恢复正常直连，不表示阻止网站。节点导入、验证、选择、续期和故障切换均在后台完成。DEV/Alpha 也提供同一简洁入口，另有明确标识的调试视图。下文“普通界面/普通包”统一指 Beta/Release 的用户体验/构建；普通 Profile 指非 OTR/Guest 的 Profile 类型，与渠道无关。

| 项目 | 最终要求 |
|---|---|
| 产品范围 | Aegis 的 Chromium 桌面产品线；先在 macOS 完成实现与验收，其他平台另行绑定证据 |
| 浏览器入站 | 本机 HTTP 与 SOCKS5；先打通 HTTP，SOCKS5 的认证和隔离单独验收，未通过不能宣称完整支持 |
| 主出站 | 固定版本 Xray，VLESS + RAW(TCP) + REALITY + XTLS Vision，使用自有或受控服务端 |
| 兼容出站 | VLESS + WebSocket + TLS，用于约定的 EdgeTunnel 类型订阅/节点；与 REALITY 分开验收 |
| 普通操作 | 当前网站只有“使用代理”开关；开=为明确当前域名启用代理，关=恢复正常直连；不附带安全防护例外 |
| 底层策略 | DIRECT / PROXY / REJECT 按明确范围执行；Beta/Release 不展示策略下拉框、规则编辑器或技术枚举 |
| 调试操作 | 仅 DEV/Alpha 调试视图展示 ALLOW/BLOCK、目标列表、规则编辑/撤销；ALLOW 允许并代理，BLOCK 明确阻止；批量 ALLOW 保留手动阻断，单目标 ALLOW 可解除 |
| 用户隔离 | 本地规则、凭据、采集及运行状态按渠道、Profile 隔离；同一服务账户的用量按授权汇总 |
| 节点策略 | 自动检测 → 选定并保持 → 故障切换；不同主体可初始分配到不同容量组，健康绑定不逐请求轮换 |
| 用量 | 服务端实际上传+下载字节，最小显示单位 MB，按量级自动切换 GB/TB；有明确账户流量额度才显示总额、剩余与比例 |
| 同步体验 | 可见且活跃时约 1 秒更新；最近同步到秒，重置时间及倒计时到分钟 |
| 调试能力 | DEV/Alpha 可展示订阅导入/更新、节点参数、手动选择、策略与脱敏诊断；受本渠道服务授权约束；Beta/Release 后台托管 |
| 渠道 | dev / alpha / beta / release，同一套核心实现、不同能力与数据命名空间 |

“一键”表示一次用户操作，不承诺瞬间完成或修复所有网站问题。Beta/Release 的开关仅控制第 9 节定义的当前域名范围，不批量放行页面资源。“全部/批量 ALLOW”仅属于 DEV/Alpha 调试流程，限定为当前观察集合及有界补充发现中的合格候选；未知归属、尚未触发的请求和不支持的协议必须明确反映为覆盖不足，不能静默算成功。

本期不建设系统 VPN/TUN，不修改系统代理、DNS 或路由表，不接管其他应用。本文“DIRECT / 默认直连 / 恢复正常直连”均表示移除本功能的代理选择，沿用 Chromium 当前生效的原有连接配置；只有该配置解析为 DIRECT 时才直接连接目标。系统/扩展代理与 PAC 按第 2 节组合表处理，既有 VPN/TUN 仍可影响实际网络路径。普通界面使用“未使用本服务代理 / 使用浏览器原有连接设置”，不能在原有代理仍生效时声称物理直连。HTTPS 保持目标站点端到端 TLS，不安装中间人证书。证书、钓鱼页、CSP/CORS 等限制不被本功能关闭。Trojan、Hysteria 2、多区域运营和付费购买流程不属于本期必需交付；未来增加时独立验收。

完整功能完成、Alpha 可用、可分发是不同状态。Alpha 的缩小覆盖范围不得当成最终需求完成，发布还需项目自身签名、公证、安装与升级证据。

**2. 源码基线与确定的技术决策**

| 项目 | 核对基线 |
|---|---|
| 仓库 | gcsagroup/aegis-browser；以下提交是设计核对基线 |
| 历史设计提交 | cb35227fcc66f4a451fc93d4b755f3beb0f3a13b；保留修订 1–3 的审阅来源 |
| 修订 4 接入核对提交 | main：ccbbaf371bad0626fb0fce3db166d5c2d0f675b0；2026-09-13 核对远端，P0 开工时再次绑定实际候选头 |
| Chromium | 151.0.7922.77，ff37cfca210138f2a40b843b4a8195ab7e4fc7ff |
| 补丁模型 | 当前接入基线为 108 个 Chromium 补丁、2 个嵌套 V8 补丁；历史设计基线为 67+2；overlay、顺序补丁及构建接线共同交付 |
| 本轮证据 | 已读项目代码及准确 Chromium 提交的接口；未编译本功能、运行 Xray 或压测 VPS |

现有原生工具栏气泡、站点边界计算、OSCrypt 和 Profile 工厂可以复用。修订 4 的源码核对改变了 P1 的工作量，但没有产生本访问服务的运行验收：

- 当前 AegisService 已由 ProfileKeyedServiceFactory 按普通/主要 OTR Profile 创建；不再安排重复的单例迁移。复用其生命周期，补查本服务的 StoragePartition、Guest、销毁顺序及迟到回调边界。[当前工厂](https://github.com/gcsagroup/aegis-browser/blob/ccbbaf371bad0626fb0fce3db166d5c2d0f675b0/apps/browser/overlay/chrome/browser/aegis/aegis_service_factory.cc#L51)
- CNAME 缓存已按 BrowserContext 分区；BlockReporter 仍持有进程回调，但 AegisService 已通过活动服务和文档归属路由。P1 复用并验证真实归属、分区回收及跨 StoragePartition 防护例外，不把全局回调的存在直接等同于跨 Profile 串用。[当前缓存](https://github.com/gcsagroup/aegis-browser/blob/ccbbaf371bad0626fb0fce3db166d5c2d0f675b0/apps/browser/overlay/chrome/common/aegis/cname_uncloak.h#L21)、[当前报告路由](https://github.com/gcsagroup/aegis-browser/blob/ccbbaf371bad0626fb0fce3db166d5c2d0f675b0/apps/browser/overlay/chrome/browser/aegis/aegis_service.cc#L1123)
- PrivacyEventStore 每文档仅 50 条、总计 200 条，且展示域名已归并；新增精确采集器，不能从展示列表反推授权集合。[事件上限](https://github.com/gcsagroup/aegis-browser/blob/ccbbaf371bad0626fb0fce3db166d5c2d0f675b0/apps/browser/overlay/chrome/browser/aegis/privacy_event_store.h#L30)
- AegisNetThrottle 已会取消请求；仅设置代理无法解除现有拦截。当前 initiator 也不能替代浏览器确认的顶层页面。[当前拦截入口](https://github.com/gcsagroup/aegis-browser/blob/ccbbaf371bad0626fb0fce3db166d5c2d0f675b0/apps/browser/overlay/chrome/common/aegis/aegis_net_throttle.cc#L108)

固定 Chromium 的 ProxyDelegate::OnResolveProxy 提供 URL、NAK、method 与 ProxyInfo，确认可作为策略接入方向。该函数同步返回，只读取已发布的本地快照；不能在其中等网络验权、启动内核或跨进程确认。异步准备与请求等待放在可暂停的派发入口；无法可靠等待时明确失败。[固定版本接口](https://raw.githubusercontent.com/chromium/chromium/ff37cfca210138f2a40b843b4a8195ab7e4fc7ff/net/base/proxy_delegate.h)

NAK 提供顶层 SchemefulSite，但不是完整的文档授权凭据；页面归属仍由浏览器确认。[固定版本 NAK](https://raw.githubusercontent.com/chromium/chromium/ff37cfca210138f2a40b843b4a8195ab7e4fc7ff/net/base/network_anonymization_key.h)

现有 CustomProxyConfig 默认不代理非幂等方法。实现必须处理该默认门槛，使命中规则的 GET、POST、PATCH 等首次发送均按路由执行；“不自动重放提交”单独控制，不能使提交第一次发送绕过代理。[配置定义](https://raw.githubusercontent.com/chromium/chromium/ff37cfca210138f2a40b843b4a8195ab7e4fc7ff/services/network/public/mojom/network_context.mojom)、[实际 delegate](https://raw.githubusercontent.com/chromium/chromium/ff37cfca210138f2a40b843b4a8195ab7e4fc7ff/services/network/network_service_proxy_delegate.cc)

**已有连接配置的组合合同**

“原有配置”指排除 Aegis 本功能覆盖后，Chromium 按其原生优先级解析的当前系统/扩展/策略代理和 PAC；不是首次开启时保存的旧副本。原有来源之间的优先级不由 Aegis 重排。

| 条件 | DIRECT / 无 Aegis 规则 / 网站关闭 | PROXY / 网站开启 | REJECT |
|---|---|---|---|
| 无原有代理，原生结果为 DIRECT | 正常防护后直连 | 仅经已授权的本 Profile Aegis 入口；失败等待/终止 | 本地拒绝 |
| 非强制系统/扩展代理或 PAC | 使用原生解析结果及其原有失败/回退语义 | 命中范围内以 Aegis 入口替换原生代理结果，不拼接原有代理或 DIRECT 作为备用；未命中请求继续用原有配置 | 本地拒绝，不访问任一代理 |
| 适用于该请求的企业强制代理、强制 DIRECT 或禁止自定义代理 | 服从原生强制配置与限制 | 本期不串联 Aegis 与强制代理，也不绕过强制 DIRECT；保留已提交选择，返回受管理限制，停止受约束业务，不声称已使用 Aegis | 本地拒绝；不以代理操作解除管理防护 |

关闭只提交 Aegis 的 DIRECT 选择，不清除或改写系统/扩展/企业配置。原有配置运行时变化提升 baseProxyConfigGeneration，与 G/S/E 一同参与新请求、连接池/preconnect 和恢复的版本检查；重新计算受管理状态，不复用已失效路径。既有业务不重放。专用控制面沿用原生配置并遵守企业限制，不经 Aegis 覆盖以免 bootstrap 递归；本期 Xray 远端拨号不增加系统/扩展代理链，适用的企业出站限制必须在启动/拨号前执行。P0 不能证明这些限制时 G0 不通过。组合验收见 A76/A115。

**3. 架构、所有权与模块边界**

~~~text
当前页工具栏气泡 / chrome://aegis
             │ 浏览器核验的 pageToken；不接受网页指定 Profile
             ▼
Profile 级 AegisAccessService
  ├─ 精确 PageAccessCollector / PageAccessSession
  ├─ AccessRuleStore / 联合策略发布 / 撤销与恢复
  ├─ ProxyProvisioningClient / ManagedEndpointSelector
  ├─ ProxyCoreController → 本 Profile 的 Xray
  └─ AccessEntitlementService → 一份用量快照、多 UI 观察者
             │ 已编译的只读策略快照
             ▼
所属 StoragePartition / NetworkContext
  → 原生策略判断 → REJECT（本地终止）
                  DIRECT（正常直连）
                  PROXY / REQUIRE_PROXY → 本机已登记入口

专用控制面连接 → 签名配置 / 身份与租约 / 分配准入 / 用量推送
服务端数据面   → 鉴权 / 转发 / 字节计量 / 账户及物理资源限制
~~~

| 模块 | 责任 | 拟落点 |
|---|---|---|
| AegisAccessService + Factory | Profile 级总入口，协调批次、规则和运行版本 | apps/browser/overlay/chrome/browser/aegis/access/ |
| PageAccessCollector / Session | 精确候选、文档归属、有界补充与取消 | 同上 |
| AccessRuleStore / RuleMutationCoordinator | 三策略规则、ALLOW/BLOCK/编辑/撤销操作、差异、版本及恢复 | 同上 |
| RequestOwnershipRegistry / RequestBlockController | 保存请求到作用域的可信归属，发布本地阻断屏障，按请求/流终止在途操作 | 同上；连接至 Browser/Renderer/Network Service 的原生入口 |
| ProxyProvisioningClient / EndpointSelector | 配置与凭据、候选绑定、健康及切换 | apps/browser/overlay/chrome/browser/aegis/proxy/ |
| ProxyCoreController | 固定内核资产、进程、入口、候选及回收 | 同上 |
| DevSubscriptionService | DEV/Alpha 本地订阅解析和调试来源，Beta/Release 不注册 | 同上 |
| AccessEntitlementService | 账户权益、服务端快照、订阅去重与显示状态 | access/ |
| AccessPolicyEvaluator | 无磁盘/网络的原生规则匹配；共享测试向量 | 中立 components/aegis_access 层 |
| Network Service 桥接 | 每 NetworkContext 快照、确认和派发约束 | services/network overlay 与顺序补丁 |
| UI 与共享合同 | 原生气泡、管理页、schema 和跨语言向量 | 现有 ui/views、ui/webui、resources；packages/core |
| 托管控制面 | 签名目录、主体、租约、撤销、容量分配及用量接口 | 独立服务，实施时绑定仓库与负责人 |
| 服务端执行与账本 | 字节累计、额度预算、速率及并发限制、去重对账 | 服务端内核适配及账本 |

net/services/network 不反向依赖 chrome/browser。网络热路径使用 C++；TypeScript 负责合同、表单和对照向量，不逐请求运行 JavaScript。现有防护、报告和缓存链路必须接入新的 Profile 所有权，不能新建正确服务后仍从旧单例取事件；无关 AI、下载等模块只做必要适配。

**4. 作用域、身份与数据模型**

调试 ALLOW/BLOCK 的精确规则键为：渠道命名空间 + Profile + StoragePartition 策略域 + 顶层 SchemefulSite + 精确目标 host + scheme/port。它们不自动扩展子域或整个 Profile。Beta/Release 网站开关由浏览器从当前导航的规范化 host 生成第 9 节定义的同域协议规则组；前端不能提交任意目标、协议、端口或策略。网站开关的协议组与调试单目标规则不能互相冒充；仅 DEV/Alpha 调试编辑器可以另行显式扩大域名或 Profile 作用域。

Profile、服务账户、网站登录账号分别建模。同一服务账户可明确绑定多个 Profile，凭据和规则仍独立，用量在服务端累计。换节点、新建 Profile 或重新登录既有账户不重置该账户额度。未知身份不通过推断合并账户，也不因匿名新主体无限重复发放资源。

V1.0 身份行为固定为“默认安装级访客权益 + 可选显式绑定服务账户”。首次普通使用由浏览器安装身份管理器向 bootstrap 自动登记受限访客主体；同一渠道安装中的普通 Profile 使用独立短期凭据，映射到同一访客权益池，不按 Profile 重复发放额度。安装凭据属于独立系统凭据命名空间，不保存在某个普通 Profile 内供其他 Profile 借用；登记、续期和短期凭据签发通过浏览器私有 IPC 调用。服务端按安装凭据、登记速率、资源池与准入合同限制访客权益，不能仅相信客户端生成的安装 ID。

保留的有效安装凭据可恢复同一访客权益；卸载或凭据丢失后，不承诺无身份依据地恢复旧访客。服务端可以拒绝再次登记或给予受限权益，不引入隐蔽设备指纹来承诺识别同一人。已认证服务账户通过正常登录恢复原账本。没有配置账户提供方的发行环境只展示访客状态，不显示不可用的登录入口；Beta/Release 的节点操作始终隐藏。

显式登录/切换账户先在暂存状态验证新身份和权益，再提升 identityGeneration、撤销旧 Profile 凭据、停止旧账户的代理流、清除旧用量缓存并装入新快照；旧身份的异步响应不能覆盖新身份。若验证失败，切换不提交，原身份保留。规则属于 Profile，切换身份时保留 DIRECT/PROXY/REJECT；有效代理组改由新身份重新分配，不能复用旧秘密或显示混合账本。已有已发送业务不自动重放。

退出账户立即在本机禁用该 Profile 的旧服务凭据并停止代理流，状态为“未连接服务账户”；规则保留，PROXY 不转 DIRECT。服务端吊销通过幂等请求完成；离线时记录待吊销项并重试，远端最迟受短期凭据/租约的有效截止约束，不把“本地已退出”冒充“离线远端已确认吊销”。用户明确选择“继续访客使用”才切回安装访客权益，不能在退出后悄悄借另一账户额度。删除 Profile 清除本地规则/秘密并发起凭据吊销，不删除或归零服务端账户账本；不含秘密的待吊销标识由安装身份管理器保存至确认/截止，其他 Profile 不受影响。所有身份改变均递增 identityGeneration，并使旧准备操作失效。

OTR/Guest 使用独立临时 BrowserContext、规则、短期凭据与内核，退出不落持久秘密。默认通过安装身份管理器取得临时访客凭据并共享该安装受限访客权益，不能每开一次会话新领完整额度；明确在临时上下文完成账户授权时才使用该账户权益。不能读取普通 Profile 秘密替代授权。服务不支持时显示不可用，不能借用普通 Profile。完整交付必须验收临时授权与退出行为；System Profile 不启用此功能。此边界不承诺服务端无法通过网络信息关联会话。

~~~text
ManagedProfileIdentity
  principalId, entitlementAccountId, serviceEnvironment, serviceRealm
  identityKind(installation_guest|authenticated|signed_out)
  installationCredentialRef, identityGeneration
  encryptedCredential, expiresAt, revision

SignedEndpointManifest
  configVersion, keyId, issuedAt, expiresAt, audience, realm
  supportedCoreRange, endpoints, capacityGroups, selectionPolicyVersion
  healthPolicy, groupEgressPolicies(groupId, allowedEgressProfiles), signature

EndpointLease
  leaseId, principalId, endpointId, assignmentId, admissionReservationId
  encryptedConfig, issuedAt, expiresAt, connectionDeadline, revision

ProxyEndpoint / ProxyGroup
  endpointId, deploymentId, capacityGroupId, trafficPoolId, failureDomains
  egressGroupId, egressAffinityCapability
  address, port, host, sni, path, protocol, transport, security, sourceId
  egressProfile(reality_vision|ws_tls_compat), allowedEgressProfiles
  groupId, sourceMode, selectionMode, selectedEndpointId, selectedLeaseId
  assignmentId, bindingRevision, policyGeneration, selectionGeneration
  networkEpoch, pendingSwitch, state

AssignmentPlan / EndpointHealth
  principalId, groupId, assignmentRevision, poolVersion, policyVersion
  orderedCapacityGroups, orderedEndpoints, expiresAt, admissionState
  configRevision, networkEpoch, lastSuccessAt, failureStage, cooldownUntil

AccessRule
  ruleId, storagePartitionScope, scope(site|profile), topLevelSite
  destinationHost, includeSubdomains=false, schemes, ports
  mode(direct|proxy|reject), proxyGroupId?
  protectionOverride(none|tracker|easylist|cname 的有限集合)
  source(user_action|user_edit|restored), lastUserAction(allow|block|set_mode)
  lifetime(persistent|profile_session|until), expiresAt?, createdByBatchId
  rowRevision, lastOperationSequence
  siteToggleId?, siteToggleRevision?  // 同域协议规则组的可选归属

SiteProxyRuleGroup
  siteToggleId, canonicalHost, storagePartitionScope
  topLevelSites(http_site, https_site), memberRuleIds
  revision, lastOperationSequence
  // 选择由成员共同的 mode(direct|proxy) 推导，不另存可漂移的 enabled

RuleMutationOperation
  operationId, kind(allow_batch|allow_target|block_targets|set_mode|delete|undo|expire)
  targetKeys, expectedRevisions, identityGeneration, operationSequence
  phase(preparing|publishing|terminating|committed|partial|failed|cancelled)
  beforeImages, afterImages, guardInstalled, durable, requiredAcks, receivedAcks
  cancelledRequestIds, unresolvedRequestIds, resultCounts, coverage

RequestPolicyContext
  requestId, browserContextToken, storagePartitionToken, topLevelSite
  documentToken|pendingNavigationToken, exactHost, scheme, port
  effectiveRuleId, policyGeneration, identityGeneration, baseProxyConfigGeneration
  lifecycle(new|dispatched|streaming|completed|cancelled)
  terminationHandle, ownerChannel

PolicyEvaluation
  effectiveMode(direct|proxy|reject), matchedRuleId, ruleSource
  dispatchOutcome(ready|waiting|denied|failed), reason, policyGeneration
  runtimeState(stopped|preparing|ready|recovering|offline|quota_exhausted|signed_out|unavailable)

PageCandidate / AccessBatch
  browserContextToken, storagePartitionToken, webContentsToken
  documentToken|pendingNavigationToken, topLevelSite, exactHost, scheme, port
  requestKind, blockReason|netError, lastAttemptRoute, occurrenceCount
  firstSeen, lastSeen, eligibility
  batchId, sourcePageToken, snapshotRevision, baseGeneration, targetGeneration
  changedRuleIds, skippedManualRejectIds, state, resultCounts, coverage, droppedCount

AccessEntitlement / UsageSnapshot
  entitlementAccountId, planId, periodId, periodStart, periodEnd, resetsAt
  expiresAt, quotaMode(limited|unlimited|unknown), quotaBytes, status, revision
  accountingVersion, uploadedBytes, downloadedBytes, usedBytes, remainingBytes
  unit=byte, metricKind=transfer_bytes, scope(account|service_pool)
  measuredAt, receivedAt, snapshotAgeMs, coverageStatus, sourceWatermarks
  freshness(current|delayed|unavailable), source

NodeUsageRecord / ByteBudgetLease / RateLease
  nodeId, counterSessionId, principalId, entitlementAccountId, periodId
  sequence, cumulativeUplink, cumulativeDownlink, accountingVersion
  leaseId, budgetBytes|rateBitsPerSecond, burstBytes, issuedAt, expiresAt, epoch
  finalSettlementState

DevSubscription / SelectionEvent
  sourceId, encryptedUrl, encryptedAuth, revision, parsedEndpointIds
  selectedEndpointId, lastUpdatedAt, providerUsageMetadata
  eventId, groupId, assignmentId, fromEndpointId, toEndpointId
  generation, networkEpoch, reason, candidateOutcome, timestamp
~~~

字段为实现合同，具体序列化版本在 P2 固定。服务端计量标识映射到内部主体，不要求收集真实邮箱。DEV/Alpha 供应方的请求数元数据使用独立模型，不混入普通版字节用量。

mode 是唯一持久策略，不另存 allow=true/block=true。DIRECT/REJECT 的 protectionOverride 必须为空且不得引用代理组；PROXY 必须引用本 Profile 的逻辑组，例外可以为空或为已明确授予的有限集合。用户 BLOCK 或在编辑器选择 REJECT 都属于手动阻断。广告过滤等原有内置规则不复制成用户 AccessRule；命中它们的拒绝原因单独报告。

默认 lifetime=persistent，直至用户删除；“本次会话”固定为本 Profile 实例的生命周期，而非某个标签页的生命周期，最后一个相关窗口关闭并销毁 Profile 时清除。until 使用用户明确选择的截止时间，重启后仍核验；到期经同一规则发布流程回到继承。无本地规则表示继承，不增加第四种处理策略。规则到期与代理租约到期不同：前者按用户设定结束覆盖，后者保留 PROXY 并显示服务不可用。

规则与恢复状态存于 Profile 内独立 access.db；由数据库位置和服务实例决定所有权，前端传来的 userId/profileId 不构成权限。秘密使用 OSCrypt/系统凭据能力加密，不写日志；不将含秘密的订阅发给未经授权的第三方转换服务。

原始 URL 的 query/fragment、Cookie、POST body 和页面正文不进入规则库或用量账本。候选保留必要 host/scheme/port 与原因；批次仅保留差异。初始保留：批次差异 7 天；脱敏切换事件最多 7 天且最多 200 条；临时 Profile 全部内存化。页面集合随文档生命周期有界回收，不回流到新文档。

健康状态不能跨重启直接当作当前事实；与 configRevision/networkEpoch 绑定。配置验签还必须验证有效期、版本防回退、audience/realm、Profile 租约及完整协议组合。规则匹配、host 规范化、后缀边界、序列化和分配排序使用 C++/TypeScript 共用 Golden Vectors。

**5. 请求归属与原生路由**

| 请求范围 | 处理合同 |
|---|---|
| 失败主导航 | 用浏览器拥有的 pendingNavigationToken 收集目标，未提交也能从错误页操作 |
| 主文档、重定向、子资源、iframe | 使用浏览器确认的顶层站点与文档；不使用子框架自报 initiator 代替 |
| Fetch/XHR、脚本、图片、CSS、媒体 | 精确目标去重，保留 scheme/port 和原因集合 |
| Dedicated Worker | 根据创建者关联页面和 Profile |
| Shared/Service Worker | 仅将可可靠关联的客户端请求纳入本站批次；无唯一归属的后台请求单列，不借用活动页身份 |
| ws/wss | 新握手遵守相同路由；既有消息不自动重放 |
| prerender/BFCache | 不把隐藏页面加入前台批次；激活/恢复时重新核对 token 和策略版本 |
| HTTP(S) 下载 | 新请求保留可证明的来源策略；已有下载不自动重启 |
| WebRTC/WebTransport/其他 UDP | 不宣称 HTTP/SOCKS 已覆盖；已要求代理的上下文不静默旁路直连，未实现时明确受限 |

匹配先确认所属上下文和有效快照，再按以下固定顺序决策：不可覆盖安全/管理限制 → 本站规则 → Profile 范围规则 → 默认 DIRECT。各作用域内部：精确 host 优先于显式后缀；多个后缀取最长 DNS 标签匹配；同 host 条件下精确 scheme/port 组合优先于覆盖更多组合的规则。后缀和顶层网站边界使用公有及私有后缀表，不能以字符串后缀替代 DNS 标签匹配。

同一规范化规则键只允许一条当前版本；编辑器将 scheme/port 集合规范化并拒绝同等级有重叠且结果冲突的新增规则，必须显式替换冲突行。损坏数据导致无法唯一决策时返回 policy_conflict 并拒绝该请求，不随机选择或退回 DIRECT。不同作用域的手动 REJECT 不是永久凌驾所有具体规则：针对目标明确 ALLOW 可在本站建立更具体的 PROXY 例外；管理限制仍不可覆盖，UI 展示实际命中的规则与来源。

三策略执行合同：REJECT 在浏览器原生加载入口本地终止，不向代理内核发送该请求；DIRECT 经过正常防护后直连；PROXY 在其有限防护例外范围内放行，再经已确认代理路径发送。DIRECT 不等于关闭防护。运行时断网、代理故障、额度耗尽、退出身份不改写 mode；保持 PROXY 并返回明确的等待/失败原因，不能改成用户 REJECT 或自动 DIRECT。

缺失或 opaque 的归属不授予本站防护例外；只有明确适用的 Profile 全局路由可以匹配。已带 REQUIRE_PROXY 意图却无可用快照时等待或失败；新 NetworkContext 在规则恢复前不能发出可能受该意图约束的请求。

命中 PROXY 后，HTTP/HTTPS/ws/wss 及所有支持的方法都必须按代理路由首次发送；命中 REJECT 的请求不能发出首次连接。禁止自动重放已发送的非幂等业务，与首次路由正确性分别验收。HTTP/SOCKS 的代理失败列表中不追加 DIRECT 作为该类请求的 fallback。

DNS 预取、preconnect、连接池、代理重试缓存、Alt-Svc 和 QUIC 必须纳入验证。改规则后的新请求不能复用旧直连连接；节点切换后的新请求不能复用旧入口。目标域名交给代理解析，代理本身的 bootstrap/DNS 走独立可信配置；不能仅据此宣称整个浏览器所有 DNS/UDP 都已代理。

**6. 一键操作、版本发布、撤销与恢复**

PageAccessCollector 独立于展示事件表。初始上限为每文档 2,048 个候选 host、每 Profile 收集器 8 MiB；超限保留 droppedCount 和 coverage=limited。必须另设入口消息队列字节/条数上限与背压，不能只限制最终集合。

BLOCK 目标列表还包含当前文档已观察的正常 HTTP(S)/ws(s) 目标；与失败候选共享有界的精确目标清单和上述总内存预算，不重复建立无上限的全量请求历史。仅保留 host/scheme/port、归属、计数与当前策略。RequestOwnershipRegistry 另外跟踪在途请求的终止句柄，其容量纳入第 13 节的并发和内存合同；达到上限时对新的受控请求有界排队或明确拒绝，不能发出无法归属和终止的请求。

**动作、目标与规则转换：底层与 DEV/Alpha 调试定义**

以下 ALLOW/BLOCK、目标选择、SET_MODE、删除及撤销描述底层执行器和 DEV/Alpha 调试视图，不是 Beta/Release 的可见入口。Beta/Release 只调用第 9 节受限的网站开关接口；后台使用同一协调器、版本检查、路由准备和恢复机制。开启网站代理不调用带防护例外的 ALLOW，关闭不调用 BLOCK。安全防护原有拒绝逻辑仍独立生效。

| 操作 | 固定目标与效果 |
|---|---|
| 工具栏/当前页“允许本页 N 个目标 · ALLOW” | 本页固定快照中可处理的失败目标，逐项建立本站精确 PROXY + 所需有限防护例外；跳过有效手动 REJECT 与不可覆盖限制，显示跳过数量和来源 |
| 目标行“允许此目标 · ALLOW” | 对明确指向的 host/scheme/port 建立或替换本站精确 PROXY，可解除同范围手动 REJECT，或形成对较宽用户规则的本站例外；不能覆盖管理限制 |
| “阻止所选 M 个目标 · BLOCK”或目标行 BLOCK | 仅对明确选择的精确目标建立 REJECT 并撤除本功能例外；包含主导航目标时会阻止该目标的后续主导航；不扩大到所有子域、端口或其他顶层网站 |
| 规则详情设为 DIRECT | 本地提交 DIRECT，清除本条 ALLOW 创建的例外；正常防护继续工作。恢复直连是明确的用户编辑，不是代理失败的自动降级 |
| 规则详情设为 PROXY | 选择代理路径，不自动新增防护例外；由 DIRECT/REJECT 进入时例外为空，需要 ALLOW 才解除相应防护；已为 PROXY 的同值保存不改动现有例外 |
| 规则详情设为 REJECT | 与 BLOCK 使用同一事务和终止流程，标记为手动阻断 |
| 撤销 | 恢复该操作前仍归该操作所有的差异；不覆盖较新编辑，恢复 PROXY 时重新验证代理可用性 |
| 删除规则 / 到期 | 移除本地覆盖后重新解析继承结果；继承 PROXY 必须先准备路由，不能先退为 DIRECT |

BLOCK 默认不勾选任何目标；无选择时按钮禁用，提供明确的目标列表入口。工具栏的次要操作为“选择目标并阻止 · BLOCK”，打开绑定本次 pageToken 的列表；已打开列表时直接执行所选 BLOCK。V1.0 不把“阻止所选目标”标成“整站阻断”，也不提供含义不明的全局 REJECT 按钮；扩大到后缀或 Profile 作用域只能通过明确的规则详情编辑，并展示受影响范围。按本站范围的主导航阻断以目标导航的 SchemefulSite 解析，不能继承上一页的顶层站点。

批量 ALLOW 的跳过依据是固定快照与提交前复核中的有效用户 REJECT；在这两次检查间新增的 BLOCK 同样受保护。跳过手动阻断属于“已保留的用户选择”，不能写成连接失败或偷偷放行。用户逐项 ALLOW 时已经明确指定目标，不再增加第二次允许确认。

同一规则的六种转换均有固定行为：DIRECT→PROXY 准备后提交，PROXY→DIRECT 先撤回例外再切换新请求路径，DIRECT/PROXY→REJECT 走本地 BLOCK，REJECT→PROXY 在代理就绪前保留旧拒绝，REJECT→DIRECT 经本地版本发布后恢复正常防护下的直连。DIRECT↔PROXY 只改变提交后的新请求；已发送业务按原路径完成或原有连接截止处理，不迁移、不重放。任何进入 REJECT 的操作必须执行在途终止。

各操作在 Profile 的 RuleMutationCoordinator 接收时取得单调 operationSequence。提交检查目标 rowRevision；同键操作按已接收顺序串行，后来的 BLOCK 会安装目标拒绝屏障并使更早、覆盖该目标的待提交 ALLOW 失效。旧 ACK、探测、身份回复和重试不得绕过版本检查。其他不相交目标可继续，批次如受影响则报告实际已完成/已跳过/已取消差异；不能把一个目标的 BLOCK 扩成全 Profile 断网。

一次点击固定初始快照，可启动最多 2 轮、共 15 秒、累计最多 256 个新域名的补充发现。只接受修复会话内同一顶层网站的后续文档；用户导航、关闭页面或切 Profile 立即停止扩张。跨注册域登录跳转不自动继承该批次。

~~~text
OBSERVING → SNAPSHOT_READY → VALIDATING/PREPARING
  → ROUTE_PREPARED → OVERRIDES_ACTIVE → RELOADING → VERIFYING
  → APPLIED / PARTIAL / FAILED / CANCELLED
~~~

1. 从真实操作的 WebContents 获取 Profile、文档/导航 token，固定候选集合和范围。默认保存为本站持久规则，可显式选择本次会话。
2. 校验候选、pageToken、代理组归属和当前 identityGeneration，复核并跳过有效手动 REJECT，生成 batchId/幂等键；重复点击同一快照返回已有批次。目标行明确 ALLOW 按上表处理被指向的拒绝，不套用批量跳过规则。
3. 写 PREPARED 差异与目标 policyGeneration=G+1；此前 G 继续负责已有状态。
4. 自动取得有效权益、配置、租约和可用内核；失败或超时保留旧规则，不要求节点配置。准备后再次确认源文档有效。
5. 发布 G+1、selectionGeneration=S、networkEpoch=E 的联合快照并等 NetworkContext 确认。此时原拦截仍可生效，不允许“已放行但仍直连”。
6. 再激活 G+1 的可覆盖防护例外，最后解除同范围旧 REJECT/临时拒绝屏障；各执行点版本不一致则等待/失败。准备期间切节点、换网络或身份变化必须重新绑定版本；后续 BLOCK 已使该操作失效时不得解除拒绝。
7. 持久化 ACTIVE，显示规则已生效；新建上下文必须先装入有效版本。
8. 受控刷新并观察结果；POST/购买/表单、既有下载、WebSocket 消息不自动重放，需重提交时沿用浏览器原有处理。
9. 有界补充发现中的每轮继续走同样的验证与发布流程，报告已生效、已存在、保留手动阻断、未解决和覆盖状态；不得借补充轮绕过手动 BLOCK。

联合规则保持语义完整：一键生成的防护例外与代理路由属于同一事务。切换 DIRECT 或 REJECT 时必须撤回该条 ALLOW 创建的例外，不提供遗漏清理的“只删 proxy”实现。V1.0 的 ALLOW 固定为允许并代理，不提供另一种隐式“允许并直连”的 ALLOW。现有独立“暂停本站防护”不隐式改变路线，也不覆盖用户 REJECT 或管理限制。

撤销使用 beforeImages 和 rowRevision 比较，仅撤销仍归该操作所有的差异。恢复目标为 DIRECT 时先撤回本操作例外再发布直连；恢复 REJECT 时走 BLOCK；恢复 PROXY 时先准备并确认路由，再恢复例外并解除当前拒绝。代理不可用时保留当前安全策略并显示“暂无法恢复此前代理规则”，不把撤销简化成 DIRECT。删除/到期暴露继承规则时采用相同的目标策略准备流程；单纯到期本身不重放网页请求。后续手动编辑及其他批次保持。

取消只停止当前等待者和后续发现，不取消其他标签页共用的代理恢复。取消已安装屏障的 BLOCK 不等于解除阻断；界面保留真实部分状态及撤销入口，只有经版本化撤销才能解除。规则会话结束或已设时间到期按公开时效合同结束覆盖，不与代理服务故障混用。

**BLOCK 发布与在途终止：冻结定义**

BLOCK 仅依赖本地 Profile 授权，不等待 bootstrap、节点、账户额度或身份登录。identityGeneration 只用于诊断；对 PROXY 准备的身份检查不能成为拒绝本地 BLOCK 的原因。

1. 验证 browser-owned pageToken、所选目标及作用域，取得 operationSequence，并在浏览器派发入口安装这些目标的临时拒绝屏障；相交的旧 ALLOW 停止提交。
2. 事务写入 BLOCK_PREPARED、目标 REJECT、空防护例外和恢复差异。无法持久化时仍继续第 3/4 步发布内存拒绝快照并终止在途请求；只有它们均确认后才显示“临时已阻止，保存失败”，提供重试保存/撤销，不报持久成功。若发布或终止也未完成，则显示“阻止未完全确认”，不能只装浏览器入口屏障就声称所有在途请求已停止。
3. 发布新 policyGeneration 到所有相关执行点，同时阻止新的加载、DNS 预取、preconnect 及新建派生请求；新建上下文先装新快照再派发。保留不可覆盖安全限制。
4. 通过 RequestOwnershipRegistry 取消命中的在途 URLLoader/导航、上传/下载、媒体、SSE 和 ws/wss。HTTP/2、HTTP/3 等共享传输按请求/流终止，不因为一个目标被 BLOCK 关闭其他网站的全部共享连接。无法唯一归属的后台请求单列为不在当前页范围内，不借用活动页身份取消。
5. 所有必需上下文确认新版本、命中在途操作完成本地终止并且事务持久提交后，才显示“已阻止”。记录提交点及哪些请求已终止；已发送/已接收或已进入系统缓冲区的字节无法追回，不承诺远端同一时刻撤回数据。

本地新派发屏障在接收操作的同一协调任务内安装，不等待磁盘或远端服务。运行中的相关执行点以发布时刻为起点，2 秒内必须确认拒绝并停止新增业务提交；目标在途操作在同一 2 秒预算内完成本地取消。操作总预算为 5 秒，包含持久化和确认。超时或任一步失败时保持已安装屏障，未确认执行点停止受影响派发，显示“阻止未完全确认/保存失败”并列出范围；不得按全部成功计数，不能通过恢复旧 ALLOW 或切 DIRECT 解除屏障。P0 若无法在不误伤其他网站的情况下做到定向隔离，则该能力验收失败，不能以关闭整个 Network Service 冒充合格实现。

原生加载检查覆盖正常网络、HTTP 内存/磁盘缓存、受控 Service Worker 响应以及 BFCache/prerender 激活前的重新校验；不能只在代理连接时检查 REJECT。已经交付页面的正文、脚本和图片不自动抹除，也不删除已完成下载；页面使用已有数据的计算不是新网络加载。BFCached 页面激活时若主导航目标已被 REJECT，显示浏览器阻断页；其他子资源拒绝按新加载及在途规则处理。无法可靠关联的共享 Worker 后台请求不算当前页的已阻断覆盖。

顶层目标被拒绝后，显示原生 Aegis 阻断页。DEV/Alpha 调试视图说明目标、Profile、规则来源与范围，提供“允许此目标并使用代理 · ALLOW”、规则详情及有权撤销的最近操作；离线时 BLOCK/规则查看/本地 DIRECT 编辑仍可用，ALLOW 准备失败保留 REJECT。Beta/Release 仅显示面向用户的防护/管理限制原因和既有安全恢复入口，不出现 ALLOW/BLOCK、策略编辑器或技术枚举，不借代理开关解除安全拦截。所有入口属于浏览器可信 UI，不依赖先访问被拒绝网站。

| 失败位置 | 必须行为 |
|---|---|
| 准备配置或路由发布失败 | 不激活新防护例外；批次可诊断失败 |
| 路由已就绪、防护未就绪 | 允许暂时多拦；恢复时重放或撤销事务，不扩大直连 |
| 内核/Network Service 退出 | 已要求代理的请求等待或失败；恢复策略后才继续 |
| 数据库损坏/写满 | 使用可验证的有效快照或失败关闭，不把读取失败当空规则 |
| 存在未完成 pendingSwitch/批次 | 按已记录阶段与版本恢复，未提交的动作不报成功 |
| 用户取消/页面已导航 | 不继续扩张授权，报告实际已生效部分及撤销入口 |

APPLIED 只代表本批观察范围内的规则与验证通过，PARTIAL 必须列出未解决原因。真实页面是否完全恢复、所有未来请求是否成功，不由一个绿色连接状态替代。

**7. 本地内核、后台接入与节点切换**

固定 Xray 版本、源提交/资产 SHA-256、平台架构及打包来源，随浏览器产物登记。只运行浏览器持有的可信资产，不从网页提供的地址下载或执行内核。每个活跃 Profile 一份稳定实例，静态资源可共享，秘密和运行状态不共享。

HTTP 入口默认启用随机的 Profile 会话凭据，只绑定 loopback；浏览器只向已登记代理地址提供认证。控制接口使用私有 IPC。端口动态分配并验证，不强占固定端口、不停止用户已有代理进程。SOCKS5 需在固定 Chromium 中完成 Profile 认证适配，不能只配置 Xray 用户密码就视为浏览器可用。[Chromium SOCKS5 说明](https://chromium.googlesource.com/chromium/src/+/HEAD/net/docs/proxy.md)

内核 STOPPED → STARTING → READY → DEGRADED/RESTARTING → READY/FAILED；READY 必须包含远端链路验证，不能只检查本机监听端口。无代理使用、准备或验证需求时不启动内核；已空闲实例按 PF08 在 60 秒内回收，持有规则本身不构成保活理由。临时候选、旧实例排空也受资源上限约束；不可用热更新时先独立准备替换实例，不能为测速重启承载业务的实例。

首次准备按需触发：复用有效缓存 → 必要时访问专用 HTTPS bootstrap → 自动获取身份和签名目录/租约 → 验签及协议校验 → 验证候选 → 发布绑定 → 恢复原批次。初始总预算 15 秒，最多 5 个不同候选、并发最多 2；等待浏览器级资源槽也计入预算。没有有效缓存且所有 bootstrap 不可达时明确失败。

控制面不套用网页 allow 规则，不递归依赖尚未启动的代理，不接收页面指定的任意 URL。可缓存仍有效且未获知撤销的配置；到期或已撤销必须停止新连接，既有连接不超过租约 connectionDeadline。服务端同样执行撤销，不能只依赖离线客户端接收通知。

控制面负责签名的部署关系和准入，浏览器负责本网络实际可达性。区分 endpointId、deploymentId、capacityGroupId、trafficPoolId 和故障域：同 VPS 的五个域名是入口变体；共享月流量池也不一定等于共享速率瓶颈。未知关系明确标记，不推断独立容量或出口。

初次分配按 principalId+groupId 生成稳定顺序，先过滤签名策略允许的出站类别，再按容量组与入口；多个实际容量组采用固定版本的加权 rendezvous 排序，单组退化为组内顺序。散列输入、权重、同分规则和序列化固定并有向量。维护、撤销、到期、冷却和准入不足的候选被排除；权重不代替硬容量限制。已健康绑定不因权重、订阅顺序或延迟轻微变化迁移。

| 项目 | 初始运行预算 |
|---|---|
| 活跃健康复核 | 距有效成功约 60 秒，±20% 抖动；成功业务流量可替代重复探测 |
| 闲置/离线 | 停止常规扫描，实际需要时验证 |
| suspect 复核 | 两轮，共最多约 6 秒，必要时使用独立验证目标 |
| 单候选验证 | 最多 4 秒，受本次总预算限制 |
| 故障确认后的切换 | 最多 15 秒、5 个不同候选、Profile 并发最多 2 |
| 浏览器级额外候选 | 同时最多 2 个验证/替换资源槽，跨 Profile 公平排队；排空仍占槽直到回收 |
| 候选冷却 | 从 30 秒指数退避到最多 10 分钟，带抖动；配置错误需新配置才能恢复 |
| 重新准入 | 两次成功复核后回候选池，不抢占当前健康绑定 |

各 group 只有一个恢复任务，反复重试不能绕过预算或冷却。网站 403/429/5xx、CSP/CORS、证书错误、验证目标自身故障不直接使节点失效；本机断网先等待、本地内核退出先本地恢复。账户耗尽属于权益失败；节点满载属于准入失败，不引发对所有别名的测速风暴。

切换 B 的顺序：准备并验证 B 的配置/租约/容量 → 暂停该组新 REQUIRE_PROXY 派发 → 发布 G/S/E 新快照 → 全部相关上下文确认 → 持久化提交绑定 → 恢复新请求到 B → 旧连接按截止排空。新上下文先取版本再出站。失败时仅可保留仍健康且版本完整的 A，否则失败关闭；已发业务不复制到 B。

入口保持只承诺入口绑定稳定；只有服务端提供且验证过出口亲和性时，才能承诺公网出口保持。原节点恢复不自动回切。切换前后使用同一账户账本，旧额度预留不能因切换立即重复发放。

DEV/Alpha 可选 dev_subscription 或 managed_test，来源不能暗中互相回退。订阅只解析支持的节点字段，不导入全局路由、DNS、allow/block 或完整上游策略组；未知格式显示不支持。DEV/Alpha 手动固定失败时保持并报错，返回自动模式才重新进入正常选择状态机。

主协议与兼容协议严格校验字段和组合，不接受 allowInsecure 等关闭验证参数。EdgeTunnel 管理页仅提供交互及兼容参考，不证明 REALITY、每账户额度或独立五节点能力。[VLESS](https://xtls.github.io/en/config/outbounds/vless.html)、[REALITY](https://xtls.github.io/en/config/transports/reality.html)、[指定界面参考](https://edt-pages.github.io/admin/)

**出站选型与抗识别边界**

V1.0 保留 VLESS + RAW + REALITY + Vision 主出站，WS+TLS 只承担已声明的兼容需求，不视为等价抗 DPI 备用。托管代理组的签名策略新增 allowedEgressProfiles；默认仅 reality_vision，只有服务运营明确配置 ws_tls_compat 且该环境独立验证后才可跨协议切换。未知类别拒绝；普通 UI 无协议选择器，已有 DEV/Alpha 来源控制仍适用。无获准兼容候选时按失败关闭处理，不能因连通性失败暗中降低协议要求。未来 XHTTP 仅作独立 P0 比较，不自动替换本期必需兼容矩阵。

每个实际出站需绑定 Xray/uTLS 版本、flow、transport/security、target/serverName、握手/ALPN、部署地址和测试网络。REALITY 目标按上游 TLS 1.3/H2、非纯跳转目标等要求核验，不能用任意热门域名代替部署证据。测试区分被动分类、对自有节点的未认证探测响应、IP/SNI 封锁与纯连通性；被动特征较少不意味着 IP 不会被封。仅能对指定配置、网络及时间窗口报告观察结果，不能声明“无法检测/保证抗 DPI”。完整依据与判断见[出站协议与 DPI 评估](egress-dpi-assessment.zh-CN.md)，A117 在 G1 按主协议子场景执行、G2 按完整矩阵执行。

**8. 服务端计量、流量额度与固定 VPS 容量**

服务端是用量权威来源。每个 Profile 获得可映射到已授权账户的独立凭据；不能向所有用户分发同一静态 UUID 后再声称能分别计量。Xray 提供用户上下行字节统计；具体计数边界、持久化、余额和耗尽执行仍由本项目适配并验证。[Xray Statistics](https://xtls.github.io/en/config/stats.html)

计量版本定义为代理解封装后目标连接的双向转发字节，包含目标 TLS 数据，不含外层代理封装、专用控制面及独立运维探测。真实请求和重试产生的字节计入；直连和本地缓存命中不计。计量不等于业务成功，远端中断时已计量的传输仍可产生用量。固定内核的计数点若与该合同不同，必须适配或修订明确的 accountingVersion 并重新验收，不能仅凭页面资源大小对账。

节点上报包含 nodeId、counterSessionId、主体、periodId、单调序号及累计值。账本幂等处理重复/乱序记录；重启产生新的计量会话，不因计数器归零回滚账户累计。节点退出、故障切换和跨周期仍需保留可恢复计量证据；批量提交不等于可以丢弃未结算流量。

Vision 与计量快路径必须联合验证。上游说明某些 Linux splice 路径可能在连接结束时才反映统计；不能据此假定本项目每秒 Stats API 已覆盖所有在途字节。P0/P3c 在固定内核与实际服务端适用快路径上验证长连接实时计量、账户预算和耗尽终止（A118）。在证明之前，保留 Vision 协议语义，使用可逐块计量/执行预算的转发路径，不启用未经验证的 splice 优化；若固定内核不能选择或适配该路径则门槛 BLOCKED，不臆造禁用参数、不移除 Vision 来冒充通过。后续启用快路径需同步证明内核级计数和额度执行，并重新测 PF03/PF04/PF09。[上游 VLESS/Vision 与 splice 说明](https://xtls.github.io/en/config/outbounds/vless.html)

有限额度采用账户中心余额预留 + 节点有界字节租约：已结算字节与未结算预留不能超过可授权余额。节点在传输路径执行预算，耗尽、到期或不能续领即停止；不等 UI 更新。租约具有唯一 ID、周期、到期和最终结算状态。节点失联时旧预留不能直接再次发放；必须完成结算或可验证的失效回收。传输块及在途字节的误差上限须实测并绑定，不能未经证明承诺零超额。

quotaMode 必须显式为 limited/unlimited/unknown。limited 要有非负 quotaBytes；unknown 不是无限。查询用量失败不自动撤销仍有效的服务授权，也不绕过节点额度限制。重置以服务端 periodId 为准；旧周期数据不覆盖新周期。额度恢复后保留原网站规则，无需重新导入或再次授权相同规则。

VPS 总账与个人用量分开：供应商可能统计出站或双向流量，还可能包含封装、重传、测试、控制面及其他进程。不得把网卡 RX+TX 直接解释为个人用量，也不得把 VPS 总剩余复制给每个用户。多个入口或渠道共用同一容量/流量池时，物理总额只计一次，测试流量虽独立分账仍占真实资源。

**固定带宽的执行合同**

| 层级 | 必须执行的限制 |
|---|---|
| 物理 VPS/速率资源池 | 按真实受限方向设置总速率、突发预算、连接/队列上限；包含共享该资源的全部服务流量 |
| 测试与正式租户 | 独立统计、权限与预算；在物理总限额之下分配，为控制面及必要运维保留容量 |
| 服务账户 | 同一账户跨 Profile/设备/连接共享速率上限与公平份额；不能靠多开连接扩大配额 |
| 节点准入 | 同时校验有效授权、可用带宽/连接容量及流量余额；满载返回可诊断状态 |
| 故障切换 | 备用需重新满足容量准入；旧预留、旧速率租约及突发余额有界回收，不能双份消费 |

单 VPS 首阶段可在单一服务端执行点按账户集中限制；多 VPS 同时服务同账户时，分配带 epoch/到期的 RateLease，各有效租约的 rate/burst 合计不得超过账户政策，不能逐包访问中心账本。过期或中心失联时只能使用仍有效的预算；续领失败按明确策略停止或降至已授权额度，不自行解除限制。

账号限速必须基于服务端鉴权映射，不能从用户可改的请求头、页面账号或共享出口 IP 推断。可以采用 Linux tc 总整形配合鉴权后的账户限速器；账号到连接/流的映射与双向计数由代理适配层负责，tc 不会自动解析加密连接中的产品身份。[tc 分类与整形](https://man7.org/linux/man-pages/man8/tc.8.html)

容量参数见第 13 节，缺失时禁止对外开放生产准入。每账户 GB 额度不是 Mbps 限速的替代。初始分配按容量权重分散主体，运行时通过服务端限速/公平分配约束热点；健康会话不因瞬时负载变化来回迁移。

**9. 网站代理开关、DEV/Alpha 调试与快速同步**

Beta/Release 管理页沿用指定参考的卡片顺序：本期流量 → 网络状态 → 当前网站代理开关。工具栏气泡复用同一个开关、当前域名与简短状态；没有“规则策略”“操作”选择、请求目标清单、ALLOW/BLOCK、订阅或节点操作。账号和用量仍正常显示，必要错误用日常语言说明。直接打开管理页而没有 pageToken 时，显示“请先打开需要设置的网站”，禁用当前网站开关，不猜测活动标签页替用户授权。若列出已保存网站，每行也仅展示域名、使用代理开关和状态。

~~~text
本期流量                          当前账户 / 安装访客
代理流量 · 上传 + 下载
[已用进度条，仅在明确有额度时显示]
已用流量          剩余流量          本期流量额度
上传 … MB/GB/TB   下载 … MB/GB/TB
下次重置：日期 HH:mm    最近同步：日期 HH:mm:ss

当前网站：news.example
当前网站使用代理                  [关 / 开]
连接状态：未使用代理 / 正在连接 / 已使用代理 / 暂时不可用
~~~

**网站开关的行为合同（所有渠道的简洁界面）**

- 域名由 browser-owned pageToken 的当前主导航确定；失败导航可以使用其可信目标。选择键固定为本渠道、本 Profile、本 StoragePartition 和规范化精确 host，不把协议、端口或路径作为不同的网站选择。IDNA、大小写、尾点及 IP 字面量按第 5 节统一规范化；不扩展到子域、相似后缀、第三方 CDN 或其他域名。
- 同域覆盖固定为 HTTP、HTTPS、WS、WSS 及浏览器本来允许访问的端口，包括非默认端口；浏览器禁止端口、证书校验、混合内容和其他安全限制仍照常执行。开启 https://news.example 后，同域 wss://news.example、https://news.example:8443 等受支持请求使用同一代理选择；http://news.example 跳转到 https://news.example 不丢失选择。已提交选择适用于之后的同域导航，不因页面 token 更新而清除；token 更新仍使尚未提交的旧操作失效。
- 底层按当前主导航 host 所属站点生成 HTTP 和 HTTPS 两个顶层 SchemefulSite 成员，成员目标均为该精确 host、schemes={http,https,ws,wss}、ports=所有浏览器允许端口；成员共享 siteToggleId 和版本。仅在路由作用域匹配时将 ws/wss 对应到 http/https 的站点族，不改变浏览器实际 origin 或安全隔离。拥有可信同族归属的同域子资源、iframe、Worker 和 WebSocket 均在组内；其他顶层站点对该域名的引用不自动继承本组，无可靠归属的后台请求沿用第 5 节限制。前端只显示域名及一个开关，HTTP→HTTPS 同域跳转读取同一组。
- 协议组的所有成员通过同一事务、协调器和 policyGeneration 一起准备、提交、撤销与恢复，不逐协议报告成功。成员缺失、版本不同或模式混杂时显示“设置暂不可用”，不能把已有代理组当作关闭或允许缺失成员直连；恢复失败按第 5/6 节处理。组内 mode 仅可为 DIRECT/PROXY，protectionOverride 恒为空；调试不得只改组内一条记录，也不得把单目标 ALLOW/BLOCK 写入该组。调试目标行指向独立的 topLevelSite+host+scheme/port，删除该行后重新求继承，不删除协议组。
- 独立调试规则按第 5 节优先级解析。其 REJECT 或与组不同的 DIRECT/PROXY 不改写组选择；已提交开关仍反映组的共同 mode，并返回 restriction=independent_rule 和用户可读说明，不能把受限范围显示成已全部代理/全部恢复。关闭只将整个组改为 DIRECT，保留更具体的独立 PROXY/REJECT；该范围仍按独立规则执行并明确显示受限。开启亦不解除独立防护例外或 REJECT。准备失败保留旧组；与独立规则冲突本身不损坏组，也不把 enabled 设为 unknown。更具体规则和协议组使用不同所有权、修订号与撤销记录；限制不禁用已开启组的本地关闭。
- 从未创建协议组时，按整个同域覆盖范围的继承结果显示状态：默认均为 DIRECT 才显示关闭，均为 PROXY 可显示开启，混合/受限结果明确说明并禁止冒充全组生效。必须用持久组元数据区分“从未创建”与“已有组但成员损坏”；不能把恢复错误解释为默认直连。
- 开启执行受限的 SET_SITE_PROXY(true)：仅准备并保存上述范围的 PROXY 路由，protectionOverride 为空，默认持久保存；不触发批量 ALLOW、不进行补充放行发现，也不要求用户选择规则、节点或时效。准备期间明确显示“正在连接”，不能宣称已生效；失败保留原已提交选择并显示“未能开启代理”。原来已开启时发生断网、额度耗尽或退出身份，开关保持开启，连接状态显示不可用，后续受约束请求等待/失败，不能静默直连。
- 关闭执行 SET_SITE_PROXY(false)：对同一协议组的全部成员本地发布显式 DIRECT，清除该功能拥有的代理例外/引用；即使底层存在较宽 PROXY，也不能因简单删除而再次继承代理。正常安全防护和不可覆盖的管理限制继续执行；关闭不是 REJECT，也不是解除防护。无网络、无可用节点、额度耗尽或退出身份时，仍可关闭。明确成功只在本地有效版本确认后显示；保存失败说明未保存，不能冒充重启后仍有效。
- 开关与连接状态分开；屏幕阅读器的开关状态反映已提交选择，准备阶段用 busy 与文字说明目标动作。准备时仍可取消开启；后续关闭/取消提升操作版本，使旧准备、ACK、探测和重试不能再次开启。不同标签页共享同一 Profile 的已提交状态。已发送的业务按既有路径完成/截止，不迁移或重放；开关改变后新请求不得复用错误路径。
- 开启和关闭均不改变既有安全防护的允许/阻止状态。若已有手动 REJECT 或不可覆盖管理策略使选择无法生效，不隐式解除它，显示“受防护或管理设置限制”；DEV/Alpha 可在独立调试入口明确处理。不得把技术失败显示成用户主动阻止。

DEV/Alpha 的“调试”视图可以显示三策略、批量/单目标 ALLOW、BLOCK、目标清单、规则来源/时效、撤销、请求覆盖、节点/订阅和脱敏日志，并沿用第 6 节完整操作合同。调试 ALLOW 可以建立限定防护例外；这不改变简洁网站开关只选择代理的语义。Alpha 同样可以切回简洁界面验收最终用户流程；选择视图不改变渠道授权。

数据以整数 byte 保存；MB=10^6 byte，GB=10^9 byte，TB=10^12 byte，MiB/GiB/TiB 来源先规范化后展示。卡片、上传/下载分项和气泡统一使用 MB/GB/TB，最小显示单位为 MB，不降为 KB/B；按 1,000 MB=1 GB、1,000 GB=1 TB 自动切换，各字段独立选择单位。常规数值最多保留两位小数并去掉末尾零，显示舍入达到 1,000 时进位到下一单位；真实零显示 0 MB，非零且小于 0.01 MB 显示“<0.01 MB”，不冒充零。单位和显示精度不改变后台计量精度。

used=uploaded+downloaded；有限额度 remaining=max(0,quota-used)，比例用原始字节计算后格式化，不能对已经舍入的 MB/GB 数值再次计算余额或扣费。进度条最多填满 100%，不截断真实超额字节；额度 0 显示未分配流量，不除零。

两位 MB 小数对应 10,000 byte 显示分辨率；每秒新快照的真实增量较小时，显示数字可保持不变。同步验收检查实际字节、来源水位及 measuredAt，不要求动画跳数。各分项独立选择单位与舍入后的显示值可能有舍入差，原始字节必须严格对账。BLOCK 后在途字节的迟到结算可以增加已用流量，必须能由记录解释，不能直接视作又发出了被拒绝的新请求。

| 用量状态 | 显示规则 |
|---|---|
| 有明确额度 | 已用、剩余、总额及比例，上传/下载分项、重置/到期、同步时间 |
| 明确未设额度 | 已用、上传、下载及统计周期；无剩余、进度条或额度重置倒计时 |
| 额度未知 | 已测量用量可以保留，额度字段暂不可用，不伪造比例或无限 |
| 暂无统计 | 暂未同步；不使用 0 冒充实际用量 |
| 旧数据/部分来源 | 保留已知累计与时间，标注延迟或覆盖不足 |
| 额度耗尽 | 真实已用、0 剩余和恢复/重置信息；规则保留 |

最近同步显示到秒：同年 MM-DD HH:mm:ss，跨年加年份；来源为当前接受快照的 measuredAt，不使用界面重绘时间。相对提示如显示则用“3 秒前”，不只写“刚刚”。重置使用日期+HH:mm；倒计时到分钟，不足一分钟为“不到 1 分钟”。本地倒计时归零不自行增加额度，等服务端确认新周期。所有示例数字/时间必须标示例，不冒充真实 VPS 数据。

| 场景 | 同步频率与行为 |
|---|---|
| 打开卡片/气泡、切账户、返回可见界面 | 立即获取完整快照并订阅；已有旧值保留真实时间 |
| 可见且账户有传输 | 约每 1 秒一次合并更新，同帧更新全部字段 |
| 可见但无传输 | 变化时推送，最迟约 5 秒确认来源新鲜度 |
| 不可见 | 关闭仅供显示的秒级订阅；服务端计量和重要权益通知继续 |
| 耗尽/撤销/重置/额度调整 | 高优先级通知，不等常规周期；节点执行独立进行 |
| 推送不可用 | 可见活跃时约 2 秒查询，空闲约 5 秒；最多一个在途请求，故障/限流退避 |

Profile 内所有气泡和管理页共享一个授权订阅与快照；跨 Profile 保持独立授权。服务端每秒批量采集活跃主体并更新可恢复的账户汇总，订阅读取同一聚合视图，不为每个客户端单独启动统计命令或扫描账本。每秒同步是用量更新，不能变成每秒对所有候选测速。

来源覆盖完整且有真实新测量才更新 measuredAt。心跳成功不证明统计新鲜；活跃测量年龄超过 5 秒或来源不完整显示“同步延迟”，超过 15 秒仍未恢复显示“暂未同步”，保留旧值。snapshotAgeMs 使用服务端来源水位和接收后单调时钟累计，UTC 仅用于时间显示。重连先取完整快照，按账户/periodId/revision 去重；本机速度积分或动画不能覆盖权威账户累计。

DEV/Alpha 另有订阅卡、自动保持/手动固定、候选状态、来源/版本和脱敏日志；支持简单/高级视图与分区保存/取消。无修改时保存禁用，切视图不丢草稿，只有校验成功才更新运行配置。Beta/Release 不注册可从 WebUI/外部调用这些调试能力的接口和入口；共享底层匹配器与执行器仍保留，不以 CSS 隐藏作为渠道隔离。

冻结的 UI 合同如下；接口名为实施时应提供的逻辑能力，可调整语言命名，不得省略参数校验和结果语义。

| 接口 | 输入与必须输出 |
|---|---|
| GetSiteProxyState / SetSiteProxy / CancelSiteProxyChange（所有渠道） | 仅接收可信 pageToken 或本 Profile 已保存的网站引用、enabled、expectedRevision 和幂等 operationId；由原生端生成第 9 节完整同域协议组，返回已提交 enabled、pending、connectionState、durable、restriction(none/independent_rule/managed/protection) 及用户可读失败原因；组无完整有效状态时 enabled 为 unknown 并说明原因，不冒充关闭；独立规则限制不覆盖组选择，Beta/Release 不返回调试行详情；不接受任意 mode、目标列表、scheme/port、protectionOverride、proxyGroupId 或节点配置 |
| GetPageAccessSummary / GetPageTargets（DEV/Alpha 调试） | browser-owned pageToken；返回有界目标集合、scope、规则版本、mode/来源、可处理与手动拒绝计数、coverage |
| PrepareRuleMutation | kind、目标引用、expectedRevisions、幂等 operationId；返回差异、精确范围、跳过原因和准备状态；批量 ALLOW 不要求第二次用户确认 |
| CommitRuleMutation | 已核验 operationId；经同一个协调器执行 ALLOW/BLOCK/SET_MODE/DELETE，返回 policyGeneration、durable、确认/终止状态和每项目结果 |
| CancelRuleMutation / UndoRuleMutation | 绑定本 Profile 的 operationId 和期望版本；返回已完成部分、实际撤销差异及保留的较新编辑，不隐式解除安全屏障 |
| ListAccessRules / ExplainPolicy | 只读本 Profile；返回规则、有效策略、命中来源、继承/显式覆盖及期限；可在无目标页时管理已保存规则 |
| GetAccessServiceState / RetryAccessService | 返回与 mode 独立的运行状态；重试不修改 REJECT，不绕过预算/冷却 |
| GetEntitlementAndUsage | 当前已绑定身份的快照与真实时间；不得由 WebUI 任意指定其他账户 |
| BindServiceIdentity / SignOutServiceIdentity / ContinueAsGuest | 执行第 4 节的暂存验证、身份代次切换、凭据失效及用量清理合同 |

上表 Prepare/Commit/Cancel/UndoRuleMutation、ListAccessRules/ExplainPolicy 仅注册给 DEV/Alpha 调试界面；GetAccessServiceState/RetryAccessService、用量与身份接口可供所有渠道使用，但 Beta/Release 输出不包含策略/节点诊断字段。SetSiteProxy 在原生内部调用同一协调器，不给普通 WebUI 暴露通用操作入口。

pageToken 和 ruleId 均须由绑定的 BrowserContext 核验；页面不能借自己传入的 Profile、账户、目标范围或版本扩大权限。普通 UI 不接收任意 proxyGroupId；服务端代理组经本 Profile 准备完成后填充。Beta/Release 的关闭开关、DEV/Alpha 的 BLOCK/显式 DIRECT 不因断网、欠额或未登录禁用；仅缺少目标、上下文已失效或无权限时禁用并说明。

DEV/Alpha 调试同页并发显示中，正在允许不能禁用所选目标的 BLOCK。新 BLOCK 立即使对应旧准备显示“已被后续阻断取代”；迟到结果不把按钮改回已允许。调试成功使用“已允许并代理”或“已阻止”，代理故障可使用“PROXY · 等待网络/恢复中/额度耗尽”；Beta/Release 仅使用网站开关合同中的日常文案。规则详情的三策略选择和 ALLOW/BLOCK 使用同一执行合同。

EnsureManagedProxyReady、GetAssignmentPlan、Prepare/Commit/RecoverEndpointSwitch 是内部操作，携带幂等 operationId 与版本；普通页面不能指定配置 URL/endpointId。DEV/Alpha 专属 Import/Refresh/RemoveSubscription、Validate/SelectDebugEndpoint、SetDebugSource/SelectionMode 在 Beta/Release 构建不注册。

UI 使用已有英语、简体中文、繁体中文资源和 Aegis 设计系统；适配宽窄窗口、浅深主题和屏幕阅读器。Beta/Release 明确区分开关选择、准备失败、连接恢复、等待网络、流量耗尽、退出身份、到期、同步延迟、保存失败和受防护/管理限制；不显示策略枚举、手动阻断计数或采集清单。DEV/Alpha 可额外区分主动阻止、保留手动阻断、阻止未完全确认和覆盖不足；所有渠道的诊断均不显示秘密。

**10. 渠道、环境、身份与发布边界**

| 渠道 | 允许能力 | 默认服务 |
|---|---|---|
| DEV | 简洁网站开关 + 独立调试视图；三策略/两动作、规则、订阅、手动节点及脱敏诊断；可做优化构建 | local/development 测试身份与用量 |
| Alpha | 简洁网站开关 + 可暴露与 DEV 相同的调试细节和管理入口；保留 Alpha 标识 | staging 内部租户 |
| Beta | 网站代理开关、用量、用户可读状态、Beta 标识与反馈；隐藏策略/操作/节点细节，调试接口不注册 | staging；明确授权时可进入 production 的独立 Beta 租户 |
| Release | 网站代理开关、用量及必要的用户状态；与 Beta 相同的调试能力隔离 | production 正式租户 |

productChannel、buildConfiguration、serviceEnvironment、serviceRealm 为独立字段。用一个受版本控制的定义源生成原生常量、WebUI 能力和打包身份；渠道缺失或无效时拒绝正式打包，不能默认 release。is_debug、输出目录和包名不构成渠道授权。

渠道、Profile 的数据目录与凭据命名空间隔离，迁移是明确流程。调试能力仅由编译渠道允许：productChannel 属于 dev/alpha；Beta/Release 不得通过 Pref、URL、启动参数、远程开关或修改 DOM 恢复调试入口/通用 mutation handler。服务端仍以 issuer/audience/realm/scope/权益鉴权，不信任客户端自报渠道；Alpha 能调试不等于可操作生产凭据或跨租户。共享服务器也必须分账和分权限，所有租户共同受真实物理容量约束。

安装并存和升级身份必须尊重仓库现有 Chromium 身份兼容要求，在 P0 设计并验证，不直接改 Bundle ID 或搬用户目录。各渠道只接受可信且匹配的升级；无自动更新系统时，手工安装包同样校验身份。渠道晋级使用同候选源码按目标参数重构建验证，不能改文件名冒充 Release。

同一 OS 用户下的目录隔离不是抵抗恶意本机程序的完整沙箱。内核秘密、IPC 权限和包签名仍需独立保证；本设计不扩大操作系统安全承诺。

**11. 性能、内存与时延验收合同**

以下为初始工程验收线，不是已有性能。采用 P0 绑定的最低支持机器及参考机器，优化构建、相同网络/目标/缓存条件对照。参数修订必须在测试前更新版本并说明原因，不能看到失败后直接放宽阈值并记原测试通过。

| 编号 | 指标与初始验收线 | 测量方式 |
|---|---|---|
| PF01 | 10,000 条规则纯匹配：平均 ≤50 µs，p95 ≤100 µs，p99 ≤500 µs；热路径无磁盘/网络/UI 往返 | 至少 100,000 次混合命中/未命中，含 host/后缀边界；记录机器、请求率和完整分布 |
| PF02 | 未命中规则的直连 p95 TTFB/LCP 增量不超过 max(基线 5%,20 ms) | 同构建关闭功能与开启功能对照，冷/热缓存分别至少 30 次；报告波动，条件不稳记 INCONCLUSIVE |
| PF03 | 同一代理路径下，Aegis 路由吞吐不低于固定本地代理基线的 95%；p95 TTFB 增量不超过 max(基线 5%,20 ms) | 同 Xray、协议、VPS、目标和并发；不把 DIRECT 与不同代理路径直接相比 |
| PF04 | 用量有效变更约 1 秒更新；节点计入字节到可见 UI 的 p95 ≤3 秒、p99 ≤5 秒 | 在声明规模/网络条件下连续至少 20 分钟，取得至少 1,000 次有效更新；同步点误差必须记录 |
| PF05 | 首次准备 ≤15 秒；故障复核 ≤6 秒、确认后切换 ≤15 秒；超过预算停止并明确失败 | 记录点击、采样、握手、发布、首个成功新请求及页面加载；不把子阶段时延当总恢复时延 |
| PF06 | 每文档 2,048 host；每 Profile 收集器 ≤8 MiB；诊断待处理最多 4 MiB 且最多 4,096 条，任一先到即限流；全浏览器该诊断队列 ≤16 MiB | 突发/重复错误与多 Renderer 压测；入口信用额度覆盖在途数据，超限合并/丢弃并标 limited |
| PF07 | 稳定内核每活跃 Profile 最多 1；全浏览器额外候选/排空资源最多 2；所有进程及峰值 RSS 有总预算 | 1/3/5 Profile 和 50 次启动/切换/退出循环；记录峰值、回收及泄漏；RSS 数值按第 13 节在 Alpha 前冻结 |
| PF08 | 无代理使用/准备需求且界面隐藏时，本功能内核为 0、用量显示订阅为 0；包含有大量 DIRECT/REJECT 规则的情况；新增后台 CPU 5 分钟均值 ≤单逻辑核 0.5% | 最后一个代理业务/验证结束后空闲回收期限 60 秒，无未结束业务时不得无限保活；回收后与功能关闭对照测 5 分钟，单逻辑核满载为 100% |
| PF09 | 声明的 VPS/账户速率和突发包络不能被多连接、多 Profile 或多设备突破 | 依服务端相同计数边界验证 bytes≤rateBitsPerSecond×时长/8+burstBytes+已冻结执行误差；同时验证物理方向总包络 |
| PF10 | 一个等权饱和账户不能靠连接数取得额外份额；等权账户稳定吞吐与公平目标偏差 ≤10% | 单节点受控同路径，预热后测 60 秒；同时存在小网页与长下载，慢远端不纳入公平率比较 |
| PF11 | 同一 Profile 多 UI 只有一份有效用量订阅；隐藏后无秒级显示请求；无查询堆积 | 从 100/1,000 合成订阅起测，按真实 VPS 能力逐步增加；只有通过的规模可写入支持上限 |
| PF12 | 1/10/30 标签页混合资源、下载和 ws/wss 时无无限队列或请求饥饿；连接池生效参数可追溯 | 记录排队 p95/p99、连接数、内存和错误；维持 PF02/PF03 及声明的队列/连接上限 |
| PF13 | BLOCK 本地屏障在接收协调任务内安装；发布后的拒绝确认/在途本地终止 ≤2 秒；总操作预算 5 秒 | 在所声明请求并发上限内测正常路径与超时故障；超时不得报全成功，保留屏障且不误伤未命中目标。记录每个取消句柄、确认代次及持久化状态 |

PF01 是策略计算预算；真实网络请求的总延迟另测。PF06 的 8 MiB 不是整个功能内存上限；总 RSS 还含内核、候选、策略副本、连接缓冲和消息队列。诊断丢弃只影响覆盖报告，不能丢安全策略消息或因背压解除拦截；安全控制通道独立且有界。

固定 Chromium 的代理链连接上限由特性参数控制，源码默认普通/WebSocket 各 128，关闭相关特性时退回各 32；实际运行可被配置影响。P0 记录生效参数和其他池限制，禁止盲目提高上限掩盖排队。[连接池](https://raw.githubusercontent.com/chromium/chromium/ff37cfca210138f2a40b843b4a8195ab7e4fc7ff/net/socket/client_socket_pool_manager.cc)、[特性参数](https://raw.githubusercontent.com/chromium/chromium/ff37cfca210138f2a40b843b4a8195ab7e4fc7ff/net/base/features.cc)

不把秒级同步当作零成本：假设每条 600 byte、每秒一次，1,000 个可见订阅的正文约占 4.8 Mbps，尚未含协议、重连和重传。该数字仅为预算算例；最终要量到线上格式大小，并与代理业务共同计入 VPS 容量。带宽支持人数依并发实际需求确定，不能用域名数量或注册人数推算。

**12. 实施顺序与阶段门槛**

使用同一条主线逐步交付。每个单元形成可独立评审的变更，包含实现、必要测试、overlay 导出、顺序补丁和 BUILD/资源接线；不能只提交展示页面或未接线的类。浏览器与服务端可以独立部署，但协议版本兼容矩阵必须先确定。

| 单元 | 交付内容 | 依赖与完成条件 |
|---|---|---|
| P0 | 从修订 4 接入基线绑定实际 checkout；验证两 Profile 三策略、原有代理组合、BLOCK 在途/缓存、HTTP/SOCKS 认证、渠道/安装身份、性能基线与服务资源合同 | 输出与当前 factory/报告路由/缓存接线的差距清单及运行证据；确认同步回调外等待点、定向取消、原有代理代次、连接池和真实构建成本；评估 Vision 快路径对计量的影响 |
| P1 | 复用已有 AegisServiceFactory、报告归属路由与 CNAME BrowserContext 分区；仅补齐访问服务所需隔离缺口 | P0；核对 StoragePartition/Guest/OTR 差异及两个普通 Profile 并发/销毁；不重复迁移已有工厂，不把已有源码或其他功能的测试直接记为本服务 PASS |
| P2 | 三策略 schema、规则库、纯匹配器、统一操作协调器、批次/恢复日志、G/S/E 与身份代次、跨语言向量 | P0；六种转换、批量/单项语义、优先级、冲突及恢复测试通过 |
| P3 | 固定 Xray 资产、Profile 入口/凭据、真实 REALITY 链路 | P1/P2；先验收 HTTP，再完成 SOCKS5 认证与隔离 |
| P3a | 托管注册、签名目录、部署/容量清单、准入、稳定分配、健康和切换状态机 | P2/P3；分为接入与分配、保持与故障判定、切换恢复三个评审单元 |
| P3b | DEV/Alpha 订阅及来源控制、四渠道编译能力和数据隔离 | P2/P3；Beta/Release 无可启用的调试管理接口 |
| P3c | 服务端字节计量、幂等账本、额度预算、周期和快速同步 | P2/P3a；真实字节对账、耗尽执行、重连和快照一致性通过 |
| P3d | 单 VPS 物理限速、按账户公平分配/并发准入；扩容时增加跨节点租约 | P3a/P3c；连接数不能扩大账户预算，传输误差有测量边界 |
| P4 | 精确采集器、正常/失败目标清单、在途归属及终止句柄、未提交导航、iframe/Worker 与覆盖报告 | P1/P2；不依赖 50 条展示列表，入口和内存有界；正常/缓存/派生请求有可信归属 |
| P5 | 三策略联合发布、全上下文切换/拒绝屏障、按流取消、身份竞争、恢复和撤销 | P2/P3a/P4；首次路由正确，BLOCK 与旧 ALLOW 不互相覆盖；故障/重启/旧 ACK 无直连窗口 |
| P6 | 所有渠道简洁网站代理开关；DEV/Alpha 调试目标列表、ALLOW/BLOCK、三策略详情及节点视图；按渠道原生阻断页、流量卡和错误状态 | P3b/P3c/P4/P5；简洁开关不创建防护例外，关闭恢复直连；调试阻断/解除/撤销流程及 Beta/Release 接口隔离均通过 |
| P7 | SOCKS5 完整验收及 WS+TLS 兼容、临时 Profile 和复杂请求覆盖补齐 | P3/P3b/P5；两入站×两出站矩阵及 OTR/Guest 均有证据 |
| P8 | 最终头补丁重放、渠道构建、性能与故障回归、安装/升级及交付档案 | 前述必需单元；按下列门槛分别报告功能与分发状态 |

先用受控单 VPS 和明确的服务身份打通主链路。五个域名若共用该 VPS，就按同一容量组验证入口选择；不为模拟独立容量复制一个复杂多区域平台。跨容量组算法、账本和租约仍用多节点 fixture 测试；真正增加第二个执行节点前必须完成对应真实部署联调。

| 门槛 | 可以声明的状态 | 必须满足的条件 |
|---|---|---|
| G0：接入可行 | 固定基线上的原型通过 | P0 有实际构建与运行证据，关键接入无未解决阻断；不能用公开 HEAD 文档代替固定提交验证 |
| G1：受控 Alpha | 简洁流程和调试视图的有限覆盖版本可试用 | 至少 HTTP→REALITY、两个普通 Profile、网站开关与调试三策略/两动作、阻断及恢复、调试联合规则、自动配置/保持/切换、真实字节统计、账户及物理限制、故障不直连；限定用户与测试容量，明确列出未覆盖场景 |
| G2：完整功能候选 / Beta | 本文最终功能覆盖已实现 | P1–P7 完成；A01–A89、A91–A118 适用必需场景及 PF01–PF13 通过；四渠道简洁入口/调试隔离、两入站/两出站、OTR/Guest 与底层三策略恢复不能用 Alpha 子集替代 |
| G3：可分发候选 / Release | 在已验证平台、规模和拓扑内可分发 | G2 加 A26/A63–A67/A88/A90 的最终包证据、项目发布门禁、全新安装/升级/回滚；实际发布动作按项目授权执行 |

G1 必查 A01–A05、A09–A11、A13–A17、A19–A23、A27–A31、A35–A40、A47–A60、A68–A78、A81–A86、A91–A118 中与 HTTP→REALITY 普通 Profile 链路和 Alpha 界面对应的子场景，并在 Alpha 实际规模测 PF01–PF13。包含未实现协议或其他渠道的混合用例只能记录“指定子场景通过”，未执行子项仍为 NOT_RUN，整行标 coverage=partial，不标 PASS，不能提前计入 G2。

未完成 HTTP/SOCKS 任一必需入口，或仅有 DEV/Alpha 订阅没有托管服务，均不能称“完整功能完成”。同样，界面每秒变化但未对账服务端字节，不算用量链路完成。发布阶段不存在通过隐藏失败功能就让同一范围验收通过的例外。

**13. 实施前绑定的参数、负责人和证据**

以下是待实测或待运营提供的事实，并非要求普通用户提供节点。先用隔离 fixture 开发；相应门槛前由实现/运维负责人填入受版本控制的环境清单。缺少必需项时该门槛记 BLOCKED，不能填入演示数字后当真实参数。

这些是已定义合同的取值绑定：例如账户提供方 URL、内核资产 hash、VPS 的 Mbps、总 RSS 数值和人员姓名；不得借绑定参数改变三策略语义、绕过 BLOCK 预算或将未知额度当无限。未绑定参数不影响 V1.0 行为冻结，但阻止相应真实部署/性能/分发门槛通过。测试环境使用明确标注的 fixture 参数，不冒充生产值。

| 参数组 | 必填内容 | 绑定时间与责任 |
|---|---|---|
| 源码与构建 | 浏览器/Chromium/V8 SHA、series hash、host contract、工具链、GN 参数、磁盘空间、测试目标 | P0，浏览器实现负责人 |
| 最低支持与参考机器 | CPU、内存、OS、架构、电源/温控、优化构建、网络条件；PF 测试固定方法 | P0，性能负责人 |
| 内核与资产 | Xray 版本/源提交、各架构 hash、构建来源、许可与随包通知、配置 schema、更新/回滚兼容性 | P3 前，内核集成负责人 |
| 托管身份 | 第 4 节安装访客/显式账户合同对应的 bootstrap 域名、账户提供方是否配置、issuer/audience/realm、签名轮换、登记/恢复凭据、短期有效截止、吊销重试及滥用上限 | 真实 Alpha 前，控制面负责人；不再选择另一套未定义身份行为 |
| 实际部署 | endpoint→deployment→capacityGroup→trafficPool/failureDomain；别名关系、出口亲和能力、allowedEgressProfiles、实际 target/SNI/ALPN 与抗识别测试范围及维护策略 | 真实 Alpha 前，运维负责人 |
| 供应商合同 | VPS 端口 Mbps、限制方向、月流量是否有限/计费方向、重置时区、共享池及额外业务 | 真实 Alpha 前，运维负责人；生产开放前复核 |
| 速率与容量 | 物理/租户/账户 rateBitsPerSecond、burstBytes、保留带宽、连接/排队上限、公平权重、准入人数及过载响应 | Alpha 压测前冻结测试值；对外开放前绑定生产值 |
| 计量与额度 | accountingVersion 的固定计数点、lease 大小/TTL、持久化边界、失联结算/预留回收、最大未结算与执行超额字节、Vision/splice 是否启用及实时预算执行证据 | P3c/P3d 集成前冻结，再用故障注入证明；账本负责人 |
| 时间与同步规模 | 服务端时钟/测量误差、推送格式大小、活跃/空闲/重连负载、支持可见订阅数 N、源水位覆盖条件 | Alpha 性能验收前，服务端及性能负责人 |
| 浏览器资源预算 | 每内核和浏览器新增总 RSS 上限、候选/排空峰值、连接缓冲/安全通道/等待队列上限、退出回收时限 | 在最低支持机器测量后、Alpha 放行前冻结；不能只填 8 MiB 收集器上限 |
| 渠道与交付 | 渠道数据目录/凭据命名空间、安装与更新身份、服务环境映射、签名公证流程和回滚允许范围 | P0 确认兼容方案；P8 核对最终包 |
| 责任与运行 | 具体负责人、测试服务及生产服务标识、事件/账本保留周期与访问权限、吊销/维护/事故操作记录 | Alpha 前有测试值和负责人；Release 前绑定正式配置 |

真实订阅、密码、UUID、私钥及完整授权头存入指定秘密管理系统，证据只记录秘密引用和脱敏配置摘要。没有账户流量额度的真实套餐可配置 quotaMode=unlimited；“尚未问清”只能是 unknown。运营决定实际配额与定价，技术方案不代填商业数据。

**14. 验收执行方法与证据格式**

每项验收绑定具体源码和运行配置；同一测试在不同入站、出站、渠道、Profile 类型或拓扑下是不同子项。结果词汇统一如下。

| 状态 | 含义 |
|---|---|
| PASS | 必需断言全部通过，有相应身份和原始证据 |
| FAIL | 已执行且出现违背合同的结果 |
| BLOCKED | 缺少依赖、资源或必填参数，无法完成验收 |
| NOT_RUN | 尚未执行；编译通过不替代运行通过 |
| INCONCLUSIVE | 已执行但观察不足、噪声过大或无法证明因果 |
| NOT_APPLICABLE | 仅限明确不在已声明拓扑/平台的子场景，写明理由和扩容前门槛；不能用于跳过本期必需功能 |

同一 VPS 的域名别名可以使“两个真实独立物理故障域”子场景不适用于该部署，但故障范围识别、双节点 fixture 及配额并发测试仍必须执行。只发布 macOS 时不要求拿其他平台结果冒充通过；HTTP、SOCKS、主/兼容出站、Profile 隔离不能以未部署为由标 NOT_APPLICABLE。

| 测试层 | 负责证明的内容 |
|---|---|
| 合同/纯函数 | schema、规范化、匹配优先级、订阅解析、用量状态、稳定排序与跨语言向量 |
| 原生 unit_tests | Profile 所有权、数据库事务、版本、撤销、健康/租约状态机、预算与可控时钟 |
| browser_tests | 真实 WebContents、未提交导航、iframe/Worker/OTR、WebUI 身份边界和原生代理接入 |
| 服务端合同/集成 | 配置签名、主体鉴权、准入、计量去重、额度与速率执行、失联租约/重置和对账 |
| 受控端到端 | 真实 HTTP/SOCKS→REALITY/WS+TLS、目标端请求标记、DNS/出口、首次托管与两 Profile 并行 |
| 故障注入 | 进程/网络服务退出、断网、旧 ACK、数据库异常、配置过期、额度耗尽、饱和与恢复 |
| 性能与发布 | PF 对照、峰值/泄漏、支持规模，固定最终包安装/升级及渠道证据 |

使用新建测试 Profile 和虚构网页/账户。目标站点提供受控 DNS 失败、Aegis 拦截、多子域、跳转、iframe/Worker、上传/下载与 ws fixture；每个业务请求带测试生成的唯一标记，用目标和代理两侧记录证明路径与是否重复。测试端点与操作系统观察工具只用于隔离测试环境，不采集日常 Cookie、真实表单或私人浏览流量。

测试 HTTPS 信任通过 Chromium 测试机制配置；产品本身仍保持证书检查。故障前后都检查默认直连和已要求代理的路线。故障切换成功要有新入口请求及版本证据；绿色图标、本地监听端口或 UI 截图单独均不够。

已有仓库脚本入口（执行时再次核对最终源码）：

~~~text
pnpm run quality:fast
pnpm --filter @gcsa-aegis/browser status
pnpm --filter @gcsa-aegis/browser apply-patches
~~~

apply-patches 只在指定的干净、隔离 Chromium checkout 执行，遵循仓库和主机存储合同。以下为拟新增入口，当前不能视为已存在：

~~~text
pnpm --filter @gcsa-aegis/browser verify:access-runtime
pnpm --filter @gcsa-aegis/browser verify:proxy-runtime
~~~

实际原生测试目标、gtest filter 与性能驱动命令在实现后登记，不能用占位命令替代真实执行。执行前验证 ExternalSSD 挂载、对应目录可写和剩余容量，不自动清理其他工作树。

每次正式验收输出下列结构，保存路径由仓库交付约定确定：

~~~text
run-manifest.json
  specVersion=V1.0, specRevision=4, frozenSpecHash, testRunId, startedAt, finishedAt
  repository/base/head SHA, chromium/v8 SHA, patchSeriesHash
  channel, buildConfiguration, GN hash, binaryHash, coreVersion/coreHash
  OS/hardware/network, serverDeployment/configHash, fixtureVersion
  declaredScale, activeFeatureFlags, parameterContractVersion
results.json
  caseId, subcase(protocol/channel/profile/topology), status
  expected, observed, evidenceFiles, failureReason
performance.json
  metricId, baseline, sampleCount, mean/p50/p95/p99/max
  rawSamplesFile, measurementUncertainty, declaredLoad
artifacts/
  脱敏的客户端/服务端/目标记录、计量对账、截图及必要抓包
~~~

Hosted 检查另记录 run/attempt、检查名称、final head、实际结论；排队、取消、跳过、无 job 均不当成成功。签名、公证、安装、升级分别有证据状态。测试后源码或影响行为的服务配置改变，必须按影响范围重跑；不能将旧提交的结果直接贴到新提交。

**15. 功能验收矩阵**

以下 A01–A118 为 V1.0 完整功能及交付矩阵；保留此前 A01–A90，A91–A102 对应完整性复评 C01–C12，A103/A104 补齐身份和时效恢复，A105–A112 验收渠道与网站开关，A108/A113/A114 覆盖修订 3 的协议组及独立预览，A115–A118 覆盖修订 4 的组合策略、组/目标隔离和出站评估。表中 ALLOW/BLOCK、手动规则、订阅和节点操作均由 DEV/Alpha 调试界面执行；Beta/Release 用原生测试夹具验证相同底层不变量，并另测调试接口不可调用，不能通过隐藏 UI 免除底层验收。网站开关不得借用带防护例外的 ALLOW 作为替代测试。测试实现必须把复合场景拆成可定位的子项。本文交付时均未执行产品验收，不能将“必须观察到的结果”读成实际结果。

| 编号 | 场景 | 必须观察到的结果 |
|---|---|---|
| A01 | 无 Aegis 规则访问普通站点，无原有代理/有原有代理两个子场景 | 无原有代理时直连目标；有原有代理时沿用其有效结果，均无 Aegis 代理出口请求 |
| A02 | 后台配置已就绪或 DEV/Alpha 只导入订阅，未添加规则 | 网页仍直连 |
| A03 | 单域名 Aegis 拦截 | 点击后精确 allow + proxy 生效并恢复目标请求 |
| A04 | 100 个不同子域被拦 | 不受 50 条展示事件限制；没有错误归并为父域通配授权 |
| A05 | 超过采集预算 | 明确显示采集不完整，禁止成功文案声称全部完成 |
| A06 | 主文档 DNS 失败、无已提交网页 | 从失败导航识别正确目标，点击后能建立规则 |
| A07 | 跨域 iframe 发起资源请求 | 归属真实顶层网站，不能伪造其他网站作用域 |
| A08 | 同页脚本放行后出现新域名 | 有界补充发现生效，达到上限后停止并报告 |
| A09 | 用户在处理期间导航或关闭标签页 | 终止旧会话，不授权新文档的请求 |
| A10 | 两个 Profile 同时访问同一网站 | A 的允许不改变 B 的结果，凭据和事件不串 |
| A11 | 同一 Profile 两个网站共用 CDN | 本站规则仅影响指定顶层网站 |
| A12 | OTR/Guest 与普通 Profile 并存 | 无默认继承，退出临时会话后不落持久规则/记录 |
| A13 | 节点参数错误、端口占用 | 明确失败，不伪装成已连接，不停止用户其他进程 |
| A14 | 核心启动前、运行中、更新中退出 | 已要求代理的请求均不落回 DIRECT |
| A15 | Network Service 或 Renderer 重启 | 策略版本重新同步，无未受约束的出站窗口 |
| A16 | HTTP2、Alt-Svc、QUIC、旧连接池 | 改规则后的新请求使用正确路线，未偷用直连 |
| A17 | DNS 预取、preconnect、IPv4/IPv6 | 命中代理范围后按规定处理，无未解释的目标旁路 |
| A18 | HTTPS/ws/wss 与 Worker | 分别证明可用链路及页面归属；不以普通 GET 代替全部验证 |
| A19 | 证书错误、钓鱼页、CSP/CORS | 不被一键功能关闭验证或误报为已修复 |
| A20 | POST/提交/既有下载 | 不自动重放，不重复提交 |
| A21 | 重复点击、重复候选、并发编辑 | 幂等、去重、版本冲突可见；同键按操作序列协调，重复点击不重复刷新或提交业务 |
| A22 | 撤销与后续手动编辑冲突 | 只撤销自己仍拥有的差异，保留较新编辑 |
| A23 | 数据库写满、损坏、事务中断 | 不产生 allow-only；恢复失败不默认为空规则直连 |
| A24 | 托管/DEV/Alpha 配置中的 REALITY 与 EdgeTunnel WS+TLS | 不混淆协议组合；不静默接受关闭验证参数 |
| A25 | DEV/Alpha 订阅失效、更新与节点删除 | 仅在有效期内保留上个有效版本；逻辑代理组有确定的失效处理，网站规则不丢失 |
| A26 | 最终补丁与二进制身份 | 根提交、Chromium/V8 提交、series、GN 参数、Xray 版本、产物 hash 一致 |
| A27 | 全新安装及同安装新普通 Profile，首次开启网站代理 | 按安装访客合同自动登记/派生独立凭据、验证/选择并继续当前操作；无节点表单或二次确认，不授予防护例外；新 Profile 不重复领取独立完整额度 |
| A28 | 配置签名错误、过期、版本回退、租约归属错误 | 拒绝候选；无有效配置时不激活放行、不直连 |
| A29 | bootstrap 故障，有/无有效缓存 | 有效缓存可在授权期内使用；无缓存时明确失败，不陷入代理初始化递归 |
| A30 | 租约到期、续租失败、服务端撤销 | 无效凭据不能继续新建连接；既有连接按截止策略处理；规则保留 |
| A31 | 当前节点故障、备用成功或全部失败 | 在授权集合内有界切换；Profile 不串，出口变更可诊断，非幂等请求不重放 |
| A32 | OTR 首次使用与退出 | 由安装身份管理器取得独立临时凭据，不读取普通 Profile 秘密；默认共享安装访客预算，显式账户授权才用账户权益；退出无持久敏感数据，不重复领取额度 |
| A33 | Beta/Release 尝试调试 URL/Pref/内部接口 | 不能调用通用规则 mutation、导入订阅或指定调试节点；DEV/Alpha 数据不自动迁入普通版本 |
| A34 | DEV/Alpha 订阅新增、刷新、删除、切换来源 | 来源拥有关系正确，失败状态明确；不悄悄切生产服务；无用量字段不显示为 0 或无限 |
| A35 | 已知大小上传、下载和实际重试的计量 fixture | 服务端字节累计与规定边界一致；上传+下载等于已用，直连/缓存及规定排除项不扣用户额度 |
| A36 | 同账户多 Profile、多节点、多设备并发 | 独立凭据共享同一授权余额；切节点不重置用量，额度执行有已测量边界 |
| A37 | 重复/乱序上报、节点重启、旧周期快照 | 不重复扣减、不回滚累计、不污染新周期，账本可对账 |
| A38 | 大文件传输中耗尽、套餐到期 | 节点执行额度限制，UI 最终一致；不换节点绕过，不回退直连 |
| A39 | 周期重置或服务端增加额度 | 更新权益与租约后可恢复，原网站规则保留，不要求重新配置节点 |
| A40 | 用量接口断网/延迟、账户越权查询 | 显示上次测量时间与未知状态；另一个账户的用量不可读取 |
| A41 | DEV/Alpha 订阅附带全局分流、DNS、策略组或未知格式 | 仅接收明确支持的节点字段；网页规则不被覆盖，含凭据订阅不自动发送给第三方转换服务 |
| A42 | DEV/Alpha 同时存在平台请求数与用户流量额度 | 请求数仅在 DEV/Alpha 供应方诊断显示，独立标注来源与单位；普通卡片只显示账户字节流量，平台进度不冒充用户余额 |
| A43 | 同一订阅生成多个优选入口 | 候选保留共同来源关系，切入口不新增额度；节点数量不作为出口隔离的证明 |
| A44 | 四渠道管理页/气泡、宽/窄窗口、浅/深主题与屏幕阅读器 | 用量和周期置顶、网络状态卡清楚；Beta/Release 当前网站只有代理开关，不出现策略/操作/节点细节；DEV/Alpha 简洁与调试视图分组正确 |
| A45 | DEV/Alpha 分区编辑、保存失败、取消、切换简单/高级视图 | 无改动时保存禁用，草稿不因视图切换丢失；只有成功校验并保存才更新配置 |
| A46 | 无额度、无重置、数据延迟、时区变化及不同单位分项 | 各状态显示准确，不伪造百分比，不混合次数/字节；倒计时基于服务端时间，不写死演示周期 |
| A47 | 多入口、共享容量组和一批合成 Profile 初始分配 | 按容量组权重形成可测分布；域名别名不增加组权重；同一主体和相同计划可复现排序 |
| A48 | 健康会话中刷新订阅、调整权重或备用变快 | 保持同一绑定；既有标签页及新打开的同组页面不发生逐请求轮换 |
| A49 | 主入口确认失败，第四/第五候选可用 | 前序快速失败且总预算充足时能继续尝试后续候选；不只测试固定前三个就认定全池不可用 |
| A50 | 准备预算耗尽，部分候选未尝试 | 明确标为超时/未完成验证；不能宣称所有节点均已失败 |
| A51 | 单站 403/429/5xx、CSP/CORS、证书错误或验证站自身故障 | 不直接触发整个 Profile 换节点；通过受控复核区分目标与入口故障 |
| A52 | 本机断网、休眠、本地内核退出 | 分别进入等待网络或本地恢复流程；不将故障扩散为全池节点失效 |
| A53 | 网络切换后旧探测/旧 ACK 晚到，或多标签页同时重试 | 旧 epoch/revision 结果不能覆盖新绑定；同组只有一个切换任务并遵守总并发预算 |
| A54 | 已知共享部署故障与独立域名故障分别注入 | 备用排序依据真实故障范围；不在坏部署的别名间循环，也不把单域名错误无依据扩大到全组 |
| A55 | 原入口恢复、冷却到期及反复抖动 | 经过恢复验证后仅重入候选；不自动抢占当前健康绑定，不出现来回切换风暴 |
| A56 | 健康入口续租、维护排空及撤销截止 | 能原地续租则保持；维护/撤销按明确截止处理，权重调整不强制搬迁健康会话 |
| A57 | 新入口发布前后各阶段崩溃、跨 NetworkContext ACK 延迟 | pendingSwitch 可恢复；新请求不偷用旧池或 DIRECT，未提交切换不记成功 |
| A58 | 一个标签页取消批次，同时其他标签页等待恢复 | 只取消该批次等待者；共用恢复任务继续，网站规则和撤销所有权不被改写 |
| A59 | 候选满载与账户额度耗尽分别发生 | 满载可按授权计划尝试其他容量组；账户耗尽不切节点绕过；切换前后用量连续 |
| A60 | 多请求和非幂等业务在切换时处于不同阶段 | 已发出的 POST/消息/下载不被复制重放；恢复后的新请求绑定新版本；旧存活连接按排空截止处理 |
| A61 | 固定入口但服务端动态出口，以及具备出口保持的受控服务 | 只在后者有实际证据时声明出口保持；普通入口保持不冒充固定公网 IP |
| A62 | DEV/Alpha 手动固定、自动模式恢复、普通版尝试调用调试接口 | 手动固定失败不暗中切换；恢复自动后走同一状态机；普通版无法启用调试选择 |
| A63 | 四渠道分别构建，包含 DEV 的优化编译和 Beta 的发布编译 | 能力由产品渠道决定；不能从编译优化模式推断 DEV 权限或正式分发状态 |
| A64 | 伪造渠道 Pref/URL/启动参数、自报服务端渠道或远程开关 | 不能扩展已编译能力、取得其他环境凭据或绕过服务端授权 |
| A65 | 四渠道并存、打开 Profile、读取 Keychain/凭据及更新包不匹配 | 数据与秘密按渠道隔离；不自动读正式 Profile，不接受不匹配更新或身份混装 |
| A66 | 渠道缺失/未知、晋级重构建与改名旧包 | 打包拒绝未知组合；候选源码和渠道身份可核对；改文件名不能通过正式产物验收 |
| A67 | 在共用域名/集群上交换环境令牌、租约或用量查询参数 | 控制面和节点均拒绝不匹配的 audience/realm/权益；测试与正式账本和日志访问不串 |
| A68 | 用量卡/气泡、MB/GB/TB 与 MiB/GiB 来源、零/微量、跨单位边界及小数显示 | 最小单位 MB，不显示 KB/B；零为 0 MB，非零微量不冒充零，按十进制自动升单位；以原始字节计算上传+下载、余额和比例，普通卡片无请求次数选项 |
| A69 | 仅固定 Mbps、明确未设流量额度 | 显示已用/上传/下载及统计周期；无剩余额度、进度条或额度重置倒计时 |
| A70 | 额度未知、额度为 0、统计延迟或实际超额 | 不把未知当无限或 0；无除零；保留真实已用与更新时间，条形封顶不截断累计量 |
| A71 | 只有 VPS 总量、多个 HOST 或多个用户共用 VPS | 不冒充个人余额，不重复容量；测试与正式账户分账但共同计入真实资源消耗 |
| A72 | 可见用量卡持续上传/下载、多设备同时消费 | 约 1 秒更新同一账户的完整累计；记录节点计入到 UI 显示的 p95/p99 和来源水位，达到约定网络/规模下的时延目标 |
| A73 | 推送心跳正常但统计源停更、部分节点失联、系统时间跳变 | 不伪装最新；超过新鲜度预算显示延迟/暂未同步，保留已知累计和真实覆盖范围 |
| A74 | 多个气泡/管理页、界面隐藏后再打开、推送中断或限流 | Profile 内合并订阅；隐藏不影响服务端计量；恢复立即拉完整快照，查询无并发堆积并有退避 |
| A75 | 周期切换、旧消息重放及传输中额度耗尽 | 同帧显示一致快照，不重复累计、不接受旧周期覆盖；节点执行不依赖 1 秒显示定时器 |
| A76 | GET/POST/PATCH 等首次发送、企业/系统/扩展代理组合 | 命中规则的支持方法首次发送均遵守代理；记录服务器唯一标记证明未重复提交，非幂等默认过滤不得造成直连；不可覆盖的企业策略明确提示 |
| A77 | 无内核/过期快照时解析路由、高频命中与发布等待 | OnResolveProxy 只读本地快照，无网络/磁盘或跨进程同步等待；需要异步准备的请求有界等待或失败；满足 PF01/PF05 |
| A78 | HTTP/SOCKS5 入站认证、错误 Profile 凭据与外部连接 | 两种入口分别验证；只监听 loopback，拒绝无效/跨 Profile 认证，浏览器不向未登记代理泄露凭据；关闭 Profile 后会话认证失效 |
| A79 | scheme/port、精确子域、私有后缀、IDNA/IPv6 与边界冲突 | C++/TypeScript 向量一致；不误匹配相似后缀，不扩大自动授权；不支持的目标明确拒绝；显式规则优先级一致 |
| A80 | Shared/Service Worker 无唯一客户端、prerender/BFCache、受代理约束的 UDP | 无可靠归属不自动授予本站例外；恢复/激活重新绑定 token；未支持的 WebRTC/WebTransport 路径明确受限，不静默直连 |
| A81 | 重装、多建 Profile、临时会话、身份恢复及窃取其他主体引用 | 不能重复领取既有账户额度或读取他人配置；凭据只授予授权主体，注册/准入滥用上限真实生效；恢复不靠复制其他 Profile 秘密 |
| A82 | 多连接/设备/节点并发、RateLease 重放/过期、切换和中心失联 | 账户及物理速率包络符合 PF09，burst 不重复发放；无有效授权不无限放行，连接/队列上限与满载响应有效 |
| A83 | 等权账户竞争、一个账户大量连接且混合网页/长下载 | 满足 PF10；公平按鉴权账户执行，多连接不增加份额；短请求无无限等待，保留的控制面容量仍可用 |
| A84 | 计数落盘/上报前后崩溃、未结算租约失联、旧预留回收与跨周期 | 使用唯一租约/计量会话恢复；已结算与未结算预算可对账，预留无证据不重发，误差不超过冻结边界；不能用进程重启归零累计 |
| A85 | 多 Renderer 错误风暴、1/3/5 Profile、候选排空与 50 次生命周期循环 | 满足 PF06/PF07/PF08/PF12；诊断背压不丢安全策略或解禁；没有残留内核、无界等待或超出冻结的内存/回收预算 |
| A86 | 同步到秒、重置到分钟、跨年/时区变化、倒计时不足一分钟 | measuredAt 显示真实日期与 HH:mm:ss；重置 HH:mm、倒计时分钟/不到一分钟；重绘和心跳不更新测量时间，本地归零不自行重置权益 |
| A87 | 升级数据库/密钥命名空间、旧版本回退、规则库损坏 | 有明确 schema/凭据迁移兼容边界；不自动跨渠道读写，不丢规则后默认直连；不兼容回退拒绝或走已验证恢复流程 |
| A88 | 内核资产损坏/替换、未知版本、不同架构与更新失败 | 只运行匹配可信清单的资产；配置/协议兼容经验证，更新失败保持安全状态；随包许可及来源齐全，回滚不越过 schema/签名边界 |
| A89 | HTTP/SOCKS5 × REALITY/WS+TLS 的完整链路及真实部署关系 | 四个组合分别有鉴权、TLS、上传/下载、ws/wss 与故障记录；别名不冒充独立 VPS，只有验证过的能力才能写入支持声明 |
| A90 | 最终候选头、干净补丁重放、四渠道产物、全新安装/升级/回滚及发布门禁 | 源码/内核/服务配置与结果绑定；项目必需检查实际成功，签名公证安装证据分别齐全；跳过/排队/旧头不冒充最终验收 |
| A91 | DIRECT/PROXY/REJECT 的全部六种有向转换与重复操作 | mode、例外、路径及持久版本符合第 6 节；REJECT→PROXY 准备失败保留拒绝，DIRECT 不携带 ALLOW 例外；重启后仍是最新有效状态 |
| A92 | 离线、无内核、欠额、退出身份时执行 BLOCK | 本地授权和持久化可完成，不启动代理、不等待服务端；未选目标禁用；对应新请求本地拒绝，不产生新目标转发 |
| A93 | 两 Profile、两顶层网站、同一 CDN 及选择主导航目标 | BLOCK 只作用于明确的 host/scheme/port 与本站范围，不把所选集合扩大成整站/全浏览器；新主导航使用目标 SchemefulSite |
| A94 | 批量 ALLOW 与有界补充遇到有效手动 REJECT；随后单项 ALLOW | 批量保持拒绝并计入保留数量；单项明确操作可替换/形成更具体本站例外，无二次确认，不覆盖管理限制 |
| A95 | 本站/Profile、精确/后缀、scheme/port、管理限制及冲突数据 | 按冻结顺序唯一解析，UI 解释来源；同等级冲突编辑被拒绝，损坏冲突失败关闭，不随机放行 |
| A96 | BLOCK 时正在上传、下载、媒体、SSE、ws/wss 与共享传输 | 满足 PF13：确认后不新增派发，命中在途流按 2 秒预算完成本地终止，不关闭其他目标共享流；未确认/保存失败不报成功 |
| A97 | ALLOW 准备中执行 BLOCK，旧 ACK/探测/身份响应和提交随后到达 | 相交旧操作失效，不能解除屏障或覆盖 REJECT；其他不相交目标继续；UI 保持后续操作结果 |
| A98 | REJECT 命中主导航、HTTP 缓存、Service Worker、BFCache/prerender | 冻结的新加载/激活合同生效，原生恢复入口不依赖目标网站；已交付页面内容不删除，无归属后台请求不冒充已覆盖 |
| A99 | BLOCK 后撤销、删除、显式 DIRECT 和后续并发编辑 | 恢复正确的前态/继承而非一律直连；恢复 PROXY 需先准备，失败保留当前安全状态；较新编辑保留 |
| A100 | PROXY 断网、节点故障、欠额、退出身份后恢复与重试 | 持久 mode 不变，错误原因独立可见；不生成用户 REJECT，不降为 DIRECT，不重放已发送业务 |
| A101 | 只有 DIRECT/REJECT 规则、无代理业务/准备且显示界面隐藏 | 达到 PF08，空闲 60 秒内内核回收，秒级显示订阅关闭；不因存在规则维持空内核 |
| A102 | 每秒微量字节增长、跨单位舍入、BLOCK 后在途迟到结算 | 原始字节与来源时间正确，即使格式化值未变也能证明新鲜；零/微量不混淆，迟到结算可对账，不伪造请求逃逸或动画增长 |
| A103 | 安装访客、多 Profile、显式登录/切换失败、退出、继续访客及删除 Profile | 第 4 节状态转换一致；无默认跨账户回退，无旧秘密或旧用量污染；离线退出本地立即生效，远端吊销/截止有独立证据；既有账户账本不归零，失去安装凭据不承诺匿名恢复，删除只影响对应本地身份 |
| A104 | persistent/profile_session/until、截止时继承 PROXY、进程重启及恢复日志 | 时效边界明确；会话规则随 Profile 实例清除；到期发布不先直连，租约到期不删除网站规则，撤销/继承均按有效版本恢复 |
| A105 | Beta/Release 的管理页、气泡、已保存网站、阻断页与错误状态 | 每个网站只有代理开关；无三策略、ALLOW/BLOCK、规则编辑、目标列表、订阅/节点详情或调试日志；用户状态和用量清楚，键盘/屏幕阅读器可操作 |
| A106 | DEV/Alpha 简洁视图与调试视图切换 | 两渠道均可调试三策略/两动作、订阅、手动节点、来源和脱敏诊断；同一核心执行合同，不从视图切换取得其他渠道/生产授权 |
| A107 | Beta/Release 中伪造 URL/Pref/启动参数、修改 DOM、直接调用通用 mutation | 编译渠道和原生 handler 均拒绝调试入口；共享核心照常工作；不是只隐藏按钮，未知渠道不能默认开放调试 |
| A108 | 同域 HTTP/HTTPS/WS/WSS、HTTP→HTTPS 跳转、8443 等非默认端口，以及 CDN/iframe/子域和无 pageToken | 第 9 节同域协议组统一生效，443/8443 等允许端口不需另开开关；可信归属的同域子资源/iframe 使用同一选择；子域、第三方、其他顶层站点及无可靠归属请求不扩大授权；安全限制仍生效，无可信操作目标禁用 |
| A109 | 在被安全拦截或受管理的网站开启/关闭代理 | 不新增防护例外，不调用 ALLOW/BLOCK，不解除手动 REJECT 或管理限制；界面如实说明限制，不声称代理已修复防护问题 |
| A110 | 已开启后离线/欠额/退出身份，再关闭；存在较宽 PROXY 继承 | 关闭在本地提交显式 DIRECT，恢复正常防护下的直连，新请求不再继承较宽 Aegis 代理，沿用第 2 节原有连接配置，不生成 REJECT；保存失败不报持久成功 |
| A111 | 首次开启准备中关闭/取消、晚到 ACK、多标签页及重复点击 | 同一协调器幂等与版本控制；后续关闭使旧开启失效，状态同步；未提交前不报已生效，失败保留原选择，业务不重放 |
| A112 | 网站开关已生效后节点故障、额度耗尽、重启与渠道晋级 | 开关选择与运行状态分开，已开启不会静默改直连；选择按本渠道/Profile 恢复，调试设置与秘密不自动迁入 Beta/Release；晋级最终包分别验收 |
| A113 | 协议组发布一半时崩溃、成员缺失、乱序 ACK、同域导航与调试覆盖冲突 | 两个顶层站点成员和四种目标协议按同一代次原子发布/恢复；关闭覆盖整个组，不遗留组拥有的 WSS 代理；独立覆盖保留并如实报告限制；损坏或部分状态显示 unknown 且无旁路；旧操作不能覆盖新选择或删除独立调试规则 |
| A114 | 离线直接打开独立交互示例，无宿主/Tweak/CDN；切换四渠道和服务状态 | 自带预览控件可切换 Beta/Release/DEV/Alpha、管理页/气泡与故障状态；普通预览无调试入口，DEV/Alpha 可展开；真实产品验收独立执行，不把文档预览当作隔离证据 |
| A115 | 原有代理为 DIRECT、系统静态代理、PAC、扩展代理、企业强制代理/强制 DIRECT，以及运行时修改 | 第 2 节组合矩阵逐项有结果；关闭恢复当前原有配置、不清除配置；Aegis PROXY 不拼入原有代理或直连备用；管理限制不绕过，配置代次变化不复用错误路径 |
| A116 | 网站开启→调试精确 BLOCK→简洁界面→离线关闭；以及单目标 ALLOW/删除/撤销和乱序准备 | 网站组始终只含 DIRECT/PROXY 且无防护例外；精确 REJECT 不覆盖组选择，关闭仍可执行；单目标 ALLOW 不开启整个组；删除恢复当前继承，独立 PROXY 与组关闭并存时明确限制；旧响应不能破坏所有权 |
| A117 | 固定 REALITY/Vision 与 WS+TLS 配置，实际网络握手、受控探测、连通性和跨协议故障恢复 | 绑定实际版本/配置/网络/时间与原始记录；主/兼容能力分别验收；allowedEgressProfiles 限制生效，不将 REALITY 故障暗中回退到未获准 WS；缺少观测不报告抗 DPI PASS，不能据一次成功声称不可检测 |
| A118 | Linux 服务端长连接及客户端适用的 Vision/splice 快路径，有限额度、秒级用量与节点故障 | 连接未关闭时已有可恢复的持续计量，余额耗尽按预算终止，不等断开后才结算；所有实际快路径满足 PF04/PF09；未验证优化保持禁用或门槛 BLOCKED，保留 Vision 协议语义 |

**16. 完成判定与本次交付状态**

完整功能必须同时满足：Beta/Release 全新 Profile 无节点操作即可用当前网站代理开关，开启只选择代理、关闭恢复正常直连；实现细节只在 DEV/Alpha 调试视图暴露，Beta/Release 原生接口不可启用调试能力；底层三策略/两动作和全部转换符合冻结合同，调试 BLOCK 可离线执行、按流终止并保留恢复入口；调试联合例外与路由原子生效且已要求代理的请求故障不直连；规则、秘密和状态按渠道/Profile 隔离；自动分配后保持健康绑定、确认故障才有界切换；真实服务端字节用量、额度与固定带宽限制均可验证；两入站、两出站、临时 Profile、身份切换、撤销、恢复与复杂请求覆盖达到 G2。

以下属于必须阻止对应门槛通过的问题：跨 Profile/渠道越权、未经规则授权扩大放行、代理失败后直连、重复业务提交、无效凭据继续服务、计量/额度可被并发绕过、不可控资源增长，以及必需场景缺少证据。安全不变量不能用总体通过率抵消。

可分发还须达到 G3，并明确支持的平台、机器、并发规模与部署拓扑。通过 fixture 不等于真实 VPS 部署通过；本地通过不等于最终头 hosted 检查通过；功能通过不等于已签名、公证或发布。

**完整性复评关闭记录**

| 复评缺口 | 冻结决策位置 | 验收对应 |
|---|---|---|
| 策略和运行失败混用 | 第 4/5/9 节：唯一 mode、独立运行原因 | A91、A100 |
| 批量/单项 ALLOW 与手动 BLOCK | 第 5/6 节：优先级、保留/显式替换、操作代次 | A94、A95、A97 |
| BLOCK 目标与页面边界 | 第 4/6/9 节：所选精确目标、可信 pageToken、原生恢复入口 | A92、A93、A98 |
| 在途终止与离线执行 | 第 6 节：本地屏障、按流取消、2 秒/5 秒预算 | A92、A96、PF13 |
| 撤销/删除/DIRECT 与继承 | 第 4/6 节：六种转换、版本化恢复、时效 | A91、A99、A104 |
| 身份默认值与切换 | 第 4 节：安装访客、显式账户、退出与恢复 | A27、A32、A103 |
| 空闲资源与 MB 秒级显示 | 第 9/11 节：真实水位、舍入、无代理需求回收 | A68、A101、A102、PF08 |

修订 2 关闭“普通界面暴露策略/操作”和“Alpha 无法调试”的渠道差异：第 1/6/9/10/12 节与 A105–A112 为对应合同；上述复评中的 ALLOW/BLOCK/规则 UI 均按 DEV/Alpha 调试范围解释。

修订 3 关闭当轮 review 的两项问题：网站开关不再仅覆盖主导航 origin，同域 HTTP/HTTPS/WS/WSS 和允许端口按完整组生效（第 4/9 节、A108/A113）；交互示例改为无外部依赖的独立文档预览（A114）。协议组原子发布属于产品验收合同，预览只能演示选择和界面，不能证明真实网络路径。

修订 4 关闭第二轮复核的三项问题：第 2 节/A115 固定原有代理配置组合；第 4/9 节/A116 及示例分开网站协议组与精确调试覆盖，BLOCK 不再把组变成 REJECT；第 2/12 节基于 ccbbaf37 改为复用现有 Profile 工厂、报告路由与 CNAME 分区。主出站保持 REALITY+Vision，WS+TLS 保持兼容角色，按 A117/A118 绑定抗识别与实时计量证据；详见[出站协议与 DPI 评估](egress-dpi-assessment.zh-CN.md)。未增加新协议实现或给出真实部署的抗 DPI PASS。

V1.0 冻结修订 4 包含 118 项功能/交付验收、13 项性能指标和 4 个阶段门槛。上述行为缺口均已落实为规范与验收，不留给实现者自行选择语义。真实 VPS 容量、内核版本、RSS 上限等未有实测材料的取值仍按第 13 节绑定，相关门槛在绑定和验证前不通过。

本次完成需求规范、文档一致性核对及交互原型更新。未修改产品代码、启动代理内核、变更系统网络、导入真实节点、构建 Chromium 或部署服务；没有产生上述产品验收的 PASS 结果。后续交付报告必须引用 V1.0、修订号及冻结文件 hash，区分设计冻结、代码完成、运行验收和可分发状态。
