// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/summary_policy.cc

#include "chrome/browser/aegis/summary_policy.h"

#include <algorithm>
#include <cstddef>
#include <string_view>
#include <utility>

#include "base/no_destructor.h"
#include "base/strings/escape.h"
#include "base/strings/string_util.h"
#include "chrome/browser/aegis/aegis_service.h"
#include "net/base/url_util.h"
#include "third_party/re2/src/re2/re2.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace aegis {
namespace {

constexpr size_t kMaxSourceUrlBytes = 8192;
constexpr size_t kMaxSourceTitleBytes = 4096;
constexpr size_t kMaxSourceTextBytes = 64 * 1024;
constexpr size_t kMaxSanitizedUrlBytes = 2048;
constexpr size_t kMaxSanitizedTitleBytes = 512;
constexpr size_t kMaxSanitizedTextBytes = 6000;
constexpr size_t kMaxHeuristicSummaryBytes = 2048;
constexpr size_t kMaxHeuristicItemBytes = 1024;
constexpr size_t kMaxHeuristicItems = 8;
constexpr size_t kMaxHeuristicTotalBytes = 12 * 1024;
constexpr size_t kMaxSystemPromptBytes = 2048;
constexpr size_t kMaxUserPromptBytes = 16 * 1024;
constexpr int kMaxPageFieldCount = 1'000'000;
constexpr size_t kMaxQueryItems = 64;
constexpr std::string_view kRedactedValue = "[REDACTED]";
constexpr std::string_view kSensitiveHostLabelMarkers[] = {
    "bank", "paypal",     "alipay",   "gov",
    "irs",  "healthcare", "hospital", "clinic",
};

bool Reject(std::string* error, std::string_view reason) {
  if (error) {
    *error = reason;
  }
  return false;
}

bool HasUnsafeControlCharacter(std::string_view value) {
  return std::ranges::any_of(value, [](unsigned char ch) {
    return ch < 0x20 && ch != '\t' && ch != '\n' && ch != '\r';
  });
}

bool ValidateUtf8Field(std::string_view value,
                       size_t max_bytes,
                       bool allow_empty,
                       std::string_view field,
                       std::string* error) {
  if ((!allow_empty && value.empty()) || value.size() > max_bytes) {
    return Reject(error, std::string(field) + " length invalid");
  }
  if (!base::IsStringUTF8(value)) {
    return Reject(error, std::string(field) + " must be valid UTF-8");
  }
  if (HasUnsafeControlCharacter(value)) {
    return Reject(error, std::string(field) + " contains control character");
  }
  return true;
}

const re2::RE2& EmailPattern() {
  static const base::NoDestructor<re2::RE2> pattern(
      R"re(((?i:[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,})))re");
  return *pattern;
}

const re2::RE2& BearerPattern() {
  static const base::NoDestructor<re2::RE2> pattern(
      R"re(((?i:bearer[ \t]+[A-Z0-9._~+/\-]{8,}={0,2})))re");
  return *pattern;
}

const re2::RE2& JwtPattern() {
  static const base::NoDestructor<re2::RE2> pattern(
      R"re(((?i:eyJ[A-Z0-9_\-]{5,}\.[A-Z0-9_\-]{5,}\.[A-Z0-9_\-]{5,})))re");
  return *pattern;
}

const re2::RE2& AwsKeyPattern() {
  static const base::NoDestructor<re2::RE2> pattern(
      R"re((AKIA[0-9A-Z]{16}))re");
  return *pattern;
}

const re2::RE2& LabelledSecretPattern() {
  static const base::NoDestructor<re2::RE2> pattern(
      R"re((?i:(?:api[_\-]?key|access[_\-]?token|refresh[_\-]?token|authorization|auth|secret|password|passwd|token)[ \t]*[:=][ \t]*(?:bearer[ \t]+)?["']?([A-Z0-9._~+/\-]{8,}={0,2})["']?))re");
  return *pattern;
}

const re2::RE2& ChinaPhonePattern() {
  static const base::NoDestructor<re2::RE2> pattern(
      R"re((?:^|[^0-9])((?:\+?86[ \t\-]?)?1[3-9][0-9]{9})(?:$|[^0-9]))re");
  return *pattern;
}

const re2::RE2& NorthAmericaPhonePattern() {
  static const base::NoDestructor<re2::RE2> pattern(
      R"re((?:^|[^0-9])((?:\+?1[. \t\-]?)?\(?[0-9]{3}\)?[. \t\-]?[0-9]{3}[. \t\-]?[0-9]{4})(?:$|[^0-9]))re");
  return *pattern;
}

const re2::RE2& ChinaIdPattern() {
  static const base::NoDestructor<re2::RE2> pattern(
      R"re((?:^|[^0-9])([1-9][0-9]{5}(?:19|20)[0-9]{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12][0-9]|3[01])[0-9]{3}[0-9Xx])(?:$|[^0-9]))re");
  return *pattern;
}

const re2::RE2& SsnPattern() {
  static const base::NoDestructor<re2::RE2> pattern(
      R"re((?:^|[^0-9])([0-9]{3}-[0-9]{2}-[0-9]{4})(?:$|[^0-9]))re");
  return *pattern;
}

const re2::RE2& CreditCardPattern() {
  static const base::NoDestructor<re2::RE2> pattern(
      R"re((?:^|[^0-9])([0-9](?:[ \-]*[0-9]){12,18})(?:$|[^0-9]))re");
  return *pattern;
}

const re2::RE2& AddressHintPattern() {
  static const base::NoDestructor<re2::RE2> pattern(
      R"re((?:^|[^A-Z0-9_\x{4E00}-\x{9FFF}])((?i:[0-9]{1,5}[ \t]+[A-Z0-9_.\x{4E00}-\x{9FFF}]+(?:[ \t]+[A-Z0-9_.\x{4E00}-\x{9FFF}]+){0,4}[ \t]+(?:street|st|road|rd|ave|avenue|blvd|lane|ln|drive|dr|路|街|巷|号)))(?:$|[^A-Z0-9_\x{4E00}-\x{9FFF}]))re");
  return *pattern;
}

bool LuhnValid(std::string_view value) {
  int sum = 0;
  bool double_digit = false;
  int digit_count = 0;
  for (auto it = value.rbegin(); it != value.rend(); ++it) {
    if (*it == ' ' || *it == '-') {
      continue;
    }
    if (*it < '0' || *it > '9') {
      return false;
    }
    int digit = *it - '0';
    if (double_digit) {
      digit *= 2;
      if (digit > 9) {
        digit -= 9;
      }
    }
    sum += digit;
    double_digit = !double_digit;
    ++digit_count;
  }
  return digit_count >= 13 && digit_count <= 19 && sum % 10 == 0;
}

void AddUnique(std::string value, std::vector<std::string>* values) {
  if (value.empty() || std::ranges::find(*values, value) != values->end()) {
    return;
  }
  values->push_back(std::move(value));
}

void CollectMatches(std::string_view text,
                    const re2::RE2& pattern,
                    bool require_luhn,
                    std::vector<std::string>* values) {
  re2::StringPiece remaining(text);
  std::string match;
  while (re2::RE2::FindAndConsume(&remaining, pattern, &match)) {
    if (!require_luhn || LuhnValid(match)) {
      AddUnique(match, values);
    }
  }
}

void CollectRecognizableSensitiveValues(std::string_view text,
                                        std::vector<std::string>* values) {
  CollectMatches(text, EmailPattern(), false, values);
  CollectMatches(text, BearerPattern(), false, values);
  CollectMatches(text, JwtPattern(), false, values);
  CollectMatches(text, AwsKeyPattern(), false, values);
  CollectMatches(text, LabelledSecretPattern(), false, values);
  CollectMatches(text, ChinaPhonePattern(), false, values);
  CollectMatches(text, NorthAmericaPhonePattern(), false, values);
  CollectMatches(text, ChinaIdPattern(), false, values);
  CollectMatches(text, SsnPattern(), false, values);
  CollectMatches(text, CreditCardPattern(), true, values);
  CollectMatches(text, AddressHintPattern(), false, values);
}

bool ContainsRecognizableSensitiveValue(std::string_view text) {
  std::vector<std::string> values;
  CollectRecognizableSensitiveValues(text, &values);
  return !values.empty();
}

bool IsOpaqueUrlSecretCandidate(std::string_view value) {
  return value.size() >= 8 && value != kRedactedValue &&
         value != "[REDACTED_SECRET]";
}

void AddOpaqueUrlCandidate(std::string_view value,
                           std::vector<std::string>* values) {
  if (IsOpaqueUrlSecretCandidate(value)) {
    AddUnique(std::string(value), values);
  }
}

std::vector<std::string> SensitiveValuesFromOriginal(
    const PageSnapshot& original) {
  std::vector<std::string> values;
  CollectRecognizableSensitiveValues(original.url, &values);
  CollectRecognizableSensitiveValues(original.title, &values);
  CollectRecognizableSensitiveValues(original.text_sample, &values);

  const GURL source_url(original.url);
  if (!source_url.is_valid()) {
    return values;
  }
  const std::string decoded_url =
      base::UnescapeBinaryURLComponent(source_url.spec());
  CollectRecognizableSensitiveValues(decoded_url, &values);

  if (source_url.has_username()) {
    const std::string username =
        base::UnescapeBinaryURLComponent(source_url.username());
    AddOpaqueUrlCandidate(username, &values);
  }
  if (source_url.has_password()) {
    const std::string password =
        base::UnescapeBinaryURLComponent(source_url.password());
    AddOpaqueUrlCandidate(password, &values);
  }
  for (net::QueryIterator it(source_url); !it.IsAtEnd(); it.Advance()) {
    AddOpaqueUrlCandidate(it.GetValue(), &values);
    AddOpaqueUrlCandidate(it.GetUnescapedValue(), &values);
  }
  if (source_url.has_ref()) {
    AddOpaqueUrlCandidate(source_url.ref(), &values);
    AddOpaqueUrlCandidate(base::UnescapeBinaryURLComponent(source_url.ref()),
                          &values);
  }
  return values;
}

std::string RedactValues(std::string_view text,
                         std::vector<std::string> values) {
  std::ranges::sort(values,
                    [](const std::string& left, const std::string& right) {
                      return left.size() > right.size();
                    });
  std::string redacted(text);
  for (const std::string& value : values) {
    base::ReplaceSubstringsAfterOffset(&redacted, 0, value, kRedactedValue);
  }
  return redacted;
}

std::string RedactRecognizableValues(std::string_view text) {
  std::vector<std::string> values;
  CollectRecognizableSensitiveValues(text, &values);
  return RedactValues(text, std::move(values));
}

std::string RedactUrlPath(std::string_view path) {
  std::string result;
  size_t start = 0;
  while (start <= path.size()) {
    const size_t separator = path.find('/', start);
    const size_t end =
        separator == std::string_view::npos ? path.size() : separator;
    const std::string decoded =
        base::UnescapeBinaryURLComponent(path.substr(start, end - start));
    const std::string safe =
        base::IsStringUTF8(decoded) && !HasUnsafeControlCharacter(decoded)
            ? RedactRecognizableValues(decoded)
            : std::string(kRedactedValue);
    result.append(base::EscapeAllExceptUnreserved(safe));
    if (separator == std::string_view::npos) {
      break;
    }
    result.push_back('/');
    start = separator + 1;
  }
  return result;
}

std::string RedactQuery(const GURL& source_url) {
  std::string query;
  for (net::QueryIterator it(source_url); !it.IsAtEnd(); it.Advance()) {
    std::string key = base::UnescapeBinaryURLComponent(it.GetKey());
    if (key.empty() || !base::IsStringUTF8(key) ||
        HasUnsafeControlCharacter(key)) {
      key = "redacted";
    } else {
      key = RedactRecognizableValues(key);
      key = std::string(base::TruncateUTF8ToByteSize(key, 256));
    }
    if (!query.empty()) {
      query.push_back('&');
    }
    query.append(base::EscapeQueryParamValue(key, false));
    query.push_back('=');
    query.append(base::EscapeQueryParamValue(kRedactedValue, false));
  }
  return query;
}

std::optional<std::string> RedactUrl(const GURL& source_url) {
  std::string path = RedactUrlPath(source_url.path());
  std::string query = RedactQuery(source_url);
  std::string ref(kRedactedValue);
  GURL::Replacements replacements;
  replacements.ClearUsername();
  replacements.ClearPassword();
  replacements.SetPathStr(path);
  if (query.empty()) {
    replacements.ClearQuery();
  } else {
    replacements.SetQueryStr(query);
  }
  if (source_url.has_ref()) {
    replacements.SetRefStr(ref);
  } else {
    replacements.ClearRef();
  }
  const GURL safe_url = source_url.ReplaceComponents(replacements);
  if (!safe_url.is_valid() || safe_url.spec().size() > kMaxSanitizedUrlBytes) {
    return std::nullopt;
  }
  return safe_url.spec();
}

std::vector<std::string> HeuristicBullets(std::string_view text,
                                          std::string_view locale) {
  constexpr std::string_view kSeparators[] = {".", "。", "!", "！",
                                              "?", "？", "\n"};
  std::vector<std::string> bullets;
  size_t start = 0;
  while (start < text.size() && bullets.size() < 3) {
    size_t end = text.size();
    size_t separator_size = 0;
    for (std::string_view separator : kSeparators) {
      const size_t candidate = text.find(separator, start);
      if (candidate < end) {
        end = candidate;
        separator_size = separator.size();
      }
    }
    std::string item(base::TrimWhitespaceASCII(text.substr(start, end - start),
                                               base::TRIM_ALL));
    if (item.size() > 20) {
      bullets.emplace_back(
          base::TruncateUTF8ToByteSize(item, kMaxHeuristicItemBytes));
    }
    if (end == text.size()) {
      break;
    }
    start = end + separator_size;
  }
  if (!bullets.empty()) {
    return bullets;
  }
  if (locale == "zh-TW") {
    bullets.emplace_back("目前頁面沒有足夠的可讀文字可產生要點。");
  } else if (locale == "zh-CN") {
    bullets.emplace_back("当前页面没有足够的可读文字可生成要点。");
  } else {
    bullets.emplace_back(
        "The current page does not contain enough readable text for key "
        "points.");
  }
  return bullets;
}

bool ContainsOriginalSensitiveValue(
    std::string_view target,
    const std::vector<std::string>& sensitive_values) {
  return std::ranges::any_of(sensitive_values, [&](const std::string& value) {
    return target.find(value) != std::string_view::npos;
  });
}

std::string PreparedPayload(const PreparedSummary& prepared) {
  std::string payload;
  payload.reserve(
      prepared.snapshot.url.size() + prepared.snapshot.title.size() +
      prepared.snapshot.text_sample.size() + prepared.summary.size() + 256);
  payload.append(prepared.snapshot.url).push_back('\n');
  payload.append(base::UnescapeBinaryURLComponent(prepared.snapshot.url))
      .push_back('\n');
  payload.append(prepared.snapshot.title).push_back('\n');
  payload.append(prepared.snapshot.text_sample).push_back('\n');
  payload.append(prepared.summary).push_back('\n');
  for (const std::string& item : prepared.bullets) {
    payload.append(item).push_back('\n');
  }
  for (const std::string& item : prepared.risks) {
    payload.append(item).push_back('\n');
  }
  return payload;
}

bool ValidateSourceSnapshot(const PageSnapshot& original, std::string* error) {
  if (!ValidateUtf8Field(original.url, kMaxSourceUrlBytes, false, "source url",
                         error) ||
      !ValidateUtf8Field(original.title, kMaxSourceTitleBytes, true,
                         "source title", error) ||
      !ValidateUtf8Field(original.text_sample, kMaxSourceTextBytes, true,
                         "source text", error)) {
    return false;
  }
  if (original.forms < 0 || original.forms > kMaxPageFieldCount ||
      original.password_fields < 0 ||
      original.password_fields > kMaxPageFieldCount) {
    return Reject(error, "source field count invalid");
  }
  const GURL source_url(original.url);
  if (!source_url.is_valid() || !source_url.SchemeIsHTTPOrHTTPS() ||
      !source_url.has_host()) {
    return Reject(error, "source URL must be HTTP(S)");
  }
  return true;
}

bool HasSensitiveHostLabel(const GURL& url) {
  const std::string host = base::ToLowerASCII(url.host());
  const std::string_view host_view(host);
  size_t label_start = 0;
  while (label_start < host.size()) {
    const size_t label_end = host.find('.', label_start);
    const std::string_view label = host_view.substr(
        label_start,
        (label_end == std::string::npos ? host.size() : label_end) -
            label_start);
    for (const std::string_view marker : kSensitiveHostLabelMarkers) {
      if (label.find(marker) != std::string_view::npos) {
        return true;
      }
    }
    if (label_end == std::string::npos) {
      break;
    }
    label_start = label_end + 1;
  }
  return false;
}

bool ValidateSanitizedUrl(const PageSnapshot& original,
                          const SanitizedPageSnapshot& snapshot,
                          std::string* error) {
  const GURL source_url(original.url);
  const GURL safe_url(snapshot.url);
  if (!safe_url.is_valid() || !safe_url.SchemeIsHTTPOrHTTPS() ||
      !safe_url.has_host()) {
    return Reject(error, "sanitized URL must be HTTP(S)");
  }
  if (safe_url.has_username() || safe_url.has_password()) {
    return Reject(error, "sanitized URL contains userinfo");
  }
  if (!url::Origin::Create(source_url).IsSameOriginWith(safe_url)) {
    return Reject(error, "sanitized URL origin mismatch");
  }

  size_t query_items = 0;
  for (net::QueryIterator it(safe_url); !it.IsAtEnd(); it.Advance()) {
    ++query_items;
    if (query_items > kMaxQueryItems) {
      return Reject(error, "sanitized URL has too many query items");
    }
    const std::string key = base::UnescapeBinaryURLComponent(it.GetKey());
    if (key.empty() || key.size() > 256 || !base::IsStringUTF8(key) ||
        HasUnsafeControlCharacter(key)) {
      return Reject(error, "sanitized URL query key invalid");
    }
    if (it.GetUnescapedValue() != kRedactedValue) {
      return Reject(error, "sanitized URL query value is not redacted");
    }
  }
  if (safe_url.has_query() && query_items == 0) {
    return Reject(error, "sanitized URL has empty query");
  }
  if (safe_url.has_ref() &&
      base::UnescapeBinaryURLComponent(safe_url.ref()) != kRedactedValue) {
    return Reject(error, "sanitized URL fragment is not redacted");
  }
  const std::string decoded_safe_url =
      base::UnescapeBinaryURLComponent(safe_url.spec());
  if (!base::IsStringUTF8(decoded_safe_url) ||
      HasUnsafeControlCharacter(decoded_safe_url)) {
    return Reject(error, "sanitized URL decoding invalid");
  }
  return true;
}

std::string NormalizedLocale(std::string_view locale) {
  if (locale.starts_with("zh-TW") || locale.starts_with("zh-HK")) {
    return "zh-TW";
  }
  if (locale.starts_with("zh")) {
    return "zh-CN";
  }
  return "en";
}

ModelPrompt BuildFixedPrompt(const PreparedSummary& prepared,
                             std::string_view locale) {
  ModelPrompt prompt;
  const std::string normalized = NormalizedLocale(locale);
  if (normalized == "zh-TW") {
    prompt.system =
        "你是 GCSA-aegis 隱私助手。根據頁面摘錄給出簡潔摘要、要點列表"
        "與隱私/安全風險。不要編造頁面中沒有的事實。用繁體中文回答。";
  } else if (normalized == "zh-CN") {
    prompt.system =
        "你是 GCSA-aegis 隐私助手。根据页面摘录给出简洁摘要、要点列表"
        "和隐私/安全风险。不要编造页面中没有的事实。用简体中文回答。";
  } else {
    prompt.system =
        "You are the GCSA-aegis privacy assistant. Summarize the page "
        "excerpt, list key points, and note privacy/security risks. Do not "
        "invent facts. Answer in English.";
  }

  prompt.user =
      "URL: " + prepared.snapshot.url + "\nTitle: " + prepared.snapshot.title +
      "\nForms: " + std::to_string(prepared.snapshot.forms) +
      ", password fields: " +
      std::to_string(prepared.snapshot.password_fields) +
      "\n--- Page excerpt (PII redacted) ---\n" +
      (prepared.snapshot.text_sample.empty() ? std::string("(empty)")
                                             : prepared.snapshot.text_sample) +
      "\n---\nRespond as JSON: {\"summary\":string,\"bullets\":"
      "string[],\"risks\":string[]}";
  return prompt;
}

bool ValidatePromptFields(const ModelPrompt& prompt, std::string* error) {
  return ValidateUtf8Field(prompt.system, kMaxSystemPromptBytes, false,
                           "system prompt", error) &&
         ValidateUtf8Field(prompt.user, kMaxUserPromptBytes, false,
                           "user prompt", error);
}

}  // namespace

bool IsModelSummaryAllowed(const PageSnapshot& snapshot, std::string* reason) {
  if (reason) {
    reason->clear();
  }
  if (snapshot.password_fields > 0) {
    return Reject(reason, "model summary blocked: password field detected");
  }

  const GURL source_url(snapshot.url);
  if (!source_url.is_valid()) {
    return Reject(reason, "model summary blocked: invalid URL");
  }
  if (!source_url.SchemeIsHTTPOrHTTPS()) {
    return Reject(reason, "model summary blocked: URL must use HTTP(S)");
  }
  if (!source_url.has_host()) {
    return Reject(reason, "model summary blocked: invalid URL");
  }
  if (HasSensitiveHostLabel(source_url)) {
    return Reject(reason, "model summary blocked: sensitive host label");
  }
  return true;
}

std::optional<PreparedSummary> PrepareSummaryForBrowser(
    const PageSnapshot& original,
    const std::string& locale,
    std::string* error) {
  if (error) {
    error->clear();
  }
  if (!ValidateSourceSnapshot(original, error)) {
    return std::nullopt;
  }

  const GURL source_url(original.url);
  const std::optional<std::string> safe_url = RedactUrl(source_url);
  if (!safe_url) {
    Reject(error, "failed to sanitize source URL");
    return std::nullopt;
  }

  const std::vector<std::string> sensitive_values =
      SensitiveValuesFromOriginal(original);
  PreparedSummary prepared;
  prepared.schema_version = kPreparedSummarySchemaVersion;
  prepared.snapshot.url = *safe_url;
  prepared.snapshot.title = std::string(base::TruncateUTF8ToByteSize(
      RedactValues(original.title, sensitive_values), kMaxSanitizedTitleBytes));
  prepared.snapshot.text_sample = std::string(base::TruncateUTF8ToByteSize(
      RedactValues(original.text_sample, sensitive_values),
      kMaxSanitizedTextBytes));
  prepared.snapshot.password_fields = original.password_fields;
  prepared.snapshot.forms = original.forms;

  const std::string normalized_locale = NormalizedLocale(locale);
  const std::string readable_text =
      base::CollapseWhitespaceASCII(prepared.snapshot.text_sample, false);
  if (readable_text.empty()) {
    prepared.summary = normalized_locale == "zh-TW" ? "未能擷取可讀頁面文字。"
                       : normalized_locale == "zh-CN"
                           ? "未能提取可读页面文本。"
                           : "No readable page text was captured.";
  } else {
    prepared.summary =
        std::string(base::TruncateUTF8ToByteSize(readable_text, 220));
  }
  prepared.bullets = HeuristicBullets(readable_text, normalized_locale);
  if (original.password_fields > 0) {
    prepared.risks.push_back(normalized_locale == "zh-TW"
                                 ? "頁面含密碼欄位，登入前請確認網域。"
                             : normalized_locale == "zh-CN"
                                 ? "页面含密码字段，登录前请确认域名。"
                                 : "Page contains password fields; verify the "
                                   "domain before signing in.");
  }
  if (source_url.SchemeIs("http")) {
    prepared.risks.push_back(normalized_locale == "zh-TW" ? "連線未使用 HTTPS。"
                             : normalized_locale == "zh-CN"
                                 ? "连接未使用 HTTPS。"
                                 : "Connection is not HTTPS.");
  }

  if (!ValidatePreparedSummary(original, prepared, error)) {
    return std::nullopt;
  }
  return prepared;
}

bool ValidatePreparedSummary(const PageSnapshot& original,
                             const PreparedSummary& prepared,
                             std::string* error) {
  if (error) {
    error->clear();
  }
  if (!ValidateSourceSnapshot(original, error)) {
    return false;
  }
  if (prepared.schema_version != kPreparedSummarySchemaVersion) {
    return Reject(error, "prepared summary schema mismatch");
  }
  if (!ValidateUtf8Field(prepared.snapshot.url, kMaxSanitizedUrlBytes, false,
                         "sanitized url", error) ||
      !ValidateUtf8Field(prepared.snapshot.title, kMaxSanitizedTitleBytes, true,
                         "sanitized title", error) ||
      !ValidateUtf8Field(prepared.snapshot.text_sample, kMaxSanitizedTextBytes,
                         true, "sanitized text", error) ||
      !ValidateUtf8Field(prepared.summary, kMaxHeuristicSummaryBytes, false,
                         "heuristic summary", error)) {
    return false;
  }
  if (prepared.snapshot.forms != original.forms ||
      prepared.snapshot.password_fields != original.password_fields ||
      prepared.snapshot.forms < 0 ||
      prepared.snapshot.forms > kMaxPageFieldCount ||
      prepared.snapshot.password_fields < 0 ||
      prepared.snapshot.password_fields > kMaxPageFieldCount) {
    return Reject(error, "sanitized field count mismatch");
  }
  if (!ValidateSanitizedUrl(original, prepared.snapshot, error)) {
    return false;
  }
  if (prepared.bullets.size() > kMaxHeuristicItems ||
      prepared.risks.size() > kMaxHeuristicItems) {
    return Reject(error, "too many heuristic items");
  }
  size_t heuristic_bytes = prepared.summary.size();
  for (const std::string& item : prepared.bullets) {
    if (!ValidateUtf8Field(item, kMaxHeuristicItemBytes, false,
                           "heuristic bullet", error)) {
      return false;
    }
    heuristic_bytes += item.size();
  }
  for (const std::string& item : prepared.risks) {
    if (!ValidateUtf8Field(item, kMaxHeuristicItemBytes, false,
                           "heuristic risk", error)) {
      return false;
    }
    heuristic_bytes += item.size();
  }
  if (heuristic_bytes > kMaxHeuristicTotalBytes) {
    return Reject(error, "heuristic payload too large");
  }

  const std::string payload = PreparedPayload(prepared);
  if (ContainsRecognizableSensitiveValue(payload)) {
    return Reject(error, "prepared summary still contains sensitive data");
  }
  const std::vector<std::string> original_sensitive_values =
      SensitiveValuesFromOriginal(original);
  if (ContainsOriginalSensitiveValue(payload, original_sensitive_values)) {
    return Reject(error, "original sensitive value escaped redaction");
  }
  return true;
}

std::optional<ModelPrompt> BuildValidatedModelPrompt(
    const PageSnapshot& original,
    const PreparedSummary& prepared,
    const std::string& locale,
    std::string* error) {
  if (!ValidatePreparedSummary(original, prepared, error)) {
    return std::nullopt;
  }
  ModelPrompt prompt = BuildFixedPrompt(prepared, locale);
  if (!ValidateOutboundPrompt(original, prepared, locale, prompt, error)) {
    return std::nullopt;
  }
  return prompt;
}

bool ValidateOutboundPrompt(const PageSnapshot& original,
                            const PreparedSummary& prepared,
                            const std::string& locale,
                            const ModelPrompt& prompt,
                            std::string* error) {
  if (!ValidatePreparedSummary(original, prepared, error) ||
      !ValidatePromptFields(prompt, error)) {
    return false;
  }
  const ModelPrompt expected = BuildFixedPrompt(prepared, locale);
  if (prompt.system != expected.system || prompt.user != expected.user) {
    return Reject(error, "outbound prompt differs from fixed template");
  }

  const std::string outbound = prompt.system + "\n" + prompt.user;
  if (ContainsRecognizableSensitiveValue(outbound)) {
    return Reject(error, "outbound prompt contains sensitive data");
  }
  const std::vector<std::string> original_sensitive_values =
      SensitiveValuesFromOriginal(original);
  if (ContainsOriginalSensitiveValue(outbound, original_sensitive_values)) {
    return Reject(error, "outbound prompt contains original sensitive value");
  }
  if (error) {
    error->clear();
  }
  return true;
}

}  // namespace aegis
