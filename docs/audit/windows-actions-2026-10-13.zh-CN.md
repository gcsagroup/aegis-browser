# Windows 提交与 Actions 验证

日期：2026-10-13。

Windows 共用功能、平台参数、构建覆盖文件及验收脚本已包含在 `codex/publish-integrated-20261013` 分支的 `a792c2ed25fbff92001bfd98c8eabd9bf24ea8b1` 及其祖先提交中。本轮将本地 33 个名称含 windows、路径含 /win/ 或扩展名为 .ps1 的受跟踪文件与该分支逐字节比较，全部一致；[清单及摘要](evidence/windows-2026-10-13/source-comparison.json)可复核。本次补交构建准备和历史进度证据，不覆盖当前较新版本为旧候选 186。

## 历史构建证据

- [升级准备回执](evidence/windows-2026-10-13/upgrade-preflight-receipts.json)：源码、依赖和工具链准备记录；仅证明准备环节。
- [186 源码身份](evidence/windows-2026-10-13/source186.json)：Windows 候选 4.0.0.186 的目标内容树及版本头摘要。
- [最后可信进度](evidence/windows-2026-10-13/poll-20261013-0658.json)：北京时间 06:58 编译 14,344 / 62,661，测试仍等待构建，结果列表为空。

07:13 既有连接发生认证失败，此后没有新的远端构建或测试回执。本次提交不代表 Windows 完整编译、原生测试或界面验收通过。原始日志、旧版本及恢复资料继续保留在本地和远端既有目录，凭据及主机连接程序不提交。

## Actions 范围

使用仓库既有 `Other Platform Coverage` 手动工作流，选取上述集成分支。其 Windows 2025 标准 runner 运行 PowerShell 验收脚本的四项安全边界测试并上传覆盖率证据；同一工作流也运行 Bash 行为测试。此工作流不构建 Chromium，不代替 Windows 原生产品测试。

本轮开始时组织仅有标准 GitHub 托管 runner，此前 Team 与 32 核 runner 购买已取消。随后获得用户明确授权，恢复 Team 月付、$40 Actions 预算及一次 32 核、最多 4 小时的完整编译试跑；付费构建状态独立记录。

## 标准 runner 实际结果

[Actions #1](https://github.com/gcsagroup/aegis-browser/actions/runs/38392531527) 于 2026-10-13 11:46 UTC 启动，绑定提交 `df5ac9f9df1a944f5f64964d0b869c3c626584e0`，最终成功，总时长 1 分 18 秒。Windows 作业 40 秒、Bash 作业 1 分 15 秒，两份覆盖率产物已下载留存。

Windows 既有验收脚本自检通过，包括原生互操作编译；Pester 安全边界测试 4/4 通过。生产脚本命令覆盖率为 57 / 1,014（5.62%），覆盖范围有限；`ui_interaction_tested=false`，不能理解为实际浏览器 UI 验收。详细回执见同目录的 `actions-run.json`、`powershell-coverage.txt`、`powershell-script-report.json` 和测试 XML。

本地候选编排回归 14 项及仓库合同检查通过；最初的测试发现表达式未匹配文件，没有运行测试，随后使用实际 `candidate_test.py` 完成 14 项回归。

## 32 核完整构建试跑配置

用户明确恢复付费方案并再次确认结算条款后，组织已成功升级到 GitHub Team，月付 7 席共 $28。新建 `aegis-windows-32`，Windows x64、32 核、128 GB 内存、1200 GB 存储、Windows Server 2025 with VS2026，最大并发 1。费用页面及付款资料截图仅留本地，不放入公开证据。

`chromium-candidate.yml` 增加默认关闭的 `windows_hosted_trial` 手动选项。选中后仅执行 Windows 试跑：先在标准 Windows runner 跑编排回归，再使用上述大规格机器。机器组限定本仓库、本集成分支的这一工作流；工作流只读源码，无 PR 自动触发，不允许直接 Re-run 消耗付费机器。

候选递增为 Ver 5.0 (203)，保持 Chromium 155.0.8059.40 的固定提交及完整补丁。Android 仅同步仓库要求的版本元数据，没有构建 Android。托管流程在全新短路径准备固定 depot_tools、Chromium 与 V8，同步依赖，核对补丁重放树，生成 GN，再编译 chrome、mini_installer、完整 Aegis 原生测试及 browser_tests。测试执行全部 Aegis 原生单元测试与四项 EnhancementBrowserTest，禁止自动重试掩盖首次失败。

每次付费 job 最多 240 分钟；编排脚本的总工作时限为 210 分钟，留出初始化与上传时间。首次至少 300 GiB 空间，运行时低于 60 GiB 停止。候选安装包、逐阶段日志、源码身份和测试摘要作为保留 1 天的 Actions 产物上传，随后下载到本地长期留存。完整构建首次依赖下载耗时尚未测得，不保证在 4 小时内完成。

当前官方 Windows 32 核价格为 $0.162/分钟，240 分钟计算费上限场景为 $38.88；Team 订阅另计。Actions $40 为月度预算，包含当月已有消费，不能解释为本次任务精准扣费封顶。来源：[runner 规格](https://docs.github.com/en/actions/reference/runners/larger-runners)、[计费](https://docs.github.com/en/billing/reference/actions-runner-pricing)。

本地 22 项回归通过，覆盖真实子进程、超时停止、剩余空间门槛、临时 Git 补丁重放与脏目录保护、空/失败/跳过的测试摘要拒绝。新增版本补丁在当前 202 源码上只读应用检查通过，仓库合同和工作流 YAML 解析通过。完整 Windows 编译尚待实际运行结果。

组织 Actions 月度预算已保存为 $40，达到上限停用为 Yes；保存时当月已用 $1.61。专用 runner 组 `aegis-windows-trial` 仅允许本仓库上述分支的候选构建工作流，runner 状态 Ready、并发 0/1。

首次完整工作流 [38395665299](https://github.com/gcsagroup/aegis-browser/actions/runs/38395665299) 绑定 `b536755836e4ddc411e3adcda688f1a12053add0`，标准 Windows 前置测试运行 22 项，其中补丁重放样本因平台换行转换失败。付费作业跳过，没有开始本次付费编译。修复仅让测试样本保留 Git 原始补丁字节，并固定临时仓库换行设置；没有放宽生产补丁树校验。修复后本地 22 项再次通过，Windows 结果以下一次工作流为准。

## 完整构建已实际启动

[工作流 38396053667](https://github.com/gcsagroup/aegis-browser/actions/runs/38396053667) 绑定 `74da61b7208ec196671d0ea8aa6cb36936c589f2`。标准 Windows runner 的 22 项前置测试全部通过，测试耗时 4.119 秒、作业耗时 23 秒；日志见 [Windows 实际回归](evidence/windows-2026-10-13/hosted-windows-preflight-passed.txt)。两个 Windows 作业均在检出前关闭自动换行转换，确保补丁和覆盖文件字节保持一致。

北京时间 20:16:42，付费作业已分配到 `aegis-windows-32-1000002792`，组为 `aegis-windows-trial`。工具链及磁盘门槛检查通过，编排脚本的 Windows、32 核与托管身份检查通过；固定 depot_tools 已准备完毕，开始下载 Chromium 源码。启动回执见 [运行状态](evidence/windows-2026-10-13/hosted-started-run.json)及 [runner 身份](evidence/windows-2026-10-13/hosted-started-job.json)。

本记录为启动时快照：完整构建和原生测试尚未完成，安装包、交互验收、签名及正式发布没有通过结论。工作流会继续在 GitHub 运行，最多 4 小时，不会自动重试付费作业。提交证据不会改写这次运行绑定的源码提交。

## 203 试跑最终结果与 204 初始化修复

上述工作流于北京时间 20:24:34 失败，32 核作业持续 7 分 52 秒。源码下载和检出完成，但首次依赖同步找不到 `git.bat`。固定 depot_tools 的 `git_cache.py` 在 Windows 使用该包装入口；编排脚本禁止自动升级后遗漏官方首次初始化，包装文件尚未生成。失败发生在依赖阶段，未执行 GN、Ninja 或原生测试，没有生成安装包。完整日志和唯一失败产物已下载到本地，ZIP CRC、解压字节和 GitHub 提供的 SHA-256 均校验通过。

用户随后授权修复、验证入口并重跑。候选递增为 Ver 5.0 (204)，脚本显式调用固定 depot_tools 的 `bootstrap/win_tools.bat`，初始化后再次核对固定提交及四个入口文件。实际运行生成的 Python、vpython、gclient，并从 vpython 子进程调用 `git_cache.Mirror.git_exe`，覆盖本次真实失败路径；随后编译、链接和运行包含 Windows SDK 与 ATL 头文件的小程序。

同一初始化与入口验证用于标准 Windows 前置作业和付费构建机器，前置失败会阻止付费作业。标准机器验证其已装 VS，32 核机器仍严格要求 VS2026。两类工具链的版本不混为同一验收。前置日志保留 7 天，完整构建产物仍保留 1 天并由跟进任务下载。本地 24 项测试、版本补丁实际重放、仓库合同和工作流解析通过；Windows 真实入口与完整构建结果待新一次运行回读。

204 首次前置运行 `38400220781` 完成了官方初始化，但探测程序放在 depot_tools 目录外，未加载官方 `vpython.toml`，误用了旧 Python 环境而失败；付费作业跳过。探测移至与 gclient 同目录后，固定提交 `8fb3361814eeb9610b761cc35f0c4b5d2e952de4` 的[运行 38400747606](https://github.com/gcsagroup/aegis-browser/actions/runs/38400747606) 在标准 Windows 上全部通过，前置作业 47 秒，包含 24 项回归和实际入口验证。实测 Git 2.55.0.windows.5、引导 Python 3.11.8、vpython Python 3.11.9、VS2026 18.10.2；Windows SDK 与 ATL 小程序编译、链接、运行均成功。详细日志为本目录证据中的 `204-*.txt`，入口结果为 `204-toolchain-result.json`。

北京时间 20:55:00，32 核作业已启动于 `aegis-windows-32-1000002795`。该机器也完成了初始化及上述工具入口验证，已进入 Chromium 源码下载。完整编译和原生测试仍待结果。当前聊天的后台跟进已更新为此运行，每 15 分钟检查，完成时下载日志及存在的安装包、校验摘要并报告；失败后不自动重复付费构建。

## 204 最终结果与 205 源码接管门禁

204 于北京时间 21:05:31 在依赖同步阶段失败，32 核作业持续 10 分 31 秒。官方初始化与所有工具入口已通过；新原因是源码仓库只有直接 URL 拉取，没有 origin，gclient 执行 `git remote set-url origin` 失败。完整日志、两个 artifact 和原始 ZIP 已在本机保存并通过 CRC、逐文件字节与远端摘要校验；没有安装包或原生测试结果。

用户授权补齐 origin，并确认免费验收范围：真实 Chromium 固定版本稀疏检出及 gclient 接管，加带固定依赖和 hook 的小仓库完整同步；两者通过后才启动 32 核付费构建。脚本在拉取前创建 origin，并在检出和同步后核对上游 URL 与提交。生产完整同步和免费检查共用这两个步骤。真实 Chromium 检查解析原始 DEPS，但跳过 Git、CIPD、GCS 依赖和 pre-DEPS hook；它不代表完整 Chromium 依赖同步通过。小仓库使用真实 Git 与 gclient，核对依赖提交及实际 hook 产物，分别留存日志。

候选递增为 Ver 5.0 (205)，Android 版本元数据按合同同步，未构建 Android。25 项本地回归、版本补丁实际应用与仓库合同通过。免费前置最多 30 分钟；付费门禁、4 小时时限及预算停止条件保持原授权。Windows 新门禁与完整构建结果等待实际运行，尚无成功结论。

## 固定 SDK 修复与仅免费验证

205 的免费接管门禁已全部通过，但付费作业在 GN 生成 x86 工具链环境时缺少 Windows SDK 10.0.28000.0 的头文件目录。完整依赖、hooks、312 份 Chromium 与 3 份 V8 补丁已成功，Ninja 与原生测试未执行，没有安装包。21:47:29 结束后，全部日志和产物已保存并校验，没有自动重跑。

本次按用户要求补足固定 SDK：使用[微软官方安装器](https://learn.microsoft.com/en-us/windows/apps/windows-sdk/downloads)的 10.0.28000.2270 包，对应 Chromium 要求的 10.0.28000.0 目录。安装前验证固定 SHA-256 和微软签名；免费与付费机器共用安装脚本，保留安装日志。验收检查指定 Include/Lib/Bin 文件，显式指定 SDK 分别编译、链接和运行 x64/x86 程序，校验实际位数，并执行固定 Chromium 原始 setup_toolchain.py 的双架构环境生成。默认 SDK 不再能代替指定版本通过门禁。

新增 windows_preflight_only 输入。启用时仅运行标准 Windows 免费门禁；即使同时勾选付费试跑，付费作业仍被阻止。本轮不启动付费构建，也不生成新 App；产品版本暂保持 205。新增旧 SDK、缺 x86 库和上游版本漂移回归，本地共 28 项通过；实际 Windows 安装及入口验证待免费运行回读。

固定 SDK 实测已完成：[免费运行 38410192444](https://github.com/gcsagroup/aegis-browser/actions/runs/38410192444) 绑定 b21caa3b2081b22bf350f9109d6c09c4c4224fa8，于北京时间 22:28:31 成功，耗时 24 分 21 秒。28 项回归、固定 SDK 安装、13 项文件检查、x64/x86 编译链接运行，以及固定 Chromium 原始 setup_toolchain.py 的两种架构环境生成全部通过；真实接管和小仓库完整同步也通过。安装器微软签名有效，安装退出码 0。付费作业 skipped，未分配机器。详见 [汇总回执](evidence/windows-2026-10-13/sdk-28000-acceptance.json)、[SDK 回执](evidence/windows-2026-10-13/sdk-28000-sdk-result.json)及 [Chromium 原始入口回执](evidence/windows-2026-10-13/sdk-28000-chromium-toolchain-result.json)。完整日志和原始产物已在本机校验留存；本轮没有完整浏览器构建、原生测试或新安装包。
