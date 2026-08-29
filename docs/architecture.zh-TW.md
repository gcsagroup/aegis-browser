# 架構

[English](architecture.md) | [简体中文](architecture.zh-CN.md) | **繁體中文**

## 產品形態

GCSA-aegis 有兩條整合式瀏覽器產品線：Chromium 分支面向桌面和 Android 路線，原生 iOS App 使用 SwiftUI 和 WKWebView。已退役的獨立擴充功能產品仍不在範圍內。

```text
                         packages/core
          策略、產生資產、Agent Contract v1 與 Golden Vectors
                               │
             ┌─────────────────┴─────────────────┐
             ▼                                   ▼
apps/browser：Chromium 分支             apps/ios：原生 iOS App
補丁堆疊 + 瀏覽器服務                   SwiftUI + WKWebView
             │                          BrowserKit / PolicyKit / AgentKit
             ▼                                   │
原生介面與平台封裝                      內嵌 Safari + Share extensions
```

`packages/core` 是可測試 TypeScript 邏輯、產生資源和共享 Agent Contract v1 的建置期來源。`apps/browser` 負責 Chromium 固定版本、補丁堆疊、overlay、建置腳本和平台封裝邊界。`apps/ios` 負責原生 Xcode 專案及內嵌擴充功能；這些擴充功能不是新的獨立產品。

## Chromium 執行路徑

1. **網路與導覽：**Chromium throttle 套用追蹤器規則、部分第一方收集路徑規則、連結清理、釣魚檢查和本機威脅情報查詢。
2. **儲存：**Cookie 分類和 bounce tracking 清理在瀏覽器掌控的生命週期和 Profile 邊界內執行。
3. **指紋表面：**Blink 及相關鉤子降低部分 Canvas、OffscreenCanvas、Audio、WebGL 和 WebGPU 表面的穩定跨站訊號。這是緩解措施，不等於匿名。
4. **下載：**使用者介面仍使用 Chromium 下載頁。整合層增加有界 HTTP(S) 平行、Metalink 和 BT/Magnet 路徑，並設定明確的資源與安全限制。
5. **頁面摘要：**renderer 提供有界候選快照，browser 再次驗證和脫敏。敏感頁面強制回退本機啟發式。使用者可設定 OpenAI、Claude（Anthropic）或 Gemini 相容端點；非 loopback 使用必須明確目標並確認。
6. **本機自動化：**所選桌面 CDP 路徑增加 loopback、來源和精確文件授權控制。獲授權的本機 agent 仍可讀取頁面 DOM，因此這不是通用資料防洩漏邊界。
7. **瀏覽器 Agent：**由瀏覽器掌控的策略代理負責書籤維護、URL 健康檢查、有界頁面操作、下載、工作流程、監控和結帳準備的規劃與執行。Observe/Ask/Act 模式、逐動作策略、審批回執、文件綁定、秘密脫敏、取消和稽核歷史均在模型層以下強制執行；v1 不授權無人值守完成最終購買。

## 原生 iOS 執行路徑

1. **瀏覽器外殼：** SwiftUI 為 iPhone 提供緊湊導覽，為 iPad 提供側欄，並承載 WKWebView 分頁、位址/搜尋輸入、導覽控制、歷史和書籤。
2. **設定檔隔離：** 一般與私密設定檔使用不同的 WKWebsiteDataStore、WKUserContentController 和擴充功能執行狀態。私密瀏覽不持久化，並停用歷史、書籤和 Agent。
3. **內嵌擴充功能：** SafariWebExtension 提供由使用者手勢觸發、短租約約束的唯讀頁面快照路徑，並以 isolated-world document token、navigation epoch、tab/frame/origin 和 worker instance 綁定授權與結果；ShareExtension 把有界 HTTP(S) URL 寫入專用、會過期且只能消費一次的 App Group inbox。真實 Safari 權限和真機 App Group 行為尚未驗證。
4. **策略模組：** BrowserSession 的主框架導覽會在網路載入前呼叫 AegisPolicyKit 的 LinkSanitizer 與 PhishingScorer，分別重寫追蹤參數和阻止高風險 URL，並顯示可見策略提示。PII 掃描與策略快照解析已有原始碼和測試，但尚未接入真實出站資料鏈。
5. **Agent Broker：** AgentKit 實作共享 Agent Contract v1、不可變任務授權、文件租約、資源登記和一次性動作能力。R1/R2 動作需要獨立確認：隨機批准 ID、最長 60 秒 TTL 與摘要共同綁定完整授權、工具、規範參數、序列、最終目標和風險；復原會校驗 ID/摘要/TTL，簽發入場先銷毀批准，隨後 capability 仍只能消費一次。使用者同意前只允許本機確定性範圍；私密設定檔拒絕 Agent 使用。
6. **離線工作流程：** 四個工作流程都可離線驗證。瀏覽器管家在獨立 R1 動作確認後執行真實的 Aegis 本機書籤交易；before/after 樹雜湊、認證加密 journal、當機過渡判定和狀態漂移檢查保護套用與撤銷。App 重新啟動後的撤銷不會自動執行，必須重新取得任務授權和獨立 R1 動作確認。深度研究、安全下載和購物助手仍不執行真實 DOM 擷取、實際下載、遠端模型呼叫、付款或下單。
7. **Simulator 路徑：** 儲存庫內 Xcode 專案和測試腳本面向專用 iPhone 與 iPad Simulator，只支援 `SIMULATOR_QUALIFIED` 證據。

## 僅研究路徑

Node-only AST 分析、有界行為/來源函數、本機聯邦模擬和 V8 Ignition 位元組碼影子屬於研究工具或 observe-only 插樁。它們不是已部署模型、完整瀏覽器資訊流系統、腳本攔截器，也不能證明通用惡意 JavaScript 防護。

## 目前原始碼與產物身分

- 目前整合 Chromium 原始碼包含 67 個頂層補丁和 2 個巢狀 V8 補丁。
- 57 補丁診斷清單和 65 補丁 Agent 驗收屬於歷史快照，均不綁定目前 67 補丁 HEAD，也不能為它授予資格。
- 目前整合 HEAD 必須重新完成精確重放、身分綁定建置和受影響執行驗收，才能成為目前本機候選。
- 原生 iOS 原始碼包含 App、BrowserKit、AegisPolicyKit、AgentKit、Safari/Share extension targets、共享合約向量和 iPhone/iPad Simulator 測試路徑；目前證據上限為 `SIMULATOR_QUALIFIED`。
- 不得把 Simulator 資格與未執行的真機或散布門檻拼接成 iOS 發布資格。

## 隱私與信任邊界

- Chromium API 憑證是可選項，透過作業系統加密儲存，並按 API 格式和正規化端點隔離，介面不回顯。
- 遠端摘要文字有界且經過遮蔽，但完整 Chromium 出站、遙測、更新、當機報告和錯誤路徑稽核仍待完成。
- 目前 iOS Agent 工作流程離線執行，不構成生產遠端模型路徑。Safari 存取唯讀並受手勢/租約約束；Share inbox 僅接收 URL，具有大小限制、過期和單次消費約束。
- 本機或 Simulator 簽署與結構檢查不等於產品身分、散布簽署、公證、provisioning、Archive、TestFlight 或已安裝真機驗收。
- Chromium Android 仍受阻於合格 x86-64 Linux 建置、目前原始碼產物和真機驗收。
- iOS 真機驗證為 `NOT_RUN`；預設瀏覽器 entitlement 為 `PENDING`；正式簽署、Archive、TestFlight 和 App Store 交付均為 `NOT_RUN`。

## 發布狀態

兩條產品線均已在原始碼中實作不同範圍，且本機證據上限不同；專案整體仍是 **release No-Go**。剩餘門檻見[路線圖](roadmap.zh-TW.md)，開發操作見 [Chromium 瀏覽器指南](../apps/browser/README.zh-TW.md)和 [iOS 工程指南](../apps/ios/README.zh-TW.md)。
