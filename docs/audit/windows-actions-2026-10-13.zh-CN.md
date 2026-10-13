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

组织管理页面当前仅列出标准 GitHub 托管 runner，未列出专用 Windows runner。此前 Team 与 32 核 runner 购买已取消，本轮未新增套餐或调整预算。Actions 的实际运行结果将在执行后补记。
