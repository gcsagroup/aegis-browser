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

组织管理页面当前仅列出标准 GitHub 托管 runner，未列出专用 Windows runner。此前 Team 与 32 核 runner 购买已取消，本轮未新增套餐或调整预算。本轮随后获得用户明确授权，恢复 Team 月付、$40 Actions 预算及一次 32 核、最多 4 小时的完整编译试跑；付费构建状态独立记录。

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
