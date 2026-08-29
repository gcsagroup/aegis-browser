[English](aegis-browser-agent-v1-architecture.md) | [简体中文](aegis-browser-agent-v1-architecture.zh-CN.md) | **繁體中文**

# Aegis Browser Agent v1 架構與權限邊界

## 產品定位

Aegis Browser Agent 是瀏覽器內的任務執行器，不是擁有瀏覽器全部權限的聊天框。使用者給出目標後，Agent 會先形成可審查的計畫，再由瀏覽器依確定性策略執行和驗證。模型只能提出結構化工具呼叫；瀏覽器決定工具是否存在、參數是否合法、是否需要核准，以及任務是否真正完成。

v1 支援 macOS 桌面端。iOS 暫時跳過，Android 後置。v1 不會自動完成付款、傳送訊息、發布內容或繞過登入保護。

## 資料流

```text
使用者目標
  → Agent Side Panel（Ask / Act / Automate）
  → Profile 層級 AegisAgentService
  → Planner（固定系統合約 + 最小工具集合）
  → PolicyBroker（scope / risk / budget / approval）
  → Browser Tools 或 AegisActorBridge
  → ResultVerifier（瀏覽器後置條件）
  → TaskStore / Timeline / 使用者結果
```

模型回應、網頁文字、WebMCP 結果和工具結果都屬於不受信任的輸入。任務狀態只能由瀏覽器狀態機轉換，模型不能直接把任務標記為成功。

## 主要元件

### AegisAgentService

每個一般 Profile 各有一個執行個體，持有任務、計畫、模型請求、Actor、瀏覽器工具、待核准動作、復原憑證和監控。OTR、Guest、System Profile 不會建立服務。關閉 Agent 時，服務會停止模型請求、Actor、待核准動作和排程任務。

### TaskScope 與 ToolRegistry

TaskScope 是建立任務時的最大授權，包含精確 origin、tab、工具、資料類別、模型目的地和預算。模型計畫只能縮小範圍，不能增加 origin、工具、資料或預算。ToolRegistry 使用編譯期 schema，v1 不允許模型註冊工具。

### 結構化模型傳輸

支援 OpenAI-compatible Responses、Anthropic Messages 和 Gemini GenerateContent 的獨立 adapter。只接受原生結構化 tool call；自然語言中的 JSON 不會被執行。禁止重新導向，禁止 Cookie；loopback 可以使用 HTTP，雲端必須使用受支援的 HTTPS 目的地。

### AegisActorBridge

Actor Bridge 將已核准的頁面工具映射為 Chromium Actor 動作。每次觀察都綁定目前的 DocumentToken，並帶有觀察指紋；導覽、復原、手動修改頁面和使用者接管後都必須重新觀察。模型看不到密碼、OTP、Cookie、卡號或受保護的表單值。

### 瀏覽器原生工具

原生工具涵蓋分頁、視窗、工作區、書籤、歷史記錄、權限、下載和監控。書籤修改採用預覽、revision 衝突檢查、分組寫入和一鍵復原；URL 檢查使用有界 HEAD 與 Range GET；下載透過 DownloadItem 管理，並驗證來源、架構和 SHA-256。

### PolicyBroker 與 ResultVerifier

風險等級如下：

- R0：唯讀，可在核准範圍內自動執行。
- R1：本機可復原的低風險操作，例如調整分頁、工作區或監控狀態；受任務確認約束。
- R2：持久的瀏覽器寫入或外部副作用，例如套用書籤分類、下載和按一下網頁；必須針對精確 action id 單獨核准。
- R3：交易、最終提交等使用者接管動作；Agent 不能代替使用者完成。
- Blocked：讀取祕密、任意程式碼、通用 CDP、跨範圍動作等會直接遭拒。

ResultVerifier 會檢查瀏覽器真實狀態。下載存在、書籤樹 revision、目前的 DocumentToken、頁面觀察指紋和結帳金額等後置條件不符合時，任務會失敗或要求重新觀察，而不是採信模型聲稱「成功」。

## 四個內建工作流程

1. 深度研究：多來源瀏覽、衝突標記、引用和未驗證項目；唯讀。
2. 瀏覽器管家：分頁和書籤整理、URL 狀態檢查、預覽/套用/復原。
3. 安全下載：尋找官方來源、比對平台架構、原生下載和雜湊驗證。
4. 購物助手：比較總價、運費、稅費、配送和退貨；可以加入購物車，但最終購買交由使用者完成。

監控只在瀏覽器執行時排程，最多 3 個並行工作，並設有退避和補跑上限；不會為背景監控自動開啟新分頁。通知只顯示監控類型和 origin，不包含頁面本文或祕密，也沒有可直接執行動作的通知按鈕。

## 持久化與復原

TaskStore 使用 Profile 內的 SQLite。持久化內容包含通過祕密標記和長度檢查的任務目標、任務合約、去識別化事件摘要、計畫步驟/進度和加密監控目標。原始工具結果、頁面本文、截圖、復原憑證、密碼、OTP、Cookie、卡號、API key 和完整本機路徑不得寫入磁碟。未完成任務保留 7 天，終態任務保留 30 天；服務啟動時會先清理過期記錄，清理失敗時 Agent 會 fail closed。

當機後，唯讀任務可在使用者確認後復原；待核准動作會過期，外部副作用不會自動重播。任何復原都要求新的頁面觀察，舊節點和舊 DocumentToken 無效。

書籤復原憑證只在目前瀏覽器工作階段內有效；瀏覽器重新啟動後不會嘗試重播復原或寫入操作。

## 明確不支援

- 自動付款、最終下單、轉帳、發文、傳送訊息或接受法律條款。
- 任意 JavaScript、shell、瀏覽器遠端偵錯或通用本機檔案存取。
- 無提示讀取密碼、Cookie、OTP、支付卡或跨 Profile 資料。
- 瀏覽器關閉後常駐的系統層級監控。
- 把本機測試通過直接解釋為公開發布、正式簽署或公證完成。
