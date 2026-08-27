# CPU 根因与论文驱动优化

- 日期：2026-08-25
- 范围：macOS Chromium Browser、本地 Git，不使用 GitHub
- 目标：解释 `https://ip.gcsa.org/` 打开后的高 CPU，修掉已证实的 GPU 致死/软件回退机制与 Aegis 热路径，并把项目引用论文转成有性能边界的后续路线
- 完成标准：发布 GN 语义正确；定向单测和 Release 构建通过；隔离 Profile 访问真实站点时无新崩溃、无软件合成回退；保存 CPU 与界面证据

## 结论

现场不是单一问题，而是三层负载叠加：

1. 最高优先级的直接崩溃与 CPU 放大机制，是所谓 Release 使用了非 official 构建语义。GPU 进程遇到 Chromium 合成器的诊断性 `DUMP_WILL_BE_CHECK` 后被当成 FATAL 连续杀死，达到重启阈值后退回软件合成。触发 damage invariant 的底层合成器问题仍需单列观察；official 语义只是让该诊断不再致死。
2. 现场会话可见媒体/WebRTC 线程及持续合成活动，但现有采样不足以证明这些负载全部来自 `ip.gcsa.org`。即使修好 Browser，也不能把该站点当成静态页基线；真实站点必须用隔离 Profile 和 Aegis ON/OFF 差分归因。
3. Aegis 的确定性热路径，是通过 builtin、first-party collect、exception 和 host 早退后仍落到 path-rule fallback 的请求，会在全局锁内线性扫描 5,740 条规则。它会放大资源较多页面的 CPU 和锁竞争，但不是 GPU 崩溃本身。

## 现场证据

### GPU 崩溃与软件合成

- 05:14:22–05:15:05 之间新增 5 个 `gpu-process` Crashpad dump。
- 5 个 dump 的栈一致：`cc::LayerTreeHostImpl::CalculateRenderPasses` → `logging::CheckError` → abort；对应 Chromium 上游 [`layer_tree_host_impl.cc`](https://chromium.googlesource.com/chromium/src/%2B/aeedb171283094693432bbb0be1769a75642a5d7/cc/trees/layer_tree_host_impl.cc) 中 `crbug.com/454680865` 的 damage 诊断。
- 原 `aegis-release.gn` 设置 `is_official_build=false`，生成物带 `-DDCHECK_ALWAYS_ON=1`，同时启用 expensive DCHECK。`base/check.cc` 明确让非 official 构建中的 `DUMP_WILL_BE_CHECK` 变成 FATAL。
- 连续崩溃后 GPU 进程参数出现 `--use-gl=disabled`，Renderer 出现 `--disable-gpu-compositing`。
- 对回退后的 GPU 进程采样，热点位于 `viz::SoftwareRenderer::DoDrawQuad`、Skia CPU tile 绘制及 backdrop filter，不是 Aegis 定时器。

原始 dump 位于本机 Chromium Crashpad `pending/`；因 dump 可能包含进程内存，不复制进仓库。以下 UUID、时间和 SHA-256 用于本机复核：

- `f53157b1-18e9-4cf9-8780-a338db24f0b8`，05:14:22，`f49e2832f337201c23cb1bf542cb06d7b7a2ad36c65a7d0dc6b18f5fab522ab7`
- `01f655d4-7935-4d28-8a4d-a2957cf64de2`，05:14:58，`3ac1f9c403538d5792ada4a0e1941c532baa514e580e3bc1adbf149e088bceae`
- `b56a65ca-685b-46aa-a1e1-baaafcf60486`，05:15:00，`8d694d2e66bd242928b98e99be31809edc62a85af7d76e942be287238086abc9`
- `448b3446-7d77-44e1-8db4-21a3ecc30cfc`，05:15:01，`9865585234cafa0500e2c1febe40404f72ea0ea2d9f06bf8970aca14a73829b0`
- `259c90cc-b1c4-409e-a489-134a40a8fbc0`，05:15:05，`3e37c71dc631622e9a0a0bb3fe6b4d31a3baebc8f4a27704f37200a7d314cf26`

### 站点自身负载

- 现场 Renderer 在不同 PID 间迁移热点；采样可见 WebRTC、Media 和 VideoFrameCompositor 线程。
- 该证据只说明当时会话创建过媒体路径，不能仅凭线程存在把 CPU 归因给该站点，也不能把所有 CPU 都归因给 Aegis。
- 因为现场使用长期 Default Profile、多个标签页和本地代理，旧实例数据只作根因证据，不作为正式性能基线。

### Aegis 过滤器热路径

- 当前真实 `compiled.json` 为 2,274,571 bytes：94,788 个 host、5,740 条 path rule、683 个 exception。
- 5,740 条 path rule 只分布在 4,543 个 host bucket，平均 1.26 条、最大 46 条；这支持按 host 缩小候选集，但 46 只是当前数据观测值，不是硬上限。
- 原 `MatchesPathRule()` 对每个普通未命中子资源在全局锁内遍历全部 path rule，并逐条调用域名和前缀比较。
- 200 次 matcher 全量未命中约执行 115 万次 path-rule 判断；500 次约 287 万次。这是按匹配调用数估算，不是页面请求数或页面工作量上限。
- 原实现只比较 `url.path()`；真实缓存中有 757 条包含 `?query` 的 path rule 不会命中。这是兼容性与正确性缺口，但突然启用会扩大拦截范围，本轮保持既有 path-only 语义，留待端到端站点回归后单独修正。

## 本轮实施

### 1. 修正发布构建语义

- `is_official_build=true`：生成 `OFFICIAL_BUILD`，关闭 always-on/expensive DCHECK；不删除 Chromium 上游诊断。
- 本轮 `gn args` 与 `toolchain.ninja` 产物证据为 `dcheck_always_on=false`、`enable_expensive_dchecks=false`、存在 `-DOFFICIAL_BUILD` 且不存在 `-DDCHECK_ALWAYS_ON`；最终仍以完成的 Release App 运行验收为准。
- 本地固定源码树没有匹配的 PGO profile，因此本地验证显式 `chrome_pgo_phase=0`。正式外发前下载匹配 profile 并恢复 PGO，是本项目自定的性能/质量门，不是 Chromium 正确性硬门，也不影响本轮崩溃语义验证。

### 2. 索引 path rule

- 在锁外解析、排序并一次构建 `host → path prefixes` 的 flat map，完成后在短临界区内整体交换。
- 查询只遍历请求 host 的域名后缀及对应少量前缀，避免每请求固定扫描 5,740 条规则。
- 请求匹配改用 `string_view` 域名后缀，不再在锁内逐层分配字符串；保留 Chromium 的单末尾点域名等价、双末尾点不等价语义。
- 新增索引替换无陈旧项、末尾点边界和 6,000 条无关规则回归。

### 3. 去掉 Canvas 整图双拷贝

- Canvas snapshot 已经验证为紧密 RGBA bitmap；现在直接在拥有的 bitmap span 上执行稳定噪声。
- 删除同尺寸临时 vector、拷入和拷回，降低频繁 `toDataURL()` / `toBlob()` 指纹探测时的分配和内存带宽。
- 这不是普通绘制帧热路径，不能用它解释软件合成的持续高 CPU。

## 论文驱动的后续顺序

### P1：下一轮，先保持加载路径有界

1. **PURL**：离线生成站点/目的地上下文的 URL 清洗规则，运行时只做索引查询；不在浏览器请求热路径构图。
2. **CookieBlock**：增加值形态、属性、过期时间和更新历史，研究写入前分类；用登录、支付和购物车回归约束误杀。
3. **CookieGraph / SST-Guard / 第一方跟踪研究**：只对已标记的可疑同站请求做 query/header 标识符模板关联，并设置每页请求数、时间与内存预算。
4. **PhishLang / Explain / EXPLICATE**：在现有 `xn--` 和简单品牌 token/hyphen 规则上，增加 Unicode 同形异义、编辑距离、注册域边界、跨域 form action 与隐藏 iframe 等确定性信号，并在拦截页标注具体线索；模型只处理启发式灰区。
5. **WebGPU privacy**：把含产品身份和 token 片段的字符串改为有限人口桶，并研究 pipeline cache 的 origin/Profile/Incognito 分区。
6. **Casper / MINIM**：本项目组合设计为用户触发时执行规则 → 本地 NER → 必要性抽象，并另建任务化、最小化的自动化观察接口；这不是两篇论文已经共同验证的流水线，需自建准确率、泄漏与 CPU 门。

### P2：结构性性能与隔离

1. 过滤表在后台构建不可变 snapshot；Browser 按 generation 缓存序列化结果，中期改只读共享内存，避免每个 Renderer 复制约 10 万字符串。
2. 阻拦事件按文档、host、类型在短窗口内聚合并设置单页速率上限。
3. CNAME 缓存改为按 Profile/网络隔离键分区的 TTL/LRU，一次 lookup 返回 alias。
4. 相同 Referer 的无变化清洗直接返回或使用小型有界缓存。
5. `chrome://aegis` 状态刷新改为事件驱动，至少在页面隐藏时暂停。

### 延后

- WebLLM、ASTrack、AdGraph、ByteDefender、FP-Fed 仍是未实现研究项。CPU 基线和产品边界稳定前，不把模型、AST、图或 bytecode 扫描放进默认页面加载路径。
- MV3 研究只保留为 Extension 历史背景，不再作为 Browser-only 架构依据。

## 验证协议

- 同一新 Release、独立 Profile、单一可见标签页；固定窗口、前后台、代理与显示条件。
- 先确认进程参数没有 `--use-gl=disabled` / `--disable-gpu-compositing`，运行窗口没有 GPU 进程重启，也没有高频重复的同源 damage 诊断 dump；单个 nonfatal dump 仍需保留并分析，不能因 official 构建不崩溃就忽略底层 invariant。
- 每轮预热后至少测量 60 秒，用累计 CPU 时间差分别统计 Browser、Renderer、GPU 与进程树；单点 `ps %cpu` 不作最终结论。正式性能结论至少重复 3 次，变异系数超过 10% 时增至 5 次。
- 使用默认 Aegis 与 `--disable-features=AegisEnabled` 做差分；本地静态页用于空闲基线，`ip.gcsa.org` 只作真实站点接受门。
- 功能门：0 Renderer/GPU 崩溃、0 Mojo/FATAL、页面可交互；性能门：Aegis ON 相对 OFF 的稳态均值增量不超过 3 个单核百分点或 OFF 基线的 10%（取较大值）。

## 验证结果

### 构建与测试

- Chromium 本地提交为 `5822011d91b368ffbe674875f04673048e4bff26`，对应补丁 `0044-perf-aegis-index-filter-paths-and-trim-canvas-copies.patch`。
- `autoninja -C out/AegisRelease chrome` 完整 official 语义重建成功，共 54,505 个本地步骤，耗时 3 小时 28 分 39 秒；紧接着再次执行显示 `ninja: no work to do`。
- 生成参数为 `is_official_build=true`、`dcheck_always_on=false`、`enable_expensive_dchecks=false`、`chrome_pgo_phase=0`、`use_thin_lto=true`；toolchain 有 `-DOFFICIAL_BUILD`，没有 `-DDCHECK_ALWAYS_ON`。
- Release `aegis_unittests` 43/43 通过；新增索引替换、6,000 条无关 path rule 和末尾点兼容性回归均通过。
- App 为 arm64、non-component、`151.0.7922.77`，占用 367,896 KiB（约 359 MiB）。launcher SHA-256 为 `92c9d54898fa44a7719b1859adef02cfcb48123bddda85ffdcc64c44b2b7cef8`，Framework SHA-256 为 `bd4bb6024b19e60ad818108c76ab498226c354e92041685a9483546ced167b54`；本地 ad-hoc `codesign --verify --deep --strict` 通过，但没有产品身份、TeamIdentifier 或公证。

### 真实站点 CPU 对照

- 每组各 5 次；每次使用全新临时 Profile，复制同一份真实 compiled filter cache，预热 30 秒后按累计进程 CPU 时间采样 60 秒。窗口、URL 和后台开关一致，关闭组只额外使用 `--disable-features=AegisEnabled`。
- Aegis ON 总 CPU 五次为 `20.55 / 3.11 / 21.10 / 27.88 / 21.23%`，均值 18.77%，中位数 21.10%。
- Aegis OFF 总 CPU 五次为 `23.67 / 27.12 / 21.76 / 26.72 / 27.96%`，均值 25.45%，中位数 26.72%。
- 同序 `OFF - ON` 为 `3.12 / 24.01 / 0.66 / -1.16 / 6.73` 个单核百分点，中位数为 3.12；中位数相对降低 21.0%。第四组 ON 比 OFF 高 1.16 个百分点，仍在预设的 3 个百分点门内。
- ON 组变异系数仍为 49.3%，原因是一轮低负载样本只有 3.11%；因此不把“降低 21%”外推为所有网页的性能收益。可确认的结论是：Aegis 没有造成该站点的稳定 CPU 增量，原 GPU crash → 软件合成放大链已经消失；页面自身在活跃态仍有约 20%–28% 的 Renderer/GPU 单核负载。
- 10 次共 600 秒正式采样均为 0 次 GPU 重启、0 次软件合成回退、0 个新 Crashpad dump、0 条 `FATAL`、0 条 `LayerTreeHostImpl` damage invariant 和 0 个遗留测试进程。临时 Profile 均按精确路径清理。

### 实际界面验收

- Computer Use 按完整 App 路径定位 `out/AegisRelease/Chromium.app`，避免与同名 LocalDev Chromium 混淆。
- `https://ip.gcsa.org/` 完整显示首页、IP 信息、连通性、WebRTC、DNS 与测速区域，没有“喔唷，崩溃啦！”或错误代码 6。
- `chrome://gpu` 显示命令行来自 `out/AegisRelease`；Canvas、Compositing、Rasterization、Video Decode/Encode、WebGL、WebGPU 全部为 hardware accelerated，`GPU process crash count` 为 0。
- `chrome://aegis` 可进入，8 个集成模块默认开启，过滤列表与策略 worker 就绪，AI Control 默认关闭。

### 可重放性与剩余边界

- `series` 现为 44 个补丁，SHA-256 为 `6d4cd8fb53b2ec30ef0890678a2103f8f6e8def347d862bb7fd2e6e27befd0f3`。
- 从固定 base 离线 44/44 重放成功；临时 HEAD 为 `5f12e69ab747f75e2ab817c63c17dbc9a6e5da41`，tree 为 `71909fd13de0fbf9981e9ac511fec6b25072a048`。该 tree 与当前 Chromium checkout 相同，稳定 patch-id 与全部 103 个 overlay 文件一致；临时 worktree 已移除。
- official 语义使上游 damage 诊断不再直接杀死 GPU，但不等于修复 `crbug.com/454680865` 对应的底层 invariant。若后续出现重复 nonfatal dump、渲染损坏或 GPU crash count 增长，仍必须按合成器问题继续追踪。
- 本轮没有执行 GitHub fetch、pull、push、PR、Release、tag 或远程 CI。项目仍是 **No-Go**：产品身份、正式签名/公证、ZIP/DMG、安装后稳定性、完整出站审计和当前 Android 构建仍未完成。
