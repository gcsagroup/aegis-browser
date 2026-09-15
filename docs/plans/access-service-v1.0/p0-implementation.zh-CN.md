# P0 首个实现切片：原生路由计划与网站协议组完整性

日期：2026-09-14。设计：Astra high；实现：Sol xhigh；独立审查：Astra high，新上下文。

用户已授权在当前访问服务文档基础上继续开发。行为权威仍是 `spec.zh-CN.md` V1.0 修订 4 与 `freeze.json`；本文件不修改冻结行为、数量或 G0–G3 门槛。

实际实现 base 为 `b5fffc324ca9b85ec4cbc244165434f044ac57ec`，工作区 `/Volumes/ExternalSSD/repositories/aegis-browser-worktrees/access-service-p0`，分支 `codex/access-service-p0`。旧文档任务头为 `d60b5952b40e511d6f98f3f33be926dbe7ab1eb7`；其未提交文档已由主任务复制，保留用户已有差异。实现、独立审查、最终检查分别补录实际 head。

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

P0 剩余：浏览器真实 RequestOwnershipRegistry/导航入口接线、同步回调外等待、定向在途取消、NetworkContext/连接池代次、原有代理来源与企业约束检测、HTTP/SOCKS Profile 认证、渠道/安装身份、Vision 计量、完整 Chrome 构建及真实浏览器路径。当前已绑定 Chromium 151 精确 checkout，并完成下述独立 GN 目标的图接线、首次构建、运行和无操作增量构建；不创建或下载新的大型 checkout，不改固定 App。

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

## 回滚

本切片尚无运行时入口或数据迁移，回滚其代码、GN/补丁与测试入口的独立提交即可；不删除用户现有文档、凭据、Profile 或构建缓存。后续真实接入单独交付，不能用回滚规划器来清除已持久 PROXY 意图或将其静默变成 DIRECT。
