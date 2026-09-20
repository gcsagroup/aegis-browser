# P0 首个实现切片：原生路由计划与网站协议组完整性

日期：2026-09-14。设计：Astra high；实现：Sol xhigh；独立审查：Astra high，新上下文。

用户已授权在当前访问服务文档基础上继续开发。行为权威仍是 `spec.zh-CN.md` V1.0 修订 4 与 `freeze.json`；本文件不修改冻结行为、数量或 G0–G3 门槛。

**当前入口（2026-09-20）：**从最新主线继续实施请读[当前开发计划](development-plan.zh-CN.md)；精确 SHA、PR、CI 与固定 Chromium 构建状态见[开发交接](handoff-20260920.zh-CN.md)。以下 2026-09-18 快照和后续切片章节是按各自记录日期保存的历史证据，不能作为今日 `develop` 的补丁编号、generation 数量、下一任务或门槛结论。今日 G0 仍为 UNVERIFIED。

## 2026-09-18 历史进度快照（已过期）

本节记录当日工程状态。后文各切片也保留其当时证据；分支、PR、补丁编号与测试状态不能用于当前进度判断。

当日快照：

- Fork `quinn521/aegis-browser` 的默认分支已经是 `develop`。当前 `develop` 为 `488544b89b43cd22fc1476aec2f44ef50275bce4`；个人 `main` 为 `013d5ba639b177a599a3036f24c82e07026568d3`。
- 当前 `develop` 的 Access patch 序列已经落到：`0121` RequestOwnershipRegistry、`0122` targeted cancellation、`0123` dispatch BLOCK barrier、`0124` ownership contract refactor、`0125` request dispatch gate、`0126` browser-owned request metadata adapter。旧快照中的 0124–0128 编号不再对应当前主线。
- `PublishedRequestRuntime` 尚未进入当前 `develop`，因此下一实现号从 `0127` 开始。旧本地堆叠中的 published runtime、committed policy generation 与 NetworkContext epoch 只保留为历史实验依据，不能作为当前主线已合入能力。
- `GenerationTuple` 五个字段已经存在于合同类型中，但当前合入主线没有完成任何一个可用于真实请求派发的 production lifecycle source。AccessRuleStore 可以持久化 `committed_policy_generation`，但该值仍由未来发布者传入；NetworkContext transport 会消费 generation tuple，但尚未拥有真实 `network_epoch` 生命周期。因此当前合入状态按 **0/5 production generation source** 计算。
- 当前已具备路由规划、可信 policy context、原子规则存储、fail-closed ProxyInfo 适配、Profile/StoragePartition NetworkContext 传输、localhost proxy 回归基础、请求所有权/定向取消、BLOCK barrier、统一 dispatch gate 与 browser-owned metadata 边界。它们仍未组成真实 Chromium 请求派发闭环。
- 本次状态刷新没有重新执行完整 Chromium build/runtime；历史 standalone/native、局部 Chromium 对象和 hosted CI 证据继续保持各自原边界。G0 仍未通过。

当日主要问题与风险（其解决状态已变化）：

1. **Published request runtime 尚未进入主线。** 需要以当前 `develop` 为基线实现 `0127`，把 browser-owned metadata、policy evaluation、route plan、dispatch gate 与只读 published snapshot 组合为单一 fail-closed runtime；在 generation source 未完成前，runtime 必须拒绝真实发送授权。
2. **Generation source 当前为 0/5。** 按 production ownership 依次补齐 committed policy generation、NetworkContext epoch、identity generation、selection generation、base proxy config generation。每项必须由实际生命周期事件推进，不能使用常量、时间戳或测试 tuple 代替。
3. **真实 Chromium vertical slice 仍未打通。** 需要把 runtime 接入一个最小真实请求入口，证明 exact-host policy → real URLLoader → 当前 Profile/StoragePartition NetworkContext → localhost HTTP proxy fixture 的闭环，并覆盖 stale generation、关闭后恢复原生 proxy、跨 Profile/partition 隔离和 fail-closed。
4. **请求面仍需逐步扩展。** 在最小闭环稳定后，再覆盖 Navigation、subresource、Worker/Service Worker、prefetch/preconnect、WebSocket、HTTP/2、HTTP/3、BFCache 等，并补真实 termination handle 与执行点 ACK/预算。
5. **用户产品入口仍未落地。** `SetSiteProxy`、可信 WebUI/工具栏开关、状态反馈及持久 site group 协调仍待实现；当前成果仍属于浏览器原生访问/代理底座。
6. **真实代理 runtime 仍有较大缺口。** Xray 生命周期、HTTP/SOCKS Profile 认证、REALITY/WS 真实链路、节点/租约、账户与额度、持续计量、故障恢复、连接池代次和企业/原有代理组合仍需按冻结规范实现和验证；Vision/splice 计量风险及 A117/A118 仍未关闭。
7. **完整 Chromium runtime/G0 仍未通过。** 最终仍需固定源码/补丁/工具链完成 GTest、Chrome build、真实浏览器代理流量和冻结 G0 项。

当日建议顺序（仅供追溯，现行顺序见[开发计划](development-plan.zh-CN.md)）：

1. 以当前 `develop@488544b89b43cd22fc1476aec2f44ef50275bce4` 实现 `0127 PublishedRequestRuntime`，保持 0/5 generation 时 fail closed。
2. 依次实现真实 generation source：committed policy generation → NetworkContext epoch → identity generation → selection generation → base proxy config generation；完成 5/5 后才允许 runtime 授权真实代理派发。
3. 打通最小真实 Chromium vertical slice：exact host → real URLLoader → localhost HTTP proxy fixture，并验证 REQUIRE_PROXY 无 DIRECT fallback、stale generation 拒绝、OFF 恢复原生配置以及 Profile/StoragePartition 隔离。
4. 扩展真实请求面和 termination/ACK，再实现 `SetSiteProxy`、可信 WebUI/工具栏入口与持久 site group 协调。
5. 接入 Xray、认证、账户/额度、持续计量、故障恢复和兼容协议，优先独立验证 Vision/splice 的在途计量合同。
6. 修复或选择兼容的 Chromium macOS toolchain，执行固定候选的完整 GTest、Chrome build、真实浏览器链路和 G0 验收。

## 范围与事实

首切片属于 P0 的可独立执行原生原型基础，不代表 P0 完成。交付生产语言 C++ 的纯路由决策函数、网站协议组完整性验证、无秘密黄金向量和实际原生单元执行结果。TypeScript 仅作共享合同/向量消费，不在网络热路径运行。

当前 main 已有 `AegisServiceFactory`，使用 `ProfileSelections::BuildForRegularAndIncognito()`；不重复迁移单例。开工时尚未找到可用的固定 Chromium 构建绑定，首轮因此使用本机 Apple clang++ 21 独立编译本切片的标准 C++ 实现；该首轮证据不证明 Chromium ABI、GN 集成或真实网络行为。后续固定 checkout 绑定与验证见“首切片实现与当前证据”。

开工时已实际核验外盘 APFS 挂载、工作区可写、约 697 GiB 可用；该容量仅是 2026-09-14 开工记录，不作为长期常量。

## 模块边界

- 新增 `apps/browser/overlay/components/aegis_access/` 中的原生类型、`AccessRoutePlanner`、`ValidateSiteProxyRuleGroup` 和 GN 目标。完整 `AccessPolicyEvaluator` 以后组合规则匹配与本路由规划器；当前不要把缺少 PSL/规则优先级的函数命名或报告为完整匹配器。
- `AccessRoutePlanner` 接收已经匹配的有效策略与已发布运行快照，输出声明式路由计划；无磁盘、网络、进程启动、跨进程调用或等待，无 Chromium browser 反向依赖。
- `ValidateSiteProxyRuleGroup` 检查已构建协议组的结构与一致性，返回三态选择；不负责主导航身份认证、IDNA、PSL、URL 解析、生成持久规则或写数据库。
- 新增原生测试运行脚本及仓库测试入口。脚本以任务临时目录编译生产 `.cc`，运行真实可执行文件，失败返回非零；不得只做源码字符串检查。保留可在固定 Chromium 环境运行的 GN 单元目标。
- 本轮不新增运行时 Pref/WebUI 入口，不改变 Bundle ID、用户目录、系统代理，不启动 Xray，不使用 `.local` 中的凭据，不改冻结文件。

## 具体逻辑接口

下面是语言无关的接口合同，C++ 使用强类型 enum/struct 和显式错误结果；可按仓库风格命名。未知枚举与不完整输入均不得落入成功分支。

`ValidateSiteProxyRuleGroup(expectedOwner, group, members) -> GroupValidation`

- group：非空 group ID、精确 canonicalHost、所有权键、HTTP/HTTPS 两个 canonical SchemefulSite、revision、lastOperationSequence、两个不同 memberRuleIds。
- 每个 member：独立 rule ID、相同所有权键、所属 group ID/revision、顶层站点、精确 host、schemes={http,https,ws,wss}、ports=all_browser_permitted、includeSubdomains=false、mode=direct|proxy、protectionOverride=none、操作序列；PROXY 引用同一本 Profile 逻辑代理组，DIRECT 不引用代理组。
- 所有权键至少包含 channel namespace、Profile token、StoragePartition policy-domain token；从 native 服务/存储上下文注入，不能接受网页自报 Profile。
- 必须恰好有 HTTP/HTTPS 两个成员，与组记录一一对应，所有版本/序列/所有权一致。不把 eTLD+1 当 exact host，不把 WS/WSS 新造为独立顶层站点。
- `expectedOwner` 必须来自原生服务/存储上下文，与组记录及成员分别核对；不能只让不可信存储字段彼此相等。返回 `presence=absent|present`、`selection=enabled|disabled|unknown`、错误原因；缺组固定为 `absent+unknown+missing_group`，由后续完整匹配器在已发布快照中求继承，不能直接解释为关闭。已有组缺成员、模式混杂、版本不一致、额外成员/重复成员等一律 `present+unknown`，不能作为关闭。
- 本函数只比较可信适配器提供的规范化标识，不自行用字符串截取域名推导 SchemefulSite。规范化/归属适配器未实现是明确缺口。

`PlanAccessRoute(input) -> RoutePlan`

- input 包含有效模式 direct/proxy/reject、`requireProxyIntent`、上下文所有权、快照所有权、快照就绪状态、请求与已发布快照的版本元组、不可覆盖安全限制、适用企业强制限制、运行状态、已登记入口引用（可缺失）。
- 版本元组至少包含 policyGeneration、identityGeneration、selectionGeneration、networkEpoch、baseProxyConfigGeneration；用于本原型的相等比较，不在这里推进版本。
- 入口引用为本 Profile/分区授权的 opaque registration ID、逻辑 proxy group ID 与相同所有权/版本信息，不是可任意传入的 proxy URL、用户名或密码；规划器要求其逻辑组与有效 PROXY 策略相同。真实性由未来原生登记器建立，本纯函数只检查一致性，typed 字段本身仍不是授权证明。
- 调用者还需明确有效策略来源是否依赖站点归属；无可靠站点归属不得消费站点规则或授予防护例外。可靠且明确适用的 Profile 全局策略可独立匹配。首切片不建立 RequestOwnershipRegistry，不把 typed 字段本身视为真实性证明。
- 输出 `action=preserve_native|use_registered_proxy|wait|deny|fail`、原有效模式、机器可读原因、当前版本、可选入口引用；没有修改持久 mode 的输出。原因至少区分 missing_snapshot、stale_generation、ownership_mismatch、invalid_policy、policy_conflict、managed_restriction、protection_restriction、proxy_unavailable、quota_exhausted、signed_out。
- `preserve_native` 代表让 Chromium 使用当前原生解析结果，不代表构造 DIRECT 结果。规划器不接收或重新排序系统/扩展/PAC 的代理列表。
- 纯函数的 wait 只是结果状态，不阻塞线程。真正可暂停派发入口、等待预算、确认和取消属于后续 P0 原生接线。

## 决策不变量

1. 所有权错误、损坏策略/协议组、快照缺失/恢复中或版本失效均等待或失败，不能因错误而默认 DIRECT。可靠的本地拒绝可以不依赖该快照；正常“无规则”只能由 `published+absent` 表示。存在 REQUIRE_PROXY 意图时缺少有效可代理策略不能输出 preserve_native。
2. 不可覆盖安全限制先拒绝；REJECT 本地 deny，不要求内核/入口已启动，不访问任何代理。
3. DIRECT 与无 Aegis 选择使用当前原生配置；本函数不重写系统/扩展/PAC、不保存开启时的旧配置副本。明确 DIRECT 不要求代理运行时 ready。
4. 适用企业强制限制下，PROXY 保留 mode 并停止业务，报告 managed；DIRECT 仍服从原生强制配置。不能链到企业代理，也不能绕过强制 DIRECT。
5. PROXY 仅在有效同所有权/版本入口 ready 时返回 use_registered_proxy。preparing/recovering 可 wait，其余故障返回对应原因；断网、额度耗尽、退出身份等均不返回 preserve_native。
6. use_registered_proxy 只返回唯一登记入口，没有 native/DIRECT fallback；入口 stale/missing 不降级。
7. 组 mode 只允许 DIRECT/PROXY，任何例外、REJECT、子域扩展、精确端口子集或成员局部编辑都不能通过组校验。调试目标行属于独立记录，本函数不把它并入组。
8. 不在本切片实现 HTTP 方法重放。规划器不按 GET/POST/PATCH 改路由；后续适配器必须对全部首次发送应用同一结果，已发送业务不得自动重放。

错误优先级需在实现中固定并测试，防止一个请求因不同遍历顺序得到不同结果。建议先输入/所有权与快照有效性，再安全限制、REJECT、DIRECT、企业 PROXY 限制、PROXY 运行及入口。对缺快照时可可靠确认的本地阻止允许提前 deny；无论分支先后都不授予直连或代理权限。

## 有价值验收用例

原生测试直接编译并调用生产实现；至少覆盖下列矩阵，给出每项实际结果。

- 无 Aegis 选择/DIRECT 在原生 DIRECT、系统代理/PAC 两类概念场景均输出 preserve_native，原生配置未被拷贝或重排；运行时 offline/signed_out 不阻止明确 DIRECT。
- REJECT 在内核 stopped、入口缺失时仍 deny，返回结果不含代理引用。
- PROXY ready 使用唯一有效入口；原生配置存在时同样只输出该入口，不产生备用。
- PROXY preparing/recovering、offline、quota_exhausted、signed_out、入口缺失分别保持模式并 wait/fail。
- 企业强制 proxy/direct/禁止自定义三类，对 PROXY 均 managed 停止；对应 DIRECT 仍 preserve_native。
- channel、Profile、StoragePartition 任一不匹配；入口所有权错误；版本元组每个字段分别落后/不一致；均不能获得可发送路线。
- REQUIRE_PROXY + missing snapshot、未恢复组、有效策略缺失/矛盾；均不 preserve_native。
- 不可靠站点归属不能使用站点策略；明确适用 Profile 全局策略可走对应模式，不把活动页面身份借给后台请求。
- 有效 DIRECT/PROXY 两成员组得到 disabled/enabled；HTTP/HTTPS 成员顺序调换结果一致。
- 缺成员、额外/重复成员、host/所有权/站点不一致、混合 mode、revision/operationSequence 漂移、protectionOverride、REJECT、includeSubdomains、scheme 缺失/重复、端口子集、PROXY 组引用不一致逐项得到 unknown。
- 输入和快照调用前后保持不变；相同输入重复结果一致；无效 enum 不落入默认许可路径。

向量放入仓库共享合同区域，全部使用 `.example`、虚构 token/入口 ID，不包含可用凭据。若以 JSON 为唯一向量源，测试构建器可将验证过的 JSON 生成 C++ fixture，再运行原生实现；不要为了运行测试引入新的生产 JSON 解析依赖。TS 与 C++ 对照只是合同证据，不是 Chromium 运行证据。

## 接线、验证与证据边界

本轮需在现有 `test:scripts` / `quality:fast` 中接入原生测试命令；缺编译器要明确失败或由显式单独检查报告 BLOCKED，不输出 PASS。新组件提供 GN source_set 与适当测试目标。遵循 overlay + 顺序补丁交付模型：可为新增组件生成只添加新路径的 format-patch 并验证等价，不假造已在固定 Chromium 完整重放。不要运行会重写 0001 或清理现有状态的 seed 脚本。

必须运行相关原生测试、仓库要求的 `quality:fast`、差异检查。最终补录 compiler、命令、实际 head、测试结果和未执行项。独立 Astra high review 审查最终实现和测试；Sol 修复后复审。CI、合并、main 门槛由主任务按实际可用入口和授权分别处理。

P0 剩余：RequestOwnershipRegistry 与 dispatch barrier 的浏览器/导航真实适配及入口接线、同步回调外等待、真实 URLLoader/导航/HTTP2/HTTP3 终止句柄、BLOCK 发布后的执行点 ACK/2 秒预算、NetworkContext/连接池代次、原有代理来源与企业约束检测、HTTP/SOCKS Profile 认证、渠道/安装身份、Vision 计量、完整 Chrome 构建及真实浏览器路径。当前已绑定 Chromium 151 精确 checkout，并完成下述独立 GN 目标的图接线、首次构建、运行和无操作增量构建；不创建或下载新的大型 checkout，不改固定 App。

本切片可报告 native_unit=PASS（实际执行后）、合同子项通过；对应 A76/A108/A113/A115/A116 等只记录所覆盖的纯决策子场景，整行仍 partial/NOT_RUN，G0 仍 NOT_RUN 或明确环境 BLOCKED。P0 不因本切片通过而结束，运行/性能/部署/分发状态不提升。

## 首切片实现与当前证据

提交前工作树已实现 `components/aegis_access` 的纯 C++ `PlanAccessRoute` 和 `ValidateSiteProxyRuleGroup`。规划器只接收已经求得的策略、浏览器上下文所有权、发布快照、代次、限制、运行状态和 opaque 登记引用；不会接收、复制或重排 Chromium 原有代理列表。网站组校验按固定错误类别检查整个成员集，因此交换 HTTP/HTTPS 成员或交换双损坏所在成员不会改变错误原因。缺组与损坏组分别保持 `absent+unknown` 和 `present+unknown`。

共享黄金向量位于 `apps/browser/overlay/components/aegis_access/testdata/route_planner_vectors.json`。TypeScript 测试读取并检查其结构与名称唯一性；Python 生成器把同一文件转成 C++ fixture，GN GTest 目标与独立 clang runner 使用同一合同套件。向量只含 `.example` token、逻辑组和入口 ID，无代理地址、用户名、密码或可用凭据；未从 `/.local/access-service/` 读取数据。

2026-09-14 在提交前最终审查修正后执行：

- `CXX=clang++ bash apps/browser/scripts/test-aegis-access-native.sh`：PASS。Apple clang++ 21 实际编译 `access_route_planner.cc`、`site_proxy_rule_group.cc` 和原生 runner，再执行 42 条路由黄金向量及网站组完整性回归，共完成 487 次断言检查；该数字是检查次数，不是 487 个独立测试。
- `pnpm --filter @gcsa-aegis/core exec vitest run src/access/route-planner-vectors.test.ts`（pnpm 9.15.0）：1 个测试 PASS，证明 TypeScript 可读取共享向量并完成结构检查；没有 TypeScript 路由实现，因此不将它报告为 TS/C++ 行为对照。
- `0114-feat-aegis-add-access-route-planning-contract.patch` 在临时 Git 仓库从空基线应用成功，只有新增 `components/aegis_access/` 路径，且与 overlay 逐字一致；本次核验的 patch SHA-256 为 `256d72ba00b4399f2bba0bc04043998cda4dbb5afa8d0022555966e0cbd95346`。

仓库 `test:scripts` 已接入原生 runner 和 GN 接线回归；GN 提供独立 `//components/aegis_access:aegis_access_unittests` 与向量生成 action。首次在已应用 114+2 补丁的 Chromium 151 精确 checkout 生成 `out/AegisLocalDev` 时，`gn gen` 成功生成 31,692 个目标，但该独立 BUILD 文件没有从根图可达，`gn desc` 返回 `matches no targets`。修复使用 Chromium 根 `BUILD.gn` 明确提供的 `root_extra_deps`：仅在产品开发配置 `apps/browser/args/aegis.gn` 把该 test 接入 test-only `gn_all`，未加入 release args，也未让 `chrome` 依赖测试可执行文件。`0114` 仍只添加 11 个 `components/aegis_access/` 路径，源码补丁和 `series` 字节未变；新增接线属于仓库产品 GN args。

本次验证的已打补丁 Chromium 源码身份为 commit `9727517827d72fe07f0237b181188457ad1de264`、tree `e7cd873e136fd1258cfe0c0fd4f6536077f3a9e3`；嵌套 V8 身份为 commit `7d57cd02dbfbd275f757206ac54ca63310e54fa6`、tree `5a6be89cfa0c35d8eb6ee81aec3cb8100780f7e9`。

修复后实际证据：

- `gn gen out/AegisLocalDev`：PASS，生成 31,696 个目标、读取 4,830 个文件；`root_extra_deps` 的当前值为 `//components/aegis_access:aegis_access_unittests`。
- `gn desc out/AegisLocalDev //components/aegis_access:aegis_access_unittests outputs`：返回 `//out/AegisLocalDev/aegis_access_unittests`，确认目标已在正常 `aegis.gn` 图中可发现。
- `gn path out/AegisLocalDev //chrome:chrome //components/aegis_access:aegis_access_unittests`：`No non-data paths found`，确认生产 Chrome 目标没有链接该测试。
- `bash apps/browser/scripts/aegis-access-gn-wiring_test.sh` 与原生 487 次断言检查均 PASS；`aegis.gn` SHA-256 为 `4daf1f62b105d8b7cff80a62cef8a0ae2742973b654173de040f13c0d6b83886`，`series` 仍为 `fbc6c99de7eb2c0e2e4abda2179af4e9671fce1dc1cc79659475e8292a4fb1c0`，`0114` 仍为 `256d72ba00b4399f2bba0bc04043998cda4dbb5afa8d0022555966e0cbd95346`。

独立目标构建最初被系统 Python 3.9 的工具链环境阻止；改用 hooks 固定的 CPython 3.11.9 后，Ninja 首次构建 exit 0，末尾为 `[3405/3405] LINK ./aegis_access_unittests`。执行 `out/AegisLocalDev/aegis_access_unittests` exit 0：实际运行 `AccessRoutePlannerTest.SharedRoutePlannerContract` 与 `SiteProxyRuleGroupTest.CompleteAtomicGroupContract` 两个 GTest，输出 `SUCCESS: all tests passed.`；随后同目标增量构建 exit 0，输出 `ninja: no work to do.`。这些结果把本切片证据提升为固定 Chromium 151 GN 独立目标 build/runtime PASS。Network Service 接线、完整 Chrome 构建和浏览器网络用例仍未执行，因此 G0、A76/A108/A113/A115/A116 整行和真实网络仍不能报告 PASS。最终仓库提交 SHA、全仓质量结果及独立审查结论由主任务在停止修改后补录。

## 后续切片：浏览器所有权适配边界与完整规则匹配

`request_policy_context.{h,cc}` 新增只能由原生适配器构造的不可变 `RequestPolicyContext`。适配器校验 channel/Profile/StoragePartition 所有权键、request ID 与 document/pending-navigation/profile-only 三种互斥形态；使用固定 Chromium 的 GURL、`SchemefulSite` 与包含私有规则的 Public Suffix List 生成精确 canonical host、有效端口、顶层网站和 registrable domain。query、fragment、正文、Cookie 与凭据不进入结果。该类型阻止匹配器直接消费网页提交的字符串字段，但尚未把 Browser/Renderer/Network Service 的真实 request ID、document token 或终止句柄接入 RequestOwnershipRegistry，因此不能单独声称端到端可信归属完成。

`access_policy_evaluator.{h,cc}` 对已发布只读规则快照执行无 I/O 匹配：先验证快照、所有权、canonical host/顶层网站、唯一 rule ID/规范化规则键、排序去重后的 scheme/port 集合和 mode/代理组/防护例外形状；再固定按本站优先于 Profile、精确 host 优先于显式后缀、后缀 DNS 标签最长优先、scheme/port 严格集合包含关系更具体的顺序选择。显式后缀必须处于公有及私有 PSL 允许的 registrable domain 内，不能用 `appspot.com` 等私有后缀跨租户扩张。多个不可比较的最具体候选、重复键、非规范存储或所有权漂移均返回 conflict/invalid，不随机选择或退回 DIRECT；缺规则保持 absent/inherit。profile-only 归属不借用活动页身份，跳过本站规则后仍可匹配明确属于同一 Profile/StoragePartition 的全局规则。

共享黄金向量位于 `testdata/policy_matcher_vectors.json`。Python 生成器把 14 个规范化/PSL/优先级/冲突用例生成到 GN C++ fixture；TypeScript 测试读取同一 JSON 并验证结构与名称唯一性。2026-09-14 在已应用 114+2 补丁、Chromium `151.0.7922.77` 的 checkout 上执行：

- 首次引入 `//net` 依赖时直接 Ninja 先因系统 Python 3.9 无法解析工具脚本的联合类型语法而失败；改为 checkout 已有 CPython 3.11.9 后继续构建成功。这是工具链环境失败，不是产品测试失败。
- `buildtools/mac/gn gen out/AegisLocalDev`：PASS，生成 31,697 个目标、读取 4,830 个文件。
- `third_party/ninja/ninja -C out/AegisLocalDev aegis_access_unittests`：PASS；初版 Chromium 源码提交为 `0bb6cfc2e7`，独立审查修正后以等价压缩提交 `83ff75c84f7425b79212c30425b329fe60e0ecd3` 重新生成 0115 顺序补丁。
- `out/AegisLocalDev/aegis_access_unittests --gtest_color=no`：21 个 GTest PASS，包含原 42 条路由向量/网站组合同、5 组请求规范化测试、14 条共享匹配向量及补充边界回归。
- `packages/core/node_modules/.bin/vitest run packages/core/src/access/policy-matcher-vectors.test.ts packages/core/src/access/route-planner-vectors.test.ts`：2 文件、2 测试 PASS。首次 pnpm 包装命令被 pnpm 10 的 `verify-deps-before-run=install` 默认行为尝试更新依赖，并因未批准 esbuild build script 中止；未批准脚本，也未保留它对 workspace 配置的建议修改。随后直接调用已安装的 Vitest 二进制确认定向用例。
- `0115-feat-aegis-add-trusted-policy-context-matching.patch` 从 0114 后的父提交应用成功，应用结果与 overlay 逐文件一致；审查修正后的补丁 SHA-256 为 `cdcd077b4e1b53b81b315ca2fa9b7bd768508fce8e24495c93fa45d2eeaab4c8`。
- `CHROMIUM_ROOT=/Volumes/ExternalSSD/repositories/aegis-chromium-151 bash apps/browser/scripts/status.sh` 确认 115 个顶层补丁的稳定 patch-id、checkout HEAD `83ff75c84f7425b79212c30425b329fe60e0ecd3`、overlay 等价及 2 个 V8 补丁均匹配；整体命令仍 exit 1，因为开发目录缺少完整 `GCSA Aegis.app` 可执行文件，Release/Android 也未构建。该状态不提升完整浏览器门槛。

仓库全量快速门禁随后以 `pnpm_config_verify_deps_before_run=false pnpm run quality:fast` 执行 PASS。该显式配置只关闭运行脚本前的隐式依赖安装，不跳过 lint、typecheck、test、browser scripts、Agent UI、Android target/UI、model relay、仓库合同或 build：core 共 28 个文件、170 个测试 PASS；browser 原生 runner 完成 487 次断言检查；GN 接线、脚本 fixture、Android 目标 38 项、Android UI 13 项、model relay 22 项、合同检查和两段 tsup 构建均通过。工作树没有修改 `package.json`、`pnpm-lock.yaml` 或 `pnpm-workspace.yaml`。

独立 Astra high review 在个人 Fork PR #3 的 `a3d2fb0f36bd2c01f21e8b61235feb8f46681082` 上隔离复现两个阻塞：根 host 同时命中精确规则和 `includeSubdomains=true` 后缀规则时，旧实现按请求字符串相等误把后缀规则标成 exact；未知 `RequestAttributionKind` 整数值会穿过无 `default` 的 switch 并生成 context。修复把 exact 定义绑定到规则类型 `includeSubdomains=false`，并对未知枚举明确返回 `invalid_attribution` 且无 context；同一 GTest 补充根域名下后缀 selector 更窄/相同以及正反规则排列的回归，互斥 metadata 和异常枚举均检查无 context。修复后的固定 Chromium 目标重新编译 4 个对象并链接成功，21 个 GTest 全部 PASS；0115 也已从 0114 父提交重新应用并与 overlay 逐文件一致。原 `a3d2fb0` 保留，仓库修复使用后续独立提交，供同一 reviewer 在新 HEAD 复审。

这些结果仅证明固定 Chromium API 上的规范化与纯匹配决策可编译、可运行，以及仓库快速门禁通过。PR #3 尚需修复 HEAD 的独立复审与 hosted CI；Network Service 派发、等待/取消、连接复用、真实 HTTP/WS、Xray、企业策略、性能及 DPI 均未执行，G0 与 A76/A108/A113/A115/A116/A117/A118 整行仍不是 PASS。

## 0117：首个 `ProxyInfo` 网络适配切片

2026-09-16 在 `origin/develop` 基线继续实现网络侧最小切片。新增 `access_proxy_route_adapter.{h,cc}`，把已经完成验证的 `RoutePlan` 应用到 Chromium `net::ProxyInfo`，但尚未把策略发布/RequestOwnershipRegistry 通过 Mojo 接入真实 Network Service delegate。

本切片固定三条行为：`kPreserveNative` 完全不修改 Chromium 已有代理解析结果；`kUseRegisteredProxy` 只接受与 RoutePlan 的 registration/group/owner/generation 全部一致的 numeric loopback HTTP 登记入口，并把代理列表替换为唯一该入口；`kWait/kDeny/kFail` 会返回 `kMustAbort`，要求更高层在网络发送前中止，同时清空代理候选作为二次 no-DIRECT 保护。伪造、远程、缺端口或未知 transport 的登记入口同样 fail closed。opaque registration id 不被解释成 host/port，真实地址必须来自独立可信登记状态；SOCKS5 保留到后续完整验收切片。

新增 `AccessProxyRouteAdapterTest` 覆盖原生配置保持、矛盾的 `kPreserveNative+kProxy` fail closed、单一 `127.0.0.1` HTTP 代理、失败态 `kMustAbort` 与去除 DIRECT、无效/不可信入口 fail closed，以及 `::1` / `[::1]` 两种 Chromium 接受的 IPv6 loopback HTTP 形态。固定 Chromium 151 `gn gen out/AegisLocalDev` 在临时补齐 0116 overlay 后成功生成 31,700 个目标；完整 Ninja build 被当前主机 Xcode 27 SDK 与 Chromium bundled lld/TAPI 不兼容阻塞，失败发生在 libc++/Rust host tool 链接阶段。为隔离产品代码，随后直接执行 Ninja 为 0117 生成的两条 clang C++ 编译命令，`access_proxy_route_adapter.cc` 与 `access_proxy_route_adapter_unittest.cc` 均 exit 0。临时同步到 Chromium checkout 的 0116/0117 文件已恢复清理，未把验证副本留在固定源码树。

该结果只把“RoutePlan → Chromium ProxyInfo”提升到固定 Chromium API 编译通过，不代表真实浏览器请求已经经过 localhost proxy。下一步仍需建立 Profile/StoragePartition 绑定的 Network Service 传输合同，把可信 request context、published snapshot、runtime registration 送到对应 NetworkContext，并对真实 HTTP/HTTPS 请求验证代理命中、OFF 保留原生配置、代理失效不直连。G0 继续保持未通过。 Chromium 151 的 `HttpStreamFactory::JobController` 对空 `ProxyInfo` 明确返回 `ERR_NO_SUPPORTED_PROXIES`，因此清空代理列表不会隐式回落 DIRECT；不过 `kMustAbort` 仍要求上层在发送前主动终止，避免把网络栈错误码当成策略控制面。最终 `0117` patch 从当前组件基线重放后与 overlay 四个文件逐字一致；Codacy review 后把安全校验拆成独立 helper 并补齐 bracketed IPv6 回归，更新后的 SHA-256 为 `fbf5ad0c9bbd7a845f541c2865defc735a19f0dc0a0eaf805f74bbbcaf431bc4`。随后使用 Chromium 151 Ninja 生成的实际 clang 命令重新编译最终 production/test 两个 0117 对象，均 exit 0；仓库 `quality:fast` 也在固定 Node 22.23.1 / pnpm 9.15.0 依赖安装后完整 PASS，包括 28 个 core 测试文件、170 个测试、Access native 487 checks、浏览器脚本/Agent UI/本地模型/仓库合同及 core build。

## 0118：Profile / StoragePartition NetworkContext 传输切片

2026-09-16 在已合并的 0117 基线继续加入 `AccessNetworkContextTransport`。该对象按 Profile 生命周期挂载，并以浏览器拥有的 `relative_partition_path` 分隔 StoragePartition；`ProfileNetworkContextService` 在构造对应 `NetworkContextParams` 时安装一个初始 inert 的 `CustomProxyConfig` 更新通道。Aegis 只在该 NetworkContext 尚未存在 custom-proxy config、更新 receiver 或 connection observer 时接管，避免覆盖其他 Chromium 功能的代理所有权。

本切片只发布规范化 exact host 选择。选中的 HTTP/HTTPS 请求由 Chromium `NetworkServiceProxyDelegate` 覆写为 0117 已校验的唯一 numeric-loopback HTTP endpoint；未选择 host、子域名和 OFF 状态让 custom config 得到 DIRECT，从而 delegate 不覆盖 Chromium 原生代理结果。POST 等首次非幂等发送允许沿同一已选择入口；单一入口即使处于 proxy retry bad map 中也不会获得 DIRECT/native 备用。发布入口必须与当前 Profile + StoragePartition 的运行时 ownership key 完全一致，跨 Profile owner、非规范 host、重复 host 或另一个 custom-proxy owner 均拒绝。

最终 `AccessNetworkContextTransportTest` 覆盖 OFF 保留原生代理、HTTP/HTTPS exact-host 命中、其他 host/子域名不命中、POST、bad-proxy no-DIRECT、清除选择恢复原生、StoragePartition 隔离、跨 Profile ownership 拒绝、已有 config/receiver/observer 不被覆盖及非规范 host 拒绝。固定 Chromium 151 的 production transport 对象和最终 unittest 对象均使用实际 Ninja clang 命令编译通过；unittest 曾被 `-Werror` 捕获一个未使用常量并已修复。`ProfileNetworkContextService` 精确对象验证持续被该 checkout 缺失的既有生成物阻挡；逐步补齐 Mojo/buildflag 后，`server_certificate_database.pb.h` 的生成需要运行 checkout 自带 `protoc`，而它因当前 Xcode 27 SDK 与 Chromium bundled lld/TAPI 已知不兼容导致 `libc++_chrome.dylib` 无法生成/加载。因此该项记录为环境 BLOCKED，不报告 Profile 对象 PASS，也不把该 host-tool 链接错误归因于 0118。完整 GTest runtime 同样尚未报告 PASS。最终 `0118` patch 从 0117 后父状态重放并与 overlay/net integration 六个文件逐字一致，SHA-256 为 `c9b2230ea879c2fc6acd146d760ebf1cec20c38652b6057a2ad6d4c3caf9e811`。

该切片仍不是端到端代理验收：尚未用真实浏览器 URLLoader/socket 对 localhost fixture 完成 HTTP/HTTPS 往返，也没有把 RequestOwnershipRegistry、published snapshot 和 runtime registration 以每请求可信上下文送进 Network Service；Xray、SOCKS5、WS、认证、计量和连接池代次仍在后续切片。G0 继续保持未通过。下一 PR 应优先做真实 localhost fixture + 浏览器请求闭环，并验证代理不可达时实际请求失败而不是直连。

## 0119：真实 localhost Proxy NetworkService 验收切片

2026-09-16 在已合并的 0118 基线上增加 `AccessLocalProxyAcceptanceTest`，不改变生产路由语义，只把 0117/0118 已冻结的单一 numeric-loopback HTTP proxy 配置送入真实 Chromium Network Service / URLLoader / socket 路径。测试使用 `EmbeddedTestServer` 同时建立 HTTP origin、HTTPS origin 与本机 HTTP proxy；`target.example` 只在测试进程的 `MockHostResolver` 中映射到 `127.0.0.1`，避免 localhost implicit bypass 掩盖代理选择，同时确保一旦发生 DIRECT fallback，仍能实际命中存活的 origin 并被测试发现。

四个验收用例分别固定：OFF 时 HTTP 请求走原生 direct origin 且 proxy 未收到请求；选中 HTTP 时请求实际抵达 localhost proxy 而 origin 不被访问；选中 HTTPS 时 Network Service 对 localhost HTTP proxy 建立 CONNECT 隧道并抵达 HTTPS origin；选中 proxy 停止后，在 origin 仍存活且域名仍可解析的条件下请求必须失败，origin 计数保持 0，从行为上防止静默 DIRECT fallback。该测试复用 `ApplyRoutePlanToProxyInfo` 生成与 0118 相同的单一 proxy list，并设置 exact-host `reverse_bypass` custom config；0118 自身仍负责 Profile/StoragePartition ownership 与配置发布边界，两层测试职责不混合。

固定 Chromium 151 `gn gen out/AegisLocalDev` 成功生成 31,703 个目标、读取 4,831 个文件。完整测试目标首次尝试被 checkout 缺失的既有 `aegis_libtorrent/.../signal_error_code.cpp` 阻断；把验收下沉到独立 `aegis_access_unittests` 后，完整链接又在既有 Xcode 27 SDK 与 Chromium bundled lld/TAPI 不兼容处失败，无法生成 `libc++_chrome.dylib`，因此四个 GTest runtime 当前记录为环境 BLOCKED，不能报告 PASS。为隔离 0119 源码本身，随后使用 Ninja 为最终测试生成的实际 clang `-Werror` 命令编译 `access_local_proxy_acceptance_unittest.cc`；补齐 9 个缺失的 Mojo/buildflag 生成输入后，第 10 次对象编译 exit 0。最终 0119 patch 只包含 components 测试 BUILD 与验收源码，SHA-256 为 `23b073253e12e854a709cb3570fdbf873e232f9c8388187af05ce25a87dbd87d`。

因此 0119 把真实 HTTP/HTTPS/fail-closed socket 行为固化为可执行 Chromium 回归，但本机环境尚未提供该二进制的 runtime PASS；G0 继续保持未通过。后续若修复/切换可兼容的 Chromium macOS toolchain，应优先运行这四个用例并把 runtime 结果绑定到精确 patch/source SHA；之后再继续 RequestOwnershipRegistry、每请求可信上下文、Xray/SOCKS5/WS/认证/计量及连接池代次。

## 0120：Access C++ GoogleTest 回归加固

2026-09-16 在 0119 基线上只增强测试，不修改生产路由实现。继续复用 Chromium 已内置的 GoogleTest、`EmbeddedTestServer`、`MockHostResolver` 与 Network Service test support，不新增 Catch2、Boost.Test 等第三方测试框架或新的供应链依赖。

`AccessProxyRouteAdapterTest` 新增 `kNone` 原生代理保持、缺失/空 registration identity、proxy group / Profile owner / StoragePartition owner / generation tuple 不匹配以及空 `ProxyInfo` 指针回归，所有不可信 endpoint 继续要求清空代理候选并 fail closed。`AccessNetworkContextTransportTest` 新增跨 partition/非法 channel ownership、绝对路径/父目录引用/超长 partition key、空/超量/重复/非规范 host 发布拒绝，并验证失败发布不会覆盖已经生效的可信选择。`AccessLocalProxyAcceptanceTest` 增加选中配置下未选 host 仍走 native direct，以及 HTTPS 选中 proxy 停止后 origin 仍存活但请求必须失败的 no-DIRECT 回归。

固定 Chromium 151 checkout 的完整 Ninja 图仍会先被既有缺失 `third_party/aegis_libtorrent/.../signal_error_code.cpp` 阻断，因此不能把该全局依赖错误解释成 0120 测试失败。绕开无关全局依赖后，使用 Ninja 为最终三个测试对象生成的精确 clang `-Werror` 命令直接编译 `access_proxy_route_adapter_unittest.cc`、`access_local_proxy_acceptance_unittest.cc` 与 `access_network_context_transport_unittest.cc`，三者均 exit 0。完整 GTest 二进制 runtime 仍受既有 checkout/toolchain 环境限制，未报告 PASS。最终 0120 patch SHA-256 为 `9af49a1e18a0fbceb763f46fa81a81b0154d577de1ff036dd9b2002c994bca6c`。

0120 的作用是提高 0117–0119 的单元/回归保护密度，不改变 G0 状态，也不把编译通过冒充真实浏览器运行通过。后续 toolchain 环境可完整链接时，应优先执行全部 `aegis_access_unittests` 与 `access_network_context_transport_unittests`，再继续 RequestOwnershipRegistry、每请求可信上下文及后续代理 transport。

## 0121：有界 RequestOwnershipRegistry 核心与终止句柄合同

2026-09-16 在 0120 基线上新增纯 C++ `RequestOwnershipRegistry` 核心状态机，并把通用 `RequestScheme` 提升到 Access 路由类型。Registry 只接受已经规范化的 browser-owned record：request ID、channel/Profile/StoragePartition owner、完整 generation tuple、document 或 pending-navigation token、可靠顶层站点、exact host、scheme/port。`RequestPolicyContext::ToOwnershipRecord()` 是现有 Chromium 规范化边界到 Registry record 的生产桥；Registry 自身不解析 URL，也不把 renderer/page 自报字符串升级为可信归属。

本切片固定 `new → dispatched → streaming → completed/cancelled` 的最小生命周期。登记容量显式有界；无效记录、重复 request ID、跨 Profile/StoragePartition owner、过时代次、非法状态跃迁和缺失 termination handle 均 fail closed，失败操作不替换、不消费已有可信记录。对 dispatched/streaming 请求取消时，Registry 在调用外部 `RequestTerminationHandle::Terminate()` 前先删除本地 entry，因此重入或迟到回调只能看到 `not_found`，不能二次取消/完成同一请求。普通完成只回收 entry，不误调用终止句柄；尚未派发的 new 请求可本地取消而无需伪造外部 handle。

测试随 feat 同步进入源码：共享 contract 同时提供 unit 与 regression 两组，standalone C++20 runner 直接编译生产 Registry 并实际执行；初次执行在仓库固定 ripgrep 15.2.0 前置下为 `PASS: aegis_access native unit (541 checks)`，其中新增 54 条检查覆盖注册/查询/dispatch/stream/complete、Profile-only 不借页面身份，以及容量溢出、重复 ID、不可信 owner、stale generation、非法 lifecycle、缺 handle、跨 Profile/StoragePartition、reentrant cancel、重复 cancel 和 late completion 等回归。GN 另提供独立 `//components/aegis_access:request_ownership_registry_unittests`，避免 Registry 的基础运行证据只能依赖 0119 后较重的 Network Service 测试目标；顺序补丁为 `0121-feat-aegis-add-request-ownership-registry.patch`，当前 SHA-256 为 `e86fe5b6013fc7ef580fd62aad0af2c3e8377653895b72d992c1f8ac27cdf478`。

证据边界保持不变：本切片尚未把真实 Browser/Navigation/URLLoader request ID 与 document token、具体 URLLoader/stream cancellation handle 接入 Registry，也没有实现按站点扫描并终止 HTTP/2/HTTP/3 共享连接中的匹配 stream；这些属于下一浏览器适配/定向取消 feat。541-check standalone PASS 证明 Registry 状态机与回归合同实际运行，不代表 Chromium Network Service runtime、完整 Chrome 或 G0 已通过。

## 0122：精确页面目标的定向在途取消核心

2026-09-16 在 0121 Registry 基线上新增 `CancelMatchingPageTarget`。取消选择器只接受 browser-owned 的 channel/Profile/StoragePartition owner、互斥的 document 或 pending-navigation token、规范化 top-level site，以及 exact host/scheme/port。只有 `site_ownership_reliable=true` 且上述作用域全部精确匹配的请求才进入批次；Profile-only/无法唯一归属的后台请求不借当前页面身份，同一站点的其他 document、其他 Profile/StoragePartition、其他 host/scheme/port 也不被误杀。

该接口有意**不把 generation tuple 放入取消选择器**。冻结 BLOCK 合同要求新 policyGeneration 发布后仍终止此前已派发的命中在途请求，且 identityGeneration 对本地 BLOCK 只用于诊断；若要求旧请求与新 BLOCK 的 generation 相等，会把正应终止的旧 generation 请求漏掉。单请求 `Lookup/Cancel` 仍保持 0121 的严格 generation 校验，只有这个 page-scoped BLOCK 批量路径按冻结语义跨 generation 匹配。

批次执行先验证 selector 和所有命中 entry，再把全部命中请求一次性移出 Registry，最后才调用外部 `RequestTerminationHandle`；因此第一个终止回调发生时，同批其他命中 request ID 也已经不可见，避免重入/迟到回调观察或操作半取消批次。`kNew` 尚未派发请求只从 Registry 移除，不伪造外部终止；dispatched/streaming 请求各自调用已登记 handle 一次，重复同一 selector 返回空成功批次而不会二次终止。

本 feat 同步增加独立 unit 与 regression contract，并由 standalone runner 与 Chromium `request_ownership_registry_unittests` 共用。focused standalone C++20 真实执行为 `PASS: aegis_access native unit (605 checks)`，较 0121 增加 64 条检查，覆盖跨 policy/identity/network generation 的命中取消、new/dispatched/streaming 结果、pending navigation、重复批次，以及其他 document/Profile/partition/background/host/scheme/port/top-level-site 隔离、无效 selector fail-closed、完整批次先删除后回调和 document/pending attribution 分离。顺序补丁为 `0122-feat-aegis-add-targeted-request-cancellation.patch`，当前 SHA-256 为 `80d825016ca65f53a80edacdc867e128a7a511c6f0d12670c2517f9bd7d2ab4b`。

证据边界：0122 完成 Registry 层的精确选择、批量原子移除和终止句柄调用合同，但仍未把真实 Browser/Navigation/URLLoader/下载/媒体/SSE/ws/wss/HTTP2/HTTP3 stream handle 接到 Registry，也没有安装 BLOCK 的新请求 dispatch barrier 或 2 秒协调预算。因此不能把 605-check standalone PASS 报告为真实浏览器在途取消或 G0 PASS；下一 feat 应把这些 browser-owned handle/派发入口接到 0121/0122 已冻结的 Registry API。

## 0123：browser-owned 新请求 dispatch BLOCK barrier 核心

2026-09-16 在 0122 精确定向取消基线上新增纯 C++ `RequestDispatchBarrierRegistry`，直接复用 `RequestCancellationSelector` 作为 browser-owned 页面目标作用域。协调层可在收到 BLOCK 操作的同一任务内先调用 `InstallBlockBarrier`，无需等待数据库、远端服务、代理准备或在途取消 ACK；后续 `EvaluateRequest` 对 exact owner + document/pending token + top-level site + host/scheme/port 命中返回 `kBlock`，对其他标签页、Profile、StoragePartition、站点、host/scheme/port 及 profile-only/background 请求保持 `kAllow`。输入 record 非法时返回 `kInvalidRequest+kBlock`，不把 malformed controlled request 当成放行。

Barrier 使用 browser-owned `operation_id + operation_sequence` 管理同一 scope 的版本。相同 operation 精确重装是幂等；更高 sequence 原子替换旧 barrier；更低/相同但不同 operation 的 install 返回 stale，不覆盖新状态。释放必须同时匹配 exact selector、operation id 和 sequence；旧 ACK、迟到撤销或错误 sequence 只能返回 `kStaleOperation`，不会清除较新的 BLOCK。Barrier 匹配有意不读取 RequestOwnershipRecord 的 generation tuple，因此发布 G+1 BLOCK 后，G/G-1 以及新 generation 的命中请求都会继续被本地屏障拒绝。

失败/超时保持 barrier 不需要额外“失败转移”：Registry 只有精确 `ReleaseBlockBarrier` 才能删除屏障。上层持久化失败、策略发布失败、在途取消未确认或 2 秒 ACK 超时时不调用精确 release，屏障自然保持；只有版本化撤销/解除 BLOCK 的 owning operation 才能释放。这一层不自行实现磁盘事务、计时器或 renderer 字符串归属推导。

本 feat 随生产代码加入独立 unit 与 regression contract，并继续由 standalone runner 与 Chromium `request_ownership_registry_unittests` 共用。focused standalone C++20 首轮真实执行为 `PASS: aegis_access native unit (646 checks)`，较 0122 增加 41 条检查，覆盖安装/查询/精确释放、跨所有 generation 的同步阻断、pending navigation、nonmatch 放行、幂等重装、容量上限、非法 barrier/request fail-closed、新 operation 替换、stale install/release 不覆盖/不清除新 barrier，以及 document/Profile/partition/background/site/host/scheme/port 隔离。顺序补丁为 `0123-feat-aegis-add-request-dispatch-block-barriers.patch`，当前 SHA-256 为 `520bdc12077e1fcc7044548fa8659a7787ee814e1c30e035def29462d6514efb`。

证据边界：0123 完成的是可独立执行的 BLOCK dispatch barrier 状态机，还未把 barrier 真正接入 `AegisNetThrottle::WillStartRequest`、Navigation/预取/preconnect/Service Worker/BFCache 等 Chromium 派发入口，也未实现执行点 ACK 与 2 秒/5 秒预算。现有 `AegisNetThrottle` 的 `request_initiator`/source-site 仍不能被当作 Access Service 的可信 page ownership；真实接线必须使用 browser-owned document/navigation metadata。646-check PASS 不代表真实浏览器 BLOCK 入口或 G0 PASS。

2026-09-18 的 `main → develop` 同步在 0123 后保留上游 review 修复补丁 `0124-refactor-aegis-request-ownership-contracts.patch`，其 SHA-256 为 `58f8136d79e293c154587240f2a67b048e186911408ab2e4b730dff19a8b5dd0`。为保持补丁序列名称唯一且按应用顺序递增，下述两个逻辑切片的运输补丁分别重编号为 0125 和 0126；章节编号仍保留原始实现记录。0121–0126 已从 0120 后的 overlay 基线按 `series` 顺序 clean replay，最终树与合并后的 overlay 一致。

## 0124：fail-closed dispatch gate 编排

2026-09-16 在 0123 barrier 状态机之上新增纯 C++ `EvaluateAndRegisterRequestForDispatch`。该 gate 固定一个关键顺序：先用 `RequestDispatchBarrierRegistry` 对完整 browser-owned record 做同步 BLOCK 判定，只有明确 `kAllow` 后才允许写入 `RequestOwnershipRegistry`；命中 barrier、record 非法、依赖缺失、重复 request ID 或 Registry 容量耗尽均返回 `kBlock`，不存在“登记失败但仍继续派发”的回退路径。gate 自身不从 renderer/page 字符串构造 owner、document 或 generation，只消费 0115/0121 已冻结的规范化 record。

本 feat 与生产代码同步增加独立 unit 与 regression contract，并提供 `//components/aegis_access:request_dispatch_gate_unittests`。standalone C++20 初轮真实执行为 `PASS: aegis_access native unit (670 checks)`，较 0123 增加 24 条检查；unit 覆盖正常 allow+register、exact BLOCK、malformed record、pending-navigation barrier 与缺失依赖 fail-closed，regression 固定跨 generation barrier 不可绕过、跨 Profile/StoragePartition 不误伤、重复 ID/容量失败不得放行，以及 BLOCK 判定必须先于 Registry mutation。当前顺序补丁为 `0125-feat-aegis-enforce-request-dispatch-gate.patch`，SHA-256 为 `c63e2a782f597b656d39591fe75915f44877e30319e0c0ecd17c82139d4c9738`。

证据边界继续收紧：0124 已把“barrier 判定 → ownership 登记 → allow”组合成一个不可跳步的可执行核心，但尚未把它挂到 Chromium `ChromeContentBrowserClient::CreateURLLoaderThrottles` 或其他真实派发入口。固定 Chromium 151 的 browser-side API 已核对可提供 BrowserContext、WebContents、FrameTreeNodeId、navigation id，并可由 RenderFrameHost 取得不可变关联的 StoragePartition；下一 feat 才负责把这些 browser-owned 元数据转换为 `BrowserOwnedRequestMetadata` 和 generation，再调用本 gate。worker/prefetch/preconnect/Service Worker/BFCache 覆盖仍未完成，670-check PASS 不代表真实浏览器 BLOCK runtime 或 G0 PASS。

## 0125：browser-owned request metadata 适配边界

2026-09-16 在 0124 dispatch gate 之上新增两层适配。可独立执行的 `browser_request_metadata_seed` 负责冻结产品渠道映射以及 document / pending-navigation / profile-only 三种互斥归属选择；Chromium 层 `AccessBrowserRequestAdapter` 只从 browser process 持有的 `Profile`、`WebContents`、`RenderFrameHost`、`StoragePartition` 与 `navigation_id` 提取可信字段，再复用 0118 `AccessNetworkContextTransport::OwnerForPartition` 生成 Profile/partition owner。它不会读取 renderer `request_initiator`/source-site，不会为缺失 transport 偷建 runtime，也不会在 worker/Service Worker 缺少可信 WebContents/frame 时借用活动标签页身份。

导航归属固定优先于旧 committed document：存在 browser `navigation_id` 时必须同时存在 `FrameTreeNodeId`，生成 pending-navigation token，并清空旧 document/top-site；只有非导航请求才允许使用 `AegisService::DocumentIdForWebContents` 与 primary main-frame `SchemefulSite`。StoragePartition 通过 request frame 的不可变关联取得，并按与 `ProfileNetworkContextService` 相同的 profile-path 相对路径规则映射到 0118 owner；跨 BrowserContext、partition 路径逃逸、缺 frame/partition/transport 均明确失败。Chromium UNKNOWN build 映射到 DEV，不得冒充 RELEASE。

本 feat 同时增加独立 unit 与 regression contract，并提供 `//components/aegis_access:browser_request_metadata_seed_unittests`。standalone C++20 真实执行为 `PASS: aegis_access native unit (689 checks)`，较 0124 增加 19 条检查；unit 覆盖渠道映射、document/pending/profile-only、非法 owner/request、缺 top-site 与 orphan site，regression 固定“新 navigation 不继承旧 document/site”、UNKNOWN 不升级 RELEASE、跨 Profile/StoragePartition token 不被重写、非法 channel fail-closed，以及 background/worker-like 输入只能保持 profile-only。当前顺序补丁 `0126-feat-aegis-add-browser-owned-request-metadata-adapter.patch` 已从 0124 refactor 与 0125 dispatch gate 之后的精确父状态生成并 clean-apply，SHA-256 为 `1091b3b1a141e5d99a3469e4afc730fc25383d547b7a66dc2b5ac4f3072ae4db`。

证据边界：689-check PASS 是 metadata seed 的真实执行，不等价于 Chrome glue runtime。固定 Chromium 151 checkout 当前没有生成可复用的 Aegis adapter Ninja compile command，且该 checkout 保持 dirty/read-only，因此本 feat 不报告 adapter object compile PASS，也不修改该 checkout 来制造证据。0125 还没有向 metadata 注入真实发布 `GenerationTuple`，也没有调用 0124 gate 或挂入 `CreateURLLoaderThrottles`；这些必须作为后续独立 feat 完成并继续同时交付 unit + regression。PrefetchContainer、preconnect、Service Worker/BFCache 与真实 URLLoader cancellation handle 仍未覆盖，G0 状态不提升。

## 0126：Profile/partition published generation 请求 runtime

2026-09-16 在 0125 browser-owned metadata 边界之上新增纯 C++ `PublishedRequestRuntime`，把“可信 owner 已发布哪一个 `GenerationTuple`”与 0121–0124 的 ownership/barrier/gate 状态组合为一个有界 runtime。browser coordinator 必须显式按 `OwnershipKey` 发布完整 generation tuple；runtime 不自行递增、猜测或从 renderer 字段恢复 generation。未发布 owner、generation 任一字段为零、请求 tuple 与当前发布值不一致、publication 容量耗尽以及后续 Registry 登记失败均保持 `kBlock`。

本地 BLOCK 语义继续优先：`EvaluateAndRegisterForDispatch` 先查询 0123 barrier，命中时即使该 owner 尚无 published generation 也直接 BLOCK，满足离线/缺快照时本地拒绝仍可执行的冻结合同；未命中 BLOCK 后才要求 exact published tuple，再调用 0124 gate。重新发布 generation 只影响后续新派发，不会删除旧 generation 的在途 Registry entry；这样 G→G+1 发布后，新旧在途请求仍可由 0122 page-target cancellation 跨 generation 一次性终止。`RemovePublishedGenerations` 也只阻止未来新派发，不把已登记请求静默当作完成。

本 feat 与生产代码同步增加独立 unit 与 regression contract，并提供 `//components/aegis_access:published_request_runtime_unittests`。standalone C++20 首轮真实执行为 `PASS: aegis_access native unit (726 checks)`，较 0125 增加 37 条检查；unit 覆盖 publish/read/replace/remove、exact generation allow、stale generation block 及旧在途保留；regression 固定非法 owner/incomplete tuple 不改状态、publication 容量不覆盖旧 owner、跨 Profile/StoragePartition publication 不串用、本地 BLOCK 在无 generation 时仍优先、generation 更新后新旧在途并存且能一次跨代取消，以及 unpublish 不删除旧 active request。顺序补丁 `0126-feat-aegis-add-published-request-runtime.patch` 已从 0125 精确父状态生成并 clean-apply，SHA-256 为 `e4cca8c129881c1502d8dcd2c409d377e88f204b53fd3d2f6717dfe2340ee080`。

证据边界：0126 冻结的是 generation publication 与 Registry/Barrier/Gate 的可执行组合，不是 generation 的真实来源。它尚未由 `AegisService`/NetworkContext 策略发布链维护，也未把 0125 `BrowserOwnedRequestMetadata` 经 `CanonicalizeBrowserOwnedRequest` 转为 record 后挂到 Chromium `CreateURLLoaderThrottles`。下一 feat 应在 browser-owned Profile runtime 中绑定真实发布源，再将 metadata + request URL + 当前 generation 送入 0126；在该来源完成前禁止使用常量 generation 或测试 tuple 冒充运行态。726-check PASS 也不代表真实 URLLoader dispatch、termination handle 或 G0 PASS。

## 0127：绑定真实 committed policy generation 来源

2026-09-16 在 0126 published runtime 之上新增 `RequestGenerationSources`，把五个 generation 分量拆成按同一 `OwnershipKey` 独立观察的真实来源。每个分量只能从非零值单调前进；重复值幂等、较小值 stale 拒绝、跨 Profile/StoragePartition owner 拒绝、未知 source enum 明确 `kInvalidSource` 且不能误写 policy slot。只有 policy / identity / selection / network epoch / base-proxy-config 五项都实际观察到后才生成完整 `GenerationTuple`；任一项缺失或被 invalidate 都回到 incomplete，不提供默认值、时间戳或常量补位。

本 feat 首先绑定已经存在的真实来源：`AccessPolicyGenerationSource` 只读取 `AccessRuleStore::ReadCommittedSnapshot`，再通过 `AdaptMatcherSnapshot` 取得 `committed_policy_generation` 与真实 owner。缺记录返回 missing；存在 PREPARED journal 时返回 recovery-required；corrupt/incompatible/invalid snapshot 与 I/O 错误均不产生 observation。只有 committed snapshot 的非零 generation 才形成 `kPolicy` observation。新增 Chromium GTest 源码固定两条集成回归：PREPARED/recovery 阶段不得提前发布下一代 generation；supersede 后恢复到原 committed generation。固定 Chromium checkout 当前保持 dirty/read-only，因此这些新增 SQLite GTest 本轮不报告 runtime PASS。

可独立执行的 production core 与同 PR unit/regression 已真实运行：standalone C++20 为 `PASS: aegis_access native unit (759 checks)`，较 0126 增加 33 条检查，覆盖五分量逐步观察、exact tuple 构造、invalidate、invalid owner、跨 owner、stale/zero、非法 source enum、四项不齐不得拼 tuple，以及只有 policy 来源时绝不能发明 identity/selection/network/base-proxy。顺序补丁 `0127-feat-aegis-bind-committed-policy-generation-source.patch` 已从 0126 精确父状态生成并 clean-apply，SHA-256 为 `a77419794a28df86f524271532f113b018b4d92a10da96cb3febfeae65662dbc`。

证据边界：0127 只把 **policy generation** 绑定到真实生产状态；`identity_generation`、`selection_generation`、`network_epoch` 与 `base_proxy_config_generation` 仍无已验证生产计数器，因此完整 tuple 继续保持 incomplete，0126 runtime 不能因此开始授权真实 URLLoader 派发。后续每一个 generation 来源必须作为独立 feat 从其真实生命周期事件产生，并继续同时交付可执行 unit + regression；在五项真实来源齐全前禁止用常量、时间戳或测试 tuple 冒充运行态。759-check PASS 不代表 AccessRuleStore Chromium GTest、真实 browser dispatch 或 G0 PASS。

## 0128：绑定真实 NetworkContext network epoch 来源

2026-09-16 在 0127 generation-source 合同上新增纯 C++ `NetworkContextEpochState`，并把真实生产事件绑定到 0118 的 `AccessNetworkContextTransport`。Chromium 151 源码已只读核对：`StoragePartitionImpl::InitNetworkContext()` 每次创建 NetworkContext 都进入 `ProfileNetworkContextService::ConfigureNetworkContextParams`，随后调用 `AccessNetworkContextTransport::ConfigureNetworkContext`；Network Service 重建同样重新走 `InitNetworkContext()`。因此本 feat 把“同一 Profile + StoragePartition 成功配置一个新的 NetworkContext”定义为 `network_epoch` 的唯一推进事件，而不是把物理网络变化、时间戳或代理选择更新冒充 epoch。

每个 partition 初始 epoch 为 0 且不得发布 observation；首次成功配置变为 1，后续 NetworkContext 重建逐次严格 +1。配置参数已被其他 custom-proxy owner 占用、partition 非法、初始配置构造失败或 epoch 已到 `uint64_t` 上限时均不提交新 epoch；上限返回 overflow，禁止回绕到 0。状态按 Profile-owned transport 与 partition key 分离，跨 Profile/StoragePartition 不共用计数。`PublishProxySelection` / `ClearProxySelection` 明确不推进 network epoch，因为节点/选择变化属于后续 `selection_generation` 的独立真实来源。对外只生成 `RequestGenerationSourceKind::kNetworkEpoch` observation，不补造 identity / selection / base-proxy-config。

本 feat 同时交付独立 unit 与 regression contract，并接入 `//components/aegis_access:network_context_epoch_unittests` 和 standalone C++20 runner。实际执行为 `PASS: aegis_access native unit (774 checks)`，较 0127 增加 15 条检查，覆盖首次/重建递增、零态不发布、精确 owner/kind/value、空状态拒绝、溢出不回绕、非法 owner 拒绝、partition 独立，以及 network observation 只能填充 network slot、完整 tuple 仍保持 incomplete。Chromium `AccessNetworkContextTransportTest` 另新增源码级回归，固定成功重建递增、Profile/partition 隔离、失败 Configure 不递增，以及 proxy selection/clear 不得改变 network epoch。固定 Chromium checkout 仍保持 dirty/read-only 且完整 GTest runtime 受既有 macOS toolchain 阻塞，因此这些新增 Chromium GTest 本轮不报告 runtime PASS。顺序补丁为 `0128-feat-aegis-bind-network-context-epoch-source.patch`，最终生成 SHA-256 为 `0205b4107885059ce03c8ab497df612ae09e24da39a53367c6e40310720d9ce4`。

证据边界：到 0128 为止，五元组中的 **policy generation** 与 **network epoch** 已绑定真实生产生命周期；`identity_generation`、`selection_generation`、`base_proxy_config_generation` 仍无已验证生产来源，因此完整 `GenerationTuple` 继续保持 incomplete，0126 runtime 仍不能据此授权真实 URLLoader 派发。下一 generation 来源仍必须作为独立 feat，从真实状态迁移产生并携带 unit + regression；G0 状态不提升。

## 回滚

本切片尚无运行时入口或数据迁移，回滚其代码、GN/补丁与测试入口的独立提交即可；不删除用户现有文档、凭据、Profile 或构建缓存。后续真实接入单独交付，不能用回滚规划器来清除已持久 PROXY 意图或将其静默变成 DIRECT。
