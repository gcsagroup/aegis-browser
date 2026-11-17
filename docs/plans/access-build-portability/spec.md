# Access 共享核心构建规格

基线为 develop `7d47f9408c50e3d5cd547231db9e2a9b79d245a4`。本规格补充 [Access 产品规范](../access-service-v1.0/spec.zh-CN.md) 和 [macOS 产品行为规格](../access-service-v1.0/macos-access-ios-parity-sdd.zh-CN.md)。

| 需求 | 可观察结果 |
| --- | --- |
| R1 共享源码 | CMake、GN 和独立回归入口使用同一份按模块分组的清单。生产代码、头文件、测试辅助代码与向量输入分开声明。 |
| R2 独立构建 | 首批 11 个生产 C++20 单元可以脱离 Chromium 编译。目标平台为 macOS arm64、Windows x64、Android arm64-v8a，另设 Android x86_64 模拟器入口。 |
| R3 同一测试合同 | 独立入口复用现有向量和断言。GN 保留 Chromium 专属用例，包括使用 Chromium `raw_ptr` 的测试。向量及生成器修改触发相应增量重建。 |
| R4 延续产品行为 | 保持原生连接语义、代理故障时禁止自动直连、Profile 与私密上下文隔离、旧发布确认失效和写请求不自动重放。 |
| R5 平台运行合同 | 后续独立交付验证真实代理启动、认证、就绪、停止和恢复。就绪需要经过验证的代理路径及 NetworkContext 发布确认。 |
| R6 证据绑定 | 源码、补丁、工具链、ABI、产物及执行结果可追溯。独立核心测试、Chromium 集成、设备和发布分别验收。 |

T0–T3 交付独立构建和 Chromium 接线。三端构建和执行均有证据后，才能确认共享核心的三端验收。T4–T7 另行交付 Windows、Android 的平台运行接入。配额、服务端、iOS 和发布沿用各自范围。
