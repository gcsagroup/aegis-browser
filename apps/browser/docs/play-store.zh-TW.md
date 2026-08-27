[English](./play-store.md) | [简体中文](./play-store.zh-CN.md) | [**繁體中文**](./play-store.zh-TW.md)

# Play Store 準備草案：No-Go

本文只記錄未來所需的身分、政策和審查門禁，不是已提交的 Play 聲明。

目前專案：

- 尚未從目前原始碼產出 Android 建置；
- 沒有綁定目前身分的 APK 或 AAB；
- 沒有生產 upload key；
- 沒有 Play Console 應用程式或已上傳產物；以及
- 沒有針對候選獲准的 Data Safety 表或公開隱私權政策 URL。

本草案不授權任何 Play 外部操作。

## 預留身分

| 項目 | 預留目標 |
|---|---|
| Application ID | `app.gcsa.aegis` |
| 顯示名稱 | GCSA-aegis |
| 短名 | Aegis |
| 預設商店語言 | 簡體中文 |
| 目標架構 | `arm64-v8a`（`target_cpu = "arm64"`） |
| 未來簽署 | Play App Signing；本機只持有 upload key |

GN 中的 application ID 只證明設定存在，不能證明最終 APK/AAB 身分、簽署、品牌或商店合規。

不得以 Chrome 或 Google Chrome 品牌發布，也不能把 Chromium 預設圖示作為最終商店素材。

## Data Safety 邊界

以下只是設計目標，必須依據精確候選驗證，不能直接複製到 Play Console：

- 產品目標是不為 GCSA-aegis 服務蒐集帳號、位置、通訊錄等個人資料。
- Chromium 預設服務、指標、當機報告、更新和全部第三方元件仍需針對候選逐項審查。
- Android 頁面摘要目前不可用。未來實作必須準確揭露本機處理和每一個由使用者設定的遠端目的地。
- 產品目標是不預裝第三方分析 SDK，但必須由最終相依圖、執行設定和網路封包擷取證明。
- EasyList 或其他外部更新不得暴露瀏覽歷史、頁面 URL、持久識別碼或不必要的標頭，並需如實揭露其行為。

最終 Data Safety 表必須依據實際提交的同一 APK/AAB、版本設定、權限、儲存行為、相依集合和網路封包擷取。

## 上架門禁

1. 在乾淨、受支援的 x86-64 Linux 環境中建置目前原始碼 Release APK/AAB。
2. 由驗證清單綁定根儲存庫 commit、Chromium commit、56 個 Chromium 補丁、2 個巢狀 V8 補丁、GN 參數、套件身分和產物雜湊。
3. 通過 First Run、一般瀏覽、`chrome://aegis`、核心保護、生命週期、儲存、升級和網路行為的真機測試。
4. 取代預設 Chromium 圖示，並審查所有名稱、螢幕擷取畫面、描述和受限品牌素材。
5. 完成權限、網路出站、資料儲存、日誌、原生程式庫、第三方授權和隱私權政策審查。
6. 取得明確核准後，才建立 Play Console 應用程式、加入 Play App Signing、產生 upload key，並填寫商店資訊和 Data Safety。
7. 先走內部測試軌和審查回覆，再決定是否擴大測試。

內部 Android 候選通過不會自動變成 Play 可發布。

## 相關文件

- [Android 建置與驗收狀態](./android.zh-TW.md)
- [Fork 架構](./fork-architecture.zh-TW.md)
- [Browser README](../README.zh-TW.md)
