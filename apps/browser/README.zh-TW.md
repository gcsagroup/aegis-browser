[English](./README.md) | [简体中文](./README.zh-CN.md) | [**繁體中文**](./README.zh-TW.md)

# GCSA-aegis Browser

GCSA-aegis Browser 是把隱私與安全能力直接整合到瀏覽器層和引擎層的 Chromium fork。它不是 Electron 外殼，也不把擴充功能當成產品本體。

策略邏輯以 `packages/core` 為來源，透過產生的規則快照、內嵌 policy worker、Chromium browser service，以及 Blink/V8 接入點落地。

目前候選為 Ver 2.0 (057)，Chromium 153.0.8010.53，198 個 Chromium 補丁及 3 個 V8 補丁；固定 macOS App 已安裝核驗。535 項原生回歸通過，集中任務驗收為 75/90（另有 2 失敗、9 前置阻塞、4 證據不足），未達到 90% 門檻。安全 100 情境、輸入與效能、三語及發行限制分別記錄，不能合稱整體通過。見[四組收尾與統一驗收](../../docs/audit/integration-final-batch-2026-09-22.zh-CN.md)。

## 历史基线（2026-09-16）

Ver 1.1 (044)的已验收基线为153.0.8010.37，包含140个Chromium补丁与3个V8补丁。完整重放树为`6f6294dfabbb9bfcf69a5a612bad3b2c41334ce5`。Ver 1.1 (044)在固定macOS测试App完成211项原生回归及版本、设置、摘要、Agent、原生下载、无痕和冷重启验收。

[044本地验收](../../docs/audit/m1-local-acceptance-044-2026-09-16.zh-CN.md)列明源码、清单、签名、恢复与限制；[9月10日记录](../../docs/audit/main-consolidation-2026-09-10.md)只保留为历史。当时完整90/100评测及M2/M3尚未完成；最新候选状态见上文。Android/Windows当前版本实机和公开发行仍未验收。

## Chromium 固定基線

| 檔案 | 含義 |
|---|---|
| [CHROMIUM_VERSION](./CHROMIUM_VERSION) | 固定的 Mac Stable 版本，目前為 `153.0.8010.53` |
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
export CHROMIUM_ROOT="$HOME/Projects/GCSA-aegis-build/macos"
```

也可把 Chromium 根目錄寫入已被 Git 忽略的 `apps/browser/.chromium-root`。

平台工作區統一放在同級 `GCSA-aegis-build` 中，分別為 `macos`、`android` 和既有共享原始碼的 `shared/chromium`。下列命令描述首次建置環境；既有的 Mac 連結工作樹如果沒有獨立 `.gclient`，不要重新 fetch。共享相依套件更新明確選擇 `shared/chromium`，Android 操作明確選擇 `android`。固定驗收 App 路徑與歷史證據保留，移動原始碼目錄不等於重新建置或發布。

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

- 列入 Chromium 序列的 152 個頂層補丁（含尚待驗收的M2候選）。
- 3 個套用在巢狀 V8 checkout 中的補丁。
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

044本地候选的140/3补丁重放、211项原生回归及关键实机验收已通过；这不替代完整任务/安全评测、跨平台实机、正式发行签名、公证和发布决定。

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
