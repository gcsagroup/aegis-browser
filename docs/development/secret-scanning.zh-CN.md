# 持续秘密扫描

Secret Scanning workflow 对 main/develop 的 PR（包括 Draft）、push、每天 UTC 03:17 和手动运行执行 Gitleaks。使用 GitHub-hosted Ubuntu runner，权限仅为 contents: read，不读取仓库 secret，也不上传原始扫描报告。现有 macOS quality/quality-gate 与平台报告工作流保持原职责。

Gitleaks 固定为 8.30.1，Linux x64 官方发布包 SHA-256 固定在 workflow 中。升级时同时更新摘要、重跑检测回归并核对历史误报。checkout 获取完整历史并禁用凭据持久化；脚本拒绝浅克隆，扫描全部已取得引用的历史，包含已删除的秘密。递归解码深度为 5，归档深度为 2。扫描错误和候选发现均使 job 失败；日志仅显示规则、文件、行号和提交，不打印匹配原文、秘密或提交正文。

## 本地复现

安装同版本 Gitleaks 后执行：

~~~bash
python3 scripts/ci/test_secret_scanning.py
bash scripts/ci/scan-secrets.sh
~~~

可用 GITLEAKS_BIN 指向已校验的二进制。回归在临时 Git 仓库中生成一次性密钥，检查干净仓库通过、已删除私钥仍被拦截、历史误报路径不能豁免新提交、行内 gitleaks:allow 不能绕过扫描，以及浅克隆拒绝执行。生成的密钥不会进入源码仓库或日志。

## 历史误报基线

.gitleaks.toml 只继承默认规则，不禁用私钥或其他规则。.gitleaksignore 只记录已审查的历史指纹，绑定精确提交、路径、规则和行号；不忽略目录、整个文件、整个提交或未来提交。禁止通过广泛排除测试目录或过滤列表消除误报。

2026-11-03 首次基线有 35 个独立指纹。相同行中的多个候选、同一代码在不同扫描范围中的重复项不会产生额外指纹：

| 文件/范围 | 已核实的原因 |
| --- | --- |
| agent_observation_unittest.cc 及对应 0142 补丁 | 秘密脱敏测试的固定输入 |
| farbling_unittest.cc 及对应 0052 补丁 | uint64_t 十六进制测试种子 |
| summary_policy_unittest.cc 及对应 0056 补丁 | 字母序列构造的 AWS ID 脱敏示例 |
| PIIScannerTests.swift、pii.test.ts | Bearer/query token 脱敏测试数据 |
| patches/archive/main-151/manifest.json | 补丁 SHA-256 摘要 |
| Tests/Fixtures/Localization/coverage.json | catalogKeysSHA256 本地化目录摘要 |
| prototypes/access-metering/sm00_synthetic_manifest.json | xrayBinarySha256 二进制摘要 |
| BrowserKit/Resources/easylist.txt | 注释及 GitHub URL 中的公开 Git 提交 SHA |
| BrowserKit/Resources/security-rules.json | 匹配跨越域名阻止列表中相邻的字符串 |

2026-11-10 为恢复的上游原始历史补充 21 个精确指纹，对应扫描器的 39 个重复候选。逐项核对精确提交、路径、规则和行号，命中行与已有基线中的同类非秘密内容完全一致；`.gitleaksignore` 注释保留对应的已审查提交短引用及行内容 SHA-256。另对首次基线修正提交 `699b2eb0` 注释中的 21 个公开提交 ID 误报逐行保留精确指纹；后续注释使用短引用。规则覆盖和新提交的检测范围保持原定义。

新增豁免前须检查精确提交和内容，记录非秘密依据。新提交中的相同测试数据会再次被检查，不能复制现有豁免自动放行。真实秘密须先撤销或轮换，再评估历史清理；不能以加入基线代替处理。

## GitHub 设置与审查

GitHub Secret Scanning、Push Protection 和 Generic/non-provider patterns 是服务端设置，YAML 不能证明启用。Generic patterns 的可用性取决于仓库类型与 GitHub Secret Protection 权益；个人仓库不能仅靠提交配置取得此能力。修改后须从服务器重新读取实际状态。

Codex Security Review 可补充审查秘密处理、凭据边界和 CI 变更；不替代持续模式扫描、GitHub 设置、必需检查或独立审批。本 workflow 使用独立的 gitleaks 检查名，不复用 quality-gate 名称；是否为 required check 须通过实际分支保护回读确认。

## 覆盖边界

范围是当前 checkout 能取得的 Git 历史，不包含未取得的已删除服务器引用、其他 fork/worktree、Actions 历史日志和 artifact、Release 附件或 runner/钥匙串状态。模式扫描也不能保证排除加密文件及任意混淆或拆分的秘密。
