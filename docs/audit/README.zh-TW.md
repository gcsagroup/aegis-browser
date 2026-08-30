# 稽核記錄

[English](README.md) | [简体中文](README.zh-CN.md) | **繁體中文**

這裡保存按日期形成的階段性工程記錄。每份檔案只代表撰寫時的證據與發佈邊界，不是即時發佈狀態頁；目前原始碼與建置關係應以[路線圖](../roadmap.zh-TW.md)、新執行的 `pnpm run browser:status`，以及最新的 [iOS 強化記錄](ios-simulator-hardening-2026-08-28.md)和重新執行的 Simulator 測試為準。

## 目前邊界

- 目前本機原型分支包含 68 個頂層 Chromium 修補程式和 2 個巢狀 V8 修補程式；在明確整合前，已發布 `main` 仍為 67 個頂層補丁。
- 57 補丁診斷清單和 65 補丁 Agent 驗收保留為歷史快照，均不綁定本機 68 補丁原型 HEAD，也不能為它授予資格。
- Android、受信任建置證明、產品身分、簽署/公證、安裝驗收和完整對外連線稽核仍是未關閉門檻。
- Script-risk、MinerGuard 與 bytecode shadow 仍屬於研究或僅觀察能力，不能授權阻擋或發佈聲明。
- 研究語料必須分開：Phase 2 是 synthetic formal fixture；Phase 3 是 13 樣本 operator-blinded public pilot，召回率為 `1/3`。兩者都不能泛化。
- iOS 證據僅涵蓋 Simulator；真機 Safari/Share 權限、預設瀏覽器 entitlement、Archive、正式簽署、TestFlight、App Store 和發布資格仍是 No-Go 門檻。

## 記錄

- [實作前基線](baseline-2026-08-24.md)
- [本機實作進度](implementation-progress-2026-08-24.md)
- [CPU 與研究最佳化](cpu-and-research-optimization-2026-08-25.md)
- [網路釣魚偵測差距與路線圖](phishing-detection-gap-and-roadmap-2026-08-25.md)
- [JavaScript 反指紋強化](js-fingerprint-hardening-2026-08-26.md)
- [JavaScript 分析與 MinerGuard](js-miner-guard-2026-08-27.md)
- [建置身分與簽署](js-build-identity-and-signing-2026-08-27.md)
- [指令碼防護第二階段研究](js-protection-research-phase2-2026-08-27.md)
- [指令碼防護第三階段研究](js-protection-research-phase3-2026-08-28.md)
- [iOS Simulator 資格驗收（歷史基線）](ios-simulator-qualification-2026-08-28.md)
- [iOS Simulator 強化驗收（目前本機複驗）](ios-simulator-hardening-2026-08-28.md)
- [Aegis Browser Agent v1 M0 基線](aegis-agent-m0-baseline-2026-08-28.md)
- [Aegis Browser Agent v1 本機驗收](aegis-browser-agent-v1-acceptance-2026-08-29.md)
- [Aegis Browser Agent v1 安全修復驗證](aegis-browser-agent-v1-security-fix-verification-2026-08-29.md)
- [Aegis Browser Agent v2 M0 基線與第三方稽核](aegis-browser-agent-v2-m0-baseline-2026-08-30.md)
- [Aegis Browser Agent v2 P0 Playwright MCP 基線](aegis-browser-agent-v2-p0-playwright-mcp-2026-08-30.md)
- [Aegis Browser Agent v2 P1/P2 前置報告](aegis-browser-agent-v2-p1-p2-preflight-2026-08-30.md)
- [Aegis Browser Agent v2 P3/P4 前置報告](aegis-browser-agent-v2-p3-p4-preflight-2026-08-30.md)
- [Aegis Browser Agent v2 M2 模型原型結果](aegis-browser-agent-v2-m2-model-results-2026-08-30.md)
- [Aegis Browser Agent v2 M4 Go/No-Go 決策](aegis-browser-agent-v2-m4-go-no-go-2026-08-30.md)

日期化原始記錄保留簡體中文單一事實來源，避免多份證據譯本逐漸不一致。本三語索引只概括範圍；重用雜湊、數量或結論前，必須查看原始記錄並重新驗證。
