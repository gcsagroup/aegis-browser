# Chromium 158 安全更新源码候选（2026-11-24）

本候选从远端 main `55bf70ea2e06517d20d383065f3df07764c676c2` 准备，桌面 pin 更新为 `158.0.8127.89`（`1de57fa19722fa6d6841d4f596c394d015580656`），Android pin 更新为 `158.0.8127.92`（`aa8057651dc34373e52d0a0cefd7904a11b3e130`）。不覆盖主目录开发内容，不更换固定 App 或用户资料。

## 安全与功能

[官方桌面公告](https://chromereleases.googleblog.com/2026/11/stable-channel-update-for-desktop_01734282054.html)列出 Critical 级别 CVE-2026-134401：Variations 输入校验缺陷，未标注已被利用。Chrome Releases、ChromiumDash、VersionHistory 和源码标签核对成功，排除 Early Stable。

桌面531项、Android352项 Chromium 补丁按序完整重放通过，两平台各3项 V8 补丁通过，不需要调整或跳过任何补丁。重放树分别为 `8214b85140c57df3231b4e07a25eb751ab3005fc` 与 `4967c54925fd2140a7d28e28c562c178f8a73ff4`；V8 基线仍为 `b601a2347f005e8bfadd32f285df97ffba5cf1bd`，补丁树为 `7e574c4a3111addec961740e38e5bd3917eb68ce`。

786份覆盖文件与重放后的Chromium及嵌套V8树一致，功能合同与最新main相同。此次上游修改的Variations文件均与官方blob完全相同；重叠的JUnit构建清单与枚举文件仅保留既有Aegis测试和Agent枚举。Windows安装夹具同步新pin，四份官方输入文件的blob未变化。

最新main的Android包名和独立Profile验收改动已保留。包名配置本身不证明旧安装兼容，实际包名、签名及保留资料升级仍须真机验证。

## 本轮验证

- 完整 `quality:fast` 通过，包含lint、类型检查、核心测试及覆盖率、脚本、功能、模型、仓库合同和访问账户回归。
- 监控及发行流程89项通过、2项跳过；跳过项不计为平台验收。
- main新增Android宿主回归63项、发行编排22项、平台路由8项通过；这些包含夹具，不能替代Android产品实机验收。
- 源码pin、许可证链接、Windows夹具pin及当前文档一致；`git diff --check` 通过。

## 尚未完成

本轮没有编译或打包。可用空间约99 GiB，低于既有100 GiB构建门槛；未清理源码、缓存或旧证据。下次真实编译前必须递增产品构建号，不能重复使用344标识新产物。

固定Ver 7.5 (344) App仍绑定原构建提交 `9d07d1820729a3c4c568005f0d590fc3b0f7e501` 和旧内核158.0.8127.37；关键文件摘要未变。原证书吊销导致严格签名与Gatekeeper失败，不是本候选的原生运行或正式发行收据。Windows没有发行签名及交互会话，Android缺受支持Linux x64构建机及真机。

草稿PR只同步源码，不授权豁免原生兼容、独立审核、必需CI、三平台签名/安装、正式Release及旧客户端更新安装回读。CVE-2026-125350的实际用户安装覆盖仍未解除，不以新版源码pin关闭历史漏洞记录。

原始检查、重放和测试证据保存于 `.artifacts/chromium-upstream/heartbeat-20261124-0907/`；正式发行、tag及资产在本轮均未生成。
