# CI 检查路由 SDD

日期：2026-11-23。状态：草案。实现基线：`gcsagroup/aegis-browser` `0049a1f3eb79fdbc97ebd9367ff764c70d36c674`。

本草案把一次路由的输出从平台布尔值细化到检查。路径决定受影响的平台和检查，提交类型决定本次允许走多深。每个作业读取同一份计划，只在前置检查成功后申请 runner。选择和结果分开记录。

本文件不切换执行入口。合入前，自动路由仍以 [CI 指南的第三批](../../development/ci.zh-CN.md) 为准。`quality.yml`、`ios-release-validation.yml` 和 `macos-delivery.yml` 继续各自运行 impact。

## 问题

两次 Ready PR 说明平台布尔值会漏掉实际消费者。

| 输入 | 基线上的实际路由 | 路径原因 |
| --- | --- | --- |
| [PR #226](https://github.com/gcsagroup/aegis-browser/pull/226) `4b6977fe`，主题 `fix(android): query Play generatedApks by versionCode` | [quality](https://github.com/gcsagroup/aegis-browser/actions/runs/45107809450) 成功，`other-platforms` 跳过；[macOS 合同](https://github.com/gcsagroup/aegis-browser/actions/runs/45107809412) 成功；[iOS 合同和归档](https://github.com/gcsagroup/aegis-browser/actions/runs/45107809264) 跳过 | 三个文件都在 `scripts/release/`，文件名不含 `macos`，也不匹配 Android 目录规则，于是落入未知路径的 macOS 回退 |
| [PR #217](https://github.com/gcsagroup/aegis-browser/pull/217) `2e57f422`，主题 `feat(windows): align uninstall dialog with installer` | [quality](https://github.com/gcsagroup/aegis-browser/actions/runs/45102410021) 失败，`other-platforms` 随之跳过；[macOS 合同](https://github.com/gcsagroup/aegis-browser/actions/runs/45102409717) 成功；[iOS 合同和归档](https://github.com/gcsagroup/aegis-browser/actions/runs/45102409708) 跳过 | 卸载视图和 `patches/` 命中共享产品，品牌测试与说明文档命中未知路径。现行 Windows 规则只认 `.ps1`、`winrm`、`platform-tests/windows-*` 和 `scripts/ci/windows*` |

#226 改动的是 `scripts/release/android-play.py`、`scripts/release/test_android_play.py`、`scripts/release/test_android_release_matrix.py`。#217 改动的是卸载视图四处源码、`chrome_unscaled_resources.grd`、`apps/browser/patches/0532-align-windows-uninstall-ui.patch`、`apps/browser/patches/series`、`apps/browser/scripts/windows-uninstall-branding_test.py` 和 `docs/windows-installer.zh-CN.md`。

#217 的 `other-platforms` 跳过不能单独证明 `windows=false`，因为 quality 已经失败。路径并集、iOS 合同跳过和 macOS 合同成功一起说明这次路由没有选中 Windows。

上表是基线 `0049a1f3` 的规则。[#412](https://github.com/quinn521/aegis-browser/pull/412) 已于 2026-11-23 合入 `quinn521/aegis-browser` 的 `develop`，那里的 `selectsAndroid` 已覆盖 `scripts/release/android-*`、`scripts/release/android_*`、`scripts/release/test_android*.py`、`scripts/release/runner.rb` 和 `scripts/release/verify-aab.py`。按 `develop` 规则，#226 得到 `android=true`、`macos=false`，不再漏选。#217 在 `develop` 上仍然漏选 Windows：卸载视图和补丁走共享产品，`windows-uninstall-branding_test.py` 不含 `winrm`，仍落入 macOS 回退。上游 `main` 尚未包含 #412。

iOS 合同目前只等待自己的 impact，不等待 quality。合同条件在 `ios-release-validation.yml` 的 contracts 作业；macOS 合同同样只等待 `macos-delivery.yml` 自己的 impact。因此 #217 的 macOS 合同可以在 quality 失败时仍然成功。

Windows 漏选的修复是 fork 的 [#413](https://github.com/quinn521/aegis-browser/pull/413)，截至 2026-11-24 仍未合入。fork 上的规则修复要随晋升才进入上游，见「Fork 与上游」。

## 边界

保留门禁、集成、深度三个自动阶段。签名、公证、TestFlight、Play 上传和 GitHub Release 继续只接受各自的手动 dispatch，不进入自动 `checks[]`。

`quality-gate` 继续只汇总 `quality`。`scripts/ci/promotion-quality.mjs` 的读取契约保持不变：先看 `quality.yml` 的 push run 结论，再要求同一 attempt 上唯一的 `quality` 与 `quality-gate` 成功。平台诊断的失败要单独显示，同时不能改变这个函数对 `quality.yml` 的结论。

C++ 路径过滤、秘密扫描、Chromium 候选和覆盖率 workflow 的现有触发保持原入口。完整 kcov 与 Pester 不从平台作业调用。

非目标：改产品源码、放宽 Draft 规则、把轻量说明名单按目录或后缀扩大、让 scope 参与平台选择。

## 计划

`quality.yml` 的 impact 是常规 Ready PR 和主线 push 的唯一计划生产者。计划使用 schema 3。

```json
{
  "schemaVersion": 3,
  "event": "pull_request",
  "repository": "gcsagroup/aegis-browser",
  "headRepository": "gcsagroup/aegis-browser",
  "branch": "main",
  "base": "<40 hex>",
  "head": "<40 hex>",
  "testedSha": "<40 hex>",
  "rulesSha": "<40 hex>",
  "planDigest": "<64 hex sha256>",
  "affectedPlatforms": {"ios": false, "android": true, "macos": false, "windows": false, "linux": false},
  "stageCeiling": "deep",
  "lightweight": false,
  "unmappedPaths": [],
  "checks": [
    {
      "id": "android-release-regression",
      "platform": "android",
      "stage": "integrate",
      "selected": true,
      "reasons": [{"path": "scripts/release/android-play.py", "rule": "android-release-consumer"}]
    }
  ]
}
```

`stageCeiling` 与 `checks[].stage` 只取 `gate`、`integrate`、`deep`，依次对应门禁、集成、深度。`checks[].platform` 只取 `quality`、`ios`、`android`、`macos`、`windows`、`linux`。其他取值使计划无效。

`planDigest` 覆盖选择，不覆盖结果。摘要输入是去掉 `planDigest` 本身后的计划，序列化为无空白的 UTF-8 JSON，再取 sha256 的小写十六进制。字符串转义与 `JSON.stringify` 一致。键顺序固定如下，不按字母排序：

- 顶层：`schemaVersion`、`event`、`repository`、`headRepository`、`branch`、`base`、`head`、`testedSha`、`rulesSha`、`affectedPlatforms`、`stageCeiling`、`lightweight`、`unmappedPaths`、`checks`
- `affectedPlatforms`：`ios`、`android`、`macos`、`windows`、`linux`
- `checks[]` 每项：`id`、`platform`、`stage`、`selected`、`reasons`
- `reasons[]` 每项：`path`、`rule`

`headRepository` 是 PR head 所在的仓库；push 和 `workflow_dispatch` 时等于 `repository`。它和 `repository` 一起参与身份核对，用来区分同仓库分支和 fork 发来的 PR。

`unmappedPaths` 按 UTF-16 码元升序排序，`checks` 按 `id` 排序，每项 `reasons` 按 `path` 再按 `rule` 排序。计划中出现上述以外的键时，消费者按 schema 3 缺字段同样处理，门禁失败。

结果写在另一份文档。一次运行的结果至少包含 `testedSha`、`runId`、`runAttempt`，以及每项已选检查的 `state`。允许的状态是 `passed`、`failed`、`cancelled`、`blocked-prerequisite`、`missing-artifact`、`reused`。`missing-artifact` 必须带具体说明。已选检查遇到失败、取消、前置阻断或缺少原生产物时，结果使用对应状态，不用一个跳过来代替。

## 规则

### R1 计划唯一

PR 从合并候选第一父提交读取 `scripts/ci/platform-impact.mjs`、规则清单和 `scripts/ci/fill-platform-route-defaults.mjs`，校验第二父提交等于事件 head，并以候选 SHA 作为 `testedSha`。`rulesSha` 是第一父提交。`pull_request.base.sha` 滞后时仍以第一父提交为准。

push 的 `testedSha` 与 `rulesSha` 都是被测提交。`github.event.before` 是其祖先时，用这个区间做差异；它缺失、为 40 个 0、等于被测提交或不是祖先时，沿用 iOS 与 macOS 的完整自动路径，不因此打开 Android、Windows 或 Linux。`workflow_dispatch` 不走轻量跳过，并保留这条 iOS 与 macOS 回退。

消费者核对仓库、head 仓库、事件、`testedSha`、`rulesSha` 和 `planDigest`。已知 schema 2 只补缺失的布尔键；已经写出的 `false` 保持 `false`。schema 2 没有 `checks[]` 时不合成检查，改走现行布尔路由，见「Fork 与上游」的切换窗口。schema 不是 2 或 3、schema 3 缺少字段、摘要不一致或身份不一致时，门禁失败。分类器和补全器都从可信提交提取，不执行候选工作区里的副本。

### R2 平台与深度独立

`affectedPlatforms` 是变更路径的并集。Conventional Commit 的 scope 不参与。`ios=true` 且 iOS 合同、归档都未选中，是合法计划，门禁不得因此失败。

普通 PR 对合并范围内的提交主题取最高阶段：

| 主题类型 | 阶段上限 |
| --- | --- |
| `feat` `fix` `perf` `refactor` `build` `revert` | 深度 |
| `test` | 集成 |
| `chore` `ci` `style` `docs` `release` | 门禁 |

`release` 继续沿用现行类型表：它是合法 Conventional 类型，本身停在门禁。多个主题并存时取更高阶段，例如 `chore` 加 `feat` 的上限是深度。

删除、类型或模式变化、符号链接、非 Conventional 主题、空主题，以及有差异却没有主题，都按受影响路径进入深度。`git diff --raw --no-renames` 把重命名显示为删除加新增，因此重命名也进入深度。

`scripts/ci/platform-impact.mjs` 自身变化时五个平台都受影响，阶段上限为深度。`scripts/ci/fill-platform-route-defaults.mjs` 的普通内容修改也覆盖五个平台，阶段仍按本次主题决定，不因文件身份直接升到深度。

push 不使用上表。它的阶段上限是该分支现有自动 workflow 已经会执行的最深阶段。触发范围之外的检查保持 `selected=false`，runner 为 0；`affectedPlatforms` 仍只反映路径并集。`blocked-prerequisite` 只用于已经选中、随后前置失败的检查。

### R3 按实际输入选检查

一项检查登记稳定 ID、平台、输入、阶段和证据。共享脚本可以属于多个平台，按实际消费者分别登记。未命中任何检查、也不是白名单说明或路由器自身的路径写入 `unmappedPaths`，并按现行规则回退到 macOS 合同；阶段仍受本次上限约束。

只有同时满足以下条件的 PR 才把 `lightweight` 设为 true，并只选中 `quality-docs`：

- 事件是 pull request，且现行 `CI_LIGHTWEIGHT_ADMITTED` 为 true。该条件是目标分支为 `develop`、仓库变量 `AEGIS_SELF_HOSTED_TEST_REPOSITORY` 已配置、当前仓库等于该变量、head 仓库等于当前仓库。
- 每个变更都是白名单文件的普通内容修改：状态 `M`，前后模式都是 `100644`。
- 白名单仍是这六个路径：`docs/plans/access-build-portability/acceptance.md`、三份 `docs/ios-webkit-protection.{en,zh-CN,zh-TW}.md`、`docs/plans/macos-access-toolbar-bubble-NOTES.md`、`docs/plans/macos-access-bubble-session-NOTES.md`。

push、未准入仓库、删除、重命名、模式变化，以及白名单与其他路径混合，都走完整门禁。

| ID | 平台 | 阶段 | 输入 | 证据 |
| --- | --- | --- | --- | --- |
| `quality-full` | quality | 门禁 | 非轻量路由的全部变更 | `scripts/ci/run-quality.mjs --scope full` 的报告 |
| `quality-docs` | quality | 门禁 | 已准入的白名单正文 | `scripts/check-repo-contracts.mjs` 日志 |
| `ios-contracts` | ios | 集成 | `apps/ios/**`、`.github/workflows/ios-*`、`scripts/ci/ios-*`、`scripts/ci/run-ios-*`、`scripts/ci/tests/ios-*`、`fastlane/**`、`Gemfile`、`Gemfile.lock`、`.github/actions/ensure-ios-ruby/**`、`scripts/release/` 里文件名以 `ios-`、`ios_` 或 `test_ios_` 开头的文件，以及下方无此前缀的 iOS 消费者 | fastlane 测试、iOS 发布回归、`scripts/ci/tests/ios-*`、iOS workflow 语法检查。切换后这些 iOS 合同只有这一处入口；`scripts/release/test_android*.py` 只留在 `android-release-regression` |
| `ios-unsigned-archive` | ios | 深度 | 见下方归档输入 | 现有自托管或 `macos-26` 作业、未签名归档，以及 `storage-receipt.json` 与 `unsigned-artifact.json` 的身份 |
| `macos-contracts` | macos | 集成 | `.github/workflows/macos-*`、`scripts/release/**` 中路径含 `macos` 的文件、共享产品、`unmappedPaths` | `test_macos_dmg.py`、`test_macos_dmg_delivery.py`、`test_macos_developer_id.py` 和 `scripts/release/macos-access-tests.sh` |
| `android-host-contracts` | android | 集成 | `apps/browser/patches-android/**`、`apps/browser/scripts/**` 中路径含 `android` 的文件、`.github/workflows/android-*`、`scripts/ci/android-*`、`scripts/ci/run-android-*` | `test:android-target`、`test:android-ui`、`test:scripts:android` |
| `android-release-regression` | android | 集成 | `scripts/release/**` 中路径含 `android` 的文件、`scripts/release/verify-aab.py`、`scripts/release/runner.rb` | 实际执行的 `test_android*.py` 文件列表。`runner.rb` 的 Node 覆盖已经在 `quality-full` 的 `scripts/ci/tests/android-release.test.mjs` 里，身份匹配时复用该条 `ci:test` 记录 |
| `windows-winrm` | windows | 集成 | `.ps1`、`scripts/ci/platform-tests/windows-*`、`apps/browser/scripts/ci/windows*`、`apps/browser/scripts/**` 中路径含 `winrm` 的文件 | `test:winrm-model-relay` 的自测结果。这个结果只属于本检查 |
| `windows-uninstall-branding` | windows | 集成 | 见下方 Windows 输入 | 同一次构建的 `resources.pak` 与生成头。缺少时状态为 `missing-artifact`，说明为 `Windows 卸载资源待验证` |
| `linux-shell-contract` | linux | 集成 | `scripts/ci/run-shell-coverage.sh`、`scripts/ci/platform-tests/kcov-*` | Bash 父子 fixture，以及现有报告校验；不编译 kcov |

无 `ios-` / `ios_` / `test_ios_` 前缀、但由 iOS 合同或 iOS 发布工具导入的文件也进入 `ios-contracts`。它们来自 #412 的消费者清单，并限于本基线已经存在的路径：

`scripts/release/artifact-transport.py`、`central-ios.py`、`central-reservation.rb`、`central_ios_protocol.py`、`central_operator_authorization.py`、`clear-empty-build-upload.rb`、`cli.rb`、`cloud-archive.py`、`cloud-signing-poc.py`、`development_key_access.py`、`development_signing.py`、`hosted-signing.py`、`local-ios-signing.py`、`prepare-ios-access-core.sh`、`prepare-ios-package-core.sh`、`private-beta-inputs.py`、`product_artifacts.py`、`product_delivery.py`、`record-ios-access-core-digests.sh`、`safari_manifest.py`、`build-ios-access-core.sh`，以及同目录下对应的 `test_artifact_transport.py`、`test_central_ios.py`、`test_central_operator.py`、`test_central_retained.py`、`test_cloud_archive.py`、`test_cloud_signing_poc.py`、`test_development_key_access.py`、`test_development_signing.py`、`test_hosted_signing.py`、`test_local_ios_signing.py`、`test_native_signing_session.py`、`test_private_beta_inputs.py`、`test_product_artifacts.py`、`test_product_delivery.py`、`test_verify_ios_archive.py`、`test_verify_ios_dsyms.py`、`test_verify_ipa.py`、`test_verify_signed_ios.py`、`verify-ios-archive.py`、`verify-ios-dsyms.py`、`verify-ipa.py`、`verify-signed-ios.py`，还有 `scripts/release/fixtures/safari-icon-xcode.png`。

其中只有归档作业实际调用的脚本同时进入 `ios-unsigned-archive`。编辑签名、公证或 TestFlight 工具会选中 iOS 合同，不会自动 dispatch 签名或上传。

共享产品是 `packages/core/**`、`apps/browser/overlay/**`、`apps/browser/patches/**` 中 `patches-android` 以外的路径。它们选中 `macos-contracts`。已知 Windows 专属路径在此之外叠加 Windows 检查，macOS 合同仍然保留。

Windows 专属输入：

- `apps/browser/overlay/chrome/browser/ui/views/uninstall_view.cc`
- `apps/browser/overlay/chrome/browser/ui/views/uninstall_view.h`
- `apps/browser/overlay/chrome/browser/ui/views/uninstall_view_unittest.cc`
- `apps/browser/overlay/chrome/browser/ui/views/aegis_uninstall_test_main.cc`
- `apps/browser/overlay/chrome/app/theme/gcsa_aegis/win/**`
- `apps/browser/overlay/chrome/installer/**`
- `apps/browser/args/aegis-windows.gn`
- `apps/browser/scripts/windows-*`
- `apps/browser/patches/**` 中路径含 `windows` 的补丁文件

`apps/browser/overlay/chrome/app/theme/chrome_unscaled_resources.grd` 同时是共享产品和品牌检查输入：它保留 macOS 合同，并选中 `windows-uninstall-branding`。`apps/browser/patches/series` 只按共享补丁选择 macOS。品牌检查的直接输入还包括测试本身所读的安装器 ICO 与生成头 `gen/chrome/grit/chrome_unscaled_resources.h`；这两份产物来自构建目录，不在源码差异里。

归档输入是参与 Aegis archive 编译的源码、Xcode 工程、依赖锁，以及归档作业实际调用的脚本：

- `apps/ios/**` 中参与编译的源码。`apps/ios/Tests/**`、`apps/ios/**/*.md`，以及 `apps/ios/scripts/` 下的模拟器、覆盖率辅助脚本，只进入 `ios-contracts`
- `apps/ios/project.yml`、`apps/ios/Aegis.xcodeproj/**`
- `apps/ios/Aegis.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `apps/ios/EmbeddedCore/embedded-core-lock.json`
- `scripts/ci/ios-ci-storage.py`
- `scripts/release/prepare-ios-access-core.sh`
- `scripts/release/ios_embedded_core.py`
- `scripts/release/verify-ios-archive.py`
- `scripts/release/test_ios_linked_bundle.py`
- `scripts/release/test_ios_profile_trust.py`
- `scripts/release/test_development_signing.py`
- `scripts/release/test_development_key_access.py`
- `apps/browser/scripts/common.sh`，因为归档步骤会 source 它
- `.github/workflows/ios-release-validation.yml`

`common.sh` 在本基线的 macOS 合同和 Android host 合同中没有被执行，因此它单独变化时只命中归档输入。`Gemfile` 与 fastlane 由 iOS 合同使用，归档作业不调用它们。

模拟器、kcov 和 Pester 继续走各分支已经存在的覆盖率入口。本基线的 `other-platform-coverage.yml` 只有 `workflow_dispatch`。Linux 轻量合同运行 `kcov-parent-fixture.sh` 与 `kcov-child-fixture.sh` 的 Bash 父子进程，并复用 `run-shell-coverage.sh` 里已经存在的报告判断：父子 fixture 被覆盖、合并报告含生产 Bash、报告不含 harness 或 fixture、不缺生产源、必需源有执行行。它不安装或编译 kcov。

### R4 按依赖分配 runner

quality 成功之后才申请选中的平台合同 runner。quality 失败、取消或未完成时，已选平台检查的状态都是 `blocked-prerequisite`，新分配的平台 runner 数为 0。这个状态由已经存在的 quality 作业写下，不另开平台 runner。

Android、Windows、Linux 的已选合同共享一次 Ubuntu checkout 和 Node 安装。每个检查单独执行、单独写结果。某个套件失败后，其余已选套件继续执行。共享安装失败时，尚未执行的套件记为 `blocked-prerequisite`。

iOS unsigned archive 同时满足四项才分配 runner：iOS 合同成功、阶段上限允许深度、至少一条归档输入命中、目标分支的现有 workflow 准入允许归档。归档还要核验现有自托管标签或 `macos-26` 回退，以及产物中的 tested SHA 与 run attempt。

Draft 或缺少明确 `draft: false` 时，impact 与平台作业都不申请 runner，平台 runner 数为 0。`converted_to_draft` 通过现有 PR concurrency 取消旧运行。重跑产生新的 run attempt；旧 attempt 的成功记录不能把当前候选判为通过。

## 分支准入

阶段上限还要落在分支已经声明的触发范围内。

| workflow | pull request | push |
| --- | --- | --- |
| `quality.yml` | `main`、`develop` | `main`、`develop`、`releases/ios/1.0` |
| `ios-release-validation.yml` | `main`、`develop` | `main`、`codex/ios-release-*` |
| `macos-delivery.yml` 自动合同 | `main`、`develop` | `main`、`promote/ios-access-closed-loop-2cd7` |

因此普通 `develop` push 可以运行 quality，以及 quality 里已有的 Android、Windows、Linux 集成合同；它不分配 iOS 合同、iOS 归档或 macOS 合同。`main` push 保持 iOS 归档和 macOS 合同的现有资格。这个草案不给上述 workflow 增加触发分支。

上表三份 workflow 在两个仓库的触发相同。上游没有 `develop` 分支，表中的 `develop` 只在 fork 生效；上游只按 `main` 的 PR 和 push 路由。

## Fork 与上游

路由在开发 Fork `quinn521/aegis-browser` 和上游 `gcsagroup/aegis-browser` 两处运行。两边的规则和 workflow 最终共享同一版本，但在一批晋升合入之前可以不同。下表是 2026-11-24 回读的状态。

| 项目 | Fork | 上游 |
| --- | --- | --- |
| 自动路由的分支 | `develop`；个人 `main` 只快进镜像上游 | `main` |
| 必需检查 | `quality-gate`、`gitleaks` | `quality-gate`、`Codacy Static Code Analysis`、`gitleaks` |
| `AEGIS_SELF_HOSTED_TEST_REPOSITORY` | 本仓库 | 本仓库 |
| `AEGIS_IOS_RUNNER_LABEL` | `aegis-ios-fork-migration` | `aegis-ios-upstream-migration` |
| 轻量说明路由 | 可准入 | 不准入：`CI_LIGHTWEIGHT_ADMITTED` 要求目标分支为 `develop` |
| 分类器 | `develop` `2c07cd24`，含 #412 | `main` `423ac984`，`platform-impact.mjs` 与基线 `0049a1f3` 相同 |
| `quality.yml` 的 `other-platforms` | 读取 `linux`，`continue-on-error: true`，按平台分步骤 | 不读取 `linux`，单个 `quality:other-platforms` 步骤 |
| `other-platform-coverage.yml`、`android-java-coverage.yml` | PR 和 push 自动运行 | 只有 `workflow_dispatch` |

### 规则跟随目标分支

PR 的分类器和补全器取自合并候选的第一父提交，也就是目标分支。指向 fork `develop` 的 PR 用 `develop` 的规则；指向上游 `main` 的 PR，包括晋升 PR，用上游 `main` 的规则。因此 #412、#413 这类规则修复合入 fork 后只保护 fork，上游要等含它的晋升批次合入 `main` 后才生效。晋升 PR 本身仍按上游旧规则分类；如果批次修改了 `platform-impact.mjs`，R2 会让五个平台都进入深度。

同一组路径在两个仓库可以得到不同计划，计划用 `repository`、`rulesSha` 和 `planDigest` 区分。对照测试按 `rulesSha` 断言。fork 的计划或结果不能用来解释上游的运行，反过来也一样。

### 晋升与回流

晋升 PR 是 `codex/promote-<D>-<B>` 到上游 `main`，差异是 `B..D`。回流 PR 是 `codex/backflow-<S>` 到 `develop`。两者都用 merge commit 合入，范围内通常有 `Merge pull request …` 或 `Merge branch …` 主题。这些不是 Conventional 主题，按 R2 进入深度。这是有意的：晋升 PR 是代码进入上游 `main` 前最后一次自动验证，merge 主题不享受豁免。

两类 PR 都由控制器以 Draft 创建（fork 的 `AEGIS_PROMOTION_AUTOMATION` 当前为 `paused`）。Draft 期间平台 runner 为 0，协调者转为 Ready 后才分配。

### Runner 与信任

只有 `github.repository` 等于 `AEGIS_SELF_HOSTED_TEST_REPOSITORY`，且 PR head 仓库等于当前仓库时，才使用自托管 runner。晋升 PR 的 head 可以在任一仓库：#201 在上游，#193、#189、#181 在 fork。head 在 fork 时，上游的 quality 回退到 `macos-15`，iOS 归档回退到 `macos-26`。计划只决定选中哪些检查，不决定 runner 标签。runner 仍由各 workflow 现有的表达式选择，结果记录实际执行环境。

### 证据不跨仓库

结果和复用都绑定 `repository`。fork `develop` push 对 D 的结果不能当作上游晋升 PR 的证据：仓库不同，`testedSha` 也是另一个合并候选。个人 `main` 快进到 S 后的 push run 记在 fork 名下，不能替代上游对 S 的 push run，`promotion-quality.mjs` 也不读取它。晋升读者继续分别核对 fork `develop` 的 D 和上游 `main` 的 S。本草案不改变镜像 push 的触发。

### 切换窗口

`pull_request` 运行的是合并候选里的 workflow，分类器却取自第一父提交。所以切换 PR 和携带切换的晋升 PR 会遇到新 workflow 配旧分类器：计划仍是 schema 2，没有 `checks[]`。这时消费者走现行布尔路由，即各 workflow 现有的平台布尔值和 `integrate`、`deep` 条件。门禁不失败，平台 runner 数与旧路由相同。只有第一父提交产出 schema 3 时，才按 `checks[]` 执行。

切换顺序：

1. 分类器、补全器、workflow 消费者和布尔回退一起合入 fork `develop`，并核验 `develop` push。合入后的下一条 `develop` PR 才第一次由 schema 3 选择。
2. 随晋升进入上游。晋升 PR 按上游旧规则走布尔回退；合入后，上游 `main` 的下一条 PR 才开始用 schema 3。
3. 回流完成、两边第一父提交都产出 schema 3 之后，再用单独的 PR 删除布尔回退。
4. 上游发现漏选或错误判绿时，回退 PR 直接指向上游 `main`，合入后按现有路径回流，不等下一批晋升。fork 上的问题直接回退 `develop`。

## 复用

同一次 quality 已经执行过相同检查时，结果状态可以是 `reused`。复用同时匹配仓库、被测 SHA、检查输入摘要、工具链、执行环境和 run attempt。任一不一致就重新执行。

`develop` 上的完整 quality 已经通过 `scripts/ci/run-android-release-tests.py` discover `scripts/release/test_android*.py`。这份证据可以满足 `android-release-regression`，但结果里要列出实际执行的测试文件，不能只记录包装命令名。被测 SHA 上的报告没有这份文件列表时，检查改为执行，不复用。本基线 `0049a1f3` 的 `run-quality.mjs` 还没有这个命令，所以这次上游 quality 运行本身不能当作 #226 的复用证据。

WinRM 成功只写入 `windows-winrm`。它不改变 `windows-uninstall-branding` 的状态。

## 验收

离线测试使用 #226、#217 的真实路径和主题，以及下表的其余输入。期望是新计划的选择和 runner 分配。对照断言绑定规则提交：基线 `0049a1f3` 的 `platform-impact.mjs` 对前两行都漏选；`develop` 上含 #412 的分类器对 #226 已正确选中 Android，对 #217 仍漏选 Windows。测试按对应规则提交断言，不写成对任意现行分类器都漏选。

| 输入 | 必须观察到的结果 |
| --- | --- |
| #226 的三个 Android Play 文件，主题 `fix(android):` | `affectedPlatforms.android=true`，其余平台为 false。选中 `android-release-regression`，不选中 `macos-contracts` 和 `android-host-contracts`。macOS 合同 runner 为 0。提供同一次 develop quality 的 `test_android_play.py` 与 `test_android_release_matrix.py` 执行记录且身份匹配时，状态为 `reused`，结果包含这些测试文件。没有文件列表时状态不是 `reused` |
| #217 的九个路径，主题 `feat(windows):` | 选中 `windows-uninstall-branding` 和 `macos-contracts`。`series` 保留 macOS 合同，文件名含 `windows` 的补丁叠加 Windows。`docs/windows-installer.zh-CN.md` 进入 `unmappedPaths`。没有同次构建的 `resources.pak` 和 `chrome_unscaled_resources.h` 时，品牌检查状态为 `missing-artifact`，说明为 `Windows 卸载资源待验证`。WinRM 通过只出现在 `windows-winrm` |
| 同一 iOS 产品源码，例如 `apps/ios/AegisApp/Feature.swift`，分别用 `ci:`、`test:`、`fix:` | 三次 `affectedPlatforms.ios=true`。依次只跑门禁、门禁加 `ios-contracts`、合同成功后再分配 `ios-unsigned-archive`。普通 `develop` push 的 iOS 合同与归档 runner 都为 0 |
| `fix:` 修改 `scripts/release/android-play.py`，同时 `test:` 只修改 `scripts/ci/tests/ios-route.test.mjs` | Android 与 iOS 都受影响，阶段上限为深度。执行或复用 Android 发布回归和 iOS 合同。归档输入未变化，归档 runner 为 0 |
| 只修改 `scripts/ci/platform-tests/kcov-child-fixture.sh` 或 `kcov-parent-fixture.sh` | 选中 `linux-shell-contract`。macOS 合同数为 0。计划不引用 `other-platform-coverage.yml` |
| Android 与 Windows 检查都被选中，其中一项执行失败 | 两项都保留各自的 `passed` 或 `failed`。失败若来自共同前置 quality，两项都是 `blocked-prerequisite`，新分配的平台 runner 为 0 |
| Draft、转回 Draft、重跑拿到旧 attempt | Draft 的平台 runner 为 0。转回 Draft 取消同一 PR 的旧运行。旧 attempt 的成功记录在当前 attempt 上的状态不是 `passed` 或 `reused` |
| `ci(ios):` 只修改 iOS 产品源码 | `affectedPlatforms.ios=true`，`stageCeiling=gate`，iOS 合同与归档 runner 为 0。计划合法，消费者不报错 |
| `feat(ios):` 只修改 `apps/browser/args/aegis-windows.gn` | 选中 Windows。scope `ios` 不打开 iOS |
| 用上游 `main` `423ac984` 和合入 #413 后的 fork 分类器，分别复放 #217 的九个路径 | 前者 `windows=false`，后者 `windows=true`。断言写明各自的 `rulesSha` |
| 晋升 PR 的 `B..D` 含一个 `Merge pull request` 主题，其余是 `docs:` | `stageCeiling=deep` |
| 晋升 PR 的范围修改了 `scripts/ci/platform-impact.mjs` | 五个平台都受影响，`stageCeiling=deep` |
| head 在 fork、目标为上游 `main` 的 PR | `headRepository` 是 fork。quality 和归档不使用自托管标签。fork `develop` 对 D 的 push 结果状态不是 `reused` |
| 切换 PR：合并候选带新 workflow，第一父提交的分类器输出 schema 2 | 执行现行布尔路由，门禁不失败，平台 runner 数与旧路由相同 |
| 个人 `main` 快进到上游 S 后的 push run | 结果记在 fork 名下。晋升读者对 S 的判断只来自上游 push run |

迁移测试还要覆盖 `qualityWorkflowRunState`：`quality.yml` 的 run 结论为 success，且 `quality` 与 `quality-gate` 成功时，旁边一个失败的 `other-platforms` 作业不改变返回的 success。同一个 run 结论变为 failure 时，函数仍返回 failure。切换执行时要保证平台失败不会把 `quality.yml` 的 run 结论改成 failure；只改读者、让它忽略一个已经变红的 workflow 结论，不算满足这条。

## 草案取舍

以 [#412](https://github.com/quinn521/aegis-browser/pull/412)（已合入 `develop`）为执行形状的起点：发布脚本按实际消费者登记，Linux 使用轻量 Bash 合同，Android、Windows、Linux 在 quality 成功后分平台执行并共享一次 Ubuntu 初始化。#412 把 `verify-ipa.py`、`product_delivery.py` 等无平台文件名的 iOS 工具列入 iOS 合同；本登记表沿用这个归属，但归档只收下表中的归档输入。

从 [Draft #410](https://github.com/quinn521/aegis-browser/pull/410) 吸收 Windows 卸载视图、`gcsa_aegis/win`、安装器目录、`aegis-windows.gn` 和 `apps/browser/scripts/windows-*`。不吸收它的两处行为：`selectPlatformChecks` 会拒绝合法的 `ios=true` 且集成阶段为 false；平台作业通过 `workflow_call` 运行完整 kcov 或 Pester。也不把所有 `overlay/**/*test.cc`、所有桌面补丁或所有 Node workspace 文件设为 Windows 或全平台输入。

## 迁移与回滚

1. 先固定预期。用上表建立离线计划测试，并按规则提交保留对照：基线对 #226、#217 漏选，`develop` 只对 #217 漏选。`promotion-quality` 的读者锁测试使用现有读者，不改其判断。
2. 再比较计划。对同一批历史输入输出新旧计划、选中原因和预计 runner。切换时每项检查只留一个执行入口：Android 发布回归不再由 iOS 合同的 `scripts/release/test_*.py` discover 顺带执行；iOS 与 macOS 不再各自生成第二份可执行计划。iOS 归档额外核对现有自托管 workflow 与作业准入，以及归档产物上的 tested SHA 和 attempt。
3. 用可测条件放行。验收矩阵中的漏选数、同一检查的重复执行数、前置失败后新增的平台 runner 数都为 0。按平台记录 runner 分钟和绿单完成时间，单独列出合同等待 quality 的时间。发现漏选、错误判绿或晋升语义变化时，用回退 PR 恢复原来的执行入口：三个 impact、`quality:other-platforms` 组合命令，以及 iOS、macOS 合同只等待各自 impact。

跨仓库的切换顺序和上游回退见「Fork 与上游」。

回滚不改写已产生的 run 或 artifact。历史失败保留在原来的 attempt 上。

## 当前变更范围

本草案和 `promotion-quality` 的读者锁是当前变更。workflow 条件、`platform-impact.mjs` 和生产路由没有切换。下一份实现先落地离线计划测试，再进入计划比较。
