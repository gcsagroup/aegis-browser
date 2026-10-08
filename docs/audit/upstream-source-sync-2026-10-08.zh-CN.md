# Chromium 155 源码同步排查与整合

2026-10-08，Asia/Shanghai。

## 结论

自动任务已适配 Chromium 155，但升级补丁及发行流程改动长期留在隔离产品目录，没有形成远端升级 PR。GitHub main 仍固定 Chromium 153；开发目录又停在更早的 detached HEAD。将构建目录的 155 当作主库版本，是本次判断错误。原流程把源码提交排在完整平台验收之后，使外部发行条件缺失同时拖住了源码同步。

## 核对结果

- 当前开发目录：`a626736eacf2fbb50378ec485c020793eae26ba6`，Chromium `153.0.8010.53`，239 个桌面补丁，产品构建号 097，另有既有开发差异。
- 本轮拉取的 GitHub main：`9b2cedb4620ddc9f7f42056638a071d5394bc2bd`，Chromium `153.0.8010.53`，245 个桌面补丁，产品构建号 103。
- 隔离源码：Chromium `155.0.8059.40`，上游 `cfaadc5a132d78e1828635aa8405a499f3e14864`，270 个桌面补丁，产品 `Ver 2.1 (125)`。Android 独立固定 `155.0.8059.39`。
- 官方核查时间 `2026-10-08T14:49:12Z`：上述桌面及 Android 版本为正式 Stable，采集 errors 与 unresolvedExploited 均为空；156 Early Stable 未纳入。

## 本次修复及验证

从真实 GitHub main 建立 `codex/upstream-155-source-sync`，以共同基点 `a4480b4ab0c04b8f486a01f7486ecdb15f2fed25` 三方整合已完成的升级。保留已合入的每日调度修改，隔离主目录既有 iOS 等开发差异。保留全部补丁序列、155 适配及持续功能验收要求；并未跳过补丁或删除原有功能来解决冲突。

- `pnpm run quality:fast` 退出码 0。
- 上游监控、功能清单、候选、发布编排、资产验证共 79 项流程回归通过。
- `verify-build-source.py --source <固定 Chromium src>` 完整重放通过，493 个 overlay 文件通过验证；Chromium tree `890250aaa300991fffb9fe1cf017a75a1ba6c42b`，V8 tree `1311034bb4ae51f33eec3046a83146649421c300`，与现有构建源码一致。
- 本轮没有重新编译 App；既有 125 的 Mac 验证只按其原始范围引用，不代表本轮完成三平台发行。
- 维护规则改为每次开发先核对真实远端主线、官方 Stable、产品 pin/补丁和实际构建树；源码提交/草稿 PR、主线兼容验收、正式发行分别跟踪。同步文档中的日调度与响应目标。

本地证据位于 `.artifacts/upstream-sync-audit-20261008/`：官方核查、三方整合文件清单、`quality-fast.log`、`source-replay.log`、`tests/`。旧隔离目录和原开发目录的未提交差异均保留。

## 尚未完成

本次分支及草稿 PR 是源码审核成果，不是 main 已升级或正式 Release。Windows、Android 的构建及实机兼容验收、Mac 正式签名/公证、发行 API 权限和真实验收包装器接线仍按 [发行接入记录](release-automation-2026-10-08.zh-CN.md) 处理；不因源码提交而豁免。主线合入必须满足仓库检查和既定兼容门槛；正式 tag、资产发布与客户端更新仍需要独立真实证据。

## 完整 CI 发现与修复

草稿 PR #32 首轮完整质量检查发现 Python 覆盖率声明漏掉 `release-contract.py`；快速检查没有执行完整覆盖率汇总，因此未发现这处遗漏。补齐生产脚本清单，并将对应 11 项回归加入覆盖率采集。维持文件集合严格匹配和原有覆盖率阈值，不豁免失败。完整 CI 的最终状态以该 PR 当前检查为准。
