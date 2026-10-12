# 四端功能對照清單

[简体中文](platform-features.zh-CN.md) · [繁體中文](platform-features.zh-TW.md) · [English](platform-features.en.md) · [JSON](platform-features.json)

本清單記錄目前工作區的實作範圍，不代表正式發行資格。各功能的本輪驗證範圍分別記錄，具體測試與未驗收項見對應報告。原始碼存在、模擬器通過和實機驗收分別記錄。

原始碼接入：有原始碼或產品合同依據；部分：與對應能力存在明確差異；未移植：尚未接入本端；系統：由平台負責。詳細的四端原因、原始碼及驗證狀態保存在 JSON 中。

| 功能 | macOS | Windows | Android | iOS |
| --- | --- | --- | --- | --- |
| 總開關與設置持久化 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 部分 |
| 跟蹤器攔截 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 部分 |
| 釣魚警告頁 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 部分 |
| 指紋防護 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 部分 |
| 挖礦防護 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 部分 |
| 字節碼檢查 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 未移植 |
| 過濾列表更新 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 部分 |
| 鏈接清理 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 原始碼接入 |
| Cookie清理 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 部分 |
| CNAME識別 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 未移植 |
| 跳轉跟蹤防護 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 系統 |
| 策略執行 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 部分 |
| 隱私AI | 原始碼接入 | 原始碼接入 | 原始碼接入 | 部分 |
| AI權限控制 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 部分 |
| 瀏覽器Agent及隱私資料隔離 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 部分 |
| Agent頁面操作 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 部分 |
| Agent瀏覽器工具 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 部分 |
| WebMCP實驗開關保持關閉 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 未移植 |
| Agent工作流 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 部分 |
| 交易實驗開關保持關閉 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 未移植 |
| 網絡訪問規則和權限 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 部分 |
| 舊資料、隱私模式和重啓兼容 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 部分 |
| 已有更新入口、摘要校驗和失敗恢復 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 系統 |
| 桌面右鍵手勢、配置持久化、練習區與PDF動作 | 原始碼接入 | 原始碼接入 | 未移植 | 未移植 |
| 搜索、主頁與啓動 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 原始碼接入 |
| 網頁顯示與網站權限 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 部分 |
| 網站存儲管理 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 原始碼接入 |
| 收藏與歷史 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 原始碼接入 |
| 標籤、窗口與工作區 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 部分 |
| HTTP 下載與完整性校驗 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 原始碼接入 |
| Metalink 與鏡像 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 部分 |
| 下載網絡與容量設置 | 部分 | 部分 | 部分 | 原始碼接入 |
| BT 與磁力下載 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 未移植 |
| 閱讀資料與批注庫 | 部分 | 部分 | 部分 | 原始碼接入 |
| 閱讀翻譯與對照 | 部分 | 部分 | 部分 | 部分 |
| PDF 文字層批注 | 部分 | 部分 | 部分 | 部分 |
| 前台網頁變化檢查 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 部分 |
| 第三方擴展安裝 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 未移植 |
| 跨設備同步 | 未移植 | 未移植 | 未移植 | 未移植 |
| 默認瀏覽器與語言 | 原始碼接入 | 原始碼接入 | 原始碼接入 | 系統 |
| WebKit 系統強化 | 未移植 | 未移植 | 未移植 | 部分 |
| 依網站增強 | 部分 | 原始碼接入 | 未移植 | 部分 |
| 使用者腳本與 AI 草稿 | 部分 | 原始碼接入 | 未移植 | 部分 |
| 內建 Markdown 閱讀 | 部分 | 原始碼接入 | 未移植 | 部分 |

## iOS 範圍與依據

### 總開關與設置持久化

`kAegisEnabled` — 提供獨立保護選項，未增加與 Chromium 同構的總開關。

原始碼：[apps/ios/AegisApp/BrowserPreferenceViews.swift](../apps/ios/AegisApp/BrowserPreferenceViews.swift)

iOS 模擬器證據：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 跟蹤器攔截

`kAegisTrackerBlocking` — WebKit 內容規則支持廣告與跟蹤過濾，規則語法覆蓋有差異。

原始碼：[apps/ios/BrowserKit/ContentFilterCompiler.swift](../apps/ios/BrowserKit/ContentFilterCompiler.swift)

iOS 模擬器證據：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 釣魚警告頁

`kAegisPhishInterstitial` — 簽章本機主機快照、PSL 網址判斷、有限結構觀察與原生阻止頁；檢查在載入後發生，非即時威脅查詢。

原始碼：[apps/ios/BrowserKit/NavigationPolicy.swift](../apps/ios/BrowserKit/NavigationPolicy.swift) · [apps/ios/BrowserKit/PageProtection.swift](../apps/ios/BrowserKit/PageProtection.swift) · [apps/ios/AegisPolicyKit/RegisteredDomain.swift](../apps/ios/AegisPolicyKit/RegisteredDomain.swift)

iOS 模擬器證據：[docs/audit/ios-webkit-protection-2026-10-12.zh-CN.md](../docs/audit/ios-webkit-protection-2026-10-12.zh-CN.md)

### 指紋防護

`kAegisFingerprintGuard` — 獨立已知指紋資源規則及預設關閉的頁面 API 限制；Worker 等可繞過，未移植引擎層級擾動。

原始碼：[apps/ios/BrowserKit/BrowserSession.swift](../apps/ios/BrowserKit/BrowserSession.swift) · [apps/ios/BrowserKit/SecurityRules.swift](../apps/ios/BrowserKit/SecurityRules.swift) · [apps/ios/BrowserKit/PageProtection.swift](../apps/ios/BrowserKit/PageProtection.swift)

iOS 模擬器證據：[docs/audit/ios-webkit-protection-2026-10-12.zh-CN.md](../docs/audit/ios-webkit-protection-2026-10-12.zh-CN.md)

### 挖礦防護

`kAegisMinerGuard` — 獨立已知挖礦主機資源攔截；Worker/WASM 組合僅提示，不宣稱未知挖礦辨識。

原始碼：[apps/ios/BrowserKit/BrowserSession.swift](../apps/ios/BrowserKit/BrowserSession.swift) · [apps/ios/BrowserKit/SecurityRules.swift](../apps/ios/BrowserKit/SecurityRules.swift) · [apps/ios/BrowserKit/PageProtection.swift](../apps/ios/BrowserKit/PageProtection.swift)

iOS 模擬器證據：[docs/audit/ios-webkit-protection-2026-10-12.zh-CN.md](../docs/audit/ios-webkit-protection-2026-10-12.zh-CN.md)

### 字節碼檢查

`kAegisBytecodeShadow` — 系統 WebKit 不使用項目的 V8 字節碼檢查補丁。

原始碼：[apps/ios/BrowserKit/BrowserSession.swift](../apps/ios/BrowserKit/BrowserSession.swift)

本項未完成本輪執行驗收。

### 過濾列表更新

`kAegisFilterListUpdater` — 手動更新及可關閉的前台檢查；不承諾後台定時。

原始碼：[apps/ios/BrowserKit/BrowserPreferences.swift](../apps/ios/BrowserKit/BrowserPreferences.swift)

iOS 模擬器證據：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 鏈接清理

`kAegisLinkSanitize` — 可配置的導航追蹤參數清理；憑據網址始終阻止。

原始碼：[apps/ios/BrowserKit/NavigationPolicy.swift](../apps/ios/BrowserKit/NavigationPolicy.swift)

iOS 模擬器證據：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### Cookie清理

`kAegisCookieJanitor` — 支持按網站和全部清除；未移植自動 Cookie 清理策略。

原始碼：[apps/ios/AegisApp/BrowserPreferenceViews.swift](../apps/ios/AegisApp/BrowserPreferenceViews.swift)

iOS 模擬器證據：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### CNAME識別

`kAegisCnameUncloak` — 未移植 Chromium 網絡層的 CNAME 識別。

原始碼：[apps/ios/BrowserKit/BrowserSession.swift](../apps/ios/BrowserKit/BrowserSession.swift)

本項未完成本輪執行驗收。

### 跳轉跟蹤防護

`kAegisBounceTracking` — 由 WebKit 自身追蹤保護處理；沒有獨立 Aegis 跳轉跟蹤模塊。

原始碼：[apps/ios/BrowserKit/BrowserSession.swift](../apps/ios/BrowserKit/BrowserSession.swift)

本項未完成本輪執行驗收。

### 策略執行

`kAegisPolicyWorker` — Swift 策略、能力令牌和來源檢查；與 Chromium 執行架構不同。

原始碼：[apps/ios/AgentKit/AgentBroker.swift](../apps/ios/AgentKit/AgentBroker.swift)

iOS 模擬器證據：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 隱私AI

`kAegisPrivacyAi` — 發送前脫敏與預覽；未內置設備端推理模型。

原始碼：[apps/ios/AegisPolicyKit/PIIScanner.swift](../apps/ios/AegisPolicyKit/PIIScanner.swift)

iOS 模擬器證據：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### AI權限控制

`kAegisAiControl` — 讀取、發送和操作分別確認，限制窗口、模式和來源。

原始碼：[apps/ios/AgentKit/BrowserOperations.swift](../apps/ios/AgentKit/BrowserOperations.swift)

iOS 模擬器證據：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 瀏覽器Agent及隱私資料隔離

`kAegisAgent` — 網頁閱讀、比較、任務保存和有限瀏覽器操作；不覆蓋桌面全部工具。

原始碼：[apps/ios/AegisApp/PageAssistantView.swift](../apps/ios/AegisApp/PageAssistantView.swift)

iOS 模擬器證據：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### Agent頁面操作

`kAegisAgentPageActions` — 固定向下滾動及導航操作；不自動填表、登錄或付款。

原始碼：[apps/ios/AgentKit/BrowserOperations.swift](../apps/ios/AgentKit/BrowserOperations.swift)

本項未完成本輪執行驗收。

### Agent瀏覽器工具

`kAegisAgentBrowserTools` — 標籤分組、工作區、用戶輸入網址、重載及關閉，執行前確認。

原始碼：[apps/ios/AgentKit/BrowserOperations.swift](../apps/ios/AgentKit/BrowserOperations.swift)

iOS 模擬器證據：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### WebMCP實驗開關保持關閉

`kAegisAgentWebMcp` — 未接入 WebMCP，也沒有可啓用的空開關。

原始碼：[apps/ios/AegisApp/BrowserOperationsView.swift](../apps/ios/AegisApp/BrowserOperationsView.swift)

本項未完成本輪執行驗收。

### Agent工作流

`kAegisAgentWorkflows` — 保留既有工作流，新增前台網頁變化檢查；後台調度未移植。

原始碼：[apps/ios/BrowserKit/ForegroundPageWatch.swift](../apps/ios/BrowserKit/ForegroundPageWatch.swift)

iOS 模擬器證據：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 交易實驗開關保持關閉

`kAegisAgentTransactionPilot` — 沒有交易執行接口，購買流程由用戶完成。

原始碼：[apps/ios/AgentKit/BrowserOperations.swift](../apps/ios/AgentKit/BrowserOperations.swift)

本項未完成本輪執行驗收。

### 網絡訪問規則和權限

`aegis-access` — 按來源的網站顯示、腳本、相機和麥克風設置；未移植 Aegis Access 代理路由。

原始碼：[apps/ios/BrowserKit/BrowserPreferences.swift](../apps/ios/BrowserKit/BrowserPreferences.swift)

本項未完成本輪執行驗收。

### 舊資料、隱私模式和重啓兼容

`profile-compatibility` — 普通標籤恢復、私密隔離、加密資料及舊下載記錄兼容；格式獨立。

原始碼：[apps/ios/AegisApp/AegisApp.swift](../apps/ios/AegisApp/AegisApp.swift)

iOS 模擬器證據：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 已有更新入口、摘要校驗和失敗恢復

`release-update` — 安裝和更新依賴 iOS 分發資格；無桌面式自更新器。

原始碼：[apps/ios/AegisApp/Info.plist](../apps/ios/AegisApp/Info.plist)

本項未完成本輪執行驗收。

### 桌面右鍵手勢、配置持久化、練習區與PDF動作

`MouseGestures` — 使用觸控與系統導航；未移植桌面右鍵手勢。

原始碼：[apps/ios/BrowserKit/BrowserWebView.swift](../apps/ios/BrowserKit/BrowserWebView.swift)

本項未完成本輪執行驗收。

### 搜索、主頁與啓動

`search-home-startup` — 搜尋引擎選擇、刪除與恢復；空清單只開啟網址，自訂 HTTPS 範本、首頁及一般分頁恢復。

原始碼：[apps/ios/BrowserKit/BrowserPreferences.swift](../apps/ios/BrowserKit/BrowserPreferences.swift)

iOS 模擬器證據：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md) · [docs/audit/ios-search-engines-2026-10-11.zh-CN.md](../docs/audit/ios-search-engines-2026-10-11.zh-CN.md)

### 網頁顯示與網站權限

`site-display-permissions` — 全局及按來源的縮放、桌面模式、JavaScript、相機/麥克風詢問或阻止；無靜默授權。

原始碼：[apps/ios/BrowserKit/BrowserSession.swift](../apps/ios/BrowserKit/BrowserSession.swift)

iOS 模擬器證據：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 網站存儲管理

`site-storage` — 按網站清除普通 Cookie、緩存和存儲，先關閉所有窗口的普通標籤。

原始碼：[apps/ios/AegisApp/BrowserPreferenceViews.swift](../apps/ios/AegisApp/BrowserPreferenceViews.swift)

iOS 模擬器證據：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 收藏與歷史

`bookmarks-history` — 收藏管理和歷史搜索；私密瀏覽不記歷史，顯式保存需確認。

原始碼：[apps/ios/BrowserKit/BrowserDataStore.swift](../apps/ios/BrowserKit/BrowserDataStore.swift)

iOS 模擬器證據：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 標籤、窗口與工作區

`tabs-windows-workspaces` — 標籤分組、普通窗口恢復、iPad 多窗口；私密標籤不跨啓動恢復。

原始碼：[apps/ios/BrowserKit/BrowserWindowStore.swift](../apps/ios/BrowserKit/BrowserWindowStore.swift)

iOS 模擬器證據：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### HTTP 下載與完整性校驗

`http-downloads` — 系統後台 HTTP 下載、暫停續傳、哈希校驗、導出及回收站。

原始碼：[apps/ios/BrowserKit/DownloadManager.swift](../apps/ios/BrowserKit/DownloadManager.swift)

iOS 模擬器證據：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### Metalink 與鏡像

`metalink-mirrors` — 導入 Metalink、逐個切換鏡像及 SHA 校驗；不合併鏡像分片。

原始碼：[apps/ios/BrowserKit/DownloadPlan.swift](../apps/ios/BrowserKit/DownloadPlan.swift)

iOS 模擬器證據：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 下載網絡與容量設置

`download-network-limits` — 新任務保存網絡策略和容量上限，續傳沿用原策略。

原始碼：[apps/ios/BrowserKit/DownloadManager.swift](../apps/ios/BrowserKit/DownloadManager.swift)

iOS 模擬器證據：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### BT 與磁力下載

`torrent-magnet` — 需要 iOS 專用傳輸後端和後台調度方案，本輪未移植。

原始碼：[apps/ios/BrowserKit/DownloadManager.swift](../apps/ios/BrowserKit/DownloadManager.swift)

本項未完成本輪執行驗收。

### 閱讀資料與批注庫

`reading-library` — 顯式採集正文，AES-GCM 本機保存，引文高亮、批注、檢索、歸檔與導出。

原始碼：[apps/ios/BrowserKit/ReadingLibrary.swift](../apps/ios/BrowserKit/ReadingLibrary.swift)

iOS 模擬器證據：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 閱讀翻譯與對照

`reading-translation` — 網頁正文脫敏預覽後翻譯；iPad 並排、iPhone 上下對照，保存後才持久化。

原始碼：[apps/ios/AegisApp/ReadingLibraryView.swift](../apps/ios/AegisApp/ReadingLibraryView.swift)

iOS 模擬器證據：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### PDF 文字層批注

`pdf-text-notes` — 導入本地 PDF 指定頁文字，不執行 OCR，不把 PDF 發給模型。

原始碼：[apps/ios/BrowserKit/ReadingLibrary.swift](../apps/ios/BrowserKit/ReadingLibrary.swift)

iOS 模擬器證據：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 前台網頁變化檢查

`foreground-page-watch` — 面板前台按間隔重載並比較正文，停止或離開前台即取消。

原始碼：[apps/ios/BrowserKit/ForegroundPageWatch.swift](../apps/ios/BrowserKit/ForegroundPageWatch.swift)

iOS 模擬器證據：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 第三方擴展安裝

`third-party-extensions` — 有項目自帶的 WebExtension 集成，尚無任意第三方擴展安裝入口。

原始碼：[apps/ios/BrowserKit/WebExtensionRuntime.swift](../apps/ios/BrowserKit/WebExtensionRuntime.swift)

本項未完成本輪執行驗收。

### 跨設備同步

`cross-device-sync` — 本輪僅本機存儲，沒有賬號同步服務。

原始碼：[apps/ios/AegisApp/AegisApp.swift](../apps/ios/AegisApp/AegisApp.swift)

本項未完成本輪執行驗收。

### 默認瀏覽器與語言

`default-browser-language` — 跳轉系統設置；默認瀏覽器資格、App 語言和硬件權限由 iOS 決定。

原始碼：[apps/ios/AegisApp/BrowserSettings.swift](../apps/ios/AegisApp/BrowserSettings.swift)

本項未完成本輪執行驗收。

### WebKit 系統強化

`webkit-system-hardening` — iOS 26.4 以上可選公開安全限制；舊版保留預設保護。保留系統詐騙警告、HTTPS 策略與 Lockdown；模擬器不能證明 MTE 效果。

原始碼：[apps/ios/BrowserKit/PageProtection.swift](../apps/ios/BrowserKit/PageProtection.swift) · [apps/ios/BrowserKit/BrowserSession.swift](../apps/ios/BrowserKit/BrowserSession.swift)

iOS 模擬器證據：[docs/audit/ios-webkit-protection-2026-10-12.zh-CN.md](../docs/audit/ios-webkit-protection-2026-10-12.zh-CN.md)

### 依網站增強

`kAegisWebsiteEnhancements` — SwiftUI 與 WKWebView 已接入；按報告記錄 iPhone/iPad 模擬器證據，不代表實機、最低系統執行或散布驗收。

原始碼：[apps/ios/BrowserKit/UserScriptController.swift](../apps/ios/BrowserKit/UserScriptController.swift)

iOS 模擬器證據：[docs/audit/site-enhancement-markdown-2026-10-13.zh-CN.md](../docs/audit/site-enhancement-markdown-2026-10-13.zh-CN.md)

### 使用者腳本與 AI 草稿

`kAegisUserScripts` — SwiftUI 與 WKWebView 已接入；按報告記錄 iPhone/iPad 模擬器證據，不代表實機、最低系統執行或散布驗收。

原始碼：[apps/ios/BrowserKit/WebsiteEnhancements.swift](../apps/ios/BrowserKit/WebsiteEnhancements.swift)

iOS 模擬器證據：[docs/audit/site-enhancement-markdown-2026-10-13.zh-CN.md](../docs/audit/site-enhancement-markdown-2026-10-13.zh-CN.md)

### 內建 Markdown 閱讀

`kAegisMarkdownReader` — SwiftUI 與 WKWebView 已接入；按報告記錄 iPhone/iPad 模擬器證據，不代表實機、最低系統執行或散布驗收。

原始碼：[apps/ios/AegisApp/MarkdownReaderView.swift](../apps/ios/AegisApp/MarkdownReaderView.swift)

iOS 模擬器證據：[docs/audit/site-enhancement-markdown-2026-10-13.zh-CN.md](../docs/audit/site-enhancement-markdown-2026-10-13.zh-CN.md)

維護方式：修改 JSON 後執行 `node scripts/check-platform-features.mjs --write` 產生三語頁面，再執行 `node scripts/check-platform-features.mjs` 檢查。現有發行合同新增功能時，缺少任意一端的說明會使儲存庫檢查失敗。
