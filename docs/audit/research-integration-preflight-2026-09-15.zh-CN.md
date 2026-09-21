# 研究材料接入前核查

核查时间：2026-09-15。这里记录 M4 的前置材料，不是模型复现报告。本轮只读论文、作者仓库、数据卡和 GitHub API，没有安装扩展、下载模型或训练。

| 项目 | 本轮核实 | 对开发的影响 |
|---|---|---|
| MINIM | 作者仓库存在推理、训练和指标脚本；根目录未显示许可证，GitHub license API 返回 404 | 可以继续独立实现任务必要性裁剪；暂不直接复制代码或捆绑权重 |
| MINIM 数据 | 数据卡标注 MIT，声明 150 个基础页面、5750 个变体，并按基础页面分组划分 | 数据卡许可不能替代代码许可；评测按基础页面隔离，不能随机拆散变体造成泄漏 |
| SCAFFOLD | LICENSE 文件引用 Apache 2.0；GitHub 自动识别为 NOASSERTION | 不能把 API 未识别误写成没有许可；引入实现前仍需核对依赖和完整许可材料 |
| SST-Guard | 作者仓库提供扩展压缩包、检测输出和真值材料；根目录 license API 返回 404 | 先借鉴有界语义信号，不直接安装扩展，也不自动打开其拦截模式 |
| PhishLang | 作者仓库说明 Ubuntu 本地服务加 Chromium 扩展；根目录 license API 返回 404 | 不是可以直接捆绑进 macOS 浏览器的单一模型；代码、权重和数据许可组合待核对 |

MINIM 的数据卡还链接到 `chaoyuvt/MINIM`，本次访问返回 404；可访问的论文作者仓库是 `yyyyhx/MINIM`。这项不一致需在复现时明确记录。数据卡的在线预览出现 schema 转换错误，不能仅靠网页预览认定完整数据可加载。[MINIM 作者代码](https://github.com/yyyyhx/MINIM) · [数据卡](https://huggingface.co/datasets/Chaoyu112358/MINIM-data)

SCAFFOLD 的作者说明真实 WebArena 等环境需要另外安装，不能用其合成环境测试代替真实网页评测；本计划仍只考虑有期限、来源和权限检查的有限只读步骤复用。[作者说明](https://github.com/BokwaiHo/SCAFFOLD) · [LICENSE](https://github.com/BokwaiHo/SCAFFOLD/blob/main/LICENSE)

SST-Guard 的窗口属性枚举范围比本计划的有界信号观察更宽，直接安装并不等于完成 Aegis 整合；PhishLang 的客户端服务也需要单独的平台适配。[SST-Guard 作者仓库](https://github.com/jazlan01/sst-guard) · [PhishLang 作者仓库](https://github.com/UTA-SPRLab/phishlang)

## 固定的材料身份

- MINIM：`456c60b6fd47941d1e5849db573dbbcb488e3ae7`。
- SCAFFOLD：`e26fe52dd7c84b2aaeee271d5a72de23a45a8526`。
- SST-Guard：`18a312c3579ebd2fdcd7b3e8d8d2c6f550cd81c6`。
- PhishLang：`6b7283854ef8a6edc73f945c1ce7e51b2e1dc4fd`。

原始 API 结果位于 `.artifacts/integration-20260915/research/license-preflight.json`。404 只表示该接口未找到可识别的根许可证，不能据此断言仓库所有子目录或压缩包都没有授权。2026-09-16 已继续递归核对四个固定仓库，并静态检查 SST-Guard 扩展归档的 42 个条目，未执行或安装。尚未取得代码、权重、数据一起复用的完整结论；详见[取舍与实验边界](research-integration-decision-2026-09-16.zh-CN.md)。

## 下一步实验口径

R01 比较规则裁剪与可合法使用的学习式裁剪时，分别记录必要元素保留率、敏感字段暴露、模型输入字节和真实任务结果。R02/R03 先建立本计划的独立站点与数据划分，再评估新增信号；不能把作者仓库的预测 CSV 当成本浏览器的真值或误报成绩。R05 先用最多三类只读任务、十个已核验模板验证来源、期限和撤销，再谈复用收益。

当前结论是“前置材料部分核实，模型试验尚未执行”。没有可合法复用的完整材料时，保留独立规则实现和证据不足记录，不以未经核验的研究扩展替换现有保护。
