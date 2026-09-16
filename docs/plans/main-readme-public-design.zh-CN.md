# Public `main` README 设计

## 目标

默认 `main` 的 README 是面向用户、潜在贡献者和上游协作者的公共产品首页，不承担内部维护流程说明。

公共 README **不出现**以下内部概念：

- `develop` 分支；
- promotion 分支；
- 个人 Fork 的同步顺序；
- 管理员合并兜底；
- 内部 Review 模型分工；
- 维护者如何把个人 `main` 再提交到上游。

这些内容继续由 `docs/development/ci.zh-CN.md` 在维护分支中管理。

## 首页信息层级

建议公共 `main` README 保持以下顺序：

1. 项目名称、三语入口与徽章；
2. 一句话产品定位；
3. 平台优先级：macOS 当前、iOS/iPadOS 下一阶段；
4. 主要能力；
5. 当前工程/发行边界；
6. Roadmap 摘要；
7. 用户/开发者快速入口；
8. 外部贡献方式；
9. 文档、许可证与鸣谢。

不在首页长期维护补丁数量、历史 SHA、旧测试总数或带日期的历史验收结论；这些继续留在 audit 文档。

## 公共徽章

公共 `main` 只展示上游公共仓库可独立验证的状态：

```markdown
[![CI](https://github.com/gcsagroup/aegis-browser/actions/workflows/quality.yml/badge.svg?branch=main&event=push)](https://github.com/gcsagroup/aegis-browser/actions/workflows/quality.yml)
[![C++ Unit Tests](https://github.com/gcsagroup/aegis-browser/actions/workflows/cpp-unit-tests.yml/badge.svg?branch=main&event=push)](https://github.com/gcsagroup/aegis-browser/actions/workflows/cpp-unit-tests.yml)
[![License: Apache-2.0](https://raw.githubusercontent.com/gcsagroup/aegis-browser/main/assets/badges/license.svg)](https://github.com/gcsagroup/aegis-browser/blob/main/LICENSE)
[![Current platform: macOS](https://img.shields.io/badge/current-macOS-555?logo=apple&logoColor=white)](https://github.com/gcsagroup/aegis-browser/tree/main/apps/browser)
```

其中 C++ workflow 必须先真实存在于上游 `main`，并至少有一轮 `main` push 成功后才展示。公共 README 不引用个人 Fork 的 Codacy 或 Actions 状态；如果未来上游自身接入 Codacy，再增加对应上游徽章。

徽章下应保留一句边界说明：CI/C++ 徽章代表各自测试范围，不等于完整 Chromium runtime、签名、公证或正式发行通过。

## 公共产品文案

建议首屏文案：

> **A local-first privacy and security browser with a controllable AI Agent. macOS comes first; iPhone and iPad are next.**

简体中文：

> **一个本地优先的隐私与安全浏览器，内置可控的 AI Agent。先做好 macOS，再推进 iPhone 与 iPad。**

繁体中文：

> **一個本機優先的隱私與安全瀏覽器，內建可控的 AI Agent。先做好 macOS，再推進 iPhone 與 iPad。**

## Roadmap 在 main 的表达

公共首页只显示短版：

- **Now — macOS**：完成 Chromium/Access Service、稳定性、签名、公证和安装验收；
- **Next — iOS / iPadOS**：从现有原生工程与 Simulator 基线继续，完成真机、平台能力和 TestFlight/App Store 准备；
- **Later — Windows / Android / Linux**：保留源码与评估入口，不承诺近期发行。

详细完成标准链接到 `docs/roadmap*.md`。macOS 与 iOS 独立获得发行资格，不能要求两个平台同时完成才能发布 macOS。

## 外部贡献者如何提 PR

公共 README 只需要告诉其他开发者标准开源贡献流程，不暴露内部集成分支：

```markdown
## Contributing

Contributions are welcome. Keep each pull request focused and include the tests or evidence relevant to the change.

1. Fork this repository.
2. Create a topic branch from the current `main`.
3. Make one focused change and add or update relevant tests.
4. Run the applicable local checks documented for the affected component.
5. Push the branch to your fork and open a pull request against this repository's `main`.
6. In the PR description, explain the problem, scope, test evidence and any remaining limitations.
7. Address review feedback on the same PR; do not rewrite unrelated history.

For Chromium changes, read `apps/browser/README.md`. For iOS changes, read `apps/ios/README.md`.
```

简体中文对应内容：

```markdown
## 参与贡献

欢迎提交贡献。每个 PR 应保持范围聚焦，并提供与改动相关的测试或验证证据。

1. Fork 本仓库。
2. 从当前 `main` 创建独立 topic branch。
3. 完成一个聚焦的改动，并补充或更新相关测试。
4. 按受影响模块的文档运行适用的本地检查。
5. 将分支推送到自己的 Fork，并向本仓库 `main` 提交 Pull Request。
6. 在 PR 描述中说明问题、改动范围、测试证据和仍存在的限制。
7. 在同一个 PR 中处理 Review 反馈，不改写无关历史。

Chromium 改动请先阅读 `apps/browser/README.zh-CN.md`；iOS 改动请阅读 `apps/ios/README.zh-CN.md`。
```

## 与 develop README 的差异

| 内容 | develop README | public main README |
| --- | --- | --- |
| 产品介绍 | 有 | 有 |
| macOS → iOS Roadmap | 有 | 有 |
| 开发分支 CI/Codacy 徽章 | 有 | 无 |
| 上游公共 CI/C++ 徽章 | 可不展示 | 有 |
| 内部 `develop` 工作流 | 有 | 无 |
| promotion / 上游同步细节 | 链接内部 CI 指南 | 无 |
| 外部贡献 PR 说明 | 可简略 | 必须清楚 |
| 历史补丁数/SHA | audit 中 | audit 中 |

## 落地顺序

1. 先让新的 README / Roadmap 在维护分支完成 Review 与 CI。
2. 当前上游功能 PR 合并后，确认 `quality.yml` 与 `cpp-unit-tests.yml` 已进入上游 `main` 且有真实成功 run。
3. 从最新上游 `main` 创建独立 docs PR，一次性更新三语 README 与三语 Roadmap。
4. 该公共 docs PR 不携带个人 Fork 的分支治理、个人 Codacy 地址或维护者私有流程。
5. 上游合并后，再把新的公共 README 作为个人 `main` 镜像基线同步回来。