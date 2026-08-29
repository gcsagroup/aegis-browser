# Aegis Browser Agent v1 安全审计与修复验证

- 日期：2026-08-29
- 审计范围：Chromium `910672213c5fcd18167b5ee26f690cf0023415e6...98344d6b78b8a94f2c36cdc7bf442180d0845ad7`
- 扫描 ID：`9cd7d673-3071-4cb4-aee2-334915d39e22`
- 扫描结果：completed，coverage complete
- 初始发现：11 项，6 medium + 5 low，全部 high confidence
- 最终修复验证提交：`9d3e05f83d3d607f750cef619f0dca6df39e624b`
- 结论：**11/11 已修复并由针对性测试覆盖；生产发布仍为 No-Go**

## 1. 威胁与信任边界

网页、DOM、WebMCP、模型输出、下载响应和恢复数据都按不可信输入处理。模型只能提出固定
schema 的工具调用；Browser Process 持有 scope、DocumentToken、风险分类、单次批准收据、
执行器和结果验证。Agent 只允许 Regular Profile，Transaction Pilot 默认关闭，最终付款
必须用户接管。

审计不包含 iOS、Android、生产签名、公证、公开发布或真实交易，也不把 Chromium 上游
安全能力当作本轮新增实现的证明。

## 2. 发现、修复与回归测试

| # | 初始问题 | 修复 | 主要回归证据 |
|---:|---|---|---|
| 1 | Actor 通用早期允许分支可覆盖 Aegis 精确来源限制 | `about:blank` 特例之外先执行调用方 policy checker；显式 block 优先于 localhost、测试开关和静态 allowlist | `EnterprisePolicyBlockOverridesGenericEarlyAllows`、Agent exact origin/document tests |
| 2 | 收藏夹 URL 检查可向本机和私网发起盲请求 | 语法层拒绝 localhost、loopback、RFC1918、link-local、凭据 URL；URLLoader 使用本地请求阻断并在重定向后复核 | `BookmarkUrlChecksRejectLocalNetworkTargets` |
| 3 | 取消任务或禁用 Agent 后活动下载仍继续 | 任务停止只取消仍为 IN_PROGRESS/INTERRUPTED 的 owned `DownloadItem`，不碰已完成或非本任务下载 | `TaskStopCancelsOnlyActiveOwnedDownloads` |
| 4 | 无效模型设置静默回退默认云端点 | Profile 配置缺失、无效或不匹配时返回不可用，不构造隐式云目的地 | `RejectsImplicitOrInvalidCloudFallback`、`RejectsUnsafeConfigurationWithoutNetwork` |
| 5 | 无预期哈希的下载被标为已验证并可打开 | 把 `integrity=not_provided` 与 verified/match 分开；只有完成、强哈希匹配和安全状态同时成立才满足后置条件 | `VerifiesScopedMetadataAndDownloadState` |
| 6 | WebMCP 返回的秘密 JSON 可进入远端模型请求 | 工具结果进入模型前做递归敏感字段/值检查和有界摘要；拒绝 secret-bearing evidence | `RejectsSecretsHiddenInWebMcpJson`、`PromptLabelsAndBoundsCumulativeEvidence` |
| 7 | WebMCP 字符串化嵌套输入可绕过敏感字段策略 | 对 JSON 字符串递归解析并检查嵌套 key/value，不只检查顶层参数名 | `RejectsSecretsHiddenInWebMcpJson` 的 nested `accessToken` 样例 |
| 8 | monitor.create 在崩溃恢复后可重复持久化 | monitor ID 由任务和 action id 形成稳定幂等键；恢复只调度一个 catch-up，不重放已完成任务 | `ReplayUsesOneStableMonitorIdentity`、`RestoresCompletedMonitorOwnerWithoutReplayingTask` |
| 9 | 结账摘要用无边界子串匹配金额 | 金额、货币和组成项使用结构化字段及精确 minor-unit 算术；最终页变化要求重新观察 | `CheckoutRequiresFreshTraceableArithmetic` |
| 10 | `page.select` 被错误分类为 R1 | 调整为精确页面写操作批准，绑定最新文档、节点和参数 hash | `SelectRequiresExactActionApproval` |
| 11 | 书签撤销令牌未绑定具体 UndoGroup | 收据绑定对应 UndoManager/组和书签 revision；后续编辑或 manager shutdown 立即清除旧收据 | `LaterBookmarkEditInvalidatesUndoReceipt`、`CompletedTaskAllowsOnlyScopedBookmarkUndo` |

## 3. 修复后验证

修复后重新执行并通过：

- Agent Core gtest：50/50。
- 模型客户端 gtest：5/5。
- 组合 Browser Aegis unit gtest：115/115。
- Browser tests：Profile/侧栏/scope 2/2。
- Interactive UI：快捷键与设置入口 2/2；两条路径均加载真实 SidePanel/untrusted WebUI。
- 3 个 ASan/libFuzzer 目标，各 1000 次，共 3000 次，无 crash。
- 61 个 Chromium 补丁从固定 base 重放后，最终树与修复 checkout 精确一致。

以下安全属性有直接回归证据：

1. scope、origin、Profile、DocumentToken 和 browser-owned capability 不能被模型、网页或
   WebMCP 扩张。
2. R2 批准绑定 exact action hash、单次使用并过期；R3 最终交易不提供通用 submit 工具。
3. 停止、禁用和恢复不重复下载、monitor 或浏览器写入。
4. 模型目的地来自任务所属 Profile 的有效显式配置；错误和 API key 不回显。
5. 浏览器结果验证器而非模型决定工具成功和任务完成。

## 4. 未关闭风险

- 本轮是固定提交区间的静态差异审计与本地修复验证，不替代持续 fuzz、上游 Chromium
  安全响应、真实站点渗透测试或第三方审计。
- WebMCP 仍是实验能力，站点工具必须继续经过相同 schema、scope、秘密和审批门。
- Agent 增量出站已审计，但 Chromium 基线仍有 Google 时间和账号检查请求；不能据此
  宣称整个浏览器零遥测。
- 没有测试真实账号、支付、Developer ID、公证或公开分发；Transaction Pilot 继续默认
  关闭。

结论只支持“**macOS 本地 RC 的 11 项已知发现已修复**”，不支持“没有未知漏洞”或
“已达到生产发布安全资格”。

## 5. 验收后入口修正

后续 Chromium 提交 `9a9baa49307e6c8ebde137ab8ed274ec63535174` 与
`70945fda21074e176dfcc2794ed7169c6fb05ac3` 只改变已验收 Agent 入口层的默认可见性并
为已有 Profile 做一次性工具栏迁移。Profile 执行偏好仍默认关闭，未开启时不创建 Agent
服务；WebMCP 和 Transaction Pilot 继续默认关闭。新增入口与迁移测试 2/2、相关 Browser
tests 4/4、Interactive UI 2/2、Aegis common 78/78 与 Browser unit 115/115 均
通过。该修正没有重新开放审计中禁止的隐式模型回退、跨 Profile、私网 URL、重复副作用
或最终付款路径。
