# Android SDD · Chromium 原生 Access Options 与入站可行性

2026-11-20 · 基于 [fork main `c5b4257a`](https://github.com/quinn521/aegis-browser/tree/c5b4257a221b7d4434a113d2c13d870139b8d6fa)。**建议采用双无认证的应用级入站设计，当前产品默认保持未准入。** 与桌面共用 Chromium 的请求归属思路，Android 需要自己的监听所有权、进程重建和设备证据。[共同合同](app-inbound-contract.zh-CN.md)

## 当前能复用什么

Android 产品目标是完整 Chromium 浏览器。历史基线 `c5b4257a` 的 Android pin 为 155.0.8059.79 / `a49e2e3d4addfd84e765b52afe230bedb81096db`，补丁序列列至共享能力补丁 0330。历史桌面为 155.0.8059.80，SOCKS5 补丁为 0350。本候选的 Android [pin](../../../apps/browser/ci-pins/android.json) 为 158.0.8127.42 / `52bdd21723d5db0c9ab11716d38feac74828cf84`，[补丁序列](../../../apps/browser/patches-android/series) 中的共享能力补丁为 0347。当前桌面为 158.0.8127.37，[SOCKS5 补丁 0366](../../../apps/browser/patches/0366-feat-access-socks5-inbound-no-auth.patch) 的存在不证明 Android 产品包含该接线。先查 Android 实际重放后的源码、GN 目标及调用者，再确定可共享的 adapter、解析、所有权检查和 wire 合同。[Android 产品边界](../../../apps/browser/docs/android.zh-CN.md) · [Chromium 代理说明](https://chromium.googlesource.com/chromium/src/+/refs/heads/lkgr/net/docs/proxy.md)

共享 C++ 核心已有 Android NDK ELF 和模拟器 CTest 记录，另有 arm64 真机未完成的条目。这些回执绑定各自提交。现有仓库证据尚未证明本方案的 Android 浏览器 APK 能经两种入站到达指定出口。WebView 的进程级代理覆盖、系统代理设置和 VpnService 均不作为本产品路径。[核心证据与真机状态](../access-build-portability/acceptance.md) · [可移植范围](../access-build-portability/spec.md)

## 合理性与 Android 特有成本

| 设计因素 | 判断与约束 |
| --- | --- |
| 协议与作用域 | Chromium 原生支持无认证 SOCKS5，HTTP 可作为绑定前的备选。选择按受信 Profile/普通或无痕、StoragePartition、路由组和核心代次发布。单条受保护请求只使用一个端点，其他应用及原生路由不纳入本设计 |
| 同机可达性 | Android 的 UID 沙箱隔离应用资源，TCP 回环地址本身没有连接方 UID 认证语义。接受应用内归属与撤销的部署适用双无认证；要求只准特定本地客户端消费出口的部署维持未准入。[Android 应用沙箱](https://source.android.com/docs/security/app-sandbox) |
| 生命周期 | 后台或缓存进程可能被系统回收，onDestroy 回调没有保证。进程重建时从持久策略恢复保护意图，旧端口和旧授权失效，在新监听就绪前拦下受保护的首包。避免靠常驻前台服务维持一个无业务的监听。[进程生命周期](https://developer.android.com/guide/components/activities/process-lifecycle) |
| 网络和资源 | Wi-Fi/蜂窝切换、断网恢复或系统 VPN 变化需要重验受影响上游与网络代次。旧探测结果不能覆盖新网络；切换期间禁止直接试目标或重放业务请求。按活跃授权引用启动/回收监听，测准备延时、持续内存、打开 socket 和后台耗电。[Android 网络状态](https://developer.android.com/develop/connectivity/network-ops/reading-network-state) |
| 实施经济性 | 省去本地密码生成、407 提示和认证缓存。登记快照、双向转发、前后台取消及跨 Profile 隔离仍有成本。以同一 APK 中的 HTTP 与 SOCKS 冷启动及持续负载对照确定性能收益 |

## Android 原生 Options SDD

**产品入口。** 在已有 Aegis 原生设置的 Access 分组打开 Options。复用 Chromium Android 的 `AegisSettings` 与 Profile 绑定设置 Fragment；普通页面提供受信当前网站入口，无痕页面只访问本作用域。Fragment 展示 Profile、站点规则、本地入站、导入导出、诊断和账户入口。[Android 原生设置补丁](../../../apps/browser/patches-android/0319-native-settings-and-single-agent-entry-263.patch) · [三端 Options 合同](app-access-options-sdd.zh-CN.md)

**原生接线。** Fragment 捕获实际浏览器 Profile/无痕作用域，用受信 native 接口读写版本化草稿、提交并订阅发布状态。协议选择自动、固定 SOCKS5、固定 HTTP，端口选择自动或指定。UI 从 native ACK 读取实际端点；配置文件、Intent、深链和 Java 层传入的渠道值均不能授予高级权限。执行能力不可用的内部构建可以保存允许的偏好并提示未准入；受限构建拒绝加载或激活内部设置。Android Chromium 158 的 0347 提供共享能力判定基础，产品 Fragment/JNI、存储与请求级安装需要本端接线。[共享能力补丁](../../../apps/browser/patches-android/0347-share-access-options-capability.patch)

**3X-UI 测试节点。** DEV / 内部 Alpha 的普通 Profile 详情提供文本输入和“扫描节点二维码”。只在用户点击扫码时请求相机权限。拒绝或取消后返回同一草稿，可继续输入文本。设备本地解码，Fragment 把文本和扫描结果交给同一个受信校验入口。旋转后只将结果交回仍存活的原编辑操作。离开页面、切换 Profile 或进程死亡后丢弃失效结果，显式 Apply 前只保留草稿。用实际内部 APK 验证两种输入等价和失效阻断，用 Beta / Release 包验证 Intent、恢复状态和 JNI 调用均无法导入或激活手动节点。托管账户联调等待服务端同事交付。[测试节点与阶段交接](app-access-options-sdd.zh-CN.md)

**状态与系统交互。** 普通 Profile 持久保存已提交配置，按原合同校验导入的版本与字段。系统返回遇到脏草稿时提供保留编辑或放弃选择。旋转或窗口重建恢复当前编辑草稿与 operationID；进程死亡后以已提交版本和操作结果重新读取，丢失的未提交草稿不自动 Apply。无痕关闭后销毁本作用域的草稿、引用和诊断。TalkBack 读出当前偏好、实际协议和失败原因，大字号、横屏和分屏下均可触达 Apply/Discard。

**验收。** 先用可识别的测试状态验证入口、渠道、表单、版本竞争、文件、旋转和系统返回，再在同一产品 APK 从原生 Options 点 Apply，对照 native 发布状态和受控源站。验证网络切换、无痕结束、指定端口冲突和杀进程恢复不会重放业务请求。UI、模拟器及 arm64 真机分别登记。[Android Options 执行工单 #210](https://github.com/gcsagroup/aegis-browser/issues/210)

## 建议的验证顺序

| 阶段 | 需要的证据 | 通过后的结论 |
| --- | --- | --- |
| 源码与构建 | 核对独立 pin/补丁、可用核心资产、GN 图和浏览器真实入口，在项目支持的 Linux 构建环境形成可追溯 APK；保存源码、APK 摘要、ABI、版本和构建身份 | 可进入 Android 运行验证 |
| 集成运行 | 在产品实际支持的最低与当前系统上验证普通/无痕、双 Profile、HTTP forward/CONNECT、SOCKS5 CONNECT、单端点发布。用受控出口和独立原连接对照检查标记 | 仅为受测系统和协议记录能力。SOCKS 未准入时可继续独立验证无认证 HTTP |
| 物理设备 | 同一 APK 检查前后台、进程被回收后的首次请求、Wi-Fi/蜂窝切换、端口复用、关闭私密、授权/额度撤销、控制面失效。保护路径在失效时原出口新增收件为零，其他有效 owner 的请求仍能完成 | 只对有实测证据的配置开放候选准入，发布和签名按独立流程判断 |

本次交付 Android 原生 Options 规格与应用级入站可行性评估。现有 Android CI 和共享核心移植工单继续按它们自己的关闭条件执行。
