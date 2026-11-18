# Access 共享核心验收矩阵

## Android 最低 API 回归（2026-11-16）

基准 `ab7a5630` 的 x86_64 编译目标是 API 26，但 NDK r30 的旧版 CMake 工具链将 `CMAKE_SYSTEM_VERSION` 设为 `1`。修复后，CTest 使用工具链为编译器解析出的最低 API。以下作业均显式检出[修复提交 `84f17768`](https://github.com/quinn521/aegis-browser/commit/84f17768d0c1bf176b53783434dc0d7e1acb5ea9)，使用 NDK 30.0.16248370 和仓库注册的 `aegis_access_contract`。

| x86_64 模拟器 | 实际结果 | 证据 |
| --- | --- | --- |
| API 25 | 通过部署前拒绝，CTest 按预期返回 8 并报告最低 API 26。adb 仅查询序列号、ABI 和 SDK，未创建设备目录或推送程序 | [adb 轨迹与 CTest 日志](https://github.com/quinn521/aegis-browser/actions/runs/43829939299/job/133172573182) |
| API 26 | 通过，CTest 1/1，892 项检查 | [API 26 作业](https://github.com/quinn521/aegis-browser/actions/runs/43828675871/job/133168431490) |
| API 36 | 通过，CTest 1/1，892 项检查 | [API 36 作业](https://github.com/quinn521/aegis-browser/actions/runs/43828675871/job/133168431405) |

x86_64 编译目标为 `x86_64-none-linux-android26`，CTest 注册参数为 `26`。API 26 和 36 运行的 ELF SHA-256 均为 `49add3b40acf1b23ceb81be2e580ce020c978f5511c731ba48ffeecb01475b53`。覆盖 arm64 预设为 `ANDROID_PLATFORM=android-30` 时，编译目标与 CTest 注册参数均为 30。该 arm64 用例只完成配置核对。

API 25 首轮验证在创建 AVD 时缺少 SDK 模拟器包，后续启动还遇到 adb 路径、主机库和 AVD 路径问题。这些作业均未运行 CTest。上表记录修正环境后在模拟器报告 API 25 时执行的拒绝检查。

本次修复的 Windows、Android arm64 设备执行、物理真机及浏览器产品验收均未执行。基准提交的平台运行记录见 [PR #359](https://github.com/quinn521/aegis-browser/pull/359)。

## 初始实现验收

基准证据为 `7d47f940` 的 macOS 独立脚本 892 项检查。下表记录实现阶段的验证。最终提交的报告随 PR 登记。

| 需求 | 用例 | 结果 |
| --- | --- | --- |
| R1、R2 | macOS CMake 构建清单与实际编译源一致，独立编译 | 通过，11 个生产单元 |
| R3、R4 | macOS CTest、脚本、增量重建及向量生成 | 通过，892 项检查，覆盖率分母保持 11 个单元 |
| R1、R3、R4 | 桌面 Chromium 及 V8 完整索引重放 | 同步 develop `da37e3ec` 后，从桌面固定版本依次重放 483 个 Chromium 补丁及 3 个 V8 补丁；Access 为 `0483` |
| R1、R3、R4 | Android Chromium 及 V8 完整索引重放、Access 源码投影 | 从 Android 固定版本依次重放 321 个 Chromium 补丁及 3 个 V8 补丁；Access 为 `0321`，共享清单、源码和向量与 overlay 一致 |
| R3、R4 | Chromium 原生测试与浏览器集成 | 分平台记录，GN 生成和编译证据分别登记 |
| R2、R3 | Windows x64 原生编译及 CTest | `ab7a5630` 通过，生成 x64 PE，在 Windows 上执行 1/1 个测试，892 项断言通过 |
| R2、R3 | Android NDK 编译 | `ab7a5630` 通过，`android-arm64` 和 `android-x64` 两个预设均生成 API 26 的 ELF |
| R2、R3 | Android 模拟器 CTest | `ab7a5630` 通过：arm64-v8a 在 API 36，x86_64 在 API 26、36，各执行 1/1 个测试，均为 892 项断言通过；物理真机未执行 |
| R2、R3 | Android 最低 API 准入 | 未通过配置核对：编译目标为 API 26，生成的 CTest 传给 adb 运行器的最低 API 为 `1`。低于 API 26 的设备拒绝行为未验证 |
| R5 | 三端真实浏览器产品闭环 | T4–T7 |
| R6 | 仓库检查、独立 Review、PR CI | 按最终提交和 PR merge 候选分别登记 |

候选记录包括提交或完整差异、清单和向量摘要、编译器与 SDK/NDK、平台和 ABI、构建参数、产物摘要、实际用例及退出码。缺失、跳过和失败的项目分别保留。

## T3 实际执行记录（2026-11-16）

被测源码为 [PR #356 的 squash 提交 `ab7a5630`](https://github.com/quinn521/aegis-browser/commit/ab7a56307a79040d571bb4173846893aac9343e6)，树为 `f24ef32c883d54e0c6adeae4f35ee9f1dc96b43f`。[验证作业](https://github.com/quinn521/aegis-browser/actions/runs/43819334510) 由单独的工作流提交 `996c47f8` 触发；两个 runner 均显式检出并核对被测提交。三个预设都使用 Debug、Ninja 和仓库注册的 `aegis_access_contract`，构建与 CTest 退出码均为 0。

| 预设 | 编译与执行环境 | 测试程序 SHA-256 |
| --- | --- | --- |
| `windows-x64` | [Windows 作业](https://github.com/quinn521/aegis-browser/actions/runs/43819334510/job/133138535634)：Windows Server 2025 x64，clang-cl 20.1.8，Windows SDK 10.0.26100.0，CMake/CTest 4.4.5；`dumpbin` 确认 x64 | `c18186d0915bb8cc9e34232de4776d0c604b6df66d28ca367a5d178de05ffd36` |
| `android-arm64` | [Android 构建](https://github.com/quinn521/aegis-browser/actions/runs/43819334510/job/133138535944)：NDK r30（30.0.16248370），Clang 21.0.0，CMake 3.31.6；macOS 上用 CTest 3.31.10 经 adb 在 API 36 arm64-v8a 模拟器执行。[JUnit 原始结果](evidence/ab7a5630-android-arm64-ctest.xml) | `2619bc01e1628afa0320befbc1ca95686d2e2ffc0ed16ddc4d77967e2a63e7aa` |
| `android-x64` | [Android 构建和 CTest](https://github.com/quinn521/aegis-browser/actions/runs/43819334510/job/133138535944)：同一 NDK、Clang 和 CMake，在 API 36 x86_64 模拟器执行 | `d47cabef70854c293bf2f11f60c5f5a187f6fefdca6d3137edb2d78e3d44f9aa` |

arm64 构建与执行分布在两台主机。执行前校验了构建制品的 SHA-256，并独立确认模拟器的 ABI 和 API。仅将生成的 CTest 注册文件中的解释器、源码和构建路径映射到执行主机；测试名、运行脚本内容、ABI、最低 API 参数和超时均保持原值。

[API 26 边界作业](https://github.com/quinn521/aegis-browser/actions/runs/43820147022/job/133141131134) 核对了编译目标 `x86_64-none-linux-android26`，并在 API 26 模拟器上复跑了与 API 36 摘要相同的 x86_64 产物。最低版本拒绝检查单列：NDK r30 下，`CMAKE_SYSTEM_VERSION` 传给测试的值为 `1`。在报告 API 25 的模拟 adb 输入下，运行器继续尝试创建设备临时目录；传入 `26` 的对照在部署前拒绝。

[API 25 模拟器作业](https://github.com/quinn521/aegis-browser/actions/runs/43820147022/job/133141130940) 完成了 x86_64 编译，但 adb 等待 `sys.boot_completed` 时没有取得就绪结果，作业达到 30 分钟上限后取消。CTest 未启动，API 25 模拟器上的拒绝行为仍未验证。

此前在 `b3a09156` 上，Windows 因无可用主机未执行，Android 因 NDK 下载超时未编译，当时只有模拟 adb 的证据。本次执行补齐了独立核心的编译与模拟器运行。Android 物理真机和三端浏览器产品闭环仍未验收。

## T3 原生复验（2026-11-17）

本轮复验 [#360 的合并提交 `367f98bc`](https://github.com/quinn521/aegis-browser/commit/367f98bc7f1eb813bd854688def3e18f34e50966)，源码树为 `cbadb5456b103f4f07c39331f26fe1e301b2686e`。[验证工作流](https://github.com/quinn521/aegis-browser/actions/runs/43914376943) 由 `edb49148` 触发。Windows 和 Android 构建作业分别检出并核对被测提交和源码树，使用 Debug、Ninja 及仓库注册的 `aegis_access_contract`。

| 平台 | 编译与运行 | CTest 实际结果 | 测试程序 SHA-256 |
| --- | --- | --- | --- |
| Windows x64 | [Windows Server 2025 原生作业](https://github.com/quinn521/aegis-browser/actions/runs/43914376943/job/133464470368) 使用 `windows-x64`、clang-cl 20.1.8、Windows SDK 10.0.26100.0、CMake/CTest 4.4.5。编译清单中 11 个 C++ 源文件，`dumpbin` 确认 x64，随后在同一主机执行 | 1/1 通过，892 项断言，退出码 0 | `e846da00db62a377c450c25661e1498e4818fef286d80c6766a1cb48f5e0f020` |
| Android arm64-v8a | [NDK 构建作业](https://github.com/quinn521/aegis-browser/actions/runs/43914376943/job/133464470611) 在 Ubuntu 24.04 使用 `android-arm64`、NDK r30（30.0.16248370）、Clang 21.0.0、CMake 3.31.6，编译清单中 11 个 C++ 源文件。macOS 上的 CTest 3.31.10 经 adb 将该 ELF 推送到 API 36 arm64-v8a 模拟器并执行 | [1/1 通过，892 项断言](evidence/367f98bc-android-arm64-ctest.xml)，退出码 0 | `2619bc01e1628afa0320befbc1ca95686d2e2ffc0ed16ddc4d77967e2a63e7aa` |

Android 编译目标为 `aarch64-none-linux-android26`，生成的 CTest 注册参数为 `arm64-v8a 26`。执行前校验了构建包内的提交标识、ELF 和注册文件摘要。跨主机执行仅映射解释器、该提交的测试脚本及 ELF 路径，保留测试名、ABI、最低 API 和 210 秒超时。[原始 JUnit](evidence/367f98bc-android-arm64-ctest.xml) 记录了设备 ABI、API、推送和断言结果。

本轮两项独立核心复验均已完成，无剩余阻塞。Android 物理真机和三端完整浏览器产品验收仍未完成。本轮未重跑 x86_64 的 API 25 部署前拒绝及 API 26、36 的 CTest；这些模拟器的[上轮结果](https://github.com/quinn521/aegis-browser/actions/runs/43864304043) 归属 #360 的 PR HEAD `0e3d6e46`。

## T3 Android arm64-v8a 物理真机核对（2026-11-17）

基于 [合并提交 `b2c78383`](https://github.com/quinn521/aegis-browser/commit/b2c783834c0e69d291f975151c123474ea9222a6)，于 04:39（UTC+8）在验证主机核对设备。`adb devices -l` 的设备列表为空，无线调试发现已启用，`adb mdns services` 返回 0 个服务。macOS USB 枚举也未发现 ADB 接口。

| 验收项 | 本轮结果 |
| --- | --- |
| Android arm64-v8a 物理真机 | **未完成**。没有可用真机，无法读取设备 ABI 和 API 级别。本轮未启动 NDK 编译，部署和真机 CTest 均未执行。 |
| 三端完整浏览器产品 | **未完成**。本轮未执行产品验收。 |

## T3 Android 真机复查（2026-11-17 12:00，UTC+8）

针对 [合并提交 `ef99ae79`](https://github.com/quinn521/aegis-browser/commit/ef99ae7955d9f0115ce81464fceb1830e43ae080)，验证主机使用 ADB `37.0.1-15733141`，设备枚举结果如下。

| 检查 | 实测结果 |
| --- | --- |
| `adb devices -l` | 0 个设备条目，无已授权的真机可供核对 ABI 和 API 级别 |
| `adb mdns services` | mDNS 已启用，发现 0 个 ADB 服务 |
| macOS USB 接口枚举 | 检查了 14 个 USB 接口，其中 ADB 接口为 0 |

Android arm64-v8a 物理真机验收为**未完成**。本轮未启动 NDK 编译、部署或真机 CTest。三端完整浏览器产品验收为**未完成**。
