[English](./android.md) | [简体中文](./android.zh-CN.md) | [**繁體中文**](./android.zh-TW.md)

# Android 狀態：No-Go

本文只涵蓋 Android 瀏覽器目標。iOS 和 WebView 外殼不在目前產品範圍內。

## 目前證據邊界

- Android 與桌面使用同一固定 Chromium `151.0.7922.77` 基線。
- 預留 application ID 為 `app.gcsa.aegis`；預留不證明已經形成有效套件或 Play 身分。
- 目前原始碼含 67 個頂層 Chromium 補丁和 2 個巢狀 V8 補丁，但**尚未從目前原始碼產出 Android 建置**。歷史 macOS 證據不綁定 Android 產物，也不能賦予其 Android 資格。
- 目前沒有綁定身分的 APK 或 AAB。即使存在 `$HOME/Desktop/GCSA-aegis.apk` 之類的歷史檔案，也不能對應到目前原始碼，更不是 RC。
- Android WebUI handler 目前無法取得一般網頁 tab，因此 Android 頁面摘要必須顯示為不可用。

在完成目前原始碼建置和真機驗收前，Android 維持 **No-Go**。

## 受支援的建置環境

Chromium Android client 不能直接在 macOS 或 Windows 上建置。本專案需要獨立、受支援的 **x86-64 Linux** checkout，並符合：

- 至少 200 GB 可用磁碟空間；
- 足夠完成 Chromium 建置的記憶體；
- 精確固定的 Chromium 基線與補丁輸入；以及
- 不把現有 macOS checkout 重複用作 Android 建置樹。

歷史 ARM64 Linux 和 QEMU 實驗不屬於目前可重現建置門禁。

## 未來建置入口

以下命令會擷取或同步網路內容。只能在獲准的 Linux 環境中執行，並先固定精確原始碼身分。

```bash
export PATH="$HOME/depot_tools:$PATH"

pnpm --filter @gcsa-aegis/browser fetch
bash apps/browser/scripts/enable-android-gclient.sh
pnpm --filter @gcsa-aegis/browser apply-patches
pnpm --filter @gcsa-aegis/browser sync
pnpm --filter @gcsa-aegis/browser build:android
pnpm --filter @gcsa-aegis/browser package:android
```

預期候選路徑如下，但它們**目前不是已驗收輸出**：

- `$CHROMIUM_ROOT/src/out/AegisAndroid/apks/ChromePublic.apk`
- `apps/browser/dist/GCSA-aegis.apk`
- application ID：`app.gcsa.aegis`
- 啟動器名稱：`GCSA-aegis`

進行商店工作前，還必須定義並驗證 AAB 路徑和 Play 簽署身分。

## 驗收條件

1. 在乾淨 x86-64 Linux checkout 中，從固定基線重放全部 67 個 Chromium 補丁和 2 個巢狀 V8 補丁。
2. 建置成功，並由清單綁定根儲存庫 commit、Chromium commit、兩套補丁序列身分、GN 參數和 APK/AAB SHA-256。
3. 驗證最終套件名稱、版本、啟動器名稱、圖示、權限、原生程式庫和簽署結構。
4. 解除安裝舊版本，在代表裝置上安裝目前 APK，完成 First Run，開啟一般網頁和 `chrome://aegis`，實際驗證核心保護。
5. Android 能夠擷取並綁定真實頁面文件前，頁面摘要必須明確不可用；完成實作後，再在真機驗證擷取、去識別化、確認、導覽失效和結果。
6. 完成啟動、前後台、當機、儲存、升級和網路驗收，不能留下殘留程序或無法解釋的出站。
7. 內部候選通過與 Play 可發布仍是兩道獨立門禁。

## Play Store 邊界

請參閱 [Play Store 準備情況](./play-store.zh-TW.md)。專案目前沒有生產 upload key、Play Console 應用程式、已上傳產物或獲准的 Data Safety 聲明。

## 刻意不做

- iOS 或 WebView 外殼
- 把 CDP 作為 Android 產品功能
- 把本機模型 sidecar 寫成 Android 承諾
- 在現有 macOS checkout 中建置 Android

相關公開文件：[Browser README](../README.zh-TW.md) 和 [fork 架構](./fork-architecture.zh-TW.md)。
