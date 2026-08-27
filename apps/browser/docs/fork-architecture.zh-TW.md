[English](./fork-architecture.md) | [简体中文](./fork-architecture.zh-CN.md) | [**繁體中文**](./fork-architecture.zh-TW.md)

# Chromium fork 架構

GCSA-aegis 是 Chromium fork。瀏覽器、網路、儲存、Blink 和部分 V8 接入點共同構成產品；沒有獨立 Extension 或 Electron 發行物。

## 狀態邊界

- 目前原始碼：**56 個頂層 Chromium 補丁 + 2 個巢狀 V8 補丁**。
- 現有 Release 身分：**54 個 Chromium 補丁 + 2 個 V8 補丁**。
- Chromium `0055`、`0056` 尚未被目前已提交的 Release 清單涵蓋。
- 現有 non-component Release build-tree 只是本機證據，不是已簽署、公證、安裝或發布的發行版。
- Android 尚未從目前原始碼建置。

## 產品形態

```text
┌──────────────────────────────────────────────┐
│ GCSA-aegis Chromium fork                     │
│                                              │
│ Browser UI / chrome://aegis / 原生頁面       │
│                    │                         │
│                    ▼                         │
│ Aegis browser service 與策略橋接             │
│   ├─ 導覽與網路控制                          │
│   ├─ Cookie、bounce 與釣魚防護               │
│   ├─ 下載與摘要編排                          │
│   └─ 本機事件與偏好設定                      │
│                    │                         │
│                    ▼                         │
│ Blink 防護 + 可選 V8 研究路徑                │
└──────────────────────────────────────────────┘
```

## 架構原則

1. 策略模型和產生輸入以 `packages/core` 為來源。
2. 必須由瀏覽器或引擎持有的執行能力放在 Chromium C++ 和 Blink。
3. 產生快照與內嵌 policy worker 把 TypeScript 策略接入 fork。
4. 使用者設定位於 `chrome://aegis`、`chrome://downloads`、`chrome://settings/downloads` 等原生 Chromium 頁面。
5. 本機證據、建置成功和可散布發行版是三種不同狀態。

## 整合對應

| 能力 | 主要接入點 | 目前邊界 |
|---|---|---|
| 網路與導覽 | URL loader 與導覽 throttle | 需要新鮮重放和代表性瀏覽器回歸 |
| 儲存保護 | Cookie 與 bounce hook | 必須保留預期的第一方登入行為 |
| 釣魚防護 | URL/頁面訊號和原生 interstitial | 本機偵測不能證明通用涵蓋 |
| 指紋保護 | Blink Canvas、Audio、WebGL、WebGPU hook | 降低部分穩定表面，不阻止全部指紋識別 |
| 下載 | Chromium 下載 UI 與隔離 torrent service | HTTPS tracker 與發布資格仍受門禁約束 |
| 頁面摘要 | 啟發式路徑和使用者設定的相容 API | 遠端使用需去識別化與確認；Android 頁面擷取不可用 |
| MinerGuard | Browser/renderer 訊號與報告 | 僅觀察，不阻斷執行或流量 |
| Bytecode shadow | 預設關閉的巢狀 V8 插樁 | 僅研究；現有身分涵蓋 2 個 V8 補丁，但不涵蓋最新 Chromium 0055/0056 |
| 本機自動化 | Loopback CDP 控制和文件授權 | 部分桌面路徑有本機證據；簽署安裝與 Android 證據獨立 |

## 補丁交付模型

`apps/browser/patches/series` 排列 56 個 Chromium 補丁，`apps/browser/patches/v8/series` 排列套用在巢狀 V8 checkout 中的 2 個補丁。重放指令碼會先驗證兩套基線。

`overlay/` 保存供開發和審查使用的預期整合原始碼。它不會獨立套用，也不能取代補丁序列。原始碼變更必須匯出為有序補丁，在固定基線上重放、建置並測試。

最新原始碼與最新合格 Release 身分必須分開描述：

- Chromium 0001–0054 和 V8 0001–0002 已有綁定身分的 Release 證據。
- Chromium 0055 增加相容模型 API 和憑據隔離。
- Chromium 0056 增加精確文件綁定的網站摘要流程。
- 0055/0056 仍需新的已提交儲存庫身分和完整 Release 證據鏈。

「列入 series」只證明順序和檔案存在，不證明乾淨重放、建置新鮮度、簽署、封裝、安裝驗收、Android 支援或發布核准。

## 摘要與憑據邊界

桌面使用者可選擇 OpenAI、Claude（Anthropic）或 Gemini 相容格式並填寫明確服務位址。允許 HTTPS；明文 HTTP 僅限數值 loopback 位址。API Key 可選，透過作業系統加密保存在目前 Profile 中。

遠端摘要前，瀏覽器會產生去識別化載荷、做第二次驗證，並在確認介面顯示目標格式、模型和目的位址。敏感頁面和含密碼欄位的頁面只能使用本機啟發式路徑。Android 目前無法為此流程取得一般頁面 tab。

## 下載邊界

HTTP(S) 下載仍由 Chromium `DownloadItem` 執行。Metalink、Torrent 和 Magnet 工作接入原生下載頁面，torrent 工作由隔離 service 承擔。全域連線設定和新工作預設值位於 `chrome://settings/downloads`。

影片擷取、媒體轉換、FFmpeg 和預裝下載擴充功能不屬於此架構。

## 平台與發布邊界

non-component macOS Release build-tree 是發布資格的輸入，不是發布結果。正式發布還需同一目前 commit 和兩套補丁序列的清單、受影響的原生與執行測試、產品身分、簽署、公證、封裝和安裝驗收。

Android 接線存在於原始碼中，但目前沒有由目前原始碼產生的 APK 或 AAB。受支援的 x86-64 Linux 建置、真機驗收、Android 頁面摘要行為和 Play 合規仍是開放門禁。

## 開發內部參考

以下文件刻意不翻譯：

- [Overlay 同步規則](./overlay.md)
- [Chromium 目錄配置](./tree-layout.md)
- [補丁維護說明](../patches/README.md)

公開配套文件：

- [Browser README](../README.zh-TW.md)
- [Android 狀態](./android.zh-TW.md)
- [Play Store 準備情況](./play-store.zh-TW.md)

## 為什麼不是 Electron

Electron 無法持有此設計所使用的全部 Chromium 網路、CookieMonster、Blink 和 V8 表面。因此專案在 Chromium 瀏覽器層和引擎層整合，並把所有發布聲明置於明確證據門禁之後。
