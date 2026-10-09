# Aegis 每日自动升级与发行接入记录

2026-10-08，Asia/Shanghai。

结论：每日计划已生效；持续功能与版本门禁已在隔离候选中实现并通过79项流程回归。正式三平台发行和旧客户端升级尚未完成，不能将计划已启用等同于完整自动发布已上线。

## 已完成

- 本地 `aegis-chromium` 每天09:00执行，状态ACTIVE，延续同一会话和唯一候选。
- GitHub补充监控每天09:17；[PR #31](https://github.com/gcsagroup/aegis-browser/pull/31)在quality、quality-gate、标题检查及Codacy均通过后正常合入。默认分支 `9b2cedb4620ddc9f7f42056638a071d5394bc2bd` 已回读确认每日表达式，旧小时表达式已移除。没有绕过服务器合并限制。
- 修正候选版本流程：构建前必须准备完整产品版本，源码、overlay、打包默认版本与Android版本保持一致；当前App与构建计数防止同版本重复编译。
- 新增23项行为要求，覆盖20个Aegis开关及访问规则、资料兼容、更新入口。新开关漏登记、已登记行为或平台被删除、旧清单摘要、零项执行、日志被修改、源码或默认分支变化均阻断相应候选或发布步骤。无开关的新功能也必须登记，不能只靠自动扫描开关判断完整性。
- 候选验收绑定产品提交、Chromium/V8源码树、产品版本和功能清单摘要；发布要求每个平台提供本次产物的真实日志。验收要求不是通过记录，包装器尚未适配时应失败。
- 79项回归通过（功能契约11、候选14、发布编排18、资产14、上游监控22），包括真实临时Git仓库中删除历史功能的拒绝测试。另以实际125源码验证完整版本一致性及同版本重编译拒绝。

## 当前边界

当前Mac候选仍为Ver 2.1 (125)，Chromium155.0.8059.40；源码与V8工作区干净，旧产物清单及7份既有验证证据摘要未变。没有重新编译、创建正式tag、发布资产或替换日常App。根工作区60项既有差异保留；本次发行流程代码位于隔离产品目录，尚未整合提交到远端。

## 尚需接入

1. Mac：登录钥匙串没有Developer ID Application；需指定既有发行证书私钥及公证配置。Apple Development/Distribution不能冒充站外发行签名。
2. GitHub：CLI账号erjinyi的仓库push权限为false。浏览器管理身份已用于本次PR，不代表每日程序取得发行API凭据；需要可自动使用的既有发行身份或受保护Actions配置。
3. Windows：真实机器的代码签名证书列表为空；旧官方CIPD包的Defender处置仍待安全确认，新155基线继续引用相同包版本。没有关闭防护、添加排除或恢复隔离文件。
4. Android：现有Docker为linux/aarch64，没有已接入的受支持Linux x64构建配置；原签名文件指定路径不存在，ADB没有连接设备。需接入已有Linux x64机器、原签名和专用ARM64设备，不创建临时身份或购买资源。
5. 真实验收包装器：资源接通后按`--baseline`接口连接现有原生/交互测试并验证完整流程，不能手写通过结果。之后才推进三平台正式包、GitHub Release及旧版客户端安装回读。

没有新上游、产品源码变化或实际失败时复用125已绑定的Mac相关验证。后续已授权合入的新功能应更新行为清单和测试入口，触发新产品候选；未经授权或尚未完成的开发差异保留。每日任务不承诺一小时内发现漏洞，实际中断及超期继续记录。

证据目录：`/Users/lazy/Projects/GCSA-aegis-build/upstream-candidate/security-update-155.0.8059.40/release-enablement-20261008`。主要文件为`result.json`、`verified-pipeline.json`、`daily-schedule-merged.json`、`local-prerequisites.json`、`windows-prerequisites-retry.jsonl`与`after-workspaces.json`。
