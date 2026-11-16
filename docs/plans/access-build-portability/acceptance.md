# Access 共享核心验收矩阵

基准证据为 `7d47f940` 的 macOS 独立脚本 892 项检查。下表记录实现阶段的验证。最终提交的报告随 PR 登记。

| 需求 | 用例 | 结果 |
| --- | --- | --- |
| R1、R2 | macOS CMake 构建清单与实际编译源一致，独立编译 | 通过，11 个生产单元 |
| R3、R4 | macOS CTest、脚本、增量重建及向量生成 | 通过，892 项检查，覆盖率分母保持 11 个单元 |
| R1、R3、R4 | 桌面 Chromium 及 V8 完整索引重放 | 同步 develop `da37e3ec` 后，从桌面固定版本依次重放 483 个 Chromium 补丁及 3 个 V8 补丁；Access 为 `0483` |
| R1、R3、R4 | Android Chromium 及 V8 完整索引重放、Access 源码投影 | 从 Android 固定版本依次重放 321 个 Chromium 补丁及 3 个 V8 补丁；Access 为 `0321`，共享清单、源码和向量与 overlay 一致 |
| R3、R4 | Chromium 原生测试与浏览器集成 | 分平台记录，GN 生成和编译证据分别登记 |
| R2、R3 | Windows x64 编译及运行 | 未执行，缺少本次可用的 Windows 工具链及主机 |
| R2、R3 | Android NDK 编译 | 未执行，NDK 下载超时 |
| R2、R3 | Android 模拟器或设备执行 | 未执行，设备运行器只有本地模拟 adb 的证据 |
| R5 | 三端真实浏览器产品闭环 | T4–T7 |
| R6 | 仓库检查、独立 Review、PR CI | 按最终提交和 PR merge 候选分别登记 |

候选记录包括提交或完整差异、清单和向量摘要、编译器与 SDK/NDK、平台和 ABI、构建参数、产物摘要、实际用例及退出码。缺失、跳过和失败的项目分别保留。
