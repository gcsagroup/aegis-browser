# JavaScript 防护 Phase 3 研究验证边界（2026-08-28）

## 结论

Phase 3 已把脚本风险研究从纯合成样本推进到一组可追溯的公开源码 pilot，补强了候选冻结后的本地盲测执行链，并完成固定真实站点协议下的 V8 bytecode shadow A/B 实跑。现有结果能证明研究工具链会识别部分挖矿能力代码，也能证明默认关闭的 shadow 在两个固定公开站点的有界导航窗口内产生 renderer 观察信号；它仍不能识别“恶意意图”，也没有形成函数级阻断或通用恶意 JavaScript 防护。

产品结论仍是 **No-Go**。公开 pilot 只有 13 个样本，3 个 mining-capable 样本只命中 1 个，召回率为 `0.333333`，而且没有独立持有方或 sealed test。真实站点 shadow 的最终 v5 报告已通过本轮固定协议的 **research-only 门**：4/4 运行完成、两个 A/B pair 均为 `no-observed-breakage`、OFF 信号为 0、ON 信号分别为 84 和 9；但报告明确 `releaseEligible=false`、`exactDocumentAttribution=false`。精确 App UI 也已绑定到同一诊断构建并留存截图。公开 pilot 继续是 `operator-blinded-local`，运行时能力继续是 observe-only / fail-open；这些局部通过不授权页面阻断、产品发布或“通用恶意 JS 防护”宣传。

## 当前权威证据

- 当前权威公开 pilot 是 **v5**：`.artifacts/research/script-risk/public-pilot-blind-score-v5-2026-08-28.json`。文件 SHA-256 为 `73249a1cd158e97cb89f14a810ceab71cc290602831daa164d8174a6686e8b1d`，其规范化报告摘要 `reportDigestSha256` 为 `0580b90d7a2cc83e3e381cdda3cb0dfe0cd03e81fa0463733995706c9b8366ab`。
- 公开 pilot 的 v1–v4 只保留为历史调试与协议演进记录，不与公开 pilot v5 合并计算，也不得替代 v5 作为当前研究结论。
- v5 的候选、未标注输入、预测和揭盲标签依次保存在 `.research-data/script-risk/phase3-blind-v1-2026-08-28/candidate-v5.json`、`unlabelled-v5.json`、`predictions-v5.json` 和 `labels-v5.json`。这些文件位于 Git 忽略的本地研究数据目录，不是可分发产品资产。
- 公开数据取得回执为 `.artifacts/research/script-risk/public-pilot-acquisition-2026-08-28.json`，SHA-256 为 `af1bd44156031b97560a3e595691caeb6389e583a486d18d341c0fc34daf8bff`；离线复核回执为 `.artifacts/research/script-risk/public-pilot-offline-verify-2026-08-28.json`，SHA-256 为 `3bb86929de9d940e2b1d4d4ecd13423a5b0fc4dde883788ada8dd13c7e74fe7d`。
- 当前权威真实站点报告是 `.artifacts/research/script-risk/bytecode-shadow-sites-pilot-diagnostic-v5-2026-08-28.json`，SHA-256 为 `1082771db0c0cca3c07314058d924e0c846267c528509643c78e7602fe9c438d`。报告权限为 `0600`，历史失败报告均另名保留，没有被覆盖。
- v5 绑定的协议 SHA-256 为 `9129386b557316c6c973130fc0c0a13e0d918b5023f19cc6319f999c7cd58609`，runner SHA-256 为 `880b6d966d3fc9342ad3c50e23e81536dd37f74a5a109038ad9a2a01b453831c`；对应私有、内容寻址的 `0600` 证据副本位于 `.artifacts/research/script-risk/protocols/` 和 `.artifacts/research/script-risk/runners/`，文件名包含精确摘要。
- v5 的外部 HMAC key 保存在 `.artifacts/research/script-risk/keys/shadow-sites-pilot-dns-rerun-2026-08-28.key`，为 32 bytes、`0600`，没有写入报告。使用该 key 对 site、manifest 和 batch 三类 commitment 重新计算后均与 v5 报告匹配；不得公开 key 内容，也不得把 batch-scoped ID 解释成永久站点标识。
- v5 使用的构建清单 SHA-256 为 `005e7e1ea0c944d41a0f2951da54f424dd37ac1254b5d17b02e3c9e58dbaca52`，App 树 SHA-256 为 `10fc4c7152fa5917090d3caf93676f7e69a1f848ccafbea163ccbd902df05efe`，主可执行文件 SHA-256 为 `16b5a5f691a1c9ad72ba9fa4690d241dcf1b4c210c3cd30bc18cd54e2537f6d3`。该身份仅为 `diagnostic-only / internal-local-only`，不是签名、可复现构建或发布证明。

## 公开挖矿能力 pilot

### 数据边界

- 协议定义位于 `packages/core/src/script-risk/evaluation/protocols/miner-capability-public-v1.json`。本次固定 13 个公开来源、13 个样本、25 个文件，共 `1,167,195` bytes。
- 标签包含 3 个 `mining-capable` 和 10 个 `benign-control`。三个正样本来源是 browser-cryptominer、LuckyHash 和 deepMiner；良性对照覆盖网络、加密散列、Wasm 特性检测、Worker、WebSocket、媒体和图形等容易产生相似信号的代码。
- 取得过程没有执行来源代码，文件仅在本地研究目录使用，不随产品分发；标签没有独立复核，协议和标签公开可查看，也没有真正 sealed test。
- `mining-capable` 只表示仓库代码呈现浏览器挖矿能力，不表示对应公开仓库或其任何部署是恶意行为。取得回执明确记录 `contextualMaliciousnessInferred=false`，本项目不得把这些来源称为“恶意脚本”或“恶意部署”。

### v5 结果

- 混淆矩阵：TP=1、TN=10、FP=0、FN=2。
- 指标：precision=`1`、recall=`0.333333`、FPR=`0`、specificity=`1`、accuracy=`0.846154`。
- 单侧精确 Clopper–Pearson 95% 界：recall 下界为 `0.016952427508441524`，FPR 上界为 `0.2588655508930522`。样本很小，因此观测到零误报不等于真实误报率为零。
- 离线分析耗时：p50=`269.2995 ms`、p95=`498.118666 ms`；总耗时为 `3888.362416 ms`。这是独立进程中的离线 AST 分析耗时，不是 Chromium 页面热路径开销。
- LuckyHash 被识别为 mining-capable；browser-cryptominer 和 deepMiner 被漏检。该结果说明当前规则对不同实现族的泛化明显不足，不具备进入页面阻断路径的条件。

预测在标签接入前已经冻结，评分文件也记录 `labelsJoinedAfterPrediction=true`；但数据定义和标签公开、操作员可见，且没有独立持有方，所以它只能称为 `operator-blinded-local`，不能称为 independent blind、sealed test 或 final evaluation。揭盲后不得围绕这 13 个样本调参并继续把同一 pilot 当作独立改进证据；后续规则变化必须冻结新候选，并使用未参与调参的新数据评估。

## 本地盲测执行链补强

候选环境校验不再只验证仓库路径后让 worker 重新读取可变文件。当前实现会在候选校验时读取 analyzer、分类规则和置信区间实现，核对候选绑定的 SHA-256，并保留同一份已验证内存字节：

- analyzer 字节直接传入资源受限 worker；worker 再核对摘要，并通过内存中的 CommonJS/VM 虚拟文件名加载，不重新读取仓库 analyzer。
- 分类规则和置信区间实现从已验证字节的 `data:` module 加载，不重新解析可变路径。
- 输出写入前仍复核仓库与候选环境，检测运行期间的源码漂移；摘要不符时失败，不生成可被误认为有效的新报告。

相关实现和回归测试位于 `packages/core/src/script-risk/evaluation/blind-protocol.mjs`、`packages/core/scripts/predict-script-risk-blind.mjs`、`packages/core/scripts/score-script-risk-blind.mjs` 和 `packages/core/src/script-risk/evaluation/blind-protocol.test.ts`。定向协议测试 30/30 通过，包含 analyzer 在 worker 之间被替换后恢复、替换后不恢复、内存字节篡改和输出前仓库漂移等用例；独立复核结论为 P0=0、P1=0。

这项补强关闭的是本地候选校验与执行之间的文件竞态，不会把操作员控制的公开 pilot 变成独立密封评测，也不会授权阻断或发布。

## 真实站点 bytecode shadow 实跑与边界

### 固定协议、运行器与构建身份

- 当前固定协议：`apps/browser/config/script-risk-shadow-protocol-v1.json`，SHA-256 为 `9129386b557316c6c973130fc0c0a13e0d918b5023f19cc6319f999c7cd58609`。
- 当前运行器：`apps/browser/scripts/verify-bytecode-shadow-sites-runtime.mjs`，SHA-256 为 `880b6d966d3fc9342ad3c50e23e81536dd37f74a5a109038ad9a2a01b453831c`。离线 `node --check` 通过，runner self-test 为 69/69。
- 运行器将固定站点、AB/BA 顺序、轮次、32 MiB trace、`dataLossOccurred=false`、renderer 记录上限、构建清单、运行期间 runner 稳定性、显式联网授权、固定 DNS/CONNECT 代理和运行后清理作为硬门禁。CDP 使用 page-only auto-attach，在 target 创建前启用 trace，并按 flat session 路由；错误报告只保留固定阶段和 CDP 方法枚举。
- 公网访问只允许经固定代理完成重新解析并 pin 到公开 IPv4 的 443 CONNECT；私网、fake-IP、保留地址、非 443、明文请求和解析失败均 fail-closed。预检使用固定 resolver，仍没有 DNSSEC/DoH 身份认证，并会向该 resolver 暴露研究访问域名；TLS 主机名校验继续保留。
- v5 使用的 Chromium HEAD 为 `8854cc463cd43bb589b6aa681add5e99ed7c676d`，V8 HEAD 为 `9c0b1f276ba116e8b25a55466207e6586b44be16`；两者在清单中均为 clean，顶层 GCSA 仓库为 dirty。构建清单、App 树和主可执行文件摘要见“当前权威证据”。运行前后身份、构建图和产物摘要稳定，构建锁全程持有；该清单仍只具备 `cooperative-local-workflow` 信任级别。

### 保留的失败历史

- 首次报告 `.artifacts/research/script-risk/bytecode-shadow-sites-pilot-2026-08-28.json`（SHA-256 `61f4472b33c68a9a3e15f678b05c722e6e4d5543cae9a619802236e5ff4bf5ce`）在启动页面前以 `public-resolution-failed` 结束：计划 4 次、完成 0 次，不能记为 0/4 检测结果。根因是系统 resolver 返回 `198.18.0.0/15` fake-IP，安全门正确拒绝。
- DNS-rerun 报告 `.artifacts/research/script-risk/bytecode-shadow-sites-pilot-dns-rerun-2026-08-28.json`（SHA-256 `951d4eaf984cbdc0ae20964aa2adeb2f1f10c3dace628105c0ea877180514c06`）完成 4 次启动，但 CDP 流程没有闭合，而且旧的全局 crash 筛选误把无关的 `AegisUITests-Runner` 崩溃记入 Chromium；因此报告不可作为 App 崩溃或协议通过证据。
- 下一版 runner 在代理 tunnel 清理时触发 `EPIPE`，进程在写报告前退出，所以没有 v2 报告。遗留的 8.4 MiB 专用 profile 已可恢复地移到 macOS 废纸篓，且没有遗留进程或新崩溃。
- v3 报告 `.artifacts/research/script-risk/bytecode-shadow-sites-pilot-diagnostic-v3-2026-08-28.json`（SHA-256 `19cf05f2ee66097f79cd8e231b581a5d2a0d7809bf11edb9c7ba791df2123869`）以 0/4 `build-lock-busy` 失败。核对没有 writer 后，才移除由上一次异常退出留下的空锁目录。该旧报告的 `liveNetworkConfirmed=true` 来自旧 runner 硬编码，在 0 次运行下没有网络证据，必须忽略。
- v4 报告 `.artifacts/research/script-risk/bytecode-shadow-sites-pilot-diagnostic-v4-2026-08-28.json`（SHA-256 `ded5e4186115ae6d4b837fc17fe4bea40d0701f9f1b02c1c585efc2e941be4f4`）完成 4/4，页面健康且 OFF/ON 信号分别为 0 与 84/9，但每次都有 1 个被代理拒绝的 Chromium 后台明文 HTTP 请求，另有 1 次被拒 CONNECT，所以协议按 `egress-denied` 失败。拒绝发生在本地代理，没有形成该明文请求的公网外发；报告不保存原始 URL、host 或 payload。

针对上述失败，runner 增加了明文请求与 CONNECT 的分离计数、固定原因枚举、active-tunnel `EPIPE` 自测，并把全局崩溃筛选收窄为 Chromium-named / Chromium Crashpad 增量，再与专用 profile、CDP 和 signal 证据组合；另从实际 CONNECT 证据派生 `liveNetworkObserved/Confirmed`。并行运行的另一个 Chromium 若在同一窗口产生全局 Chromium-named crash artifact，仍可能造成误报。现场 exact-App 诊断把固定后台请求定位到 Chromium NetworkTime 组件；v5 同时通过 feature 与专用 profile preference 关闭该背景查询，不放宽明文或私网门禁。该根因没有单独持久化 receipt，无法仅由不保存 URL/host 的 v4 报告独立复核。

### v5 固定协议结果

- 最终报告 `.artifacts/research/script-risk/bytecode-shadow-sites-pilot-diagnostic-v5-2026-08-28.json` 为 `passed=true`、`qualification=research-only`、`releaseEligible=false`。4/4 运行均为 `protocolOutcome=ok`、`pageOutcome=ok`、`failureStage=complete`，两个 pair 均为 `no-observed-breakage`。
- 两次 OFF 运行均观察到 0 条 shadow telemetry；两次 ON 运行分别观察到 84 和 9 条，仅来自 renderer。所有运行均为 `dataLossOccurred=false`、`capReached=false`、`skippedTooLargeCount=0`。
- 四次运行的允许/固定解析 CONNECT 分别为 8/8、8/8、4/4、5/5；拒绝 CONNECT、拒绝明文、明文请求、upstream error 均为 0。`liveNetworkAuthorized=true` 记录的是操作员显式授权；`liveNetworkObserved/Confirmed=true` 才由本次 pinned + allowed CONNECT 证据派生。
- 每次运行的 profile crash、全局 Chromium-named crash artifact delta、signal 和残留自有进程均为 0；代理关闭、临时根目录删除和清理复核均通过。批次结束后没有遗留运行器临时目录、构建锁或匹配的 Chromium 进程。
- 该结果只证明两个固定站点、单轮 AB/BA、限定导航窗口内的 renderer 级 observe-only 信号和粗粒度页面存活。报告明确 `telemetryAttribution=bounded-navigation-window-run-level`、`exactDocumentAttribution=false`；它没有证明具体 document、script 或 function 归因，也不是长时间性能、完整破站率、恶意分类或阻断结果。

### 精确 App UI 证据与退出异常

UI 检查使用构建清单绑定的 `<chromium-checkout>/out/AegisRelease/Chromium.app` 和全新专用 profile，没有操作 `/Applications/Chromium.app`，也没有修改任何页面开关。`chrome://version` 显示 Chromium `151.0.7922.77`、精确可执行文件路径和精确 profile；`chrome://aegis` 显示“挖矿脚本检测（仅观察）”，明确只提醒、不终止脚本或连接，并显示“AI 控制已关闭（默认）”。本地截图均为 `0600`：

- `.artifacts/research/script-risk/ui/exact-chromium-version-v5.jpeg`，SHA-256 `8fd383c19e46e76606271858b4681a938a2a7e7f999eccf36d2cf0a333fa4ea1`。
- `.artifacts/research/script-risk/ui/exact-chromium-aegis-v5.jpeg`，SHA-256 `b0759f80c6457787bb4dc8cd4a765b6e18d63e46ac192cc19895300c43121419`。
- `.artifacts/research/script-risk/ui/exact-chromium-aegis-lower-v5.jpeg`，SHA-256 `b6070786ac0693809d3ec0b853eb46d72d5434bf7da67e3d158b1cfb064d12cb`。
- `.artifacts/research/script-risk/ui/exact-chromium-aegis-bottom-v5.jpeg`，SHA-256 `9ea76eb8126905e86f70e3c7881bd1dc7fd210db597f0eed8bdedf5509866a12`。
- `.artifacts/research/script-risk/ui/exact-chromium-aegis-ai-control-v5.jpeg`，SHA-256 `26097c9ca0b5892bbe1d7cfa335512a246e8e3ef8b7bf5802914b55e4a9aaf20`。

这次独立 UI 会话对 `SIGTERM` 和应用退出快捷键均未在 10 秒内响应，最终按已复核的单一主 PID 强制结束；两个由该 exact App 启动的 crashpad 进程随后一并消失。15 MiB 专用 profile 已可恢复地移至 `<Trash>/GCSA-aegis-ui-exact-v5-2026-08-28-PWG5Wa`，源目录和匹配进程均为零。该退出异常不影响 v5 runner 的四次自动清理结果，但必须作为生命周期 No-Go 证据另行诊断，不能宣称 UI/退出流程已具备发布质量。

## 与论文目标能力的差异

现有 Phase 2/3 组件覆盖了 AST 结构观察、有限 provenance flow、V8 opcode shadow、本地模型接口和联邦本地模拟，但仍缺少论文级或产品级闭环：

1. **没有 ASTrack 分支切片或阻断。** 当前只生成结构签名与候选摘要，不做语义安全分析、分支切片、代码改写或选择性删除。
2. **没有 V8 bytecode 函数级识别与执行阻断。** 当前 opcode shadow 只输出有界观察事件，`would_block=0`，不终止函数、脚本、Worker 或连接。
3. **没有完整浏览器实时信息流。** 当前 provenance flow 是调用方供数的有界研究函数，没有覆盖真实 DOM、Cookie/storage、redirect、网络、Worker 和 Wasm 的完整端到端采集。
4. **没有已部署的本地 LLM 或联邦检测服务。** 现有内容只是灰区 advisory contract 和联邦本地模拟，没有模型权重、真实推理后端、跨设备安全聚合、隐私预算运营或页面判定接入。

因此项目不能宣传“已复现论文完整系统”“可阻断任意恶意脚本”“通用恶意 JavaScript 防护”或“挖矿脚本零误报检测”。目前准确表述只能是：已经具备可审计、仅观察的脚本风险研究原型，在一个小型公开挖矿能力 pilot 中验证了有限识别能力，并在两个固定公开站点上验证了 bytecode shadow 观察链能够按开关产生有界信号。

## 下一阶段门禁

1. 保持 v5 冻结，不基于揭盲样本回调阈值；另建开发集，并由独立持有方准备未见过的良性、挖矿能力和恶意行为样本。
2. 冻结 v5 真实站点报告与其 runner/config/build 证据，不把 2 个站点、单轮 4 次运行外推为总体破站率。下一协议必须增加独立站点集、重复轮次、长时运行、性能预算和 document/script/function 归因，并继续使用新报告文件名保留失败历史。
3. 优先复现并修复独立 UI 会话无法优雅退出的问题；在修复前，不把 runner 自动清理通过等同于完整浏览器生命周期通过。
4. 扩充混淆、动态代码生成、低占空比、Worker/SharedWorker/ServiceWorker、code cache/snapshot 和 Wasm 绕过覆盖，同时加入登录、支付、视频、游戏和本地 AI 等高负载良性对照。
5. AST 分支安全/切片、函数级 bytecode 识别、实时 provenance、实际本地模型或联邦服务都应先走独立离线数据与灰度门；没有证据时不得直接进入默认页面热路径。
6. 只有独立 sealed test、误报/召回置信界、性能与破站率、kill switch、回滚和正式安全审批全部关闭后，才可另行评估页面阻断；在此之前继续 observe-only / fail-open。
