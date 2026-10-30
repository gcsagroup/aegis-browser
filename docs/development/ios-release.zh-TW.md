# iOS 封裝與 TestFlight

Alpha 固定僅供內部測試，原生匯出開啟 `testFlightInternalTestingOnly`，上傳後必須讀回 `INTERNAL_ONLY`。Beta 可供內外測試，禁止正式送審。Release 可用於各目的地，每個階段均明確選擇。上傳不會自動送審或公開發佈。

使用乾淨且已提交的原始碼、Ruby 3.3.6、鎖定的 Fastlane、Node 22.23.1、Python 3.11+ 與 Xcode。執行 `bundle install`，以 `./release ios plan` 讀取來源 SHA/tree 與原生輸入摘要。所有變更均需明確指定 `--profile`。

```sh
./release ios package --profile alpha --version 1.0.0 --build 6 --run-id ios-alpha-6
./release ios upload --profile alpha --version 1.0.0 --build 6 --run-id ios-alpha-6 --destination testflight --manifest-sha256 MANIFEST_SHA256
./release ios wait --profile alpha --version 1.0.0 --build 6 --destination testflight
./release ios status --profile alpha --version 1.0.0 --build 6 --destination testflight
```

範例編號僅供示意，實際先查 ASC，再選未使用的 build。`compliance`、`metadata`、`distribute` 必須保留原始 manifest 摘要、run ID 與完成的上傳記錄，重用同一產物。合規 JSON 需有明確布林答案、來源 SHA、原生輸入摘要及授權說明；中繼資料 JSON 僅允許語言別的 `description`／`whatsNew`，保留回饋聯絡資訊及其他語言。不匯出私鑰，不改共用鑰匙圈 ACL，憑證資料不得進入參數、Git 或公開證據。

Actions 的封裝與上傳統一使用 **iOS Delivery**；獨立保留 **iOS Release Validation** 自動無憑證驗證與 **iOS Coverage** 模擬器覆蓋率。手動執行三個 iOS 工作流程均要求實際倉庫 Admin 權限（包含組織所有者授予的 Admin），原發起者和重跑者都必須通過驗證。Maintain/Write/Read 和權限未知均在受保護作業排隊前拒絕；GitHub 原生介面仍可能向 Write 顯示執行按鈕。本地流程驗證真實 token 使用者，runner 在簽章探測前驗證真實 CLI Admin。fork 交付入口維持停用。

表單精簡為 7 項：`operation`、`profile`、`version`、`build`、`source`、`groups`、`stage_input`。新封裝通常只填版本與未使用的 build，預設產生 Alpha 產物；Beta/Release 明確選擇。後續操作選擇 operation，將上次成功執行 Summary 的整行**交付憑據**貼入 `source`；profile 保持 `auto`、版本與 build 留空，便會沿用原產物身分。

`package` 只封裝；`draft` 封裝至私有 Draft，依版本／包型／build 推導並核對精確已有 Tag；`upload` 上傳原 IPA 至 TF；`wait`／`status` 等待／查詢；`metadata` 更新已確認描述；`compliance` 寫入已授權合規答案；`distribute-internal`／`distribute-external` 明確選擇內測／外測並填現有 `groups`。Alpha 禁止外測。只有 metadata/compliance 需要 `stage_input` JSON。

交付憑據保留包型、版本、build、原封裝 run、最新狀態 run、精確 attempt 與獨立固定的 manifest 摘要。憑據不提供權限，也不取代來源、成功生產者、完整性或防重複檢查。每次等待整次執行成功，再用最新 Summary 憑據；結果未知先讀回對帳，不可重傳。推送 `candidate/ios/版本-profile.build` 仍只封裝至私有 Draft，不自動上傳 TF，正常 Draft 優先使用 Tag 觸發。先驗證來源與產物，再載入 ASC 憑證；外測 Beta Review 與正式送審仍須獨立授權。

上游合併前通過必需 CI；合併後追蹤新 main CI，重新測試本地 Fastlane、Actions、Tag→私有 Draft 三種方法及 Alpha/Beta/Release 三種封裝，下載驗證每份產物並讀回 TF 結果。外測 Beta Review 與正式送審不在自動驗收中執行。上游通過後僅停用 fork 的 iOS 入口，保留歷史與回復快照，不影響其他平台。完整設定、JSON 範例及復原步驟見 [iOS operations](ios-release.md)。

目前已驗證的 Apple 系統加密實作，在實際 Info.plist 中宣告布林值 `ITSAppUsesNonExemptEncryption=false`；匯出驗證會比對簽章 App 的同一宣告。加密實作或依賴變更後必須重新評估，歷史 IPA 維持原樣。驗收先讀回 TF 自動識別的 `usesNonExemptEncryption=false`，再考慮明確的合規更新。

候选 Tag 还需独立于工作流代码的仓库保护：[限定规则](../../.github/ios-candidate-admin-ruleset.json) 仅覆盖 `refs/tags/candidate/ios/**/*`，创建、更新、删除只允许仓库 Admin。先以 disabled 准备，通过 GraphQL 确认 role ID5 的 `repositoryRoleName=admin`，再启用并用真实 Admin token 执行 `node scripts/ci/ios-operator.mjs --verify-candidate-tag-policy`。不扩大绕过角色或 Tag 范围。交付权限边界以通过合并流程的 main 代码可信为前提，共享 main 审核治理不在此次 iOS 改动中。
