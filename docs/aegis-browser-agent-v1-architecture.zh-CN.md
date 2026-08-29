[English](aegis-browser-agent-v1-architecture.md) | **简体中文** | [繁體中文](aegis-browser-agent-v1-architecture.zh-TW.md)

# Aegis Browser Agent v1 架构与权限边界

## 产品定位

Aegis Browser Agent 是浏览器内的任务执行器，不是拥有浏览器全部权限的聊天框。
用户给出目标后，Agent 先形成可审查计划，再由浏览器根据确定性策略执行和验证。
模型只能提出结构化工具调用；浏览器决定工具是否存在、参数是否合法、是否需要审批，
以及任务是否真正完成。

v1 支持 macOS 桌面端。iOS 暂时跳过，Android 后置。v1 不自动完成付款、发送消息、
发布内容或绕过登录保护。

## 数据流

```text
用户目标
  → Agent Side Panel（Ask / Act / Automate）
  → Profile 级 AegisAgentService
  → Planner（固定系统合同 + 最小工具集合）
  → PolicyBroker（scope / risk / budget / approval）
  → Browser Tools 或 AegisActorBridge
  → ResultVerifier（浏览器后置条件）
  → TaskStore / Timeline / 用户结果
```

模型响应、网页文本、WebMCP 结果和工具结果都属于不可信输入。任务状态只能由浏览器
状态机转换，模型不能直接把任务标为成功。

## 主要组件

### AegisAgentService

每个普通 Profile 一份实例，持有任务、计划、模型请求、Actor、浏览器工具、待审批、
撤销凭证和监控。OTR、Guest、System Profile 不创建服务。关闭 Agent 时，服务停止
模型请求、Actor、待审批和调度任务。

### TaskScope 与 ToolRegistry

TaskScope 是创建任务时的最大授权，包括精确 origin、tab、工具、数据类别、模型目的地
和预算。模型计划只能缩小范围，不能增加 origin、工具、数据或预算。ToolRegistry 使用
编译期 schema，v1 不允许模型注册工具。

### 结构化模型传输

支持 OpenAI-compatible Responses、Anthropic Messages 和 Gemini GenerateContent 的独立
适配器。只接受原生结构化 tool call；自然语言中的 JSON 不会被执行。重定向禁止，
Cookie 禁止，loopback 可使用 HTTP，云端必须使用受支持的 HTTPS 目的地。

### AegisActorBridge

Actor Bridge 将已批准的页面工具映射为 Chromium Actor 动作。每次观察都绑定当前
DocumentToken，并带有观察指纹；导航、恢复、手动改页和用户接管后必须重新观察。
模型看不到密码、OTP、Cookie、卡号或受保护表单值。

### 浏览器原生工具

原生工具覆盖标签页、窗口、工作区、收藏夹、历史、权限、下载和监控。收藏夹修改采用
预览、revision 冲突检查、分组写入和一键撤销；URL 检查使用有界 HEAD 与 Range GET；
下载通过 DownloadItem 管理并校验来源、架构和 SHA-256。

### PolicyBroker 与 ResultVerifier

风险等级如下：

- R0：只读，可在批准范围内自动执行。
- R1：本地可逆的低风险操作，例如标签页、工作区或监控状态调整；受任务确认约束。
- R2：持久浏览器写入或外部副作用，例如应用收藏夹分类、下载和网页点击；必须针对
  精确 action id 单独批准。
- R3：交易、最终提交等用户接管动作；Agent 不能代替用户完成。
- Blocked：秘密读取、任意代码、通用 CDP、跨范围动作等直接拒绝。

ResultVerifier 检查浏览器真实状态。下载存在、书签树 revision、当前 DocumentToken、
页面观察指纹和结账金额等后置条件不满足时，任务失败或要求重新观察，而不是采信模型
声称“成功”。

## 四个内置工作流

1. 深度研究：多来源浏览、冲突标记、引用与未验证项；只读。
2. 浏览器管家：标签页和收藏夹整理、URL 状态检查、预览/应用/撤销。
3. 安全下载：寻找官方来源、匹配平台架构、原生下载和哈希验证。
4. 购物助手：比较总价、运费、税费、配送与退货；可加入购物车，但最终购买交给用户。

监控只在浏览器运行时调度，最多 3 个并发，带退避和补跑上限；不会为后台监控自动打开
新标签页。通知只显示监控类型和 origin，不包含页面正文或秘密，也没有可直接执行动作的
通知按钮。

## 持久化与恢复

TaskStore 使用 Profile 内 SQLite。持久化的是通过秘密标记与长度检查的任务目标、任务
合同、脱敏事件摘要、计划步骤/进度和加密监控目标。原始工具结果、页面正文、截图、
撤销凭证、密码、OTP、Cookie、卡号、API key 和完整本地路径不得落盘。未完成任务保留
7 天，终态任务保留 30 天；服务启动时先清理过期记录，清理失败则 Agent fail closed。

崩溃后只读任务可在用户确认后恢复；待审批动作过期，外部副作用不自动重放。任何恢复
都要求新的页面观察，旧节点和旧 DocumentToken 无效。

收藏夹撤销凭证仅在当前浏览器会话内有效；浏览器重启后不会尝试重放撤销或写操作。

## 明确不支持

- 自动付款、最终下单、转账、发帖、发信或接受法律条款。
- 任意 JavaScript、shell、浏览器远程调试或通用本地文件访问。
- 无提示读取密码、Cookie、OTP、支付卡或跨 Profile 数据。
- 浏览器关闭后常驻的系统级监控。
- 把本地测试通过直接解释为公开发布、正式签名或公证完成。
