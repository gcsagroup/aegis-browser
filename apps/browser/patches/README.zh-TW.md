[English](./README.md) | [简体中文](./README.zh-CN.md) | [**繁體中文**](./README.zh-TW.md)

# 補丁

本目錄中的補丁套用於本機 checkout 內固定的 Chromium 提交（`../CHROMIUM_COMMIT`）之上。

## 約定

1. 檔案命名為 `0001-short-title.patch`、`0002-...`
2. 按套用順序列入 `series`
3. 優先採用小型、易審查的差異，透過 `aegis/` 整合層接入，避免大範圍改寫 Blink
4. 不要把完整 Chromium 原始碼樹放進本 Git 儲存庫

## 目前本機補丁序列

狀態「series 中」只表示補丁檔案列在目前本機 `series`；不表示已經進入上游 Chromium、通過發行門檻或可以發布。49、67 和 95 補丁記錄只保留為歷史快照。目前整合原始碼包含 **120 個 Chromium 補丁 + 2 個巢狀 V8 補丁**：0057–0065 是原 Browser Agent 整合，0066–0067 是設定/更新和視覺品牌，0068–0108 以 Browser Agent v2 Runtime 取代並強化 v1 執行路徑，同時加入跨平台入口、定時自動化、指定網站路由、Profile 隔離、有界恢復、瀏覽器綁定的分頁/文件能力、正確產品身分、脫離 UI 序列的持久化、確定性銷毀和啟用斷言時安全的限流處理。補丁 0109–0113 增加並強化 GitHub 瀏覽器更新及產品狀態/文案；補丁 0114–0116 增加存取路由規劃、可信策略匹配及 Profile 規則庫原子持久化/復原合約。補丁 0117 增加首個 fail-closed `net::ProxyInfo` 路由介面卡，只接受已登記的 numeric-loopback HTTP Proxy 入口且不提供 DIRECT fallback；補丁 0118 透過 Chromium 原生 custom-proxy delegate 將精確 host 選擇綁定到 Profile/StoragePartition NetworkContext，未選取的 host 保留 Chromium 原生 Proxy 結果；補丁 0119 增加真實 NetworkService/URLLoader 的 localhost HTTP/HTTPS Proxy 驗收案例，並覆蓋 Proxy 不可用時禁止 DIRECT 回退；補丁 0120 使用 Chromium 內建 GoogleTest 擴充 Proxy identity tuple、partition/selection 邊界、未選取網站原生路由及 HTTPS dead-proxy fail-closed 迴歸。補丁 0079–0095 重放到 Chromium 原始碼提交 `c930fa41ef7e9522f145848f3080ee0cc1edc4d8`；補丁 0096–0101 產生 `1c63ce994b2815fe1f3dc07608ff121d987e0441`（tree `451b3148d12fc2cff2df293cb0f1bb0d6242a908`）；補丁 0102 產生已提交原始碼 `13807aaf086948bdff0370e356718d0c2ac54d27`（tree `4546f1afcabf38013ba9bef7e9e5d078ffd3ca77`）。成品資格仍按平台分別判定，且必須綁定這份精確原始碼的驗收證據。

| ID | 目的 | 狀態 |
|----|------|------|
| 0001 | 增加 `chrome/browser/aegis/` 樁程式碼與 feature flag | series 中 |
| 0002 | 接入網路節流與 tracker host 請求取消 | series 中 |
| 0003 | 內嵌 `chrome://aegis` WebUI 設定介面 | series 中 |
| 0004 | 透過導覽節流增加網路釣魚攔截頁 | series 中 |
| 0005 | 增加 Canvas、Audio 與 WebGL 的 FingerprintGuard 擾動接入點 | series 中 |
| 0006 | 將 `packages/core` 策略快照封裝為 C++ `.inc` 與 JSON | series 中 |
| 0007 | 增加 EasyList 編譯器與執行階段過濾清單更新器 | series 中 |
| 0008 | 去除追蹤查詢參數並增加 Cookie 清理器 | series 中 |
| 0009 | 揭示 CNAME 並清除跳轉追蹤 Cookie | series 中 |
| 0010 | 增加網路釣魚 URL 啟發式與可解釋攔截頁 | series 中 |
| 0011 | 增加面向密碼表單與緊迫文案的網路釣魚頁面感知 | series 中 |
| 0012 | 透過 gin 增加 JavaScript 策略 worker 與 Privacy AI/Ollama sidecar | series 中 |
| 0013 | 擾動 WebGPU `adapter.info` | series 中 |
| 0014 | 修正啟動 DCHECK；策略 worker 改在 `chrome://aegis` 執行 | series 中 |
| 0015 | 在設定和選單中增加 `chrome://aegis` 入口 | series 中 |
| 0016 | 增加模組說明文案與 Ollama 模型設定 | series 中 |
| 0017 | 啟動後延後過濾清單和 Cookie 清掃 | series 中 |
| 0018 | EasyList 啟動時使用本機 `compiled.json` 快取 | series 中 |
| 0019 | 更新 EasyList 快取：24 小時檢查、HTTP 304 處理與失敗退避 | series 中 |
| 0020 | 增加易懂的攔截頁文案、摘要與工作階段清理清單 | series 中 |
| 0021 | 增加 Cookie 精確清單與第一方收集路徑攔截 | series 中 |
| 0022 | 增加工作階段清單即時重新整理、Canvas 自我檢查與 GA4 收集假象 | series 中 |
| 0023 | 讓攔截可見、去除 Referer 參數、標註 Cookie，並增加本機 CDP/AI 控制 | series 中 |
| 0024 | 從遠端 CDP 目標清單隱藏內部頁，並在工作階段清單顯示 Agent 連線 | series 中 |
| 0025 | 本機 CDP 連線時顯示瀏覽器橫幅，並增加開啟 `chrome://aegis` 的按鈕 | series 中 |
| 0026 | 在 `chrome://aegis` 一次檢測 Canvas、WebGL、Audio 與 WebGPU | series 中 |
| 0027 | Audio 指紋按網站只擾動一次，並涵蓋 `copyFromChannel` | series 中 |
| 0028 | 按網站穩定化 WebGPU limits 與 subgroup 數值 | series 中 |
| 0029 | Android 套件包含 `chrome://aegis`，並為 Play 預留顯示名稱和套件身分 | series 中 |
| 0030 | Android 設定開啟 `chrome://aegis`，並在行動端停用 CDP/Ollama | series 中 |
| 0031 | 強化摘要/Ollama、網路釣魚與本機 CDP 安全邊界及迴歸測試 | series 中 |
| 0032 | 保存遠端 CDP 生產接線與安全測試檢查點 | series 中 |
| 0033 | 統一遠端 CDP 來源傳播、目標授權與敏感協定攔截 | series 中 |
| 0034 | 跨 hash 導覽保持初始空白文件所有權語意 | series 中 |
| 0035 | 修正 Aegis WebUI TypeScript lint | series 中 |
| 0036 | 修正 CDP 瀏覽器測試通知 matcher 類型 | series 中 |
| 0037 | 穩定 Aegis 瀏覽器單元測試建置與臨界值斷言 | series 中 |
| 0038 | 遠端建立目標時保留並單次授權初始文件 | series 中 |
| 0039 | 擷取 Ollama 最終 HTTP 請求本文，並驗證原始 PII 不外送 | series 中 |
| 0040 | Profile 銷毀前釋放 Aegis 元件、回呼與原始指標 | series 中 |
| 0041 | 在生產路徑停用 Google AIM eligibility 伺服器請求，同時為測試 factory 保留正向門 | series 中 |
| 0042 | 一般未註冊 Profile 不建立 policy FM/GCM listener，企業註冊後單次啟動 | series 中 |
| 0043 | 將 Aegis 阻擋、CNAME、Referer 與參數事件切回 Remote 所屬序列，並保護結束生命週期 | series 中 |
| 0044 | 按網域索引 path rule、縮短清單替換臨界區，並移除 Canvas 擾動的整圖雙重複製 | series 中 |
| 0045 | 增加結構化頁面保護事件、網站彙總、隱私裁剪與暫時網站暫停 | series 中 |
| 0046 | 增加瀏覽器原生盾牌入口、目前網站氣泡與一次性感知引導 | series 中 |
| 0047 | 增加保護概覽、摘要前確認、網路釣魚線索優先解釋與事件驅動狀態 | series 中 |
| 0048 | 將摘要來源限制在設定頁同一視窗，並拒絕跨視窗/Profile 分頁 | series 中 |
| 0049 | 增加有界網路釣魚頁面收集、品牌仿冒/路徑/短連結訊號與本機多來源 SHA-256 威脅索引 | series 中 |
| 0050 | 整合多連線加速下載與 BT 下載 | series 中 |
| 0051 | 增加原生下載設定及安全預設值 | series 中 |
| 0052 | 強化 Canvas、OffscreenCanvas、Audio、WebGL 與 WebGPU 反指紋 | series 中 |
| 0053 | 增加僅觀察、不阻擋的 MinerGuard | series 中 |
| 0054 | 增加預設關閉的 V8 bytecode shadow 觀察能力 | series 中 |
| 0055 | 支援可編輯位址的 OpenAI、Claude（Anthropic）與 Gemini 相容 API、模型清單及按位址隔離憑證 | series 中 |
| 0056 | 在目前網站保護氣泡中原地完成 AI 摘要確認與結果顯示，並以精確文件工作階段完善 API 請求生命週期 | series 中 |
| 0057 | 固定 Agent 使用的 V8 bytecode shadow 觀察提交 | series 中 |
| 0058 | 增加任務合約、狀態機、策略代理、模型協定、任務儲存與固定工具登錄表 | series 中 |
| 0059 | 將 Aegis 精確範圍、文件綁定與任務生命週期接入 Actor 執行層 | series 中 |
| 0060 | 增加原生側欄、選單、快速鍵、設定入口和桌面 Browser/UI 測試 | series 中 |
| 0061 | 修正固定區間安全稽核發現，並完成資源封裝、真實快速鍵和桌面整合強化 | series 中 |
| 0062 | 預設顯示 Browser Agent 入口並補充迴歸測試 | series 中 |
| 0063 | 為既有 Profile 遷移 Agent 工具列入口 | series 中 |
| 0064 | 明確側欄就緒訊號並修正入口狀態 | series 中 |
| 0065 | 自動開啟任務頁面並支援空白分頁任務 | series 中 |
| 0066 | GCSA 設定移除上游 AI/Google 入口、恢復搜尋引擎管理，並重做關於頁與更新狀態 | series 中 |
| 0067 | 接入 GCSA Logo 與跨平台 App 圖示，同時保留 Chromium 內部身分和使用者資料目錄 | series 中 |
| 0068 | 增加 Browser Agent v2 原生混合 Runtime 原型 | series 中 |
| 0069 | 強化 v2 自主 Runtime 與策略邊界 | series 中 |
| 0070 | 簡化 Browser Agent v2 新手引導和任務入口 | series 中 |
| 0071 | 強化模型規劃與執行流程 | series 中 |
| 0072 | 瀏覽前先由模型理解使用者目標 | series 中 |
| 0073 | 強制使用瀏覽器原生工具並確定性路由指定網站 | series 中 |
| 0074 | 將隱含的目前頁面任務綁定到作用中文件 | series 中 |
| 0075 | 增加常用任務按鈕和定時自動化 | series 中 |
| 0076 | 修正跨平台建置接線與品牌資源 | series 中 |
| 0077 | 完成跨平台 Browser Agent v2 Runtime 與入口 | series 中 |
| 0078 | 模型格式有界失敗後恢復安全的唯讀計畫 | series 中 |
| 0079 | 隔離主要無痕 Profile，並收緊 Guest、CDP、NetLog、Actor、CNAME、Advanced 與 Torrent 生命週期 | series 中 |
| 0080 | 強化本機 Qwen 的目前頁面計畫 | series 中 |
| 0081 | 執行前驗證模型計畫順序 | series 中 |
| 0082 | 拒絕瀏覽器開啟目標後的重複入口導覽 | series 中 |
| 0083 | 降低本機 Qwen 原生工具輪次延遲 | series 中 |
| 0084 | 要求定時自動化由瀏覽器持久保存 | series 中 |
| 0085 | 對證據綁定的執行輪次做一次不擴權修復 | series 中 |
| 0086 | 阻止模型路由到非公開 URL | series 中 |
| 0087 | Agent 工作區使用產品 Logo | series 中 |
| 0088 | 加入品牌化 Android Agent 入口和任務編輯器 | series 中 |
| 0089 | 從較弱模型路由中恢復指定網站搜尋 | series 中 |
| 0090 | 書籤等瀏覽器資料任務保持使用原生工具 | series 中 |
| 0091 | 丟棄 browser-only 路由中無害的冗餘目標而不誤報失敗 | series 中 |
| 0092 | 驗證書籤目標語意、修復漏步計畫，並確保僅預覽任務維持唯讀 | series 中 |
| 0093 | 支援明確的本機 fixture URL 有效性檢查 | series 中 |
| 0094 | 正規化原生任務完成證據 | series 中 |
| 0095 | 保留已驗證完成狀態和書籤復原能力 | series 中 |
| 0096 | 將模型瀏覽器能力綁定到即時任務上下文 | series 中 |
| 0097 | 等待範圍內導覽提交，並在 Profile 初始化前註冊 Aegis 服務 | series 中 |
| 0098 | 在瀏覽器身分介面使用 GCSA Aegis 品牌 | series 中 |
| 0099 | 將 Agent 工作儲存移出 UI 序列 | series 中 |
| 0100 | 在測試夾具銷毀前清空 Profile 指標 | series 中 |
| 0101 | 同源 URL 遇到限流後有界完成其餘書籤檢查 | series 中 |
| 0102 | 在有界 URL 檢查中安全讀取不可合併的 Retry-After | series 中 |
| 0103 | 等待原生下載完成並驗證真實下載結果 | series 中 |
| 0104 | 讓無痕服務防護在 Android 正確編譯 | series 中 |
| 0105 | 註冊 Android Agent 通道，修復定時任務安全回退及狀態提示 | series 中 |
| 0106 | 使用快取語言設定，避免 Windows 介面執行緒阻塞；補充原生瀏覽器回歸測試 | series 中 |
| 0107 | 在資料啟動時恢復已啟用的 Agent 監控 | series 中 |
| 0108 | 補齊已核驗的執行、安全文字、監控與摘要修復 | series 中 |
| 0109 | 增加 GitHub 瀏覽器更新偵測和安裝包下載 | series 中 |
| 0110 | 保留本機驗收建置使用的連結資源限制 | series 中 |
| 0111 | 頁面關閉後繼續完成更新包安全檢查 | series 中 |
| 0112 | 修正 GitHub 更新器 Chromium 風格並遞增至 Ver 1.1 (003) | series 中 |
| 0113 | 修正設定文案與產品狀態並擴充翻譯 | series 中 |
| 0114 | 增加原生存取路由規劃與網站群組合約 | series 中 |
| 0115 | 增加可信請求歸屬正規化與策略匹配 | series 中 |
| 0116 | 增加 Profile 存取規則原子持久化與復原 | series 中 |
| 0117 | 將已登記的 loopback HTTP Proxy 以 fail-closed 方式套用到 Chromium `ProxyInfo`，不提供 DIRECT fallback | series 中 |
| 0118 | 將精確網站的 localhost HTTP Proxy 選擇綁定到 Profile/StoragePartition NetworkContext | series 中 |
| 0119 | 增加真實 NetworkService/URLLoader localhost Proxy 驗收與 Proxy 失效 fail-closed 回歸 | series 中 |
| 0120 | 擴充 Access C++ GoogleTest 的 ownership、partition、selection 與 fail-closed 迴歸覆蓋 | series 中 |

0103–0105 已從 0102 基線精確重放到 `1e1341b51e3254d4638bc1917b140f30d4c1e9d7` 的原始碼樹 `babd10e2e757d7b57f1b7ef18eac26ee5becc9cb`，平台實際驗收仍是獨立門檻。

0106 已從該候選精確重放到 `383d157c6f3601101038aef6ff964e61b6af7b4f`（tree `2c509e07ec25fa8811adae17f9826e967c9bcee1`）。這是歷史原始碼節點，不代表目前完整補丁序列。

2026-09-10 從固定基線完整重放 108 個補丁，得到原始碼樹 `319366182c31108e29e62d2f2199aff29a0b86e8`；2 個 V8 補丁也單獨核驗。詳見[合併記錄](../../../docs/audit/main-consolidation-2026-09-10.md)。本次提交沒有重新編譯 App。

在乾淨、固定版本的 checkout 上執行 `pnpm --filter @gcsa-aegis/browser apply-patches` 進行套用。任何 series 變化都必須重新完成離線重放、冷建置、增量建置和受影響測試。
