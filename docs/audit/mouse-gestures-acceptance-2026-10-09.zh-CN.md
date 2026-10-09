# 桌面鼠标手势：141 本地验收记录

2026-10-09，Asia/Shanghai。本记录只对应下列已冻结的构建与测试，不随分支后续提交自动更新。

## 结论与源码身份

Mac ARM64 的原生右键手势已完成本地构建、测试、安装核对和界面验收，版本为 Ver 2.2 (141)，Chromium `155.0.8059.40`。Windows 实机及正式发行尚未完成。[使用指南](../../apps/browser/docs/mouse-gestures.zh-CN.md)说明默认动作、配置和 PDF 绑定。

- 产品构建提交：`2df337fcc0597cdcc8111a158b66d92cb578e115`。
- Chromium 源码提交：`54f07a43cd269449dbecb0993e3ec686e02a378b`。
- Chromium 源码树：`e0698e7a315b146b07c890a2ab754c06a3cdd49d`。
- 构建清单记录的 App 树 SHA-256：`71ca6dd927ade86c3517f37ec1e66ffba886409b4a9c2b44ede3211e83bd4aa4`。
- 273 个桌面补丁完整重放通过，506 项 overlay 与源码一致；官方构建流程、输入与产物身份核验、`pnpm run quality:fast` 均通过。

后续文档提交不改变上述构建身份，也不产生新 App。此处 App 树哈希不是可下载安装包的哈希。

## 测试与实际操作

| 范围 | 结果 |
| --- | --- |
| 手势单元测试 | 9 项通过 |
| 手势原生交互 | 12 项通过 |
| 既有 Agent 界面 | 2 项通过 |
| 设置、PDF 与 Agent 回归 | 10 项通过 |
| 跨进程子框架与失焦场景额外复测 | 同一用例连续 5 次通过 |

共 33 个不同用例，另加 5 次重复执行；最终运行没有自动重试。测试覆盖右键菜单、左键点击和拖选、滚动、刷新、标签切换/关闭/恢复、取消、跨框架、设置保存与练习保护。默认 OOPIF 与旧 GuestView 两种 PDF 模式均覆盖翻页、页边界、适合宽度/整页及通用后退。

固定验收 App 的 347 个文件和 5 个链接与构建产物一致，测试目标编译未改变 App 字节。通过 Computer Use 实际检查的范围分别为：

- 141：关于页版本、设置侧栏入口、手势设置布局、保存与刷新回读。
- 140：添加 `LR` 对应 PDF 下一页，保存回读后删除并恢复 9 个默认绑定。
- 139：内置 PDF 的右键菜单；最终 141 另有上述两种 PDF 原生交互及加载/焦点回归。

历史问题已修复并保留诊断记录：输入回调结束前关闭标签导致的生命周期问题、跨框架命中区域尚未就绪导致的测试超时、Chromium 155 设置项改名导致的旧测试取值崩溃。上述跨版本界面检查不冒充全部在 141 上重新操作。

## GitHub 与上游同步

[PR #32](https://github.com/gcsagroup/aegis-browser/pull/32)承载 Chromium 155 源码整合；[PR #33](https://github.com/gcsagroup/aegis-browser/pull/33)以其分支为基础，承载鼠标手势、回归和文档。记录时两者均为草稿；GitHub main 仍为 `9b2cedb4620ddc9f7f42056638a071d5394bc2bd` 的 Chromium 153 基线，不能把候选目录的版本当作主线已升级。

[上游排查记录](upstream-source-sync-2026-10-08.zh-CN.md)说明根因：升级已在隔离目录适配，但源码提交被完整发行条件拖住。现将源码提交与草稿 PR、主线兼容验收、正式发行分别跟踪。现有每日北京时间 09:00 的维护任务已更新：每轮核对真实远端与官方正式 Stable，保留本次功能分支，将 `MouseGestures` 纳入持续回归；无实质变化时保持静默。

## 尚未完成

- PR #32 的 16 项中等及以上静态扫描问题仍待处理；PR #33 的构建提交 `2df337f` 对应 Codacy 检查已通过，后续提交以各自检查结果为准。
- Windows 手势构建与实机验收，以及上游升级的 Windows/Android 完整兼容验收尚缺。
- 当前 Mac App 仅本地 ad-hoc 签名，尚未完成正式签名、公证和完整发行更新链路资格。
- 本轮未合入 main，也未创建正式 tag、GitHub Release 或公开二进制。

## 证据保存

原始机器收据保存在本地工作区 `.artifacts/mouse-gestures-20261008/`，没有随源码上传。主要文件为 `acceptance-141.json`、`141-build-manifest.json`、`install-141.json`、`quality-fast-141.log`、`source-replay-141.log`，以及 `unit-141`、`interactive-tests-141`、`regression-tests-141`、`crossframe-repeat-141` 对应的日志和 summary JSON。实际界面截图为 `native-settings-141.png`、`native-version-141.png` 与 `pr33-final.png`。

这些文件记录本地验收，公开摘要不能替代下载者对自己平台、构建和产物的独立验证。
