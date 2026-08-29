[English](./overlay.md) | [简体中文](./overlay.zh-CN.md) | [**繁體中文**](./overlay.zh-TW.md)

# Overlay 原始碼與補丁同步規則

`overlay/` 保存 Browser 整合層的預期原始碼。它不是可獨立執行的產品，也不能只修改這裡而不更新 Chromium 補丁序列。

本機開發流程是：先在固定 Chromium base 上重放 `patches/series`，再把本次 overlay 差異同步到本機 Chromium 開發分支，編譯並測試，最後把通過的本機提交匯出為新的順序補丁。舊補丁不在原處改寫；`status` 必須同時驗證 patch-id、checkout 和 overlay 一致性。

目前階段禁止 fetch、push 或使用 GitHub。完整目錄邊界見 [tree-layout.zh-TW.md](./tree-layout.zh-TW.md)。
