# macOS 与 iOS 本轮验收证据

对应[验收报告](../../native-website-reading-ui-2026-10-13.zh-CN.md)。macOS Ver 5.0 (202) 与 iOS Ver 7.0 (118) 的原生构建、签名和 UI 验收在本机完成；本目录保存当时的日志及官方 xcresult 摘要，不代表 GitHub Actions 已运行或产品已经发布。

## 结果

- `mac-unit-202.log`：307 项原生单元测试通过。
- `mac-browser-202.log`：4 项 EnhancementBrowserTest 通过。
- `ios-iphone-118-summary.json`、`ios-ipad-118-summary.json`：分别从原始 xcresult 用 `xcrun xcresulttool get test-results summary` 导出，各 13 项通过，零失败；同名 `.log` 保存完整命令和测试过程。
- `ui-core-202.log`：14 项界面、语言及阅读边界测试通过。
- `quality-fast-202.log`：本机开发目录的完整快速质量检查通过；`quality-fast-public.log` 为公开提交工作区另行执行的检查。
- `mac-build-202.log`、`mac-sign-202.log`、`contracts-202.log`、`patch-tests-202.log`：构建、签名和契约检查记录。
- `public-patch-replay.json`：本轮两项补丁接在既有公开资产补丁之后可重放，结果与本轮覆盖文件一致，未重新引入不公开的研究模型权重。

`manifest.json` 记录源日志及公开副本摘要。日志清理行尾空白，并将本机绝对路径替换为 `<home>`、`<repo>`、`<build-root>`；测试结果不改写。最终截图展示原生英文、繁体脚本设置和 iOS 深色阅读。脚本名称与文章正文是验收输入，保持原文。

完整原始测试包、PDF、较早失败证据、应用备份和日常会话恢复回执仍保留在开发机 `.artifacts/ui-unification-20261013/`。公开副本初次检查因补丁编号已被既有公开资产补丁占用而失败，失败日志保留为 `quality-fast-public-initial.log`；顺延编号后完整重跑通过，见 `quality-fast-public.log`。验收测试服务的 20 项代表性自检和平台特性 4 项测试也通过。

本次没有构建、连接或部署 Windows；Android 仅随仓库契约同步版本元数据，没有新增平台验收结论。
