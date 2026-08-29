# 研究與實作映射

[English](research-map.md) | [简体中文](research-map.zh-CN.md) | **繁體中文**

本文區分已實作工程、研究啟發和缺失證據。引用論文不表示 GCSA-aegis 已重現其模型、資料集、準確率、隱私或安全結論。目前產品是整合式 Chromium Browser；擴充功能相關研究只保留為歷史背景。

## 釣魚、URL 與解釋

- [用戶端 URL 分析](https://arxiv.org/abs/2506.03656)：瀏覽器已有有界 URL 和頁面啟發式；一般導覽熱路徑不執行 JavaScript 動態分析。
- [PhishLang](https://arxiv.org/abs/2408.05667)：實作包含 punycode，以及部分品牌、路徑、憑證和跨站表單信號，但沒有論文中的雙輸入語言模型。
- [Explain, Don’t Just Warn!](https://arxiv.org/abs/2505.06836)：釣魚攔截頁顯示原因碼和權重；使用者理解測試與更完整的多語言證據仍未完成。
- [EXPLICATE](https://arxiv.org/abs/2503.20796)：確定性原因碼提高可追溯性，但不是完整可解釋 AI 系統的重現。

目前方向：高置信確定性檢查留在瀏覽器內；未來模型只處理有界灰區；任何阻斷行為變更前，必須使用獨立標註資料驗證誤報。

## 追蹤、Cookie 與連結清理

- [WebGraph](https://arxiv.org/abs/2107.11309)：Core 已有對呼叫方事件進行有界聚合的行為圖函式。Chromium 尚未採集完整 DOM、儲存、識別碼、跳轉和網路流，因此不是瀏覽器 WebGraph 系統。
- [PURL](https://arxiv.org/abs/2308.03417)：執行階段程式碼使用固定追蹤參數集合；網站級規則應離線生成，並在相容性回歸後才能採用。
- [ASTrack](https://arxiv.org/abs/2301.10895)：僅 Node AST 結構簽名原型可識別多站候選，但沒有分支安全分析、語意切片、程式碼改寫或選擇性刪除。
- [AdGraph](https://arxiv.org/abs/1805.09155)：尚未實作正式環境圖分類器。
- [第一方與 SST 追蹤](https://arxiv.org/abs/2606.16720)和 [SST-Guard](https://arxiv.org/abs/2604.27497)：目前只涵蓋部分收集路徑與參數模式，不涵蓋全部伺服器端埋點。
- [MV3 廣告攔截研究](https://arxiv.org/abs/2503.01000)：適用於歷史 Extension 階段，不能證明目前 Browser-only 架構。
- [CookieBlock](https://www.usenix.org/conference/usenixsecurity22/presentation/bollinger)：目前 Cookie 處理基於規則和名稱，仍需代表性登入與付款回歸。
- [CookieGraph](https://arxiv.org/abs/2208.12370)：尚未實作完整 Cookie 資訊流圖。
- [The CNAME of the Game](https://petsymposium.org/popets/2021/popets-2021-0053.pdf)：瀏覽器將網路層提供的 DNS alias 與本機追蹤器規則比較；這不是通用 CNAME 追蹤器分類器。

## 隱私 AI、最小化與本機自動化

- [Big Help or Big Brother?](https://arxiv.org/abs/2503.16586)：桌面摘要支援本機啟發式和使用者設定的相容 API。遠端使用僅在確認目標後傳送有界脫敏文字，但仍缺完整 Chromium 出站證明。
- [WebLLM](https://arxiv.org/abs/2412.15803)：研究性質本機 advisory contract 只接收去識別的特徵類別，錯誤時必須棄權。目前沒有 in-browser WebLLM 後端或捆綁模型。
- [Casper](https://arxiv.org/abs/2408.07004)：目前脫敏使用確定性模式和校驗演算法；更廣泛的本機 NER 屬於後續工作。
- [MINIM](https://arxiv.org/abs/2606.13949)：所選 CDP 路徑透過來源和精確文件授權縮小暴露面；獲授權的本機 agent 仍可讀取已授權 HTTP(S) 頁面的原始 DOM。

## 指紋與 JavaScript 研究

- [ByteDefender](https://arxiv.org/abs/2509.09950)：預設關閉的 V8 Ignition opcode shadow 原型輸出有界、僅觀察摘要；沒有函式級模型或阻斷，也不涵蓋全部 cache、snapshot 或 Wasm 路徑。
- [FP-Fed](https://arxiv.org/abs/2311.16940)：本機模擬研究裁剪更新、成對遮罩和 Gaussian noise；固定不可部署，不是真實 secure aggregation 或 opt-in 正式環境系統。
- [WebGPU 隱私](https://arxiv.org/abs/2606.26412)：已降低部分 adapter 字串、limit bucket 和高熵 subgroup 訊號；主動輸出、計時與 pipeline cache 通道仍待研究。

## 目前 JavaScript 與 MinerGuard 邊界

- 僅 Node AST 分析器使用 TypeScript parser，限制大小和複雜度，只輸出計數與原因碼，不輸出原始碼、字面量、URL 或 payload。它不在頁面執行路徑中。
- 有界行為與來源函式只處理呼叫方提供的分類事件，不是線上瀏覽器資訊流系統。
- MinerGuard 組合部分瀏覽器側 CPU 估算、Worker/Wasm/WebGPU/共享記憶體訊號、WebSocket 觀察和強端點 token；只記錄觀察結果，不停止腳本、Worker 或連線。
- Phase 2 固定協議下的正式研究語料仍由合成 fixture 構成。內容摘要只校驗完整性，不證明獨立封存；`sealIsolationVerified=false`、`finalEvaluationEligible=false`，最終評測入口保持閉鎖。
- Phase 3 另行使用 `operator-blinded-local` 協議評測了 13 個公開原始碼樣本：3 個標記為 `mining-capable`，10 個為良性對照，候選器命中 3 個正樣本中的 1 個，recall 為 `0.333333`。該 pilot 沒有獨立持有方或 sealed test，不是最終評測。

## 證據與發行門禁

1. 研究指標、產品執行證據和發行資格必須分開。
2. 偵測器影響頁面行為前，必須補齊獨立良惡性標註、真實網站、混淆測試、誤報測量、效能預算和破站測試。
3. 僅觀察訊號、合成 fixture 結果、小型 operator-blinded 公開 pilot 或聲明完整性檢查都不能寫成安全授權。
4. 受影響門禁必須在同一已提交原始碼和帶身分清單的產物上重跑。目前原始碼包含 67 個頂層 Chromium 補丁和 2 個巢狀 V8 補丁；先前的 57 補丁診斷清單和 65 補丁 Agent 候選僅為歷史證據，均不綁定目前 HEAD，也不能為它授予資格。

研究專案對正式環境阻斷和「通用惡意 JavaScript 防護」聲明仍為 **No-Go**。
