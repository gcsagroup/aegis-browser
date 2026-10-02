[English](./android.md) | [**简体中文**](./android.zh-CN.md) | [繁體中文](./android.zh-TW.md)

# Android 状态：No-Go

本文只覆盖 Android 浏览器目标。iOS 和 WebView 壳不在当前产品范围内。

## 当前证据边界

- Android 与桌面使用同一固定 Chromium `153.0.8010.53` 基线。
- 预留 application ID 为 `app.gcsa.aegis`；预留不证明已经形成有效包或 Play 身份。
- 当前共享源码含140个Chromium补丁与3个V8补丁，重放树为`6f6294dfabbb9bfcf69a5a612bad3b2c41334ce5`；153 Android构建、安装包身份与真机尚未验收，Mac044结果不能转作Android证据。
- 当前没有绑定身份的 APK 或 AAB。即使存在 `$HOME/Desktop/GCSA-aegis.apk` 之类的历史文件，也不能映射到当前源码，更不是 RC。
- v2 源码会解析全页 Agent 标签背后的公开网页，并把当前页面任务绑定到该文档。页面采集、脱敏、导航失效和结果仍需真机验收。
- v2 源码将进程级远程调试 latch 置于 Android DevTools HTTP/socket 启动之前，并覆盖延迟启动。无痕 Profile 一旦触发 latch，本进程内待处理和后续启动都会被拒绝；真机验证仍未完成。

在完成当前源码构建和真机验收前，Android 维持 **No-Go**。

## 受支持的构建环境

Chromium Android client 不能直接在 macOS 或 Windows 上构建。本项目需要独立、受支持的 **x86-64 Linux** checkout，并满足：

- 至少 200 GB 可用磁盘空间；
- 足够完成 Chromium 构建的内存；
- 精确固定的 Chromium 基线与补丁输入；以及
- 不把现有 macOS checkout 复用为 Android 构建树。

历史 ARM64 Linux 和 QEMU 实验不属于当前可复现构建门禁。

## 未来构建入口

以下命令会拉取或同步网络内容。只能在获准的 Linux 环境中执行，并先固定精确源码身份。

```bash
export PATH="$HOME/depot_tools:$PATH"

pnpm --filter @gcsa-aegis/browser fetch
bash apps/browser/scripts/enable-android-gclient.sh
pnpm --filter @gcsa-aegis/browser apply-patches
pnpm --filter @gcsa-aegis/browser sync
pnpm --filter @gcsa-aegis/browser build:android
pnpm --filter @gcsa-aegis/browser package:android
```

预期候选路径如下，但它们**当前不是已验收输出**：

- `$CHROMIUM_ROOT/src/out/AegisAndroid/apks/ChromePublic.apk`
- `apps/browser/dist/GCSA-aegis.apk`
- application ID：`app.gcsa.aegis`
- 启动器名称：`GCSA-aegis`

开展商店工作前，还必须定义并验证 AAB 路径和 Play 签名身份。

## 验收条件

1. 在干净的x86-64 Linux源码目录，从固定基线精确重放当前140个Chromium补丁与3个V8补丁。
2. 构建成功，并由清单绑定根仓库 commit、Chromium commit、两套补丁序列身份、GN 参数和 APK/AAB SHA-256。
3. 验证最终包名、版本、启动器名称、图标、权限、原生库和签名结构。
4. 卸载旧版本，在代表设备上安装当前 APK，完成 First Run，打开普通网页和 `chrome://aegis`，实际验证核心保护。
5. 在真机验证页面采集、文档绑定、脱敏、确认、导航失效和结果处理。
6. 完成启动、前后台、崩溃、存储、升级和网络验收，不能留下残留进程或无法解释的出站，并验证延迟 DevTools 启动不能绕过无痕进程 latch。
7. 内部候选通过与 Play 可发布仍是两道独立门禁。

## Play Store 边界

参见 [Play Store 准备情况](./play-store.zh-CN.md)。项目当前没有生产 upload key、Play Console 应用、已上传产物或获批的 Data Safety 声明。

## 刻意不做

- iOS 或 WebView 壳
- 把 CDP 作为 Android 产品功能
- 把本地模型 sidecar 写成 Android 承诺
- 在现有 macOS checkout 中构建 Android

相关公开文档：[Browser README](../README.zh-CN.md) 和 [fork 架构](./fork-architecture.zh-CN.md)。
