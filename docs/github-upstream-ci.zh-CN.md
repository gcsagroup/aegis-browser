# GitHub 三平台 Chromium 候选流水线

目标是让 Mac ARM64、Windows x64、Android ARM64 的构建与验收独立连续运行，结果汇总到 GitHub。工作流需审核合入并接通构建机；三平台实际构建与验收全部通过前，不能报告线上自动升级已经接通。

## 两条工作流

- `.github/workflows/chromium-upstream.yml`：每小时第 17 分钟及手动触发，运行监控回归，独立核对三平台正式 Stable、公告和源码提交，保存结果。使用 GitHub 托管 Linux，不读取本机安装状态；云端报告没有本机 App 证据时，不能解除本机漏洞状态。GitHub 定时调度可能延迟，不能承诺严格一小时 SLA。
- `.github/workflows/chromium-candidate.yml`：手动触发，或推送 `codex/upstream/**` 候选分支时运行。前置官方检查通过后，同时执行三个构建任务，一个失败不取消其他平台。每台机器沿用自己的固定源码与输出目录，不重新检出、清理或覆盖其他开发工作区。

候选执行顺序：核对该平台官方版本与候选双 pin → 对干净基线应用完整补丁 → 临时索引复现整个 Chromium/V8 源码树 → 递增产品构建号 → GN 检查 → 编译 → 原生测试 → 生成候选包 → 运行机器配置的实际验收程序 → 校验本次产物哈希与验收记录 → 上传日志与产物。

工作流只读仓库，不创建 Release、不合并 PR、不正式签名公证、不替换现用 App。不会绕过源码冲突或测试失败；失败时保留补丁名、Git 现场、日志及旧产物。上游检测不具备自动进行语义适配的能力；新版本仍需生成并修正候选分支，修复提交后构建自动继续。当前未接入自动写代码的代理。

## 当前优先方案：GitHub 托管

2026-09-16 用户选择优先使用 GitHub 提供的机器。上游监控及 23 项脚本回归使用公开仓库的标准 `ubuntu-latest`，不依赖自托管机器或 `AEGIS_BUILD_RUNNERS_READY`。审核分支推送可以验证实际云端执行；合入默认分支后才有每小时定时运行。首次云端没有 `.chromium-root` 时记录源码路径为空，不伪造本机安装证据。

完整 Chromium 构建需要独立评估。GitHub 公布标准机器存储为 14 GB，托管任务上限 6 小时；Windows/Linux 可使用付费大规格机器。以下为 2026-09-16 官方价格快照，仅计算机器运行费用，不包含存储、税费或组织套餐：

| 平台 | 评估规格 | 每分钟美元 | 运行 2 小时 | 运行 6 小时 |
| --- | --- | --- | --- | --- |
| Android 的 Linux x64 构建 | 32 核、128 GB 内存、1200 GB 存储 | 0.082 | 9.84 | 29.52 |
| Windows x64 构建 | 32 核、128 GB 内存、1200 GB 存储 | 0.162 | 19.44 | 58.32 |

2 小时与 6 小时只是成本场景，不是已经测得的构建时长。大规格机器需要组织的 Team 或 Enterprise Cloud 套餐，公开仓库也收费。付费执行需先确定预算；目前没有启动付费机器，也没有新增预算或付款信息。

Mac 大规格机器公布存储仍为 14 GB，完整 Mac 构建暂沿用现有环境。Android 托管 Linux 可运行模拟器测试，但不能替代现有 ARM64 真机验收；APK 构建、模拟器与真机结果分别记录。

现有 `chromium-candidate.yml` 是专用源码目录方案，保持就绪开关关闭。它不能仅更换 `runs-on` 就当作托管完整构建：还需要适配首次依赖准备、六小时时限、缓存/产物交接、工具链与真实验收。下面的自托管注册说明保留为备选，不是免费上游检查的前置要求。

来源：[标准机器](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)、[大规格机器](https://docs.github.com/en/actions/reference/runners/larger-runners)、[时限](https://docs.github.com/en/actions/reference/limits)、[计费](https://docs.github.com/en/billing/reference/actions-runner-pricing)。

## 构建机接入

| 平台 | GitHub runner 标签 | 固定输出 | 候选产物 |
| --- | --- | --- | --- |
| Mac ARM64 | `self-hosted`, `macOS`, `ARM64`, `aegis-upstream` | `src/out/AegisRelease` | ad-hoc 签名 App 的 ZIP |
| Windows x64 | `self-hosted`, `Windows`, `X64`, `aegis-upstream` | `src/out/AegisRelease` | `mini_installer.exe`，非正式签名发行包 |
| Android ARM64 | `self-hosted`, `Linux`, `X64`, `aegis-upstream` | `src/out/AegisAndroid` | `ChromePublic.apk`，非 Play 发布 |

三台专用机器需预装 Python 3.12+、Git、对应 Chromium 工具链和系统依赖。Android 编译必须使用 Linux x64；实际验收另需连接专用 ARM64 测试设备。Mac 桌面、Windows UI 验收需要可交互的测试会话。不要将允许任意外部 PR 执行代码的通用 runner 用作这里的构建机。

首次机器准备：在独立候选目录检出该平台官方 Chromium 基线，同步其 DEPS、V8、工具链和项目额外依赖（包括平台需要的 libtorrent/Boost）；不要借用正在编译的目录。脚本会应用项目补丁；已有适配后的源码也可以使用，但必须与本次候选完整补丁树一致。依赖的首次安装和机器注册尚未由此脚本自动完成。

每台机器设置服务环境变量 `AEGIS_CI_CONFIG`，指向本机 JSON，例如 Mac：

```json
{
  "sourceRoot": "/Volumes/AegisBuild/upstream-candidate/src",
  "jobs": 6,
  "minFreeGiB": 100,
  "acceptanceCommand": ["python", "/Volumes/AegisBuild/acceptance/run.py"]
}
```

Windows 使用相应 Windows 路径，Android 使用 Linux 路径。`minFreeGiB` 不得小于 30；监测低于阈值时中止进程树，保留文件。`.aegis-ci-lock` 位于源码父目录；已有锁时直接停止，只有确认原进程已退出才能由维护者处理遗留锁。源码目录必须由此 runner 独占，不能与本地构建或另一任务同时使用。

三个 runner 在线且接受对应标签、依赖与验收程序均准备好后，才将仓库变量 `AEGIS_BUILD_RUNNERS_READY` 设为 `true`。变量不存在时工作流前置检查明确失败，不会无限等待不存在的机器。

## 各平台版本与补丁

默认读取 `apps/browser/CHROMIUM_VERSION`、`CHROMIUM_COMMIT` 和 `patches/`。若 Android 与桌面发布版本不同，在候选分支增加 `apps/browser/ci-pins/android.json`：

```json
{
  "version": "153.0.8010.36",
  "commit": "507c6ee3e2f3b2ca0e660547e5b9ea4820c67f4c",
  "patchDirectory": "patches/android"
}
```

这只是格式示例，不能仅新增 pin 冒充源码已经适配；`patchDirectory` 必须包含该平台真实的完整 `series` 和 `v8/series`。Mac/Windows 可用同名平台 JSON 独立配置。版本、提交必须同时匹配本次官方检查，当前正式仓库的 151 pin 不会被当成 153 候选编译。

每次真实构建在机器固定 out 的 `.aegis-ci/build-number.json` 递增编号，并记录实际产品版本。源码产品版本头在本次构建期间修改、结束时恢复；生成包的版本、源码 HEAD、两棵源码树和包 SHA-256 写入结果。该流水线不修改仓库正式版本文件，也不将候选编号提交到主分支。

## 真实验收接口

`acceptanceCommand` 是由维护者在专用机器配置的参数数组，不经过 shell，也不接受 PR 文本作为命令。执行器会追加：

```text
--artifact <本次ZIP/EXE/APK> --source <src> --out <out>
--evidence <本次证据目录> --receipt <acceptance.json> --run-id <本次运行ID>
```

该程序必须实际执行平台验收，输出本次产物的记录：

```json
{
  "runId": "运行参数给出的ID",
  "artifactSha256": "本次产物真实SHA256",
  "checks": {
    "native_tests": "passed",
    "browser_smoke": "passed",
    "actor_permissions": "passed",
    "v8_security_regressions": "passed"
  },
  "evidenceFiles": ["runtime/browser.log", "runtime/security.log"]
}
```

不能手工填写通过作为替代。必须适配到已有平台验收程序并验证：Windows 可复用 `windows-agent-ui-acceptance.ps1` 和 `windows-protection-headless-acceptance.ps1`，Android 可复用 `android-agent-ui.mjs` 并实际运行设备上的原生测试，Mac 必须启动本次候选 App。两项 V8 回归及 Actor 权限测试也需保留真实日志；尚未配好的项目填 pending 或失败，不能跳过。

此接口的各平台包装程序依赖具体测试机器、设备、profile 和模型服务，本次没有虚构实现或通过记录。桌面两组独立原生测试由流水线直接编译并运行；Android 原生测试仅交叉编译，实际执行必须由设备验收程序完成。验收接口缺失或任意项目不通过，候选包仍保存，整个任务保持失败。

## 启用与完成标准

1. 使用仓库配置的 SSH 身份推送审核分支，审核合入后启用定时工作流。2026-09-16 核实 SSH 认证账号为 `GCSA-ToolsTeam`，推送预检通过；`gh` API 账号 `erjinyi` 的 `push=false` 与 runner 查询 HTTP 403 仅代表该 API 身份，不代表 SSH 推送权限。
2. 注册以上三个 runner 并配置独立源码、工具链及实际验收命令。
3. 发布各平台已经适配的候选 pin/补丁，手动运行一次完整工作流；检查每个平台的安装包、原生/设备日志和最终验收记录。
4. 三平台真实运行全部通过才算自动候选链路接通。正式签名、发布、安装升级继续作为后续独立步骤，不靠绿色编译结果替代。

当前本地 153 候选不由这些工作流接管或重复启动。

## 管理员首次注册操作

1. 用组织所有者或仓库管理员账号打开仓库 `Settings → Actions → Runners → New self-hosted runner`。这是 GitHub 仓库权限，不是要求把所有构建进程以系统管理员运行。
2. 按机器选择系统与架构：Mac 选 macOS/ARM64，Windows 选 Windows/x64，Android 构建机选 Linux/x64。Android 手机通过 ADB 接入 Linux 构建机，不注册为 runner。
3. 在对应机器的独立 runner 目录，依次执行页面生成的 Download 和 Configure 命令。注册令牌一小时有效，直接在目标机器使用，不提交到仓库或粘贴到讨论中。
4. runner 名称分别填写 `aegis-mac-arm64`、`aegis-windows-x64`、`aegis-android-linux-x64`；额外标签填写 `aegis-upstream`，保留自动生成的系统和架构标签。工作目录可使用默认 `_work`，不要填写现有 Chromium 源码目录。
5. 首次验证在已登录的测试用户会话启动：Mac/Linux 执行 `./run.sh`，Windows 执行 `./run.cmd`。Windows 桌面 UI 验收先不要选择作为系统服务运行。
6. 终端显示 `Listening for Jobs`，GitHub 页面显示 `Idle`，表示注册连接成功。记录机器名称及状态，随后由项目维护者配置独立源码、工具链、`AEGIS_CI_CONFIG` 和真实验收程序。注册成功不等于编译环境已经就绪。
7. 三平台环境验收完成后再设置 `AEGIS_BUILD_RUNNERS_READY=true`；首次注册时不要提前启用。

如果看不到新增按钮，由组织管理员检查仓库管理员角色及组织的 runner 限制。自托管构建机仅接受本仓库受信任候选分支，本工作流没有外部 PR 触发入口。

官方参考：[自托管 runner](https://docs.github.com/en/actions/reference/runners/self-hosted-runners)、[Android 构建要求](https://chromium.googlesource.com/chromium/src/+/main/docs/android_build_instructions.md)。

## 已知平台回归差异

153 候选在 Mac 的 regress-crbug-542403045 已通过。sandbox/regress/regress-543557673 使用 --sandbox-testing；该版本 V8 在 SandboxTesting::Enable 对非 Linux 平台直接 FATAL，因此需要 Linux 上的 d8 执行。不能在 Mac/Windows 跳过后填写通过；平台验收应明确区分本平台原生测试和相同 V8 源码在 Linux 的共享安全回归证据，保存源码树、编译配置与日志。
