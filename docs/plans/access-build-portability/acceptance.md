# Access 共享核心验收矩阵

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
