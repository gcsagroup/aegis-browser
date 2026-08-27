# JavaScript 防护后续执行：构建身份、运行时与签名（2026-08-27）

## 结论

- **本地反指纹能力与源码—产物闭环通过**：当前 Release App 完成 346/346 条真实运行时断言；固定摘要的 schema v3 清单在运行前、运行后和报告发布前均验证通过。
- **通用恶意 JavaScript 检测仍是 No-Go**：本轮没有新增 AST、V8 bytecode、行为图、信息流、LLM 或联邦学习检测器，能力边界仍是 API 输出扰动、反跟踪、钓鱼缓解和浏览器内部安全边界。
- **公开发布仍是 No-Go**：本地证据的信任等级是 `cooperative-local-workflow`，不是受保护 CI 的签名证明；同时缺少正式产品 Bundle ID、Developer ID、hardened runtime、公证、stapling 和真实安装验收。

本轮只完成本机源码、构建、测试、运行时、隔离打包和可视检查；没有部署、上传、发布、公证或使用生产签名密钥。

## 已实施

### 1. schema v3 本地构建身份

`build:release` 现在使用同一原子目录锁执行以下顺序：归档旧清单和旧 `Chromium.app`、确认目标 App 不存在、生成 GN 图、冻结输入、编译、再绑定最终 App。失败构建不会产生 finalized manifest，旧 App 保留在 `.aegis/history/`，没有被删除。

身份脚本现在硬校验：

- 固定 Chromium base 到 HEAD 的 52 个提交与 `patches/series` 顺序完全一致；每个 format-patch header SHA 和稳定 patch-id 都匹配对应提交；
- 仓库 146 个 overlay 文件在 Chromium checkout 中逐项匹配内容、类型和权限；
- `aegis-release.gn` 与实际 `args.gn` 经 Chromium 自带 `gn format --stdin` 规范化后完全一致，并记录 `build.ninja` 哈希；
- begin 阶段亲自观察到 App 不存在，finalize 阶段要求同一锁、同一源码、同一构建图、同一目标集合、App 在本次尝试后创建，且 Ninja log 在 begin/finalize 之间确实变化；
- 对完整 App 目录树记录路径、模式、大小、文件内容和内部符号链接，拒绝路径穿越、父目录符号链接逃逸和树外链接；
- 清单 payload、文件及 sidecar 都有 SHA-256，验证方必须提供独立固定摘要。

该证据证明本机受控流程中的一致性与构造观察，不抵抗控制同一主机、源码和清单的攻击者。因此明确输出：

- `localSourceArtifactBinding=true`
- `trustLevel=cooperative-local-workflow`
- `trustedBuildAttestation=false`

### 2. 打包与签名边界

macOS 打包现在与构建共用锁；非诊断打包必须显式提供 `AEGIS_BUILD_MANIFEST_SHA256`。版本分量、格式列表、component 类型、DIST 与源 App 交叠、中间父目录和 identity 叶子符号链接都在任何 dist 修改前 fail-closed。复制前后两次来源验证 JSON 必须逐字相同，包快照使用独立 artifact root，并记录父构建 manifest SHA、manifest ID、源 App 树 SHA 以及本地 plist/签名后处理关系。

签名脚本只在主 App 与外置 sibling Helper 全部 `codesign --verify --deep --strict` 已通过时跳过，否则完成嵌套 ad-hoc 签名并强制做最终 strict/deep 验证。实机验收还发现当前 macOS `codesign` 不支持 `--quiet`；该参数已移除，fake-codesign 夹具已增加 sibling 修复成功和持续无效分支。

### 3. 运行时发布门分层

反指纹验证器会在执行 Chromium 前校验固定清单，完整矩阵结束后再次校验，并在报告发布前做第三次末次校验；清单、源码、构建图或 App 树任一变化都会失败。运行全程与 build/package 共用锁。报告路径会规范化真实父目录，拒绝通过符号链接覆盖 App、身份清单、sidecar、Git 元数据或已跟踪源码；报告使用不覆盖的原子发布，异常处理也不再回写禁止目标。

发布门不再把本机清单直接等同于发行证明，而是分别输出：

- `localArtifactIntegrity`
- `localWorkflowConstructionObserved`
- `trustedBuildAttestation`
- 运行时、覆盖、签名结构、hardened runtime、Developer ID、Gatekeeper 和产品身份门

## 当前证据

### 构建身份

- manifest：`$HOME/Projects/GCSA-aegis-chromium/src/out/AegisRelease/.aegis/build-manifest.json`
- manifest SHA-256：`8c3794c2a4c23ce92b87f3f01132be1c9e0c82cbe7f7777fd39d62750b373cb9`
- manifest ID：`b4b39b3b-da04-4bc8-ac33-00ce4ccbdb91`
- Chromium HEAD：`53bd1c0a39f8c6ffe58d346c140b98a295f98de1`，checkout clean
- App 树 SHA-256：`40263db6b4ce39726b474d82c6e3cf0f504082635af539b0e8f888f40c4db18f`
- 固定摘要、payload、sidecar、源码前后、构建图前后、补丁 lineage、overlay、GN、App 树：全部通过
- 根仓库保留用户与并行开发的未提交工作，因此资格是 `diagnostic-only`，不是 clean candidate

### 测试与真实运行

- 脚本测试：通过；身份自测 9/9，运行时验证器自测 14/14，build/package 路径门与签名夹具通过
- Blink farbling 定向测试：3/3
- `aegis_unittests`：63/63
- `aegis_browser_unittests`：43/43
- 本地运行时报告（保留在工作区证据目录，未随公开源码发布）：`.artifacts/fingerprint-runtime-release-2026-08-27-8c3794c2-r2.json`
- 报告 SHA-256：`03b658c44dd54588d652537c33bcadc58a99105c228935571d87be873a4d1ad4`
- `runtime_pass=true`、`coverage_complete=true`、346/346、`sourceArtifactBinding.verified=true`、`terminalVerified=true`
- 11 次受控浏览器运行全部退出 0，0 FATAL、0 残留进程、0 新增或修改 Crashpad/DiagnosticReports 记录
- `release_eligible=false`；验证器退出码 2 表示行为通过但发行门未齐

实际桌面 `chrome://aegis` 已在本轮较早阶段用 Computer Use 验收：保护运行、8 个模块可见，Canvas/Audio/WebGPU 探针返回受保护结果，WebGPU vendor/architecture 为空且页面没有 `Aegis` 明文标记。最终重建 App 的完整树哈希与当时被测 App 相同。最终复查时 Mac 再次锁屏，自动解锁被拒绝；没有绕过系统锁，也没有改动用户现有标签。

### 隔离打包与签名

- 隔离目录：`/tmp/aegis-package-acceptance-final-r2.c5XpBd`
- 包快照 SHA-256：`f029fac1d5268736cf1c3eb109a80635ffedf9f41e78d109c942979a09d0dcc0`
- 打包 App 树 SHA-256：`fd7fa49d11813eae62708287c62eae85a2df3c41645c2ebc32ace6110ea7d78b`
- `codesign --verify --deep --strict`：通过，仅证明本地 ad-hoc 结构有效
- `CFBundleDisplayName=GCSA-aegis`，但 `CFBundleIdentifier=org.chromium.Chromium`
- `TeamIdentifier=not set`，无 hardened runtime；`spctl --assess` 返回 rejected
- 首个新隔离包在真实签名门暴露了 `codesign --quiet` 不受支持，失败目录 `/private/tmp/aegis-package-acceptance-final.UvflyJ` 保留且未生成成功 identity；修复后使用全新目录重跑通过
- 当前 Keychain 只发现两张 Apple Development 身份，没有 Developer ID Application 身份；未替用户选择团队或修改产品 Bundle ID

build-tree App 本身保留 Chromium linker/ad-hoc 状态，strict/deep 仍失败；隔离包通过 ad-hoc 结构门不能反推 build-tree App 或公开发行包已签名。

## 门禁结论

- JavaScript 反指纹行为：**Pass**
- 本地源码、构建图与 App 完整性：**Pass（cooperative-local-workflow）**
- 隔离包 ad-hoc strict/deep 结构：**Pass（仅本地）**
- 通用恶意 JavaScript 内容检测：**No-Go**
- 受信任构建证明：**No-Go**
- 产品身份、Developer ID、hardened runtime、公证、Gatekeeper、安装验收：**No-Go**
- 部署与公开发布：**未执行，No-Go**

下一步只有在用户确认正式产品 Bundle ID、签名团队和发行渠道后，才能进入独立干净构建器、Developer ID 嵌套签名、公证/stapling、安装后多次独立启动与升级保留验收。当前不应继续把论文级检测研究塞入默认页面热路径；应先用冻结数据集离线评估 AST/行为图候选的精度、破站率和性能预算。
