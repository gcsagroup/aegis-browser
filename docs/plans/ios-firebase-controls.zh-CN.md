# iOS Firebase 诊断与远程配置控制

范围：仅允许 Firebase Remote Config 暂停崩溃报告和使用统计。不会远程修改浏览、防护、AI、脚本、网址、账号或用户同意；不包含 Firebase 控制台发布、App Store 元数据修改、打包上传。

## 用户选择与生效规则

- 三个独立开关：发送崩溃报告、发送使用分析、允许远程诊断配置。未设置过的项目默认关闭；已明确保存的采集选择继续保留。
- 生效许可 = 本机采集选择 AND 远程许可；关闭远程配置时仅采用本机选择。服务未配置时仍可保存选择，但不启动服务。
- 远程配置启用后，在没有有效配置、配置格式错误或超过 24 小时时暂停两类上报。网络失败保留仍在有效期内的最近一次正确配置；不延长缓存年龄。
- 参数白名单：`aegis_diagnostics_schema` 必须为 `1`；`aegis_crash_reports_allowed`、`aegis_analytics_allowed` 必须为 `true` 或 `false`。全部有效才接受。未知参数不会执行。远程值永远不写入用户的采集偏好。
- 默认不使用实时监听、用户属性、受众定向、个性化或 A/B 实验。启动和 SwiftUI scene 回到 active 时异步拉取，正常最短拉取间隔 12 小时、网络超时 10 秒；不会阻塞浏览器启动。重新开启须向后端请求晚于撤销边界的新配置，只有该路径将缓存有效时间设为零；后端限流仍生效。

## 生命周期与数据边界

远程配置使用单独命名的 Firebase App/Installations 实例，与诊断的默认实例分离。关闭开关立即丢弃应用策略及其缓存，并使进行中的请求结果失效；请求返回后删除专用 Installations 身份，避免共享删除影响 Crashlytics。SDK 缓存不因删除身份而清空，所以持久化撤销时间，并在清理完成时推进边界；重新开启只接受晚于该边界的后端配置，依据 SDK 的实际 fetch 时间计算 24 小时有效期。仅将固定版本 Firebase 13.1.1 对当前专用 App 返回的精确“本地身份不存在”错误视为清理已完成；其他未知、网络、Keychain 错误不能忽略，升级 SDK 时须复核该兼容判断。删除失败保留清理标记、显示待清理状态，并允许重试；重新开启须先完成清理。未完成网络请求不能被承诺撤回。

远程配置请求本身会使用安装标识及 SDK 请求元数据；关闭 Analytics 不等于 Remote Config 不联网。不会添加网址、网页正文、搜索词、用户标识或自定义 Analytics 事件。启动 Firebase 前先显式禁用 Analytics 持久化开关，再在注册校验及缓存校验后应用有效许可；此前默认开启的安装也受此门约束。

Crashlytics 保持关闭自动上传。应用等待启动时首次远程尝试结束（或远程配置关闭），再一次性决定发送或删除历史报告。SDK 的 send/delete 共用一次性承诺，不能用后来的 delete 撤销已经允许排队的报告，即使网络尚未发送。后续暂停限制尚未获准发送的报告及后续启动，不声称已授权报告能追回。设置页明确提示这一边界。Analytics 停用时停止收集并重置本地 Analytics 数据；不会删除已上传数据。

## 控制台参数与回退

在对应 dev/prod 项目创建上述三个参数，无条件默认值建议为 `1` / `true` / `true`；客户端仍要求本机选择。紧急暂停将对应 allowed 参数设为 `false`。这不是立即到达所有设备的紧急开关：仅在允许远程配置且成功拉取后生效。恢复为 `true` 也不能开启用户关闭的采集项。

仅交付配置模板和客户端，不在本次任务发布线上参数。上线前另行核对控制台项目、实际 SDK 请求、隐私披露及新构建；build 15 保持原样。

## 验证要求

单元与回归覆盖默认关闭、已有选择保留、参数校验、24 小时有效期、关闭后旧回调丢弃、快速关闭/重开、清理失败及重启重试、请求失败保留有效缓存、远程值不能写回本机选择。原注册环境隔离回归保留。验证原生编译、设置入口、本地化和鸣谢资源；模拟器/真机、线上 Firebase、CI 与签名发行证据分别记录。

依据：[Remote Config API](https://firebase.google.com/docs/reference/swift/firebaseremoteconfig/api/reference/Classes/RemoteConfig) 的 Installations 同步与删除要求、[iOS Remote Config](https://firebase.google.com/docs/remote-config/ios/get-started)、[Crashlytics 可选上报](https://firebase.google.com/docs/crashlytics/ios/customize-crash-reports)。
