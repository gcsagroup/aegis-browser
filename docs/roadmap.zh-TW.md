# 路線圖

[English](roadmap.md) | [简体中文](roadmap.zh-CN.md) | **繁體中文**

## 狀態詞彙

- **歷史原型：** 只能證明方向，不能代表目前可交付物。
- **已進入原始碼：** 程式碼或補丁存在；建置和執行狀態另算。
- **原始碼已同步：** 補丁血統、overlay 和外部 checkout 一致。
- **Simulator-qualified：** 具名 iOS 原始碼與測試範圍在指定 iPhone/iPad Simulator 上共同執行；真機、簽署、散布和商店狀態另算。
- **門檻已通過：** 具名原始碼、產物、平台和代表性測試範圍共同通過。
- **具備發布資格：** 同一可散布產物通過身分、信任、簽署、安裝、隱私、平台和投放門檻。

## 目前結論 — 2026-08-29

目前整合 Chromium 原始碼包含 67 個頂層補丁和 2 個巢狀 V8 補丁。先前的 57 補丁診斷清單和 65 補丁 Agent 驗收保留為歷史快照，均不綁定目前 67 補丁 HEAD，也不能為它授予資格；目前仍需重新完成精確重放、身分綁定建置和受影響執行驗收。

原生 iOS 產品已具備 SwiftUI/WKWebView 瀏覽器、一般/私密隔離、內嵌 Safari/Share extensions、Agent Broker、四個離線確定性工作流程、共享 Agent Contract v1 向量，以及 iPhone/iPad Simulator 路徑。目前證據上限為 **SIMULATOR_QUALIFIED**。真機驗證為 `NOT_RUN`；預設瀏覽器 entitlement 為 `PENDING`；正式簽署、Archive、TestFlight 和 App Store 交付均為 `NOT_RUN`。

專案整體為 **release No-Go**。兩條產品線都沒有同時具備可信目前原始碼散布套件和完整發布門檻證據。

## 歷史階段

### 階段 0 — 鷹架

Monorepo、三語產品頁和核心策略原型建立了產品方向。

### 階段 1 — 擴充功能原型

MV3 擴充功能驗證了部分追蹤器、網路釣魚和隱私摘要構想。它不再是獨立產品或發布目標。

### 階段 2 — 核心原型

連結清理、Cookie 分類、PII 遮蔽、網路釣魚啟發式和產生策略資產進入可重用、可測試程式碼。僅研究評估器仍與瀏覽器決策分離。

## 階段 3 — Chromium 產品線

### M0：基線與復原 — 完成

- Chromium 固定為版本 `151.0.7922.77` 和基礎提交 `ff37cfca210138f2a40b843b4a8195ab7e4fc7ff`。
- 已有本機復原點和證據保留邊界。

### M1：Chromium 收斂與快速門檻 — 完成

- 歷史 browser-only 收斂退役了獨立擴充功能產品，並把 Chromium 能力集中到 `apps/browser`。
- 該邊界禁止獨立 `apps/extension`，不禁止之後建立帶內嵌擴充功能的原生平台瀏覽器。
- Workspace 已凍結 JavaScript 相依套件，並有可重複快速品質門檻。

### M2：Chromium 整合與本機建置身分 — 部分完成

- 有序原始碼現包含 67 個頂層 Chromium 補丁和 2 個巢狀 V8 補丁。
- 57 補丁診斷清單和 65 補丁 Agent 候選保留各自已記錄的本機證據，但只涵蓋對應歷史 HEAD。
- 65 補丁候選通過了具名原生、瀏覽器、fixture、生命週期和本機 UI 範圍；它不是已簽署、公證和安裝驗收的散布套件。
- 目前 67 補丁 HEAD 仍需重新完成乾淨重放、精確身分清單、受影響測試和執行驗收。

### M3–M4：安全邊界與穩定性 — 部分完成

- Chromium 原生追蹤器、連結、Cookie、網路釣魚、指紋、下載、摘要和本機自動化控制已進入原始碼。
- 具名早期補丁頭通過過部分歷史原生、瀏覽器和執行門檻。
- MinerGuard 和 V8 位元組碼影子仍是 observe-only；研究評估器不授權攔截或生產安全聲明。
- 目前診斷產物上的 bytecode-shadow v5 按固定研究協議在兩個公開網站完成 4/4 執行；其報告仍為 `research-only`，且 `releaseEligible=false`。
- 完整的產品級出站歸因、遙測/更新/當機報告複核、代表性功能行為矩陣、啟動壓力、誤報評估和更廣泛的目前頭重跑仍未完成。

### M5：Android — 後置

- 目前證據集中沒有合格的 x86-64 Linux 建置環境。
- 目前原始碼沒有綁定身分的 APK/AAB，也沒有真機驗收。
- Android 頁面摘要和平台特定行為需要目前原始碼驗證。

### M6：Chromium 內部候選版本 — 待完成

Chromium 內部 RC 需要乾淨、綁定身分的目前原始碼建置、受影響測試和執行門檻、產品身分、簽署與公證準備、封裝、已安裝 App 驗收、隱私/出站複核和回復證據。不得從原始碼同步推導這些結論。

## 階段 4 — 原生 iOS 產品線

### I0：工程與產品拓撲 — Simulator-qualified 範圍

- 原生 Xcode 專案定義 Aegis App、BrowserKit、AegisPolicyKit、AgentKit、內嵌 Safari/Share extensions 和 iPhone/iPad 單元/UI 測試 targets。
- iOS App 是產品線；其 extension targets 仍是內嵌元件，不是獨立產品。

### I1：瀏覽器外殼與設定檔隔離 — Simulator-qualified 範圍

- 已有 SwiftUI/WKWebView 分頁、導覽、一般歷史/書籤、iPhone 緊湊介面和 iPad 側欄。
- 一般與私密設定檔隔離資料儲存、使用者內容控制器和擴充功能狀態；私密模式不持久化，並停用歷史、書籤和 Agent。
- 最低系統、多 runtime、生命週期、真實站點和真機矩陣仍待完成。

### I2：內嵌擴充功能與策略路徑 — 部分完成

- Safari 已有手勢/租約約束的唯讀快照門，並以 document token 與 navigation epoch 綁定授權文件；Share 已有有界、會過期且只能消費一次的 HTTP(S) URL inbox。
- BrowserSession 主框架導覽已接入 LinkSanitizer 與 PhishingScorer，並提供追蹤參數清理和高風險 URL 攔截；PII 出站保護仍未接入真實資料鏈。
- 真實 Safari 權限、App Group 行為、Share 到 App 生命週期和真機端對端驗收仍未完成。

### I3：Agent Contract v1 與四個工作流程 — Simulator-qualified 離線範圍

- AgentKit 已實作共享合約 codec/向量、授權、文件租約、資源登記、一次性能力、Broker、同意狀態和復原邊界。R1/R2 批准使用隨機 ID、最長 60 秒 TTL、完整動作摘要、精確復原校驗和簽發前銷毀。
- 深度研究、瀏覽器管家、安全下載和購物助手可離線確定性驗證。
- 本機書籤套用/撤銷交易、認證加密 journal、當機復原判定和跨重啟後的 Agent 雙確認撤銷入口已在 Simulator 範圍實作；真實 DOM 擷取、實際下載、生產模型路由、付款和下單仍不屬於已實作發布證據。
- 最終具名證據使用 Aegis-Debug、Xcode 26.6 與 iOS Simulator 26.5：iPhone 17 共 81 項，80 通過，依設計跳過僅適用於 iPad 的側欄測試；iPad Air 11-inch (M4) 81/81 通過。39/39 安全定向單元測試和 2/2 關鍵 UI 測試是上述完整套件的子集，不能另行相加。

### I4：真機與散布 — 待完成

- 真機瀏覽器、私密模式、Safari、Share、生命週期、效能、無障礙和隱私驗收為 `NOT_RUN`。
- 預設瀏覽器 entitlement 與核准為 `PENDING`。
- Development Team/provisioning、正式簽署、Archive、TestFlight、App Store 中繼資料/隱私聲明、安裝、升級和回復均為 `NOT_RUN`。

## 跨產品工作
### M6：macOS 本機發行候選 — 已完成；散佈資格待完成

精確目前原始碼已有乾淨、帶身分綁定的 macOS 本機構建、受影響測試、fixture 執行證據、A1–A10 驗收、完整固定提交區間安全稽核，以及 11 項發現的修復驗證。產品身分、受信任構建證明、Developer ID 簽名、公證、散佈封裝、安裝 App 驗收、完整 Chromium 對外連線稽核、Android 和發行授權仍未完成，因此正式發行仍為 No-Go。

### M7：文件與發布邊界 — 進行中

- 公共 README、架構和路線圖用英文、簡體中文和繁體中文描述兩條產品線。
- 附日期的稽核紀錄仍是歷史快照，不能覆蓋本路線圖。
- 原始碼發布、安裝套件發布、TestFlight、App Store 和生產部署仍是不同決策。

## GitHub 原始碼同步

2026-08-28 授權涵蓋透過 SSH 將原始碼分支同步到 `git@github.com:gcsagroup/aegis-browser.git`，不涵蓋 Git tag、GitHub Release、二進位檔、簽署憑證、公證、Play 上傳、TestFlight、App Store 提交或生產部署。

## 發布退出標準

1. 從乾淨狀態提交並重現兩條產品線的精確目前原始碼及巢狀血統。
2. 在合格主機上產出綁定身分的目前原始碼 Chromium 與 iOS 散布候選。
3. 在這些精確候選上通過受影響單元、瀏覽器、執行、隱私、出站、效能、代表性站點、Simulator 和真機門檻。
4. 分別完成 Chromium 身分/簽署/公證/封裝門檻，以及 iOS entitlement/provisioning/簽署/Archive/TestFlight/App Store 門檻。
5. 對精確候選完成安裝、升級、回復、隱私/出站、第三方聲明、文件與散布授權複核。
