[English](./README.md) | [简体中文](./README.zh-CN.md) | [**繁體中文**](./README.zh-TW.md)

# GCSA-aegis Browser

GCSA-aegis Browser 是把隱私與安全能力直接整合到瀏覽器層和引擎層的 Chromium fork。它不是 Electron 外殼，也不把擴充功能當成產品本體。

策略邏輯以 `packages/core` 為來源，透過產生的規則快照、內嵌 policy worker、Chromium browser service，以及 Blink/V8 接入點落地。

## 目前狀態

- 目前原始碼已合併至 `main`。108個Chromium補丁從固定基線完整重放後得到原始碼樹 `319366182c31108e29e62d2f2199aff29a0b86e8`；[9月10日合併記錄](../../docs/audit/main-consolidation-2026-09-10.md)分別列出原始碼驗證與尚未完成的平台驗收。

- Browser Agent v2 候選原始碼列出 **108 個頂層 Chromium 補丁**和 **2 個巢狀 V8 補丁**。補丁 0079–0095 精確重放到 `c930fa41ef7e9522f145848f3080ee0cc1edc4d8`；補丁 0096 重放到 `f8dff6e3a5dd02527c093b57cde78fc4b0dcb34f`；補丁 0097 產生 `a3040bb0dea05e87c2a141b9a29a237a96953620`；補丁 0098 產生 `911f5c45acf3de10741008cf8f40948d57d31b7a`；補丁 0099 產生 `54f2d8dcf03ecf53b074b4919769ea652fdf5ab5`（tree `915676bbfbd340b8b8feb15aecacc70dfd53861b`）；補丁 0100 產生 `44b79c59cf594b83af5c181842a57c2604d209ed`（tree `b8285fda53d21dff5ee56c39be1455ad3e5c3c82`）；補丁 0101 產生 `1c63ce994b2815fe1f3dc07608ff121d987e0441`（tree `451b3148d12fc2cff2df293cb0f1bb0d6242a908`）；補丁 0102 產生已提交原始碼 `13807aaf086948bdff0370e356718d0c2ac54d27`（tree `4546f1afcabf38013ba9bef7e9e5d078ffd3ca77`）。
- 57、65、67、95 和 97 補丁記錄保留為歷史快照，不能為 108 補丁成品授予資格。
- macOS 原生與瀏覽器測試已在候選原始碼上通過；仍需精確平台清單和最終 UI 驗收。目前沒有正式產品簽署、公證、安裝或已發布的桌面發行版。
- Android 和 Windows 候選正在驗證；完成實機/主機記錄前，不接受任何 APK、AAB 或 Windows 安裝套件。

因此，儲存庫目前沒有可發布的桌面或 Android 產物。

## Chromium 固定基線

| 檔案 | 含義 |
|---|---|
| [CHROMIUM_VERSION](./CHROMIUM_VERSION) | 固定的 Mac Stable 版本，目前為 `151.0.7922.77` |
| [CHROMIUM_COMMIT](./CHROMIUM_COMMIT) | 補丁所基於的精確 Chromium commit |

此版本是固定快照，不會自動跟隨更新的 Stable 版本。

## 文件

- [Fork 架構](./docs/fork-architecture.zh-TW.md)
- [Android 建置與驗收狀態](./docs/android.zh-TW.md)
- [Play Store 準備草案](./docs/play-store.zh-TW.md)

- [Overlay 同步規則](./docs/overlay.zh-TW.md)
- [Chromium 目錄配置](./docs/tree-layout.zh-TW.md)
- [補丁維護說明](./patches/README.zh-TW.md)

實際操作以 `patches/series`、`patches/v8/series` 和 `scripts/` 下的腳本為準。歷史狀態記錄不能取代目前重放、建置或執行驗證。

## 儲存庫配置

```text
apps/browser/
  args/                 GN 設定
  overlay/              預期的整合原始碼
  patches/series        有序 Chromium 補丁清單
  patches/v8/series     有序巢狀 V8 補丁清單
  scripts/              擷取、重放、建置、執行、驗證和封裝工具
  docs/                 公開與開發文件
```

Chromium 原始碼放在本儲存庫之外。典型本機設定為：

```bash
export REPO_ROOT="$HOME/Projects/GCSA-aegis"
export CHROMIUM_ROOT="$HOME/Projects/GCSA-aegis-chromium"
```

也可把 Chromium 根目錄寫入已被 Git 忽略的 `apps/browser/.chromium-root`。

## 本機流程

以下命令從儲存庫根目錄執行。Bootstrap、fetch、sync 和相依套件下載會存取網路。

```bash
# 準備 depot_tools。
pnpm --filter @gcsa-aegis/browser bootstrap

# 擷取固定 Chromium 原始碼，需要數十 GB 空間。
pnpm --filter @gcsa-aegis/browser fetch

# 依序重放 Chromium 和巢狀 V8 補丁。
pnpm --filter @gcsa-aegis/browser apply-patches

# 準備用於本機 BT 建置的固定 libtorrent 原始碼。
pnpm --filter @gcsa-aegis/browser bootstrap:libtorrent

# 建置並執行 component 開發版。
pnpm --filter @gcsa-aegis/browser build
pnpm --filter @gcsa-aegis/browser run

# 產生 non-component Release build-tree 輸入。
pnpm --filter @gcsa-aegis/browser build:release
pnpm --filter @gcsa-aegis/browser run:release

# 檢查 checkout、補丁、overlay 和輸出狀態。
pnpm --filter @gcsa-aegis/browser status

# 執行儲存庫和 Browser 指令碼門禁。
pnpm run quality:fast
pnpm --filter @gcsa-aegis/browser test:scripts

# 選用：預檢無金鑰本機模型的 Agent 原生工具呼叫協定。
node apps/browser/scripts/verify-agent-local-model.mjs \
  --base-url http://127.0.0.1:8000/v1 --model MODEL --rounds 2
```

本機模型預檢不會保存完整提示詞或原始回應。它會重複檢查模型探索、目標路由、計畫和執行
呼叫，但不能取代在真實瀏覽器裡的端到端執行。

Windows 介面驗收使用共享的 [驗收腳本](./scripts/windows-agent-ui-acceptance.ps1)，不要繼續維護伺服器上的獨立副本。
執行前先執行 [腳本自測](./scripts/windows-agent-ui-acceptance_test.ps1)，傳入 Windows Node 的 `-NodePath` 和全新的 `-EvidenceDir`；
此自測只驗證啟動參數與視窗輔助程式碼編譯，不算介面通過。實際驗收須在已解鎖桌面執行，不能自動批准其他程式的防火牆彈窗。

常用輸出目錄：

- `$CHROMIUM_ROOT/src/out/AegisLocalDev`：component 開發輸出。
- `$CHROMIUM_ROOT/src/out/AegisRelease`：non-component Release build-tree 輸入。
- `apps/browser/dist`：僅在身分和發布門禁通過後產生的封裝輸出。

建置成功不會自動把產物升級為 RC 或發行版。

## 補丁與 Overlay 模型

`overlay/` 保存預期的 Aegis 整合原始碼。它既不是獨立產品，也不是已套用原始碼的唯一事實來源。變更必須匯出到有序補丁序列，並在精確固定的 Chromium 基線上重新重放。

目前原始碼口徑：

- 列入 Chromium 序列的 108 個頂層補丁。
- 2 個套用在巢狀 V8 checkout 中的補丁。
- 57、65、67、95 和 97 補丁身分屬於歷史記錄，不涵蓋目前 v2 候選。
- 補丁 0079–0095 已在先前驗證的 78 補丁原始碼樹上透過隔離索引精確重放；補丁 0096 獨立產生精確的 96 補丁原始碼樹；補丁 0097 產生精確的 97 補丁原始碼樹；補丁 0098 產生精確的 98 補丁原始碼樹 `7069e2b065466bbab3e3007e5866a3790e85ed47`；補丁 0099 產生精確的 99 補丁原始碼樹 `915676bbfbd340b8b8feb15aecacc70dfd53861b`；補丁 0100 產生精確的 100 補丁原始碼樹 `b8285fda53d21dff5ee56c39be1455ad3e5c3c82`；補丁 0101 產生精確的 101 補丁原始碼樹 `451b3148d12fc2cff2df293cb0f1bb0d6242a908`；補丁 0102 產生精確的 102 補丁原始碼樹 `4546f1afcabf38013ba9bef7e9e5d078ffd3ca77`。成品身分和執行資格仍按平台分別判定。

「已列入 series」只表示補丁檔案存在，不證明重放、可重現建置、平台驗收、簽署、封裝或發布已經完成。

## 產品邊界

目前桌面原始碼包括：

- tracker、連結、Cookie、bounce 和釣魚防護；
- 針對部分 Canvas、Audio、WebGL、WebGPU 表面的 Blink 指紋擾動；
- 原生 HTTP(S)、Metalink、Torrent 和 Magnet 下載；
- 本機啟發式摘要，以及使用者設定的 OpenAI、Claude（Anthropic）或 Gemini 相容 API；
- Browser Agent v2：包含模型優先目標路由、可見計畫、瀏覽器掌控的執行/觀察/驗證循環、常用任務按鈕、定時自動化、有範圍約束的書籤/URL/頁面/下載工具、精確核准，以及最終購買前的強制使用者接管；
- 僅觀察的 MinerGuard 訊號；以及
- 預設關閉、需明確啟用的 V8 bytecode-shadow 研究路徑。

必須保留以下邊界：

- MinerGuard 只觀察和回報，不會停止指令碼、Worker 或網路連線。
- 指紋擾動只降低部分穩定表面，不能讓瀏覽器「不可識別」。
- 遠端摘要需使用者確認，並先在 browser 側去識別化。允許 HTTPS；明文 HTTP 僅允許數值 loopback 位址。
- API Key 可選，透過作業系統加密保存在目前瀏覽器設定中，不回顯明文。
- v2 原始碼已實作 Android 頁面擷取和目前頁面綁定；是否執行合格取決於目前 APK 的實機驗收。

下載功能位於 Chromium 原生 `chrome://downloads` 和 `chrome://settings/downloads`。影片擷取、媒體轉換、FFmpeg 和預裝下載擴充功能不屬於產品範圍。

## 發布邊界

桌面發布前，同一候選必須完成：

1. 從固定基線乾淨重放；
2. 清單綁定根儲存庫 commit、Chromium commit、兩套補丁序列、GN 參數和產物雜湊；
3. 受影響的原生、指令碼和執行測試通過；
4. 產品身分、簽署、公證與封裝；
5. 代表系統上的全新安裝和升級驗收；以及
6. 明確的發布決定。

108個Chromium補丁和2個V8補丁均通過從固定基線開始的完整隔離索引重放。最近的本機macOS候選已有527項原生測試結果；本次原始碼提交未重新建置或發布App、APK與Windows套件。最終Qwen輸出、安裝產物驗收、正式簽署和公證仍是獨立門檻。

## Android

Android 與桌面共用固定 Chromium 基線，並從乾淨的 x86-64 Linux checkout 建置。只有完成 APK 精確身分和實機執行記錄後才可接受該建置；macOS 和 Windows 不能作為 Chromium Android 建置主機。

請參閱 [Android 建置與驗收狀態](./docs/android.zh-TW.md) 和 [Play Store 準備草案](./docs/play-store.zh-TW.md)。以下是建置入口，本身不構成驗收證據：

```bash
pnpm --filter @gcsa-aegis/browser build:android
pnpm --filter @gcsa-aegis/browser package:android
```

## 網路邊界

本機檢查、補丁重放和多數儲存庫測試不需要 GitHub。Bootstrap、fetch、sync、EasyList 更新和缺少的 Chromium 相依套件可能存取外部服務；執行中的 Chromium 也可能產生與 Git 操作無關的網路流量。

使用網路、簽署、封裝或發布憑證前，必須再次確認精確命令和候選身分。

### 瀏覽器自身更新

「關於 GCSA Aegis」檢查 GitHub 正式版本，自動下載符合平台的安裝套件並校驗，安裝需手動完成。見[更新流程](../../docs/github-browser-updates.zh-CN.md)及[Ver 1.1 (018) 本機驗收](../../docs/ui-copy-acceptance.zh-CN.md)。
