// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/summary_policy.h

#ifndef CHROME_BROWSER_AEGIS_SUMMARY_POLICY_H_
#define CHROME_BROWSER_AEGIS_SUMMARY_POLICY_H_

#include <optional>
#include <string>
#include <vector>

namespace aegis {

struct PageSnapshot;

inline constexpr int kPreparedSummarySchemaVersion = 1;

// renderer 只能提交脱敏后的结构化字段，不能提交 system/user prompt。
struct SanitizedPageSnapshot {
  std::string url;
  std::string title;
  std::string text_sample;
  int password_fields = 0;
  int forms = 0;
};

struct PreparedSummary {
  int schema_version = 0;
  SanitizedPageSnapshot snapshot;
  std::string summary;
  std::vector<std::string> bullets;
  std::vector<std::string> risks;
};

struct ModelPrompt {
  std::string system;
  std::string user;
};

// browser 进程在调用任意兼容模型 API 前执行的强制策略。本机 loopback
// 也不能绕过敏感页的启发式摘要边界。拒绝时 reason 包含可展示的原因。
bool IsModelSummaryAllowed(const PageSnapshot& snapshot, std::string* reason);

// 在 browser 进程内生成仅含脱敏字段的摘要输入和本机启发式结果。任何返回值
// 都已经通过 ValidatePreparedSummary；失败时返回 nullopt 并填写 error。
std::optional<PreparedSummary> PrepareSummaryForBrowser(
    const PageSnapshot& original,
    const std::string& locale,
    std::string* error = nullptr);

// 校验 renderer 返回的安全快照与本地启发式结果。失败时不应 Probe 或
// 调用任何兼容模型 API。
bool ValidatePreparedSummary(const PageSnapshot& original,
                             const PreparedSummary& prepared,
                             std::string* error);

// 使用 browser 内固定模板构造 prompt，并在返回前执行最终二次校验。
std::optional<ModelPrompt> BuildValidatedModelPrompt(
    const PageSnapshot& original,
    const PreparedSummary& prepared,
    const std::string& locale,
    std::string* error);

// 对即将发往兼容模型 API 的完整 prompt 做一致性和敏感值复核。
bool ValidateOutboundPrompt(const PageSnapshot& original,
                            const PreparedSummary& prepared,
                            const std::string& locale,
                            const ModelPrompt& prompt,
                            std::string* error);

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_SUMMARY_POLICY_H_
