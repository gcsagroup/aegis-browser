# iOS 可移植功能验收记录

日期：2026-10-11。基线：`main` 的 `e96c623`。本轮只修改 iOS、四端功能清单及对应检查和文档。已有桌面阅读与签名改动保留；不据此声称已合并、已发布或桌面三端完成新一轮验收。

## 实现范围

1. 搜索提供商及安全自定义模板、主页与启动、默认/网站缩放和桌面模式、JavaScript、弹窗、媒体、历史、网站权限与数据清除。
2. 导航保护开关与过滤规则前台更新；AES-GCM 阅读资料库、来源和引文绑定、PDF 指定页文字层、翻译预览、主动保存、检索、归档、导出及确认删除。
3. 手动或模型建议的有限操作，冻结窗口/模式/标签/导航版本，两次确认、防过期与重放；前台网页比较；下载网络和容量规则随任务持久化。
4. 40 项四端功能目录。覆盖原 Chromium 合同 24 个稳定 ID，补充 16 项浏览、阅读、下载及平台能力。检查缺端、缺译文、失效源码、缺验收依据和生成页面漂移。

使用方式见[简体中文](../ios-portable-features.zh-CN.md)、[繁體中文](../ios-portable-features.zh-TW.md)及[English](../ios-portable-features.en.md)。各平台差异见[四端清单](../platform-features.zh-CN.md)。

## 验收结论

本轮约定的三批可移植功能已完成。当前候选为 **Ver 4.0 (80)**。先完成双端全量回归，再对发现的问题修复复测；所有已知失败项均已有通过的复测结果。Ver 4.0 (79) 与 (80) 的产品 Swift 源码及资源一致，(80) 仅修改两项 UI 测试的短距离滚动和构建版本。

| 构建及范围 | iPhone | iPad |
| --- | --- | --- |
| (78) 全量，每台 245 项 | 241 通过、1 失败、3 项 iPad 专属跳过 | 242 通过、3 失败 |
| (79) 全部 207 项原生 + 6 条相关 UI | 213 全部通过 | 211 通过、2 项设置滚动失败 |
| (80) 两项设置 UI 复测 | 2 全部通过 | 2 全部通过 |

三个构建的输入清单前后均一致，运行时警告均为零。没有将多轮结果合称为“(80) 全量 245 项通过”。PDF 导入、阅读批注、翻译确认及显示、有限操作、前台检查和设置回读已用 Computer Use 实际操作；细节见下文。

四端清单共 40 项，其中 iOS 的 25 项记录对应范围的模拟器证据；固定滚动和 Aegis Access 代理能力保留未验收说明，其余未移植或系统负责的功能没有标记为通过。696 条界面文案的简体中文、繁體中文、英文无缺译，编译提取的 656 条键全部存在，格式占位符无不一致。

## 各轮验证记录

- Ver 4.0 (70)：编译在下载设置错误提示处触发 Swift 编译器断言；修正错误变量引用后重新构建。
- Ver 4.0 (71)：18 项新增原生回归在 iPhone 和 iPad 均通过，涵盖配置、来源隔离、加密存储、PDF、计划执行和下载回读。
- Ver 4.0 (72)：扩大到真实脚本开关、60 秒网页重载、四条新界面流程。网页重载比较通过；发现标题更新、界面点击及嵌套完成按钮定位问题。保留失败结果，不作为通过证据。
- Ver 4.0 (73)：动态页面标题和 JavaScript 网站覆盖设置修正后原生复测通过；继续修正手机键盘遮挡及表单滚动。此轮运行期间修改过输入，不能作为最终一致性依据。
- Ver 4.0 (74)：22 项新增原生测试在双机均通过；私密取消流程双机通过，阅读翻译保存及归档在 iPad 通过。其余界面测试暴露键盘焦点与按钮定位问题，整体不通过。输入清单前后保持一致。
- Ver 4.0 (75)：四条新增界面流程双机全部通过，输入保持一致。发现键盘工具栏的布局警告，未将本轮作为最终候选。
- Ver 4.0 (76)：移除键盘工具栏布局警告来源，并修正拒绝执行时沿用上次完成步数的问题。截图复核发现 iPad 表单宽度导致阅读对照仍上下排版，主动停止未完成的回归，改为全屏阅读后继续验证；此轮不作为全量通过依据。
- Ver 4.0 (77)：双机模型操作及拒绝重放计数通过，运行时警告为零。iPad 全屏阅读已显示左右对照；归档测试点击宽屏行空白处导致末尾断言失败，改为点击实际开关，并补充双端阅读排版断言后重新集中运行。
- Ver 4.0 (78)：完整回归每台 245 项；iPhone 241 通过、1 失败、3 项 iPad 专属跳过，iPad 242 通过、3 失败。两端各 207 项原生测试均通过，运行时警告为空，输入保持一致。界面失败为损坏下载记录提示缺少“原文件已保留”，以及 iPad 设置滚动定位。
- Ver 4.0 (79)：修正下载解码错误映射、PDF 成功导入后的旧提示，并将翻译与模型步骤确认改为携带固定数据的弹窗；补充发送地址、模型、正文的首次显示断言。全部原生及 6 条相关界面流程共 213 项：iPhone 213 项全部通过；iPad 211 通过、2 项设置滚动定位失败。两端各 207 项原生测试通过，新增的翻译/模型首次预览断言、私密取消和损坏记录提示均通过。运行时警告为空，输入前后保持一致。
- Ver 4.0 (80)：将两个设置测试改为短距离触屏滚动，避免越过目标控件。两端各 2 项全部通过，运行时警告为空，输入保持一致。产品源码和资源与 (79) 相同。

测试使用独立模拟器、合成网页、模型和下载服务。构建目录保持为仓库同级 `GCSA-aegis-build/ios/DerivedData`，每次编译递增构建号。失败与通过的日志和结果包分别存放在 `/tmp/aegis-ios-parity-*`，不覆盖旧记录。

## 证据边界

- 网络模型由本机合成服务返回固定回复。只证明发送确认、格式校验、取消及保存行为，不证明真实模型翻译质量或开放网页任务能力。
- 前台检查实测读取、按间隔刷新和比较正文；关闭面板或进入后台即停止。后台定时任务不在实现范围。
- 下载网络访问标志及每任务规则经过代码和本地传输检查；真实蜂窝切换、系统锁屏调度与耗电需真机验证。
- 仍未取得实机 iOS、签名分发、App Store、Windows 或 Android 本轮原生发布验收。WebKit、BT/磁力后端、第三方扩展、跨设备同步与 Chromium 深层能力差异已明确登记。

## 新增回归覆盖

`PortableFeatureTests` 包含 22 项原生检查：

- 搜索参数编码、自定义模板拒绝不安全结构、来源隔离、设置范围限制、损坏配置保留、规则更新节流。
- 真实 WebKit 的主页、缩放、历史和全局/网站 JavaScript 设置；清除网站数据时关闭多个普通窗口的标签并保留私密标签。
- 阅读资料密文、重启回读、搜索、归档、删除、错误密钥、损坏文件、并发保存、来源和引文绑定；PDF 有字页、空白页及越界页。
- 翻译结构校验、敏感内容处理、模型计划拒绝脚本及新增网址、跨窗口/模式/导航拒绝、过期及重复执行拒绝；分组和工作区实际回读。
- 前台检查读取、停止、敏感页面拒绝，以及等待 60 秒后实际重载并检测正文变化。
- 下载策略随任务保存、真实下载及哈希、续传沿用原策略、超限后保留容量错误原因。

四条新增界面流程覆盖设置保存后重启、下载选项修改、翻译预览及保存重开、双端对照布局、归档、私密保存/发送取消、模型建议和执行分别确认、前台检查开始与停止。模型回复来自合成服务，取消路径还校验服务端请求计数为零。

## 模拟器实际操作

Computer Use 操作使用独立 QA iPhone/iPad，PDF 为本次生成的两页合成文件：第一页含 `12 hectares`，第二页为空白。样本经 PDF 文本检查及逐页渲染检查，随后从模拟器的系统“文件”选择器导入。

- iPad Ver 4.0 (78)：导入空白页显示无法读取文字层；改为第一页成功。输入引文和批注后保存，再打开可读回内容并显示高亮。网页译文实际显示左右对照；归档后从普通列表消失，打开归档筛选后重新出现。
- iPad Ver 4.0 (78)：预览并确认手动分组，显示完成 1 步；前台检查显示已检查 1 次，停止后恢复开始按钮。搜索引擎改为 Bing，保存后重新进入设置读回 Bing；下载容量改为 500 MB 并回读。
- iPhone Ver 4.0 (78)：打开合成文章，读取正文，输入引文 `12` 和批注 `iPhone reading verified`，保存后返回列表并重新打开；来源、批注及引文高亮均保留，截图为 `iphone-78-reading-reopened.png`。
- 此次操作发现：PDF 空白页失败后再成功读取第一页，返回列表仍残留上次错误提示。已在 Ver 4.0 (79) 的双端实际操作中复验并消除。
- iPhone 的翻译首次确认页未显示服务地址、模型和正文，已取消发送并保存 `iphone-78-translation-preview-empty.png`。这暴露了仅测试“确认后得到译文”的不足。Ver 4.0 (79) 已修正预览数据传递，发送前会断言实际显示的地址、模型和正文。

本地截图存放于 `.artifacts/ios-parity-20261011/`，包含 `ipad-78-pdf-empty.png`、`ipad-78-pdf-saved.png`、`ipad-78-pdf-reopened.png`、`ipad-78-reading-columns.png`、`ipad-78-operation-completed.png`、`ipad-78-watch-stopped.png`、`ipad-78-settings-reopened.png` 和 `ipad-78-download-settings.png`。

- iPad Ver 4.0 (79) 实际复验：同一 PDF 连续读取空白页 2、有效页 1，保存引文及批注并返回列表，旧错误已消失。首次翻译确认完整显示本机服务地址、模型及正文；确认后显示左右对照译文并可保存。证据：`ipad-79-pdf-return-no-error.png`、`ipad-79-translation-preview.png`。
- iPad Ver 4.0 (79) 模型操作复验：首次发送预览显示地址、模型、目标及所选标签网址；生成分组与保存工作区两步，另行确认执行后显示完成 2 步。证据：`ipad-79-plan-preview.png`、`ipad-79-plan-completed.png`。
- iPhone Ver 4.0 (79) 实际复验：从系统“文件”导入同一 PDF，先读空白页 2 再读有效页 1，填写引文 `12 hectares` 和批注 `iPhone PDF verified`，保存并返回列表，批注可见且没有残留错误。证据：`iphone-79-pdf-return-no-error.png`。
- iPhone Ver 4.0 (79) 翻译实际复验：首次确认完整显示地址、模型和正文，确认发送后显示上下排版的原文与译文。PDF 重新打开后引文高亮和批注保留。证据：`iphone-79-translation-preview.png`、`iphone-79-pdf-reopened.png`。

## 复现与本地证据

在仓库根目录执行以下命令。运行器会递增构建号，输出目录须使用新的名称；这里保留本轮使用的命令及目录：

```bash
# (78)：双端完整回归
bash apps/ios/scripts/run-simulator-tests.sh --execute --output-dir /tmp/aegis-ios-parity-78

# (79)：全部原生与六条相关 UI
bash apps/ios/scripts/run-simulator-tests.sh --execute \
  --only-testing AegisTests \
  --only-testing AegisUITests/AegisUITests/testAdvertisingFilterSettingsAndSiteException \
  --only-testing AegisUITests/AegisUITests/testDamagedRecordsShowErrorsAndKeepBrowsingAvailable \
  --only-testing AegisUITests/AegisUITests/testPortableSettingsPersistAndDownloadRulesAreEditable \
  --only-testing AegisUITests/AegisUITests/testPortableReadingTranslationSaveRestartAndArchive \
  --only-testing AegisUITests/AegisUITests/testPortablePrivateReadingCancelDoesNotSaveOrSend \
  --only-testing AegisUITests/AegisUITests/testPortableModelPlanConfirmationAndForegroundWatch \
  --output-dir /tmp/aegis-ios-parity-79

# (80)：两项设置 UI 的最后复测
bash apps/ios/scripts/run-simulator-tests.sh --execute \
  --only-testing AegisUITests/AegisUITests/testAdvertisingFilterSettingsAndSiteException \
  --only-testing AegisUITests/AegisUITests/testPortableSettingsPersistAndDownloadRulesAreEditable \
  --output-dir /tmp/aegis-ios-parity-80

node --test scripts/check-platform-features.test.mjs
node scripts/check-repo-contracts.mjs
python3 apps/ios/scripts/simulator-fixture-server.py --self-test
git diff --check
```

检查脚本覆盖代表性的完整目录、漏登发布功能、缺端/缺译文、缺少验收依据等输入；4 项测试通过。合成服务自测 14 项通过。仓库合同及差异空白检查通过。

完整 `.xcresult`、构建及测试日志保留在上述 `/tmp` 目录。摘要、构建环境、输入 SHA-256 清单、产品输入比较及实操截图另存于本地 `.artifacts/ios-parity-20261011/`，未加入 Git。`acceptance-summary.json` 汇总三轮结果，`79-80-input-comparison.json` 记录最后两轮的差异。初始 60 项并行工作文件均存在；其中 55 项哈希未变，5 项在其他工作中更新，本轮未覆盖或回滚。Git 基线仍为 `e96c623`。
