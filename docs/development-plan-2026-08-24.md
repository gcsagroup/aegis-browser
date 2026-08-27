# GCSA-aegis 修复与发布准备开发计划

- 版本：Draft v0.2（Browser-only 修订）
- 日期：2026-08-24
- 状态：**待用户确认，尚未授权实施**
- 首个目标：形成可审计、可复现、可内部分发的 macOS + Android RC
- 产品边界：只交付集成式 Chromium Browser，不保留、不构建、不分发 Extension
- 非目标：本计划不自动部署、不公开发布、不使用生产签名密钥、不上传 Play Store

## 1. 目标、假设与完成标准

### 目标

把当前“源码和旧产物并存的工程原型”恢复为一条完整证据链：

```text
固定源码与补丁 → 冷环境安装/构建 → 自动测试 → 实机行为 → 自包含产物 → 文档声明
```

### 关键假设

1. `apps/browser` Chromium fork 是唯一产品线；`apps/extension` 不再作为参考实现或研究工具保留，完成基线封存后从源码、Workspace、CI 和文档中移除。
2. 第一阶段只交付“内部 RC”。Developer ID、公证、Play upload key 和公开分发另设批准门。
3. `packages/core` 是 Browser 的构建期策略源码，不是独立产品或 Extension；继续通过生成物校验和共享测试向量约束 Chromium C++/JS 集成，不能依赖人工同步。
4. 当前根仓库、外部 Chromium checkout、调试日志、截图、tombstone、APK 都属于待保护现场；未经确认不清理、不覆盖、不移动。
5. 临时关闭核心功能只能用于定位问题，不能作为 RC 的最终修复。

### 最终完成标准

- 根仓库具有明确 commit，所有剩余工作区改动都有说明。
- 能从固定 Chromium base commit 干净应用 0030 个补丁，生成与记录一致的 patched HEAD。
- 全新环境可通过 frozen install、build、lint、typecheck 和测试。
- `apps/extension` 及其专用脚本、依赖、测试、产物和文档入口已移除；产品验证只针对 Browser。
- macOS 开发版与非 component release build 均由当前源码构建成功。
- Tracker、Filter List、Link Sanitize 等核心功能默认状态与产品声明一致，且没有稳定复现崩溃。
- CDP、Ollama 脱敏、功能开关等 P0/P1 安全用例全部通过。
- macOS 安装 App 与 Pixel 9 Pro Fold 真机验收通过。
- App、ZIP、DMG、APK 均有 SHA-256、源码 SHA、Chromium SHA、补丁哈希和构建参数映射。
- Roadmap、README、产品页和平台文档只陈述已有证据支持的状态。

## 2. 当前基线与实施边界

### 已确认基线

- 根仓库尚无 commit，当前文件全部未跟踪。
- 外部 Chromium checkout 已有 0030 个补丁提交，但另有 5 个修改文件和 63 个删除的测试资源。
- 当前 Aegis 能力已经通过 Chromium patches/overlay 集成到 Browser：C++/Blink 执行层、`chrome://aegis`、策略 worker 和规则快照均有源码落点。
- 当前仍保留 `apps/extension`，根 `package.json` 的默认 `dev` 仍启动 Extension，Browser README/架构文档也仍将其定义为研究工具；因此仓库尚未收敛成 Browser-only。
- `pnpm install --frozen-lockfile` 因 lockfile 与 manifest 不一致而失败。
- JS Workspace 可以在先构建依赖后通过 build、lint 和 typecheck；冷状态 lint/typecheck 失败。
- 现有 33 个 TS 测试包含旧 Extension 覆盖，不能作为 Browser 产品证据；6 个 C++ 测试通过，但 Browser/UI 仍存在占位测试。
- 当前 Chromium 源码因 Rust build-script 配置问题构建失败。
- 当前没有可分发的 macOS App、ZIP 或 DMG；`out/AegisRelease` 不是完整产物。
- 今天安装的 Android APK 已通过网页、`chrome://aegis` 和设置入口实机冒烟，但 APK 不在仓库 `dist`，且无法映射到一个干净源码基线。

### 本计划的批准边界

用户确认本计划后，默认只授权本地源码修改、测试、构建和内部 RC 制作。以下动作仍必须单独确认：

其中，删除 `apps/extension` 属于本计划 M1 的明确范围，但必须在 M0 生成可恢复基线之后执行；本次修订计划不实施删除。

- 使用 Developer ID、Apple 公证服务或生产签名密钥。
- 使用 Play upload key、上传 Play Console 或开放测试轨。
- 对外发布 DMG、ZIP、APK、Git tag、Release 或下载链接。
- 删除或移动现有日志、截图、tombstone、APK、模型、构建树或其他研究证据。
- 清除 Android App 数据、重置真机或覆盖不可恢复的用户数据。

## 3. 执行原则

1. **先封存现场**：先记录身份、哈希和差异，再做任何整理。
2. **先失败测试，后修复**：每个已知缺陷先落回归用例，再修改实现。
3. **当前源码优先**：旧二进制只能作为历史证据，不能证明当前 checkout。
4. **安全默认 fail closed**：CDP、模型出站、规则同步和状态报告不得静默降级成不安全成功。
5. **状态分层**：只使用“源码存在 / 自动测试通过 / 构建通过 / 实机通过 / 可内部分发 / 可公开发布”。
6. **不以关闭功能换稳定**：功能开关可用于二分定位，但 RC 必须恢复产品承诺的默认状态。
7. **最小改动**：不引入与当前修复无关的框架、抽象或功能扩展。

## 4. 分阶段实施计划

### M0：现场封存与版本基线

预计：0.5–1 人日。

步骤：

- [ ] 记录根仓库与 Chromium checkout 的分支、HEAD、status、diff、文件哈希和工具链版本。
- [ ] 记录 Chromium base commit、patched HEAD、`patches/series` 哈希、GN 参数和现有二进制时间戳。
- [ ] 将根目录内容分类为源码、文档、调试证据、构建产物和外部二进制；本阶段只分类，不清理。
- [ ] 对 `apps/extension` 及其 Workspace、脚本和文档引用生成删除前清单与哈希，确保后续移除可从基线 commit 恢复。
- [ ] 保存外部 checkout 5 个修改文件的完整差异，以及 63 个删除路径清单；确认哪些删除是意图、哪些是异常。
- [ ] 检查磁盘余量；进入 Chromium 冷构建前至少保留 120 GiB 可用空间，空间不足时停线而不是清理现有证据。
- [ ] 在用户确认后建立 `codex/aegis-recovery` 工作分支和首个可追溯基线提交；大体积证据只保存摘要与哈希。
- [ ] 定义唯一的构建身份清单格式：根 SHA、Chromium SHA、补丁哈希、工具链、GN 参数、平台和产物哈希。

验证与退出条件：

- 任一现有改动都能从记录中恢复或重新识别。
- 不存在未分类的删除、覆盖或来源不明的发行声明。
- 若无法判断 63 个删除是否有意，立即停线并请用户确认，不执行恢复或提交。

交付物：基线清单、差异备份、文件分类清单和实施分支。

### M1：Browser-only 收敛、Workspace 可复现性与快速质量门

预计：1–2 人日。

步骤：

- [ ] 修正 `pnpm-lock.yaml` 与各 package manifest 的差异。
- [ ] 删除 `apps/extension` 源码及其专用配置、静态资源、测试和构建产物；不把代码迁移回 Browser，因为产品能力已经在 Chromium 集成层实现。
- [ ] 移除根 `dev` 对 `@gcsa-aegis/extension` 的引用，以及 Workspace、lockfile、CI、脚本和文档中的 Extension 专用依赖；根入口改为明确的 Browser 工作流。
- [ ] 保留 `packages/core`，并验证其只通过 snapshot、policy worker 和生成的 C++ `.inc` 服务 Browser。
- [ ] 消除 typecheck/lint 对已有 `dist` 的隐式依赖；优先使用项目引用或源码路径，不把“先 build”当永久规避方案。
- [ ] 增加统一的冷环境验证入口，覆盖 install、build、lint、typecheck、test。
- [ ] 把 Browser 的 status 脚本、UI 的 `echo` 与真实测试明确分开，禁止计入测试通过数。
- [ ] 建立 `quality-fast` CI：frozen install、core/Browser 辅助代码的 build、lint、typecheck、Vitest 和生成物校验。
- [ ] 增加生成物漂移检查，确保 core snapshot、policy worker、C++ `.inc` 与源码同步。

验证与退出条件：

- 在全新临时 checkout 中，`pnpm install --frozen-lockfile` 成功。
- build、lint、typecheck、test 可分别从冷状态独立成功。
- 缓存存在与否不改变结果。
- `apps/extension` 不存在，安装图、Workspace、lockfile、CI 和文档均不再引用 Extension 包或产物。
- `packages/core` 生成的规则与 worker 能被 Browser 冷构建消费。

### M2：Chromium 构建链修复

预计：2–4 人日，不含首次同步和冷编译等待时间。

步骤：

- [ ] 将 Linux ARM64/qemu 的 Rust host-tool workaround 与 macOS Apple Silicon 构建路径分离。
- [ ] 修复 `serde_json` 缺少 `fast_arithmetic` cfg 的根因；避免继续逐 crate 硬编码 synthetic build-script 输出。
- [ ] 核对并处理 63 个删除的 Chromium 测试资源，确保不会由脏 checkout 掩盖构建问题。
- [ ] 在固定 base commit 的干净 checkout 中应用全部补丁，验证 0030 个补丁无人工干预完成。
- [ ] 对齐 repository overlay、patch series 和实际 Chromium 源码；所有必要修改最终回写为可重放补丁。
- [ ] 完成 `out/Aegis` 开发构建、受影响 C++ 单测和 `out/AegisRelease` 非 component 构建。
- [ ] Release 构建同时覆盖 `chrome` 与 macOS installer 目标，避免只有中间 framework 而没有完整 App。
- [ ] 强化 `browser:status`：校验 base/patched SHA、dirty 状态、补丁完整性、产物类型和新鲜度，而不只检查目录存在。

验证与退出条件：

- 当前源码能够连续两次增量构建成功。
- 干净 checkout 能执行一次完整构建成功。
- `aegis_unittests` 和新增的构建脚本回归测试通过。
- `out/AegisRelease/Chromium.app` 存在且不依赖输出目录外的 component dylib。
- 如必须继续关闭核心功能才能构建或启动，M2 不能标记完成。

### M3：核心功能稳定化与单一策略合同

预计：3–5 人日。

步骤：

- [ ] 用独立 profile 和固定 fixture 重现当前“无法打开/崩溃”链路，保留符号化堆栈。
- [ ] 为 `last-modified` non-coalescing header DCHECK 等已知崩溃先补回归测试，再落修复。
- [ ] 逐项启用 Aegis 总开关、Tracker、Filter List、Link Sanitize，执行单模块、组合和全开矩阵。
- [ ] 恢复 Tracker、Filter List、Link Sanitize 的产品默认状态；不接受“默认关闭但 UI 显示可用”。
- [ ] 为 Tracker、第一方 collect、CNAME、bounce、Cookie、链接去参和 EasyList 缓存补正例、负例、关闭状态测试。
- [ ] 为 Phish URL 与页面特征增加真实原因传递、误报负例和继续访问语义测试。
- [ ] 确认 Browser 的 Tracker 开关同时控制内置规则与动态过滤列表，Link Sanitize 读取真实 Browser pref。
- [ ] 在 Browser 拦截页分离“继续一次”和“永久标记安全”，并展示真实检测理由。
- [ ] 让 policy worker 的 ready/error 状态反映实际 renderer worker 是否已加载，而不是只反映开关。
- [ ] 由 `packages/core` 输出共享规则和 golden vectors，Chromium C++ 与 Browser 内嵌 policy worker 对同一合同执行回归；CI 阻止 `gbraid` 等生成物再次漂移。

验证与退出条件：

- 全部核心功能默认开启时，完成 50 次开发版冷/热启动压力循环；安装 RC 另完成至少 10 次独立启动，无崩溃。
- 每个开关的 UI 状态、持久化值和实际网络/页面行为一致。
- 主导航不被 Tracker 规则误拦，关闭模块后对应行为真实恢复。
- 同一输入在 core、Chromium C++ 和 Browser 内嵌 policy worker 中的关键决策一致。

### M4：安全与隐私正确性

预计：3–5 人日。

#### CDP / AI Control

- [ ] 已存在 CDP 服务不是 loopback 时拒绝启用并报告真实失败，不能 warning 后返回成功。
- [ ] `loopbackOnly`、监听地址和客户端计数从真实状态计算。
- [ ] 对 `/json/list`、WebSocket、`Target.getTargets`、discover 和 auto-attach 统一应用内部 target 过滤。
- [ ] 将相同授权检查应用到 `getTargetInfo`、直接 attach、activate、close 以及按已知 target ID 访问，防止“不可枚举但仍可操作”。
- [ ] 移除或收窄 `remote-allow-origins=*`；只保留本机自动化所需的最小握手范围。
- [ ] 增加 loopback 正例、非 loopback 负例、浏览器内部/本地/内联敏感 target 隐藏和横幅状态集成测试。

#### 本地 AI / Ollama

- [ ] 将 WebUI 到 browser service 的任意 prompt 字符串改为结构化 snapshot；在服务边界统一构造 prompt，并重新脱敏正文、URL、query、fragment 和标题。
- [ ] 对 loopback URL 做规范化和 DNS/IPv4/IPv6 边界测试，阻止绕过。
- [ ] 拒绝 userinfo、异常路径和跳转到非 loopback 的响应；脱敏失败时 fail closed 到启发式摘要。
- [ ] 使用本地 mock Ollama 捕获请求，证明测试邮箱、令牌和其他 PII 不进入请求。
- [ ] Ollama、WebLLM 不可用时显示准确降级状态；未安装 WebLLM 不得呈现为可用能力。

#### Chromium 出站与“无遥测”声明

- [ ] 建立启动、普通浏览、Safe Browsing、崩溃报告、更新、Variations 和过滤列表更新的出站清单。
- [ ] 用受控代理或 DNS 记录实际流量；明确哪些请求被关闭、保留或替代。
- [ ] Safe Browsing 等安全能力若保留联网，必须精确披露，不能继续用笼统“无遥测”覆盖。
- [ ] 在运行时证据完成前，相关文档状态保持“未验证”。

验证与退出条件：

- 所有 P0/P1 安全与隐私回归通过。
- 不存在“状态显示安全但实际 fail-open”的路径。
- 模型请求与浏览器出站声明都有运行时证据。

### M5：Android 修复、可复现构建与 Pixel 实机验收

预计：2–3 人日，不含首次 Linux 同步和冷编译时间。

步骤：

- [ ] 在干净 x86_64 Linux 环境从固定源码和补丁重建 `chrome_public_apk`。
- [ ] 让 Android `chrome://aegis` 能获取当前 HTTP/HTTPS tab；完成启发式摘要，或在修复前明确禁用按钮。
- [ ] 校验 Android 不暴露 CDP/Ollama UI，后台也不启动相应监听。
- [ ] 校验 applicationId、版本、架构、权限、签名和 APK SHA。
- [ ] 在 Pixel 9 Pro Fold 清洁安装并完成首次运行、普通网页、地址栏 `chrome://aegis`、设置入口、重启持久化。
- [ ] 验证普通、无痕、多标签和多窗口的 Profile 隔离；摘要不能从错误 Profile 或已关闭标签页取内容。
- [ ] 验证 Tracker、Phish、Link、Cookie、Fingerprint 和摘要的代表性正负例。
- [ ] 覆盖折叠、展开、横竖屏、浅色/深色、较大字体、前后台切换和覆盖安装。
- [ ] 检查 logcat、ANR 和 tombstone，确保旧崩溃不再出现。

验证与退出条件：

- Android M1d 的三条路径有同一 APK 的完整证据。
- 摘要真实读取当前网页；不能显示成功假象。
- 无稳定复现崩溃、ANR 或后台敏感服务。
- APK 可以映射回根 SHA、Chromium SHA、补丁和 GN 参数。

### M6：macOS 自包含 RC 与打包验收

预计：2–3 人日。

步骤：

- [ ] 从干净固定源码生成 `is_component_build=false` 的 release App。
- [ ] 在源码构建阶段确认产品显示名、图标、Helper、entitlements、版本和 Bundle ID；推荐 Bundle ID 为 `org.gcsa.aegis`，最终值需用户确认，不能只在打包后改 `Info.plist`。
- [ ] 使用 Chromium/macOS 正式嵌套签名流程，避免把 `codesign --deep` 或 `xattr -cr` 当发行方案。
- [ ] 生成 App、ZIP、DMG、SHA-256 和构建身份清单。
- [ ] 从 ZIP 解压、从 DMG 挂载后分别安装验证，不能复用 build tree 直接启动代替。
- [ ] 在独立用户目录连续启动至少 10 次，验证首次启动、重启、升级和设置保留。
- [ ] 使用真实安装 App 检查 `chrome://aegis`、菜单/设置入口、三语、核心功能和小/常用/最大窗口布局。
- [ ] 内部 RC 可使用明确标注的 ad-hoc 签名；公开发布前必须另行确认 Developer ID、公证和 stapling。
- [ ] 生成第三方许可清单、NOTICE/SBOM 和产物依赖扫描摘要。

验证与退出条件：

- App 脱离 `out/` 目录独立运行。
- `codesign --verify --deep --strict` 通过。
- 内部 RC 若未公证，必须明确标记“仅内部分发”，不得写成公开可发布。
- 产物版本、源码与补丁身份一致，没有旧 dylib 或旧资源混入。
- 只有另行确认 Developer ID 后，才执行 hardened runtime、公证、stapling 和 Gatekeeper 外部分发检查。

### M7：文档纠偏与最终状态评审

预计：0.5–1 人日。

步骤：

- [ ] 更新根 README：补上 `apply-patches`，给出真实冷构建顺序。
- [ ] 更新 Browser README：补丁范围从 0023 改为 0030，产物路径与命令以实测为准。
- [ ] 删除 README、架构、research map 和产品页中将 Extension 描述为参考实现、研究工具或可选交付物的内容，统一为 Browser-only。
- [ ] 更新 `packages/core` 中“Extension today / Browser later”等过时注释，明确 core 只服务当前 Browser 集成。
- [ ] 更新 Roadmap：分开记录源码、构建、自动测试、实机、内部分发和公开发布状态。
- [ ] 更新 Android 文档：记录 M1d 实测、摘要真实能力和 Linux 构建证据。
- [ ] 更新产品页：硬编码会话数据标注为演示，不把旧产物路径写成当前分发包。
- [ ] 更新 overlay/tree-layout/architecture/research map：区分已实现、接口占位、未来研究。
- [ ] 将“无遥测”“默认不出机器”“可分发”等声明链接到对应验收证据或标为未验证。
- [ ] 添加自动文档检查：版本、补丁数量、关键命令、产物路径和内部链接。

验证与退出条件：

- 同一能力在 README、Roadmap、产品页和平台文档中的状态一致。
- 每项发布性声明都有自动测试、实机证据或明确“未验证”标签。
- 文档只在平台验收后更新为完成，不能预先勾选。

## 5. 测试与 CI 矩阵

### 快速门：每次变更

- frozen install
- core/Browser 辅助代码 build、lint、typecheck、Vitest
- core snapshot / policy worker / generated `.inc` 漂移检查
- Browser-only 边界检查：不得重新引入 Extension package、manifest、构建或分发入口
- 文档链接、版本和补丁数量检查

### Chromium 增量门：修改 overlay、patch、GN 或 native code 时

- 干净应用补丁
- 编译受影响目标
- `aegis_unittests` 与缺陷相关 C++ 测试
- 固定本地 fixture 的 Browser 集成测试

### RC 冷构建门

- 无旧缓存完成 macOS 非 component build
- x86_64 Linux 完成 Android build
- 生成产物身份清单和 SHA-256
- macOS 安装 App 与 Pixel 真机验收

### 建议 CI 作业

- `quality-fast`：Linux，JS workspace 快速门。
- `patch-integrity`：固定 base 上应用补丁并检查生成物。
- `chromium-macos`：自托管 macOS runner，native build、单测和冒烟。
- `chromium-android`：x86_64 Linux runner，APK 构建与静态校验。
- `release-candidate`：手动或 tag 触发的无缓存双平台构建，不自动公开发布。

## 6. 发布闸门

### G0：现场与身份

- 根仓库和 Chromium checkout 身份明确。
- 当前 dirty work 已封存；无未说明删除。
- 0030 个补丁可干净重放。

### G1：可复现质量

- frozen install、build、lint、typecheck、自动测试全部冷状态通过。
- Browser/UI 不再把占位脚本计作测试。
- `apps/extension` 及全部专用引用已移除，`packages/core` 只为 Browser 生成策略资产。

### G2：核心功能与安全

- 三项被默认关闭的核心能力已恢复并通过稳定性矩阵。
- CDP loopback/target 隔离 fail closed。
- 模型请求满足完整脱敏合同。
- 功能开关与真实行为一致。
- 出站与隐私声明有运行时证据。

### G3：产物完整性

- macOS App 自包含；App、ZIP、DMG、APK 都有身份和哈希。
- 签名与目标渠道一致，无旧构建混入。

### G4：实机验收

- macOS 安装 App 完成功能、视觉、重复启动和升级检查。
- Pixel 完成首次运行、网页、设置、`chrome://aegis`、摘要和折叠屏检查。
- 无未解决崩溃、ANR、敏感数据泄漏或成功假象。

### G5：声明一致性

- Roadmap、README、产品页和平台文档一致。
- 未完成能力明确标为实验性、未实现或未验证。
- 许可、品牌、隐私、Data Safety 和渠道要求已审查。

### 直接 No-Go 条件

出现任一项即停止发布：

- 当前源码不能冷构建，或产物无法映射源码 SHA。
- macOS App 仍依赖 build tree，或签名验证失败。
- CDP 可通过非 loopback 访问，或内部 target 可从远程协议枚举。
- 正文、URL、标题中的测试 PII 进入模型请求。
- 核心功能默认关闭，或 UI 开关与真实行为不一致。
- Workspace、CI、文档或发行物中仍保留 Extension 产品线或依赖其结果证明 Browser。
- 真机存在稳定复现崩溃、ANR 或错误成功状态。
- 文档仍把演示、旧产物或“源码存在”描述成可发布。

## 7. 工期与里程碑

| 阶段 | 预计人日 | 主要依赖 | 里程碑 |
|---|---:|---|---|
| M0 基线封存 | 0.5–1 | 用户确认分类边界 | G0 可评审 |
| M1 Browser-only / Workspace | 1–2 | M0 | Extension 移除，JS 冷质量门通过 |
| M2 Chromium 构建 | 2–4 | M0 | 当前 native 源码可构建 |
| M3 核心稳定化 | 3–5 | M2 | 核心功能全开稳定 |
| M4 安全与隐私 | 3–5 | M2，可与 M3 部分并行 | G2 可评审 |
| M5 Android | 2–3 | M2–M4、Linux 构建机 | Pixel 实机通过 |
| M6 macOS RC | 2–3 | M2–M4 | 内部 RC 可分发 |
| M7 文档 | 0.5–1 | M5、M6 | G5 可评审 |

单人串行预计约 **14–24 人日**，不含 Chromium 首次同步、冷编译和外部服务等待。具备 macOS 与 x86_64 Linux 构建机时，M3/M4 和 M5/M6 可适度并行，预计约 9–14 个工作日完成内部 RC。

## 8. 风险、回退与停线规则

- 每个阶段使用独立提交；不得用 `reset --hard`、广域清理或覆盖式同步处理 dirty work。
- Chromium 构建优先使用新 out 目录或明确隔离的增量目录，不删除现有可用产物。
- 临时 feature flag 只用于二分；阶段结束前恢复预期默认值并留下测试。
- 生成物更新必须可重复，且以 CI diff 为零作为验收。
- Android 不自动清数据；需要清洁安装时先确认并保存必要证据。
- 签名、公证、Play 上传和公开发布保持关闭，直到用户单独授权。
- 任何身份不明、PII 出站、非 loopback CDP、稳定崩溃或产物无法对应源码的情况立即停线。

## 9. 建议的确认方式

推荐确认范围：

> 确认按本计划实施到 G5，目标为内部 RC；允许本地源码修改、测试和构建，但不使用生产签名密钥、不公证、不上传 Play、不公开发布、不删除现有证据。

若只希望先降低风险，可先批准 M0–M2；完成基线与冷构建恢复后，再根据实测结果确认 M3–M7。
