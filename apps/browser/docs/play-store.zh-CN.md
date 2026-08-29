[English](./play-store.md) | [**简体中文**](./play-store.zh-CN.md) | [繁體中文](./play-store.zh-TW.md)

# Play Store 准备草案：No-Go

本文只记录未来所需的身份、政策和审核门禁，不是已提交的 Play 声明。

当前项目：

- 尚未从当前源码产出 Android 构建；
- 没有绑定当前身份的 APK 或 AAB；
- 没有生产 upload key；
- 没有 Play Console 应用或已上传产物；以及
- 没有针对候选获批的 Data Safety 表或公开隐私政策 URL。

本草案不授权任何 Play 外部操作。

## 预留身份

| 项 | 预留目标 |
|---|---|
| Application ID | `app.gcsa.aegis` |
| 显示名 | GCSA-aegis |
| 短名 | Aegis |
| 默认商店语言 | 简体中文 |
| 目标架构 | `arm64-v8a`（`target_cpu = "arm64"`） |
| 未来签名 | Play App Signing；本地只持有 upload key |

GN 中的 application ID 只证明配置存在，不能证明最终 APK/AAB 身份、签名、品牌或商店合规。

不得以 Chrome 或 Google Chrome 品牌发布，也不能把 Chromium 默认图标作为最终商店素材。

## Data Safety 边界

以下只是设计目标，必须基于精确候选验证，不能直接复制到 Play Console：

- 产品目标是不为 GCSA-aegis 服务收集账号、位置、通讯录等个人数据。
- Chromium 默认服务、指标、崩溃报告、更新和全部第三方组件仍需针对候选逐项审查。
- Android 页面摘要当前不可用。未来实现必须准确披露本地处理和每一个由用户配置的远程目的地。
- 产品目标是不预装第三方分析 SDK，但必须由最终依赖图、运行配置和网络抓包证明。
- EasyList 或其他外部更新不得暴露浏览历史、页面 URL、持久标识或不必要的请求头，并需如实披露其行为。

最终 Data Safety 表必须基于实际提交的同一 APK/AAB、版本配置、权限、存储行为、依赖集合和网络抓包。

## 上架门禁

1. 在干净、受支持的 x86-64 Linux 环境中构建当前源码 Release APK/AAB。
2. 由经过验证的 Android 清单绑定根仓库 commit、Chromium commit、67 个 Chromium 补丁、2 个嵌套 V8 补丁、GN 参数、包身份和产物哈希。
3. 通过 First Run、普通浏览、`chrome://aegis`、核心保护、生命周期、存储、升级和网络行为的真机测试。
4. 替换默认 Chromium 图标，并审查所有名称、截图、描述和受限品牌素材。
5. 完成权限、网络出站、数据存储、日志、原生库、第三方许可和隐私政策审查。
6. 获得明确批准后，才创建 Play Console 应用、加入 Play App Signing、生成 upload key，并填写商店信息和 Data Safety。
7. 先走内部测试轨和审核回执，再决定是否扩大测试。

内部 Android 候选通过不会自动变成 Play 可发布。

## 相关文档

- [Android 构建与验收状态](./android.zh-CN.md)
- [Fork 架构](./fork-architecture.zh-CN.md)
- [Browser README](../README.zh-CN.md)
