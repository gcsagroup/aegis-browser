# 路線圖

[English](roadmap.md) | [简体中文](roadmap.zh-CN.md) | **繁體中文**

## 平台口徑

三條線同時推進，目標不同。一個平台的進度不會授予另一個平台發布資格。

| 軌道 | 目前目標 |
| --- | --- |
| iOS / iPadOS | 已上架。App Store 1.0.0 已公開。目前工作是這條已發布線的維護，加上 Access 驗收。 |
| macOS | 爭取發布資格。Chromium 整合已在原始碼中；執行與散布驗收仍未完成。 |
| Windows | 同事負責 Windows 原始碼移植和原生驗收。runner 准入及原生建置、測試、瀏覽器和安裝器驗收按既有決定保持暫停。Android 與 Linux 仍是後續評估，不承諾發布日期。 |

macOS 發布資格不等待下一次 iOS 商店提交。iOS 維護和 Access 驗收也不等待 macOS 發布資格。Access 順序見 [TODO.md](../TODO.md#access-roadmap-todo)：先收 [#157](https://github.com/gcsagroup/aegis-browser/issues/157)、[#158](https://github.com/gcsagroup/aegis-browser/issues/158)，再做 [#136](https://github.com/gcsagroup/aegis-browser/issues/136) 與 [#155](https://github.com/gcsagroup/aegis-browser/issues/155) 的網頁取證，然後是 iPhone [#137](https://github.com/gcsagroup/aegis-browser/issues/137)、[#160](https://github.com/gcsagroup/aegis-browser/issues/160)、[#138](https://github.com/gcsagroup/aegis-browser/issues/138)。macOS 同步清理 [#165](https://github.com/gcsagroup/aegis-browser/issues/165) 與 [#179](https://github.com/gcsagroup/aegis-browser/issues/179)，再推進 [#140](https://github.com/gcsagroup/aegis-browser/issues/140) 與 [#141](https://github.com/gcsagroup/aegis-browser/issues/141)。

## 證據詞彙

- **已進入原始碼：** 程式碼存在；建置與執行狀態另算。
- **已驗證：** 具名原始碼與聲明的測試範圍在同一身分下通過。
- **Simulator-qualified：** 具名 iOS 原始碼與測試範圍在指定 Simulator 上通過；真機與散布狀態仍需單獨證明。
- **具備發布資格：** 同一個可散布產物完成該平台的身分、建置、執行、隱私、簽署、安裝和發布門檻。

徽章與歷史稽核紀錄只證明各自明確聲明的範圍，不會自動授予發布資格。

## 目前主線 — macOS 發布資格

macOS 是爭取桌面發布資格的軌道。Chromium 原始碼、儲存庫品質門檻、獨立 C++ 原生測試和部分整合驗證已經存在，但專案仍然**不具備正式發布資格**。完整目前原始碼的 Chromium 執行證據，以及最終簽署/公證/散布鏈仍需獨立完成。

先清理 [#165](https://github.com/gcsagroup/aegis-browser/issues/165) 與 [#179](https://github.com/gcsagroup/aegis-browser/issues/179)，再做綜合瀏覽器驗收。隨後推進 [#140](https://github.com/gcsagroup/aegis-browser/issues/140) 與 [#141](https://github.com/gcsagroup/aegis-browser/issues/141)。這兩項缺陷與 iOS Access 順序並行處理，不把 Windows 工作拉進本軌道。

### MAC-1 — 核心瀏覽器與 Access Service

**目標：** 在不削弱 fail-closed 邊界的前提下，收斂目前瀏覽器整合與網路路由缺口。

完成標準：

- Access 路由、Profile/StoragePartition ownership 和 NetworkContext 接入具備對應單元/回歸測試。
- 必要 Chromium 目標能針對目前固定原始碼真實編譯，並在合格環境執行相應 GoogleTest / browser 場景。
- HTTP/HTTPS 代理、代理不可用以及原生直連場景能夠證明預期行為，不出現靜默 DIRECT fallback。
- Browser Agent、隱私控制與瀏覽器原生能力繼續保持明確的安全和使用者同意邊界。

### MAC-2 — 穩定性與發布候選

**目標：** 把已整合原始碼收斂為可重現、身分綁定的 macOS 候選。

完成標準：

- 從固定 Chromium 原始碼與有序補丁序列開始的乾淨重放/建置可重現。
- 同一候選通過代表性瀏覽、設定隔離、下載、Agent、更新、當機/重啟以及真實網路場景。
- 效能、隱私/出站與回歸審查綁定目前候選，而不是歷史補丁頭。
- 安裝 App 的身分能夠精確映射到儲存庫、Chromium、V8、補丁序列和建置輸入。

### MAC-3 — macOS 散布

**目標：** 讓首個穩定 Aegis macOS 安裝套件具備正式散布資格。

完成標準：

- 同一候選完成 Developer ID 簽署與公證。
- 在代表性受支援系統驗證封裝、全新安裝、啟動、升級和回復。
- 針對該精確產物完成發布說明、第三方聲明、隱私邊界和散布授權複核。
- 最後由單獨的明確發布決定授權發布；原始碼合併或 CI 成功本身不代表授權發布。

## 目前主線 — iOS 已上架維護與 Access 驗收

iPhone 與 iPad 的 App Store 1.0.0 已公開，外部 Beta 走 [TestFlight](https://testflight.apple.com/join/EwUW1VDx)。原生應用程式是 SwiftUI/WKWebView，具備一般/私密設定檔隔離、內嵌 Safari/Share extensions、AgentKit 與 Simulator 基線。目前 iOS 工作維護這條已發布線，並在真機上驗收 Access。這不是重寫，也不是第一次上架。

Access 驗收順序：先收 [#157](https://github.com/gcsagroup/aegis-browser/issues/157) 與 [#158](https://github.com/gcsagroup/aegis-browser/issues/158)，再做 [#136](https://github.com/gcsagroup/aegis-browser/issues/136) 與 [#155](https://github.com/gcsagroup/aegis-browser/issues/155) 的網頁取證，然後是 iPhone [#137](https://github.com/gcsagroup/aegis-browser/issues/137)、[#160](https://github.com/gcsagroup/aegis-browser/issues/160)、[#138](https://github.com/gcsagroup/aegis-browser/issues/138)。下面的 IOS-3 是後續商店候選的門檻。1.0.0 已上架並不關閉這些 Access 工單；原始碼就緒也不授權下一次提交。

### IOS-1 — 目前原始碼真機基線

**目標：** 將現有原生產品綁定到目前已提交原始碼，並突破 Simulator-only 證據上限。

完成標準：

- 目前原始碼的 Debug/Release 建置以及 Xcode 工程產生輸入可重現並完成差異審查。
- iPhone 與 iPad 真機上的導覽、私密模式、生命週期、無障礙和代表性站點行為通過。
- Safari extension、Share/App Group 與一般/私密隔離完成真機端到端驗證。

### IOS-2 — 產品完善

**目標：** 補齊真正 iOS 產品所需的隱私、策略和 Agent 鏈路，而不是停留在 Simulator demo。

完成標準：

- PolicyKit 保護涵蓋預期真實導覽/出站路徑，並有隱私回歸測試。
- Agent 授權、同意、復原與內嵌擴充功能邊界在真機完成驗證。
- 生產模型路由、真實站點以及任何新增網路/下載能力均經過明確的安全與隱私審查。

### IOS-3 — 散布

**目標：** 讓 Aegis 具備 TestFlight 與 App Store 交付條件。

完成標準：

- 所需 entitlement、Development Team 與 provisioning 設定獲批且可重現。
- 精確候選完成正式簽署與 Archive。
- 完成 TestFlight 安裝/升級、Privacy Manifest、App Store 隱私中繼資料和必要合規材料。
- App Store 提交仍是單獨的發布決定，不由原始碼完成狀態自動觸發。

## Windows 與後續平台

同事負責 Windows 軌道：[#170](https://github.com/gcsagroup/aegis-browser/issues/170) 的原始碼對齊，以及 [#182](https://github.com/gcsagroup/aegis-browser/issues/182) 的原生建置、測試和 runner 驗收。按 [2026-11-18 的決定](https://github.com/gcsagroup/aegis-browser/issues/182#issuecomment-6977894606)，Windows runner 准入、GN、編譯、原生測試、瀏覽器和安裝器驗收繼續暫停，待同事恢復授權執行。本路線圖只記錄這一歸屬。不把 Windows 工作排進 iOS 或 macOS 軌道，也不把 Windows 寫成已具備發布資格。

Android 與 Linux 仍是後續評估。現有原始碼和手動入口保留。它們不阻塞 iOS 維護或 macOS 發布資格，目前也不承諾發布日期。

## 跨平台持續工作

以下工作貫穿整個 Roadmap：

- 共享策略與 Agent Contract 相容性；
- CI、測試證據和原始碼身分完整性；
- 安全審查、相依套件與授權維護；
- 明確區分原始碼狀態、測試證據與發布聲明的文件。

歷史補丁數量、舊測試總數和附日期的驗收結果繼續保留在[稽核紀錄](audit/README.zh-TW.md)中，不再作為不斷變化的 Roadmap 里程碑。

## 發布規則

每個平台獨立獲得發布資格。任意發布候選都必須讓建置、執行、隱私、簽署、安裝和散布審查指向**同一份精確原始碼和產物**。一個平台通過永遠不會自動授予另一個平台發布狀態。
