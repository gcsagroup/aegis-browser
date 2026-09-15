# Chromium 上游更新与安全补丁维护

本流程由用户于 2026-09-13 授权执行。目标是及时发现正式 Stable 和已被利用漏洞，准备可审核升级候选，并分别验证源码、构建产物与安装运行状态。

## 调度与来源

- 在当前 Codex 任务中每小时运行一次检查。普通更新最多每日汇总；已被利用漏洞、新的采集失败、恢复、候选失败或需要处理的变化立即报告。已报告的相同状态保持安静。
- 本地计划任务需要电脑开机、Codex 应用运行、项目可访问；这不是独立服务器上的全天候监控。
- 官方来源：Chrome Releases 的 JSON 公告流、ChromiumDash 的平台 Stable 记录、VersionHistory 的平台版本，以及 chromium.googlesource.com 的发布标签。
- 固定回查最近 45 天。已记录但未覆盖的已利用漏洞持续保留，不因超出回查窗口消失。首次运行不能保证覆盖 45 天以前的所有历史漏洞。
- 排除 Early Stable 和小比例提前投放；不能把最大版本号直接作为正式 Stable。Mac ARM64、Windows x64、Android 分别核对；iOS 的 WebKit 更新另行跟随 Apple，不套用 Chromium 版本结论。
- 公告、API、标签不一致或获取失败时，结果为不完整，保留上次成功时间；不能报告“没有更新”。标签与 ChromiumDash 的源码提交必须一致。

## 执行与证据

在项目根目录执行：

```bash
python3 apps/browser/scripts/check-chromium-upstream_test.py
python3 apps/browser/scripts/check-chromium-upstream.py
```

脚本只读正式版本、源码位置和本机 App 包元数据，只在 `.artifacts/chromium-upstream/monitor/` 写入结果：

- `latest.json`：最新核查、来源 URL/内容摘要、平台候选、未解决的已利用漏洞、检查错误。
- `last-success.json`：最近一次完整成功核查；失败运行不会覆盖。
- `state.json`：上次尝试与成功时间、报告去重指纹。
- `runs/`：状态变化时保存的历史证据，不每小时重复保存同一状态。
- `check.lock`：排斥同时运行的检查。退出码 0 表示检查完成，2 表示结果不完整；两者都不表示安全更新已经安装。

`notification.notify` 是本轮报告建议，不是消息已送达的证明。定时执行器还要检查运行记录与当前任务上次实际报告，避免中断时漏报。普通待报变化会保留到每日汇总窗口。包元数据不证明签名、源码回补或正在运行的进程；旧安装包仍在时不能因为修改了源码版本就解除提醒。

## 候选流程与验收

1. 发现 → 核对平台正式公告、版本与提交，并保存候选版本。响应目标：已被利用漏洞 1 小时发现、24 小时候选验证；普通安全更新 72 小时验证。这是目标，超期必须报告原因。
2. 保存现场 → 记录主仓库、Mac 源码、V8 的 HEAD、补丁差异和未跟踪源码；不覆盖、清理或丢弃开发改动。
3. 隔离准备 → 统一使用 `/Users/lazy/Projects/GCSA-aegis-build/upstream-candidate`，复用共享 Git 对象；每次只有一个候选在执行。读取当前候选记录，已有任务运行时不重复拉取/构建。版本变更先保存旧候选证据。
4. 重放 → 在候选的独立源码和 V8 中按序应用所有项目补丁，核对依赖版本。遇到冲突保留 Git 状态、补丁编号和错误，由当前任务进行有依据的适配；禁止无条件采用 ours/theirs 或跳过补丁。
5. 测试 → 先验证受影响源码和补丁，再运行相关上游回归、Aegis 原生测试、构建与真实 App 验收。每次 Mac 编译或打包前递增产品版本/构建号，并保持后续候选构建路径一致。
6. 审核 → 完成版本双 pin、补丁、依赖、构建身份、测试报告和升级/回退说明后形成候选。源码修复、产物构建、设备安装运行分别记录，不能相互替代。
7. 发布 → 合并、正式签名/公证、替换固定验收 App、发布与终端自动升级，等候候选结果审核；监控任务不自行执行。

当前正式源码入口是产品主仓库的 main。隔离候选只用于准备与检查，不把主仓库版本文件先改成尚未通过的版本。禁止在已有开发工作区直接运行可能 `checkout --force` 的旧 fetch 脚本。空间不足时保留候选和准确失败原因，不自动删除 out、源码、依赖、用户资料或旧证据。

## 2026-09-13 初始状态

- 正式固定版本及本机两个 App 均为 `151.0.7922.77`。
- 已核对正式候选：Mac/Windows `153.0.8010.37`，提交 `b75a5a95ea1a1b55bdbfd6d9f42d47be7507fb8b`；Android `153.0.8010.36`，提交 `507c6ee3e2f3b2ca0e660547e5b9ea4820c67f4c`。
- 已确认 CVE-2026-85046 对应的 V8 修复未进入当前源码；CVE-2026-87491 尚无回补证据，需继续逐项核验。
- 旧 Release 完整性检查为 5 个失败、2 个警告，不能作为升级或发布完成证据。
- 原有改动已保存在 `.artifacts/chromium-upstream/20260913-baseline/`。首次联网检查与回归结果见 monitor 目录；候选的实际进度以候选目录内记录为准。
- 已拉取 `153.0.8010.37` 候选并重放 58/108 个 Chromium 补丁；第 59 个补丁遇到 Actor 权限检查重构冲突，现场已保留。V8 已对齐新版依赖，2/2 个项目补丁重放通过。以上只表示源码准备进度，尚未完成依赖同步、原生编译、回归或 App 验收。具体冲突和下一步见 `.artifacts/chromium-upstream/candidate-status.zh-CN.md`。

来源：[9 月 3 日安全公告](https://chromereleases.googleblog.com/2026/09/stable-channel-update-for-desktop_01882797386.html)、[9 月 8 日正式 Stable 公告](https://chromereleases.googleblog.com/2026/09/stable-channel-update-for-desktop_0808145027.html)、[VersionHistory API](https://developer.chrome.com/docs/web-platform/versionhistory/reference)。
