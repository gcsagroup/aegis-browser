# GCSA-aegis

[English](README.md) | [简体中文](README.zh-CN.md) | **繁體中文**

GCSA-aegis 是一個本機優先的隱私與安全瀏覽器專案，現有兩條產品線：[`apps/browser`](apps/browser/README.zh-TW.md) 下的 Chromium 分支，以及 [`apps/ios`](apps/ios/README.zh-TW.md) 下的原生 iOS 瀏覽器。核心能力整合在各自的瀏覽器產品內；專案不會復活已退役的獨立擴充功能產品。

> **狀態 — 2026-08-29：** 整合後的原始碼包含 67 個頂層 Chromium 補丁和 2 個巢狀 V8 補丁。先前的 57 補丁診斷清單和 65 補丁 Agent 驗收僅為歷史證據，不能為目前 67 補丁 HEAD 授予資格。原生 iOS 產品仍只在已記錄的 Simulator 範圍內為 **SIMULATOR_QUALIFIED**。專案整體仍是 **發行 No-Go**，尚需補齊目前整合原始碼的建置/執行證據、受信任證明、正式簽署、公證、已安裝分發套件驗收、iOS 真機驗證和目前原始碼的 Android 套件。

一般桌面 Profile 正常啟動後會直接顯示 Agent 入口。模型呼叫、工具和監控仍需使用者在 `chrome://aegis` 明確開啟；WebMCP 與交易提交能力繼續預設關閉。

## 產品形態

- **Chromium 產品線：** [`apps/browser`](apps/browser/README.zh-TW.md) 負責 Chromium 固定版本、補丁堆疊、瀏覽器整合、建置和平台封裝邊界。
- **原生 iOS 產品線：** [`apps/ios`](apps/ios/README.zh-TW.md) 已實作 SwiftUI/WKWebView 瀏覽器、一般與私密設定檔隔離、內嵌 Safari/Share extensions 和 Agent Broker。
- **共享策略與合約來源：** [`packages/core`](packages/core) 提供可測試策略、產生資產，以及由 TypeScript 與 Swift 共用的 Agent Contract v1 Schema 和 Golden Vectors。
- **iOS Agent 範圍：** 深度研究、瀏覽器管家、安全下載和購物助手四個受控工作流程回傳確定性結果，可離線驗證；這不構成生產遠端模型路徑的證據。
- **擴充功能邊界：** Safari 與 Share target 是 iOS App 的內嵌元件；獨立 `apps/extension` 產品仍被禁止。

## 證據邊界

原始碼同步、乾淨的外部 Chromium checkout 和 iOS Simulator 資格屬於不同證據層級，均不能證明對應目前原始碼已通過全部建置、執行、簽署、安裝、真機、隱私、商店和發布門檻。

歷史 Chromium 測試數量、清單和產物雜湊保留在附日期的稽核紀錄中，不得跨補丁 HEAD 拼接或寫成目前發行證據。研究證據也必須分開：Phase 2 是 synthetic formal fixture，Phase 3 是 13 樣本 operator-blinded public pilot，召回率為 `1/3`；兩者都不能泛化為廣義惡意 JavaScript 偵測結論。iOS 的 `SIMULATOR_QUALIFIED` 僅限具名 Simulator 路徑，不是真機、散布或 App Store 證據。

## 快速開始

JavaScript 工具鏈固定為 Node.js `24.14.0` 和 pnpm `9.15.0`。

```bash
pnpm install --frozen-lockfile
pnpm run quality:fast
pnpm --filter @gcsa-aegis/browser status
```

準備和建置 Chromium 需要大型外部 checkout。執行網路、建置、封裝或執行命令前，請先閱讀[瀏覽器指南](apps/browser/README.zh-TW.md)。原生 App 的建置與測試說明見 [iOS 工程指南](apps/ios/README.zh-TW.md)；其安全預設測試入口是：

```bash
bash apps/ios/scripts/run-simulator-tests.sh --dry-run
```

## 儲存庫結構

```text
apps/browser       Chromium 固定版本、overlay、補丁、建置與驗證腳本
apps/ios           原生 iOS App、內嵌擴充功能、AgentKit 與 Simulator 測試
packages/core      共享策略、偵測器、產生資產與 Agent Contract v1
docs/              架構、路線圖、研究映射、產品頁與稽核紀錄
```

## 文件

- [文件索引](docs/README.zh-TW.md)
- [架構](docs/architecture.zh-TW.md)
- [路線圖與發布門檻](docs/roadmap.zh-TW.md)
- [iOS 工程指南](apps/ios/README.zh-TW.md)
- [研究到實作映射](docs/research-map.zh-TW.md)
- [三語產品頁](docs/product.html)
- [更新日誌](CHANGELOG.md)

## GitHub 同步邊界

2026-08-28 已授權透過 SSH 將原始碼儲存庫同步到 `git@github.com:gcsagroup/aegis-browser.git`。該授權僅涵蓋原始碼分支同步，不授權建立或發布 Git tag、GitHub Release、二進位檔、安裝套件、簽署憑證、公證提交、Play 上傳、TestFlight 建置、App Store 提交或生產部署。

## 授權

Apache-2.0，見 [LICENSE](LICENSE)。

## 測試

```bash
pnpm run quality:fast
bash apps/ios/scripts/run-simulator-tests.sh --dry-run
```

這些命令涵蓋儲存庫快速 JavaScript/腳本門檻和不產生變更的 iOS Simulator 預檢。Chromium 原生建置與目前頭執行矩陣、iOS `--execute` 結果、真機、簽署、封裝、安裝和商店驗收仍是獨立門檻。
