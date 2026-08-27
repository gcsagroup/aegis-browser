# Android（M1：能装能开）

范围：只做 Android。iOS 不做完整浏览器。  
钉扎：与桌面相同，Chromium `151.0.7922.77`。  
首发：侧载 APK；包名已按 Play 预留。

## 这台 Mac 编不出 APK

Chromium 151 原文：*Building the Android client on Windows or Mac is not supported and doesn't work.*

另外，Android `gclient sync` + `out/AegisAndroid` 大约还要 **100GB**。不要在现有 Mac checkout 上加 `target_os = ["android"]`，会把磁盘撑满且仍然编不过。

本机角色：改 overlay / 打补丁。编译放到 **Linux**（推荐本机 [UTM](https://mac.getutm.app/) 开 Ubuntu，磁盘 ≥200GB、内存 ≥16GB）。

官方 Android 构建机是 **x86-64 Linux**。Chromium 151 没有 Linux_arm64 的 clang/rust 主机包。若 Linux 虚拟机是 ARM64，需安装 `qemu-user` + `qemu-user-binfmt` 和 `libc6:amd64`，并在编译前 `ulimit -s unlimited`（否则 rustc 会 SIGSEGV）。x86-64 虚拟机更接近官方环境，但在 Apple Silicon 上同样是仿真。ARM64 上 `gperf` 的 CIPD 包不存在，脚本会改拉 `linux-amd64` 并用 qemu 跑。

## Linux 上怎么编

同一钉扎，单独一份 checkout（不要复用 Mac 那份）：

```bash
# 在 Linux 上
export PATH="$HOME/depot_tools:$PATH"
pnpm --filter @gcsa-aegis/browser fetch
bash apps/browser/scripts/enable-android-gclient.sh
pnpm --filter @gcsa-aegis/browser apply-patches
pnpm --filter @gcsa-aegis/browser sync
pnpm --filter @gcsa-aegis/browser build:android
pnpm --filter @gcsa-aegis/browser package:android
```

产物：

- `out/AegisAndroid/apks/ChromePublic.apk`（内部文件名仍叫 ChromePublic）
- `apps/browser/dist/GCSA-aegis.apk`
- applicationId：`app.gcsa.aegis`
- 桌面显示名：`GCSA-aegis`

侧载：

```bash
adb install -r apps/browser/dist/GCSA-aegis.apk
```

打开任意网页即为 M1 通过。设置 → 隐私和安全 → GCSA-aegis 打开模块页（也可在地址栏输入 `chrome://aegis`）。Android 上不显示 CDP / Ollama；摘要只走启发式。

## Play 预留

见 [play-store.md](./play-store.md)。侧载用 debug 签名即可；上架前再生成 upload key。

## 刻意不做（Android）

- iOS / WebView 壳
- 本机 CDP / Ollama sidecar 当卖点
- 把现有 Mac checkout 改成 Android 构建树
