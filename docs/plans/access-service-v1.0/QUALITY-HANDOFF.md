# QUALITY-HANDOFF：W0 固定 Chromium 验证

更新：2026-09-24 18:16 UTC（#177 合并后证据核对）。负责人 Q；本页保留各候选失败和旧执行快照，最新结果见下节。W0 的选定原生及浏览器矩阵已在 #177 最终 H 通过，但不据此升级 G0 或 131 个验收主行；本轮不新增 required gate。

## #177 最终交付与适用边界

#177 的 B=`42f48b535f4ff0c302b6c4e98762fcee86495e1c`、H=`1f86a6e218c2bccebf2654c266a4d6e2ab0e2e37`、PR 测试 M=`547ed2a2f0368f9d15dde0bd481edf8184209252`（父提交 B/H、tree 与 H 相同）。2026-09-24 18:10:37 UTC 使用 squash merge 进入 develop，S=`43e4e55070d098986585034616029588a75e104d`，单父 B、tree=`47d39dbdbfe74d4bea51cca0740e5980cae84885` 与 H 相同。以下证据只支持该 H、M 或 S 各自的身份，不转用于新晋升候选。

| 验证 | 最终结果和原始回执 |
| --- | --- |
| 固定源准入 | `source-attempt21/result.json` PASS/sourceStable=true；Chromium patched HEAD=`1609c11c72e0c2e51500808b96864c37b7e4c467`、tree=`7beea934d52bd9c37c4470304cd1966260b8a951` |
| 原生与浏览器 | `native-attempt5/result.json` 17 个目标、181 项 PASS；`browser-attempt17/result.json` Chrome 56/56 PASS；`content-attempt6/result.json` Content 6/6 PASS；均为 H1f86a6e、sourceStable=true，逐目标二进制与 runtime 摘要见原始回执 |
| 本地与托管 PR | 产品树 `.artifacts/ci/local-1f86a6e-mise/report.json` full PASS/sourceStable=true；PR quality/quality-gate run `36020104115` attempt 1 SUCCESS，C++ run `36020104055` attempt 1 SUCCESS；托管质量报告绑定 B/H/M |
| 独立 Review | 同一最终 B/H/M 的 Astra/high 原始回执 `.artifacts/ci/pr177-final-independent-review.md`：CLEAR，未发现未关闭的确定 P1/P2，覆盖边界以原文为准 |
| develop 实际推送 | S 的 CI run `36039414436` attempt 1 quality/quality-gate SUCCESS、C++ run `36039414451` attempt 1 SUCCESS；推送报告 `quality-evidence-36039414436-1` 的 testedSha=S、sourceStable=true |

上述 Chromium 回执位于 `/Volumes/ExternalSSD/repositories/aegis-chromium-w0-20260924/evidence/`，本地质量及 Review 回执位于产品工作树的 `.artifacts/ci/`；它们均非 Git 提交内容，换机器须取得原始回执。原生构建使用记录中的 macOS 26.5 SDK / bundled LLD 本机参数变体。MHTML 普通分支用计数替代终端；relay watchdog/取消、完整缓存/BFCache/prerender BLOCK、性能与发布范围仍有独立覆盖缺口。故这里关闭的是 #177 已声明代码与测试证据审查，不把 W0/G0、131 个主行或其他候选判为已验收。

## 历史执行快照：冻结来源与所有权

- 初始盘点 D：`7f74e0a4e971f91d08d90536e429aba7b82cf37d`；原生执行前纳入仅 README 排版的 #176，当时候选 B=`42f48b535f4ff0c302b6c4e98762fcee86495e1c`。当时 M、S 尚未生成；最终身份见本页开头。
- 产品工作树：`/Volumes/ExternalSSD/repositories/aegis-browser-worktrees/access-w0-quality-20260924`，分支 `codex/access-w0-quality-20260924`。
- Q 新候选：`/Volumes/ExternalSSD/repositories/aegis-chromium-w0-20260924/src`；从闲置 H13 副本进行 APFS clone，仅复用构建输入。各次 source admission 和失败报告独立保存；相对输出 `out/Pr129Verification` 可增量复用构建对象，但二进制和运行结果必须重新绑定最终 H。
- Chromium 固定 `151.0.7922.77` / `ff37cfca210138f2a40b843b4a8195ab7e4fc7ff`；新 patched tree、V8、参数/二进制哈希与 sourceStable 须由新候选实际生成。
- 首轮资源核验：外盘 APFS 挂载、可写，约 350 GiB 可用；重型构建前重查。
- 其他任务：PID 64342 / PPID 63161，`evidence/pr23-c9b07b7/native-two-targets.py`，产品 H=`c9b07b72d249b5e1ac1978e11f863b2d953e668a`，source=`aegis-chromium-phase3-20260922/pr23-088fc98/src`，out=`out/Pr129Verification`；其 `.aegis-pr23-native-slot` 与 `.aegis-ci-lock` 归原任务。Q 不 kill/reset/replay，不在它运行时启动第二个重型 Ninja。以上 PID 只是观测快照，启动前重新检查。

## 已有精确证据（历史，不转用）

GitHub 回读 #162：B=`131da2fec25b783e0cc42374728e1f5ffb01cf53`，最终 H=`4670c4dd5f24db61f38f102cc60475658e63554a`，S=`ca4e1b24c750746d6e20a83fa58f1d2500791d02`，2026-09-23 19:51:06 UTC MERGED。旧 H12=`6664528…`/M=`0723b8d…` 不能当作 H13 的 M。

历史 evidence 根目录：`/Volumes/ExternalSSD/repositories/aegis-chromium-phase3-20260922/evidence/pr162-h13-4670c4d/`。本地证据不属于 Git 提交，换机器须取得原始文件。

| 报告 | 结果及准确范围 | SHA-256 |
| --- | --- | --- |
| `native-attempt1/result.json` | `PARTIAL_PASS`，16+45+35=96 tests，sourceStable=true | `c8fd0baf2bbe835d96f055f8a2d588475a619ce5175217bc16cbe681b225976f` |
| `browser-attempt1/result.json` | 冲突导航、History、Settings 各枚举/运行 1 项，exit 0，sourceStable=true；History/Settings 内层 Mocha 已观测 | 14b10b65815874fd61722e99140a4880e5cea3c8821cf3e19182e0e9e46e9898 |

browser binary SHA-256=`603a83cb2ad79f798fff517105e2e54ad2d8898cd5d512fbf3c14488b61523ef`；旧 Chromium tree=`2b924501f5eb8aeac1ce9a911f710f773fe8690d`，旧 V8 tree=`5a6be89cfa0c35d8eb6ee81aec3cb8100780f7e9`。旧参数是显式本机 SDK26.5/bundled LLD 变体，不能称产品原参数通过。

## 本轮第一候选与失败归档

第一候选 H=`cf2329a47e3e35e5e4f89f76767750758ab703f5`，tree=`a41fc24b885741bdd42659c864b0654868d52b2c`；B=`42f48b535f4ff0c302b6c4e98762fcee86495e1c`。以下结果只属于该 H；修复后新 H 必须重验。

| 证据 | 第一候选结果 |
| --- | --- |
| 本地 full quality | PASS/sourceStable=true；产品树 `.artifacts/ci/local-cf2329a/report.json` |
| 托管 PR #177 | CI run `35968346198` attempt 1，quality/quality-gate SUCCESS；报告 tested M=`1921ad40521087696b391c19d1403ee3fa38fddc`，父提交恰为 B/H，tested tree 与 H 相同；不是新 H 的 CI |
| source admission | PASS/sourceStable=true，Chromium tree=`3084075654bfdc589978b00bc5d40c0f55ee1ad1`；Q evidence `source-attempt1/result.json` |
| native attempt 1 | **FAIL/sourceStable=true**；前 10 targets 共 81 tests PASS，第 11 adapter target 首项在 TestingProfile SetUp 因 `chrome::DIR_USER_DATA`（1001）未注册而崩溃，另外 4 项 SKIPPED，后 6 targets NOT_RUN；实际 out args 在首个 runtime 前及结束后哈希相同 |
| browser attempt 1 | **FAIL/sourceStable=true**；41 项实际枚举，NoPublishedPolicyPreservesNativePath PASS；第 2 MainNavigationWithoutPolicyPreservesNativePath 的 origin==1 等待超时，后 39 项 NOT_RUN |
| navigation diagnostic 1 | 同 H 精确用例重跑 exit 1；netlog 捕获 `/resource` 外的 `/favicon.ico` GET，后者收到 HTTP 200/origin；原 fixture 对两者均计数。证据支持修观测范围，不能改成 >=1 放宽断言 |
| 独立 Review | 产品代码 Astra/high CLEAR；外部 browser driver 的 actual out args 稳定性 P2 修后同 reviewer CLEAR。代码 CLEAR 不消除上述真实失败 |

Q evidence 根：`/Volumes/ExternalSSD/repositories/aegis-chromium-w0-20260924/evidence/`。`native-attempt1/`、`browser-attempt1/` 和 `navigation-diagnostic1/` 保存命令、退出码、二进制 hash、summary 与原始日志；不要覆盖 attempt 或删除失败记录。0171 修三个 Profile unit 的 Chrome suite/任务环境，0172 将自动 favicon 与业务请求计数分开；两项均属测试设施修复，修后运行仍待证明。

## 第二候选与编译失败归档

第二候选 H=`745bf3c1d2b3f80e406311b422d94f567fd8a7dc`，tree=`fc0398a30d91d8a56319c78152aea5c1e138f10a`，B 不变。local full PASS/sourceStable=true，source admission 2 PASS/sourceStable=true，Chromium tree=`93c55d2db0a3922495cf231d027638f818e1bd8c`。托管 CI run `35970171524` attempt 1 的 quality/quality-gate SUCCESS；M=`eab204f274f4f782cc9cfb21b16ab20c7531b4dd` 的父提交精确为 B/H、tree 与 H 相同。

- `native-attempt2/result.json`：**FAIL/sourceStable=true**，前 11 targets/86 tests PASS，包含 adapter 全部 5 项，证明 bootstrap 修复已实际运行；第 12 dispatch_state unit 因测试替身 `bool* terminated_` 违反 Chromium raw_ptr 检查而编译失败，后 5 targets NOT_RUN。实际 out args 前后 hash 相同。
- `browser-attempt2/result.json`：**FAIL/sourceStable=true**，新增 favicon helper 的 `GURL::path_piece()` 不在固定 151 API 中，编译失败，0 项 runtime；不能复用第一候选的枚举/运行结果。
- 第二候选的独立代码 Review 曾给 CLEAR，实际编译暴露上述 API 错误后，同 reviewer 已明确撤回 CLEAR，修正为未通过，后续修复必须由同 reviewer 复审并实际编译运行。
- 后续补丁修测试替身非空引用与其生命周期，以及固定版本路径 API；不关闭编译检查、不放宽计数断言。第三候选 17 unit / 41 browser 仍待重验，前两轮失败保留。

## 第三候选：完成设施修复后暴露产品边界缺陷

第三候选 H=`ceb6eade5f6ddd71e9571bbd5df1367fca04dd70`，tree=`814adc044ee92ad8c410d6d4d3fa1ad6569dcb66`。local full/source admission 3 PASS/sourceStable=true；Chromium tree=`a6805f88563723b3083d101ebd7760d9cd5572b0`。定向 dispatch_state/browser_tests 编译和链接 PASS/sourceStable=true，不能当 runtime。托管 CI `35971446141` attempt 1 SUCCESS，M=`57e24c424669cfe01649dd0d502bebce0f89f7b3` 的父提交精确为 B/H、tree 一致；独立静态复审未发现 P1/P2，未替代运行验证。

- `native-attempt3` **FAIL/sourceStable=true**：前 14 targets/102 tests PASS；transport 31 tests 实际 25 PASS/6 FAIL，其中 5 项为固定 Chromium PAC 序列化不含分号后空格，1 项为 transport 错误接纳尾点 host。后两个目标在独立 `native-tail-diagnostic3` 中 store 35/runtime 9 PASS，结果是 PARTIAL_PASS，不能拼成完整门 PASS。
- `browser-attempt3` **FAIL/sourceStable=true**：41 项实际枚举，前 10 PASS（包括 favicon 修复后的导航、PREPARED/Profile 隔离、frame prefetch native/proxy）；第 11 `PrefetchWithoutEndpointFailsClosed` 得到 loaded 而非 error，后 30 NOT_RUN。失败 ASSERT 之后的 origin/proxy 计数并未执行，不能从无计数报错推断没有请求。
- `prefetch-diagnostic3` 同 H/二进制精确复现 FAIL/sourceStable=true。NetLog 的 target `/resource` 请求带 Sec-Purpose:prefetch，新建 cache entry，代理解析 DIRECT，实际 GET 获得 HTTP 200 / Content-Length 6（origin）。这是缺 endpoint 的真实直连缺陷，不是 DOM 事件格式或 cache hit。

尾点边界经独立 Astra/xhigh 只读检查：transport、请求 context 和内存规则校验需一致拒绝尾点，Store 已拒绝；不将尾点静默剥离并合并 site。固定 Chromium 的 GURL/PSL/site 及 Network Service host 匹配保留尾点。保留 factory 先查 snapshot 的顺序：无 published snapshot 的有效尾点网站仍 native；存在 snapshot 时尾点目标或 top-level-site fail-closed，包括没有匹配规则的请求。请求侧拒绝是本轮保守设计选择，规范要求统一处理但未规定唯一算法。新增真实入口回归须证明有效 DNS 正路径与发布后零 origin/proxy 增量；模型反例不替代浏览器证据。

0175–0176 修正 PAC fixture 和尾点边界，0177–0186 继续修复文档 factory、prefetch 和身份绑定；下节记录后续候选的独立结果。保留原 41 项并纳入新增回归，最终二进制的实际枚举数量必须记录。W0/G0 不因上述局部通过升级。

## 后续候选与仍待闭合的浏览器边界

- H=`1de11ad6d6f9e017cb6a25ca2a774faf1e821a3d`：local full、source admission 4 通过；定向 native 两目标 79 项通过。定向浏览器的三条真实 routing 用例仍走 DIRECT。静态定位到 RFHI 在提交前建立 document subresource factory，原 Aegis wrapper 只接受 active RFH；不能用这 79 项推断浏览器通过。
- H=`acf57e72e6c33b2cee0187091c9a5666b9b36795`：local full、source admission 5 通过。浏览器定向构建在 SDK 缺失 `usr/local/lib` 目录处链接失败，0 项 runtime。Q 将 SDK26.5 复制到自己的输出目录并补空目录后，独立 LLD 探针通过；未改系统 SDK。
- H=`79e89a07565f11345082c285b426ea0b2a2c535d`：source admission 8 与定向对象编译通过；`browser-document-diagnostic8` 实际 9 项通过、1 项失败，sourceStable=true。失败的旧 Clone 用例在 RFH 身份前置断言处停止，未触达 Clone 请求。独立预审发现 sandbox HTTP opaque origin 可跳过 wrapper、预提交 prefetch 被误中止、重建 bundle 丢失特殊 factory；此 H 未通过审查。
- H=`f8ccc94dd6ffa0bc2a2b1d1360c4d5155755fe92`：0181–0184 与 overlay 准入 9、local full 通过；`browser-attempt9` 在 GN 检查发现 Chrome browser test 引用 Content 私有头，0 项 runtime。H=`d89d1f272d7342ef55068e03f2e5424411590f5c` 改用公开 RFH API，source admission 10 通过；`browser-attempt10` 因独立预审发现非 HTTP 受限 default factory 被替换，在 Ninja 351/2316 时主动中断，0 项 runtime、sourceStable=true。
- H=`c6f14c2ed670dd2b8ed714def9caa17850758655`：0185 保留非 HTTP 原 default，0186 增加真实导航取消回归，source admission 11 通过；`browser-attempt11` 构建中主动中断，0 项 runtime、sourceStable=true。独立预审指出 0186 的 pending Clone 同步 Flush 会等待尚未绑定的对端而挂起；后续 5fd9a25 删去该 Flush。另有更重要的 P1：MHTML 子帧最终 URL 可为 HTTP，但原 default 是禁网 factory，0185 仍只凭 HTTP URL 将它重建为普通网络 factory。
- 0187 仅在 RFHI 确实创建 NetworkService default 时记录可信资格并允许 prefetch 重建；MHTML/WebUI 等原受限 default 保持原 bundle，restricted/recursive 路径在新建跨源 factory 前拒绝。新增真实 HTTP MHTML 子帧 `content_browsertests` 回归。独立复审发现初稿变量作用域编译阻塞，H=`882c354357b8e7f4e9e9948e144bd99188a57e76` 已修复；`source-attempt13` PASS/sourceStable，Chromium tree=`b97227ce6ad046a51681903d57be496b33c29bad`。`compile-0187-objects13` 的 RFHI、prefetch service、Chrome hook/Aegis factory 与 browser fixture 六对象全部编译 PASS/sourceStable，**无完整链接或 runtime**。同一 Astra/high 静态复审暂无未关闭 P1/P2；最终复审仍须绑定新 H 的实际运行证据。

以上是 H882c354 时的源码准入与待验清单，不是最终运行结论。#177 已按本页开头的最终 H 完成相应矩阵、复审与合并；台账 131 个主行与 G0 均不因此升级。

## 历史最小完成矩阵（#177 最终结果见开头）

17 个目标在本轮源代码 BUILD.gn 中均有声明。下列“历史”专指上述 H13 receipt，NOT_RUN 不断言从未在其他候选执行。第一候选失败详情见上节；下一修复候选每项目标必须实际枚举非零测试并执行，记录命令/退出码、summary、二进制哈希、sourceStable。

| unit target | H13 历史结果 | 2026-09-24 11:30 旧快照 |
| --- | --- | --- |
| `access_identity_generation_state_unittests` | NOT_RUN | NOT_RUN；缺新候选执行证据 |
| `access_proxy_selection_generation_state_unittests` | NOT_RUN | NOT_RUN；缺新候选执行证据 |
| `access_base_proxy_config_generation_state_unittests` | NOT_RUN | NOT_RUN；缺新候选执行证据 |
| `request_generation_tuple_builder_unittests` | NOT_RUN | NOT_RUN；缺新候选执行证据 |
| `browser_request_metadata_seed_unittests` | NOT_RUN | NOT_RUN；缺新候选执行证据 |
| `request_ownership_registry_unittests` | NOT_RUN | NOT_RUN；缺新候选执行证据 |
| `policy_publication_ack_tracker_unittests` | NOT_RUN | NOT_RUN；缺新候选执行证据 |
| `request_dispatch_gate_unittests` | NOT_RUN | NOT_RUN；缺新候选执行证据 |
| `aegis_access_unittests` | PASS，45 tests | NOT_RUN；缺新候选执行证据 |
| `access_service_coordinator_unittests` | PASS，16 tests | NOT_RUN；缺新候选执行证据 |
| `access_browser_request_adapter_unittests` | NOT_RUN | NOT_RUN；缺新候选执行证据 |
| `access_request_dispatch_state_unittests` | NOT_RUN | NOT_RUN；缺新候选执行证据 |
| `access_identity_generation_source_unittests` | NOT_RUN | NOT_RUN；缺新候选执行证据 |
| `access_proxy_selection_generation_source_unittests` | NOT_RUN | NOT_RUN；缺新候选执行证据 |
| `access_network_context_transport_unittests` | NOT_RUN | NOT_RUN；缺新候选执行证据 |
| `access_rule_store_unittests` | PASS，35 tests | NOT_RUN；缺新候选执行证据 |
| `access_published_request_runtime_unittests` | NOT_RUN | NOT_RUN；缺新候选执行证据 |

第三候选 Access browser suite 包含 38 个 `AccessProxyingURLLoaderFactoryBrowserTest` 源码定义和 3 个 `AccessLoadingPredictorPrefetchBrowserTest`，共 41 项；后续候选又新增回归，最终数量以新二进制的实际非零枚举为准。历史 clone 只含 3/17 个 unit 二进制，另 14 个需要构建。

| 必需入口 | 源码映射 / 范围 | 2026-09-24 11:30 旧快照 |
| --- | --- | --- |
| 导航 / redirect | `MainNavigation*`、`SubframeNavigation*`、`SameHostRedirectReevaluatesThroughProxy`、`RedirectToUnselectedHostFailsClosed` | 缺新候选执行证据 |
| PREPARED / Profile 隔离 | `MainNavigationConsumesPreparedSnapshotBeforeCommit`、`MainNavigationRoutingIsolatedAcrossProfiles` | 缺新候选执行证据，必须精确非零枚举 |
| Worker / SharedWorker / Service Worker | `WorkerMainResource*`、`WorkerSubresource*`、`SharedWorkerSubresource*`、`ServiceWorkerProcessScript*`、`ServiceWorkerSubresource*`；browser-process SW 脚本仅验证当前原生边界 | 缺新候选执行证据；不扩大为 SW update 全覆盖 |
| missing endpoint / BLOCK | `ProxyPolicyWithoutSelectedEndpointFailsClosed`、各 `WithoutEndpointFailsClosed`、`BlockBarrierTerminatesInFlightProxyRequest` | 缺新候选执行证据；不代表完整缓存/BFCache/prerender BLOCK |
| frame prefetch | `PrefetchWithoutPolicyPreservesNativePath`、`PrefetchUsesSelectedProxy`、`PrefetchWithoutEndpointFailsClosed`，由页面 `<link rel=prefetch>` 触发 | 缺新候选执行证据 |
| browser-process helper | `BrowserProcessPrefetch*` 5 项，直接调用包装 helper | 缺新候选执行证据；不替代真实 LoadingPredictor 入口 |
| LoadingPredictor 真实入口 | 0148 有 `PrefetchManagerTest.AegisProfileUsesGatedFactoryWhenNetworkContextPrefetchEnabled` 模式选择 unit；本轮新增真实 `PrefetchManager::Start` 派发 regression | 本轮新增 `AccessLoadingPredictorPrefetchBrowserTest` 三项源码（native/proxy/missing endpoint），实际通过 `PrefetchManager::Start`；**缺执行证据**，不覆盖预测生成或导航触发 |

资源占用独立于上述源码/执行缺口：主机重启后旧 Hc9 Ninja 已消失，旧报告 `TESTING`、sourceStable=null 与双锁保留为 `INTERRUPTED_UNKNOWN`。协调任务随后取得旧 owner 明确交接，下一重型构建时段归 Q；启动前仍须重查实际进程/容量，只管理 Q 的候选锁。

## 历史执行计划（#177 完成前快照）

1. 刷新远端 B/D 与 main/upstream 身份，建立外盘隔离工作树；原始 inventory、PR 和进程快照在产品树 `.artifacts/w0-quality-20260924/`。
2. `mise exec -- python -B scripts/dev/chromium_access_gtests_test.py`：17 tests，exit 0；只证明 runner 回归，不是 Chromium unit/browser 结果。
3. LoadingPredictor regression 源码与健康观测检查就绪后冻结最终 H，做 ordered patches + exact overlay 准入；保存新 Chromium/V8 tree、参数、工具、源码输入摘要。
4. 资源释放后 Q 取得自己的 candidate lock；按 unit 小批次串行执行 coordinator/store/runtime/transport/dispatch/tracker 及其余已声明目标，再 build/list/run 真实 browser 入口。每次实际非零枚举，禁重试掩盖失败，首次失败按设施/产品分类并报告协调者。
5. 最终 H 运行 local full quality、独立 Astra/high Review、托管 PR B/H/M + attempt + check source；合并由协调者按实时授权/门槛决定。未闭环项明确保留，不升级 131 个 A/PF 主行。

主会话只能确认模型家族 GPT-6，精确后缀/effort 未由运行时暴露；有界测试实现阶段显式选 `gpt-6-sol` / `xhigh`。该快照时最终独立 Review 尚未执行；#177 最终回执见本页开头。
