[English](./README.md) | [简体中文](./README.zh-CN.md) | [**繁體中文**](./README.zh-TW.md)

# Aegis 原生 iOS 專案

本目錄是 GCSA-aegis 的原生 iOS 產品線，不是 Chromium 的 WebKit 包裝層，也不是獨立擴充功能產品。目前原始碼包含 SwiftUI/WKWebView 瀏覽器、一般/私密隔離、內嵌 Safari/Share extensions、Agent Broker、共用 Agent Contract v1，以及四個離線確定性工作流程。

> **證據狀態 — 2026-08-28：`SIMULATOR_QUALIFIED_HARDENED`。** 此狀態只涵蓋目前具名的 iPhone/iPad Simulator 路徑，並綁定最新本機強化證據。實機驗證為 `NOT_RUN`；預設瀏覽器 entitlement 為 `PENDING`；正式簽署、Archive、TestFlight 與 App Store 交付皆為 `NOT_RUN`。專案整體仍是 **release No-Go**。

## 環境與專案產生

專案宣告 iOS 18.4 deployment target、Swift 6 嚴格並行、iPhone/iPad device family 與 Xcode 26。需要 Xcode 26 系列、可用的 iOS Simulator runtime、Node.js 和 XcodeGen。

XcodeGen 沒有唯讀產生模式。先檢查工具與已提交專案；只有在明確需要重新產生時才執行第三個命令，並複核產生的差異：

```bash
xcodegen --version
xcodebuild -list -project apps/ios/Aegis.xcodeproj
xcodegen --spec apps/ios/project.yml
```

無正式簽署的 Simulator Debug 建置範例：

```bash
xcodebuild \
  -project apps/ios/Aegis.xcodeproj \
  -scheme Aegis \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/aegis-ios-build-NEW-ID \
  CODE_SIGNING_ALLOWED=NO \
  build
```

`/tmp/aegis-ios-build-NEW-ID` 應替換為新的暫存路徑。此命令只會產生本機 Simulator 建置證據，不等同於 Archive、正式簽署或可散布套件。

## Simulator 測試

先單獨驗證離線 fixture，再執行預設 dry-run：

```bash
node apps/ios/scripts/verify-fixtures.mjs
bash apps/ios/scripts/run-simulator-tests.sh \
  --dry-run \
  --output-dir /tmp/aegis-ios-NEW-ID
```

dry-run 會驗證 fixture 與 Safari 文件身分 Node harness、讀取 Simulator runtime/device type，並列印計畫命令；不會建立裝置、啟動測試或建立輸出目錄。

明確需要執行 iPhone/iPad 測試時，請使用一個尚不存在的 `/tmp/aegis-ios-*` 目錄：

```bash
bash apps/ios/scripts/run-simulator-tests.sh \
  --execute \
  --output-dir /tmp/aegis-ios-NEW-ID-EXECUTE
```

執行模式預設選擇最新可用的 iOS runtime，依序使用專用的 `Aegis QA iPhone 17` 與 `Aegis QA iPad Air 11-inch (M4)` Simulator，必要時只建立缺少的裝置。腳本不會 erase、delete、shutdown、uninstall 或清理任何 Simulator，也不會覆寫既有輸出；結果儲存在具名 log、metadata、summary 與 `.xcresult` 中。

可用參數包含 `--project`、`--workspace`、`--scheme`、`--test-plan`、`--runtime` 與 `--output-dir`。預設 scheme 是 `Aegis`；儲存庫也宣告 `Aegis-Debug` 與 `Aegis-Release`。原生 iOS 專案不屬於 pnpm workspace，不應把 `pnpm run quality:fast` 當成 Xcode 測試的替代品。

## 模組結構

- `AegisApp`：SwiftUI App、iPhone/iPad 配置、瀏覽器與 Agent 任務中心，以及 Share inbox 取用入口。
- `BrowserKit`：WKWebView 分頁、導覽、一般/私密設定、歷史記錄、書籤與 WebExtension 資源載入。
- `AegisPolicyKit`：連結清理、PII 掃描、網路釣魚評分與策略快照解析。
- `AgentKit`：Agent Contract v1 codec、授權與租約、資源登記、一次性動作能力、Broker，以及四個離線工作流程。
- `SafariWebExtension` 與 `SharedWebExtension`：受使用者手勢和短租約約束的唯讀頁面觀察路徑。
- `ShareExtension` 與 `Shared/ShareInbox.swift`：受限 HTTP(S) URL 的專用 App Group 交接。
- `Tests` 與 `scripts`：單元/UI 測試原始碼、離線 fixture 驗證，以及 iPhone/iPad Simulator 執行入口。
- `project.yml` 與 `Aegis.xcodeproj`：XcodeGen 唯一真源和目前產生的專案。

## Agent 與安全邊界

- 一般與私密設定使用不同的 WKWebsiteDataStore、WKUserContentController 和擴充功能狀態；私密設定不會持久化，並停用歷史記錄、書籤與 Agent。
- AgentKit 以不可變任務授權、文件租約、不可重複使用的資源 ID 登記和一次性 capability 約束動作；使用者同意前只允許本機確定性工作。
- R1/R2 受保護動作需要獨立於任務授權的第二次確認；核准物件使用隨機 ID、最長 60 秒 TTL 和完整動作範圍摘要，復原與簽發都必須精確相符。進入簽發後，無論成功或拒絕都會先銷毀該核准，不能重播。
- 四個工作流程維持離線受控：瀏覽器管家會在獨立 R1 動作確認後，對目前 Aegis 本機書籤執行移除追蹤參數、精確去重和穩定排序。交易使用 before/after 樹雜湊、Keychain 金鑰支援的 AES-GCM journal、File Protection、當機轉換判定與狀態漂移保護；App 重新啟動後只會復原「可復原」入口，仍需新的任務授權和獨立 R1 動作確認，絕不自動寫入。深度研究仍不讀取真實網站，安全下載不發起真實下載，購物助手不付款或下單；目前沒有生產遠端模型路徑。
- Safari 路徑目前只觀察有界頁面資訊，受 profile、tab、frame、origin、route、worker instance、gesture nonce、isolated-world document token、navigation epoch 和短租約綁定。授權前不讀取 DOM/location；授權後的單次腳本任務會先核對完整 URL 與文件身分，再固定快照；導覽變更會安全拒絕或主動燒毀租約。結果尚未形成進入主 App/Agent 的完整產品管線，真實 Safari native messaging、Private Browsing 與 worker 生命週期也尚未跑通。
- Share inbox 只接受無 credentials 的 HTTP(S) URL，並限制大小、有效期和取用次數；主 App 目前在取用後導覽，尚未在此路徑前接入完整 PolicyKit 掃描。
- BrowserSession 主框架導覽已在網路載入前接入 AegisPolicyKit 的 LinkSanitizer 與 PhishingScorer，並在清除追蹤參數或阻擋高風險 URL 時顯示提示；PII Scanner 仍未接入真實出站/模型網路鏈。目前的 delegate 與 UI 測試不等同於網路層零請求儀器，也未涵蓋真實重新導向逐跳矩陣。
- 共用合約 Schema 與 Golden Vectors 位於 [`packages/core/src/agent/contracts/v1`](../../packages/core/src/agent/contracts/v1/agent-contract-v1.schema.json)，Swift 測試讀取同一組向量；這證明合約相容範圍。書籤交易另有真實本機 Store 測試，但這些證據都不等於實機或發布安全證明。

## 目前驗收證據

2026-08-28 的目前本機工作樹建置使用 Xcode 26.6、iOS Simulator 26.5：iPhone 17 共 113 項，112 通過、0 失敗、1 項依設計跳過（僅 iPad 分欄）；iPad Air 11-inch (M4) 共 113 項，113 通過、0 失敗。安全定向單元/整合測試 70/70、關鍵 UI 測試 4/4 通過；Safari Node 文件身分測試與 Release 測試入口隔離檢查也通過。

Computer Use 可見驗收實際完成高風險導覽阻擋、追蹤參數清理、書籤整理跨重啟復原撤銷，以及再次重啟不重播。完整範圍、結果套件路徑、截圖與剩餘風險請參閱[《iOS Simulator 強化驗收記錄》](../../docs/audit/ios-simulator-hardening-2026-08-28.md)。舊[資格驗收記錄](../../docs/audit/ios-simulator-qualification-2026-08-28.md)保留為歷史基準；目前結果仍綁定 dirty 本機工作樹，不是乾淨提交、簽署成品或發布候選證據。

## 已知發布門檻

- 凍結並提交精確的 iOS 原始碼身分，複核 XcodeGen 重新產生差異。
- 完成 Debug/Release 建置、最低系統與多 runtime、真實網站、生命週期、效能、無障礙和隱私矩陣。
- 完成實機安裝，以及 Safari 權限、Share App Group、一般/私密隔離和 Agent 安全邊界的端對端驗收。
- 擴充並驗證 PolicyKit 的 PII 出站執行路徑；若擴充到真實 DOM、真實下載或遠端模型，另做權限、同意、DLP、復原和出站驗收。主框架 URL 導覽策略與書籤跨重啟撤銷 journal 已納入 Simulator 範圍，但仍需真實網站和實機矩陣。
- 準備並取得預設瀏覽器 entitlement；補齊 Privacy Manifest、隱私標籤、第三方聲明和出口合規資料。
- 設定 Development Team/provisioning，完成正式簽署、Archive、TestFlight、App Store、安裝/升級/回復和散布授權。

## 相關文件

- [iOS Simulator 資格驗收記錄](../../docs/audit/ios-simulator-qualification-2026-08-28.md)
- [iOS Simulator 強化驗收記錄](../../docs/audit/ios-simulator-hardening-2026-08-28.md)
- [產品架構與 Agent 整合方案](../../docs/ios-product-architecture-and-agent-integration-2026-08-28.md)
- [iOS 專案執行計畫](../../docs/ios-project-execution-plan-2026-08-28.md)
- [Aegis Browser Agent v1 實作方案](../../docs/aegis-browser-agent-v1-implementation-plan-2026-08-28.md)
- [Aegis Browser Agent v1 開發執行計畫](../../docs/aegis-browser-agent-v1-development-execution-plan-2026-08-28.md)
- [儲存庫架構](../../docs/architecture.zh-TW.md)與[路線圖](../../docs/roadmap.zh-TW.md)
