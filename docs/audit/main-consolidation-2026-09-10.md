# 2026年9月10日：main合并与GitHub源码提交

结论：两个本地开发分支的历史已合入main，代码已推送至[GitHub](https://github.com/gcsagroup/aegis-browser)。本地及origin仅保留main。本次仅提交源码、补丁、测试和文档，不是二进制发行。

## 提交范围

- [31a2b8f](https://github.com/gcsagroup/aegis-browser/commit/31a2b8f)：整合当前Browser Agent v2、摘要性能、模型选择、语言/格式约束、独立监控和相关回归。
- [a5e334b](https://github.com/gcsagroup/aegis-browser/commit/a5e334b)：接入已迁移的集成分支历史，保留主目录的较新实现。
- [f3d6f7b](https://github.com/gcsagroup/aegis-browser/commit/f3d6f7b)：合入原型历史，并保留62份独有实验代码及历史报告。旧的3份产品目录内runtime spike仅保留在Git历史中，不重新接入生产构建。

两个旧工作目录改为脱离分支的保留快照，文件内容与未提交改动均核对未变。清理前已生成并验证Git bundle，未提交源码也已归档。没有删除浏览资料、模型、构建缓存或失败证据；本机界面输出与`.artifacts`不上传。

## 验证

| 检查 | 结果与范围 |
|---|---|
| `pnpm run quality:fast` | 通过；核心168项及脚本、Agent界面、Android目标/界面驱动、模型中转、仓库合同和核心包构建 |
| 原型单元测试 | 主目录离线安装锁定依赖后，38项通过；首次缺依赖的失败未当作通过 |
| 补丁重放 | 从固定基线完整重放108个Chromium补丁和2个V8补丁；不改外部构建目录的HEAD或工作文件 |
| 当前源码一致性 | 新增0108补丁补齐51个顶层overlay文件的差异；嵌套V8文件单独核验 |
| Git一致性 | 两个旧分支均为main祖先；首次源码推送后，本地main、origin/main与GitHub main均为f3d6f7b |
| 凭据与本机资料检查 | 检查待提交文本和新增分支历史中的常见密钥格式；匹配项为拒绝凭据URL的合成测试，不是全面秘密扫描保证 |

重放后的Chromium源码树为`319366182c31108e29e62d2f2199aff29a0b86e8`，固定基线为`ff37cfca210138f2a40b843b4a8195ab7e4fc7ff`。V8源码树为`5a6be89cfa0c35d8eb6ee81aec3cb8100780f7e9`，固定基线为`792d9716fea48312ad7ce4413c538e00628b1d50`。源码树一致不等于二进制可重复构建证明。

## 仍未完成

最近本地macOS候选已有527项原生回归结果，详见[摘要与监控修复记录](summary-latency-2026-09-10.md)。本次没有重跑或扩张这些结果，也没有重新打包、启动App或更新产品版本号。

最新Qwen语言/格式与真实通知显示、Windows安全告警后的人工验收，以及最新Android APK和指定设备验收仍未完成。此前22.739秒与17.855秒只属于报告内明确的性能候选，不移用于所有模型、页面或最终发布包。

本次没有创建tag、GitHub Release、发行包或部署服务。[完整十项验收](aegis-browser-agent-v2-cross-platform-acceptance-2026-09-05.md)保持原定范围，项目仍为发行No-Go。原型测试不能替代实际产品验证。
