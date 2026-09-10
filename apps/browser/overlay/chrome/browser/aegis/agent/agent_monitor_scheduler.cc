// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/agent_monitor_scheduler.h"

#include <algorithm>
#include <optional>
#include <utility>

#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "chrome/common/aegis/security_text.h"
#include "crypto/sha2.h"

namespace aegis::agent {
namespace {

constexpr size_t kMaxObservationBytes = 32768;

bool ContainsAny(std::string_view text,
                 std::initializer_list<std::string_view> words) {
  return std::ranges::any_of(words, [&](auto word) {
    for (size_t pos = text.find(word); pos != std::string_view::npos;
         pos = text.find(word, pos + word.size())) {
      if (base::IsAsciiAlpha(word.front()) && pos > 0u &&
          base::IsAsciiAlphaNumeric(text[pos - 1u])) {
        continue;
      }
      if (base::IsAsciiAlpha(word.back()) && pos + word.size() < text.size() &&
          base::IsAsciiAlphaNumeric(text[pos + word.size()])) {
        continue;
      }
      return true;
    }
    return false;
  });
}

// 用整数保存百分之一单位，避免浮点比较及不同小数格式造成假降价。
std::optional<int64_t> ParseMonitorAmount(std::string_view input) {
  if (input.empty() || input.size() > 20u) {
    return std::nullopt;
  }
  const size_t separator = input.find_last_of(".,");
  const bool decimal = separator != std::string_view::npos &&
                       input.size() - separator - 1u <= 2u;
  const auto whole = decimal ? input.substr(0, separator) : input;
  const auto fraction = decimal ? input.substr(separator + 1u)
                                : std::string_view();
  if ((decimal && fraction.empty()) || whole.empty()) {
    return std::nullopt;
  }
  std::string digits;
  size_t group_size = 0;
  char grouping = 0;
  for (const char c : whole) {
    if (base::IsAsciiDigit(c)) {
      digits.push_back(c);
      ++group_size;
    } else if ((c == ',' || c == '.') && group_size > 0u &&
               ((!grouping && group_size <= 3u) ||
                (grouping == c && group_size == 3u)) &&
               (!decimal || c != input[separator])) {
      grouping = c;
      group_size = 0;
    } else {
      return std::nullopt;
    }
  }
  if (group_size == 0u || (grouping && group_size != 3u) ||
      !std::ranges::all_of(fraction, base::IsAsciiDigit<char>)) {
    return std::nullopt;
  }
  digits += fraction;
  digits.append(2u - fraction.size(), '0');
  int64_t amount = 0;
  if (!base::StringToInt64(digits, &amount) || amount <= 0 ||
      amount > 100000000000000LL) {
    return std::nullopt;
  }
  return amount;
}

struct MonitorPrice {
  std::string currency;
  int64_t amount;
  bool operator==(const MonitorPrice&) const = default;
};

// 币种代码优先保留本来的含义；单独的 $ / ¥ 不擅自推断成美元或人民币。
constexpr std::pair<std::string_view, std::string_view> kCurrencies[] = {
    {"us$", "USD"}, {"hk$", "HKD"}, {"nt$", "TWD"},
    {"ca$", "CAD"}, {"au$", "AUD"}, {"usd", "USD"},
    {"eur", "EUR"}, {"gbp", "GBP"}, {"cny", "CNY"},
    {"rmb", "CNY"}, {"jpy", "JPY"}, {"hkd", "HKD"},
    {"twd", "TWD"}, {"cad", "CAD"}, {"aud", "AUD"},
    {"inr", "INR"}, {"krw", "KRW"}, {"chf", "CHF"},
    {"$", "$"}, {"€", "EUR"}, {"£", "GBP"},
    {"¥", "¥"}, {"￥", "¥"}, {"元", "CNY"},
};

std::optional<std::string> SerializeObservation(base::DictValue value) {
  std::string json;
  if (!base::JSONWriter::Write(value, &json) ||
      json.size() > kMaxObservationBytes) {
    return std::nullopt;
  }
  return json;
}

}  // namespace

std::optional<std::string> ReadAgentMonitorObservation(
    AgentMonitorKind kind,
    const base::ListValue& nodes) {
  if (nodes.empty() || nodes.size() > 512u ||
      kind == AgentMonitorKind::kUrlStatus) {
    return std::nullopt;
  }
  std::optional<MonitorPrice> price;
  std::optional<bool> inventory;
  base::ListValue content;
  size_t bytes = 0;
  for (const auto& node : nodes) {
    if (!node.is_dict()) {
      continue;
    }
    const auto* raw_text = node.GetDict().FindString("text");
    const auto* raw_label = node.GetDict().FindString("label");
    bytes += (raw_text ? raw_text->size() : 0u) +
             (raw_label ? raw_label->size() : 0u);
    if (bytes > kMaxObservationBytes) {
      return std::nullopt;
    }
    const auto normalized = NormalizeSecurityText(
        (raw_label ? *raw_label : "") + std::string(" ") +
        (raw_text ? *raw_text : ""));
    if (!normalized.valid_utf8) {
      return std::nullopt;
    }
    const std::string text = base::ToLowerASCII(
        base::CollapseWhitespaceASCII(normalized.text, false));
    if (text.empty()) {
      continue;
    }
    if (kind == AgentMonitorKind::kPageChange) {
      content.Append(normalized.text);
      continue;
    }
    if (kind == AgentMonitorKind::kInventory) {
      if (ContainsAny(text, {"预计", "預計", "即将", "即將", "预售", "預售",
                             "pre-order", "preorder", "expected in stock"})) {
        continue;
      }
      bool unavailable = false;
      std::string positive_text = text;
      for (const auto phrase : {"out of stock", "not in stock", "sold out",
                                "currently unavailable", "not available",
                                "没有货", "沒有貨", "无现货", "無現貨",
                                "缺货", "缺貨", "无货", "無貨", "售罄", "售完"}) {
        if (positive_text.contains(phrase)) {
          unavailable = true;
          base::ReplaceSubstringsAfterOffset(&positive_text, 0, phrase, "");
        }
      }
      // 先移除否定短语，不能把 not in stock 中的 in stock 当成有货。
      const bool available = ContainsAny(
          positive_text, {"in stock", "有货", "有貨", "现货", "現貨", "库存充足"});
      if (unavailable && available) {
        return std::nullopt;
      }
      if (unavailable || available) {
        if (inventory && *inventory != available) {
          return std::nullopt;
        }
        inventory = available;
      }
      continue;
    }
    if (kind != AgentMonitorKind::kPrice) {
      return std::nullopt;
    }
    // 页面可能同时展示原价、运费和优惠券；它们不是商品当前售价。
    if (ContainsAny(text, {"list price", "original price", "was ", "msrp",
                          "shipping", "coupon", "save ", "原价", "原價",
                          "划线价", "劃線價", "运费", "運費", "优惠券"})) {
      continue;
    }
    for (const auto& [marker, currency] : kCurrencies) {
      for (size_t pos = text.find(marker); pos != std::string::npos;
           pos = text.find(marker, pos + marker.size())) {
        if ((pos > 0u && base::IsAsciiAlpha(text[pos - 1u])) ||
            (base::IsAsciiAlpha(marker.back()) &&
             pos + marker.size() < text.size() &&
             base::IsAsciiAlpha(text[pos + marker.size()]))) {
          continue;
        }
        size_t start = pos + marker.size();
        while (start < text.size() &&
               (base::IsAsciiWhitespace(text[start]) || text[start] == ':')) {
          ++start;
        }
        size_t end = start;
        while (end < text.size() &&
               (base::IsAsciiDigit(text[end]) || text[end] == '.' ||
                text[end] == ',')) {
          ++end;
        }
        if (start == end) {
          end = pos;
          while (end > 0u && base::IsAsciiWhitespace(text[end - 1u])) {
            --end;
          }
          start = end;
          while (start > 0u &&
                 (base::IsAsciiDigit(text[start - 1u]) ||
                  text[start - 1u] == '.' || text[start - 1u] == ',')) {
            --start;
          }
        }
        if (start == end || (start > 0u && text[start - 1u] == '-') ||
            (end < text.size() && text[end] == '%')) {
          continue;
        }
        const auto amount = ParseMonitorAmount(
            std::string_view(text).substr(start, end - start));
        if (!amount) {
          return std::nullopt;
        }
        MonitorPrice candidate{std::string(currency), *amount};
        if (price && *price != candidate) {
          return std::nullopt;
        }
        price = std::move(candidate);
      }
    }
  }
  base::DictValue result;
  result.Set("version", 1);
  result.Set("kind", static_cast<int>(kind));
  if (kind == AgentMonitorKind::kPrice && price) {
    result.Set("currency", price->currency);
    result.Set("amount", base::NumberToString(price->amount));
  } else if (kind == AgentMonitorKind::kInventory && inventory) {
    result.Set("available", *inventory);
  } else if (kind == AgentMonitorKind::kPageChange && !content.empty()) {
    result.Set("content", std::move(content));
  } else {
    return std::nullopt;
  }
  return SerializeObservation(std::move(result));
}

bool IsValidAgentMonitorObservation(AgentMonitorKind kind,
                                    std::string_view observation) {
  if (observation.empty() || observation.size() > kMaxObservationBytes) {
    return false;
  }
  const auto value =
      base::JSONReader::ReadDict(observation, base::JSON_PARSE_RFC);
  if (!value || value->FindInt("version") != 1 ||
      value->FindInt("kind") != static_cast<int>(kind)) {
    return false;
  }
  if (kind == AgentMonitorKind::kPrice) {
    const auto* currency = value->FindString("currency");
    const auto* amount = value->FindString("amount");
    int64_t parsed = 0;
    return currency && amount &&
           std::ranges::any_of(kCurrencies, [&](const auto& entry) {
             return entry.second == *currency;
           }) &&
           base::StringToInt64(*amount, &parsed) && parsed > 0 &&
           parsed <= 100000000000000LL && *amount == base::NumberToString(parsed);
  }
  if (kind == AgentMonitorKind::kInventory) {
    return value->FindBool("available").has_value();
  }
  const auto* content = value->FindList("content");
  return kind == AgentMonitorKind::kPageChange && content && !content->empty() &&
         content->size() <= 512u &&
         std::ranges::all_of(*content, [](const auto& entry) {
           return entry.is_string();
         });
}

bool DidAgentMonitorConditionMatch(AgentMonitorKind kind,
                                   std::string_view previous,
                                   std::string_view current) {
  if (!IsValidAgentMonitorObservation(kind, previous) ||
      !IsValidAgentMonitorObservation(kind, current)) {
    return false;
  }
  const auto before = base::JSONReader::ReadDict(previous, base::JSON_PARSE_RFC);
  const auto after = base::JSONReader::ReadDict(current, base::JSON_PARSE_RFC);
  if (!before || !after || before->FindInt("version") != 1 ||
      after->FindInt("version") != 1 ||
      before->FindInt("kind") != static_cast<int>(kind) ||
      after->FindInt("kind") != static_cast<int>(kind)) {
    return false;
  }
  if (kind == AgentMonitorKind::kPrice) {
    const auto* old_currency = before->FindString("currency");
    const auto* new_currency = after->FindString("currency");
    const auto* old_amount = before->FindString("amount");
    const auto* new_amount = after->FindString("amount");
    int64_t old_value = 0;
    int64_t new_value = 0;
    return old_currency && new_currency && !old_currency->empty() &&
           *old_currency == *new_currency && old_amount && new_amount &&
           base::StringToInt64(*old_amount, &old_value) &&
           base::StringToInt64(*new_amount, &new_value) &&
           old_value > 0 && new_value > 0 && new_value < old_value;
  }
  if (kind == AgentMonitorKind::kInventory) {
    return before->FindBool("available") == false &&
           after->FindBool("available") == true;
  }
  if (kind == AgentMonitorKind::kPageChange) {
    const auto* old_content = before->FindList("content");
    const auto* new_content = after->FindList("content");
    return old_content && new_content && !old_content->empty() &&
           !new_content->empty() && *old_content != *new_content;
  }
  return false;
}

std::string AgentMonitorIdempotencyKey(std::string_view task_id,
                                       std::string_view action_id) {
  return "aegis-" + base::HexEncode(crypto::SHA256HashString(
                        std::string(task_id) + "\n" + std::string(action_id)));
}

bool AgentMonitorDefinition::IsValid() const {
  const bool runtime_target_valid =
      target_url.is_empty() ||
      (target_url.is_valid() && target_url.SchemeIsHTTPOrHTTPS() &&
       target_url.username().empty() && target_url.password().empty() &&
       target_url.spec().size() <= 8192u &&
       url::Origin::Create(target_url) == origin);
  return !monitor_id.empty() && monitor_id.size() <= 128u && !task_id.empty() &&
         task_id.size() <= 128u && !origin.opaque() &&
         (origin.scheme() == "http" || origin.scheme() == "https") &&
         !target_hash.empty() && target_hash.size() <= 128u &&
         target_ciphertext.size() <= 16384u && last_value_hash.size() <= 128u &&
         last_observation.size() <= kMaxObservationBytes &&
         (last_observation.empty() ||
          IsValidAgentMonitorObservation(kind, last_observation)) &&
         last_observation_ciphertext.size() <= 131072u &&
         runtime_target_valid && interval >= base::Minutes(15) &&
         interval <= base::Days(7) && consecutive_failures >= 0 &&
         consecutive_failures <= 20 &&
         last_check_status >= AgentMonitorCheckStatus::kNotChecked &&
         last_check_status <= AgentMonitorCheckStatus::kSummaryUnavailable &&
         (last_http_status == 0 ||
          (last_http_status >= 100 && last_http_status <= 599));
}

bool ShouldNotifyMonitorUrlResult(const AgentMonitorDefinition& previous,
                                 AgentMonitorCheckStatus next_status,
                                 std::string_view next_value_hash) {
  const bool measured = next_status == AgentMonitorCheckStatus::kSucceeded ||
                        next_status == AgentMonitorCheckStatus::kHttpError;
  const bool first_success =
      previous.last_check_status == AgentMonitorCheckStatus::kNotChecked &&
      next_status == AgentMonitorCheckStatus::kSucceeded;
  return (previous.last_check_status != next_status &&
          !first_success) ||
         (measured && previous.last_check_status !=
                          AgentMonitorCheckStatus::kNotChecked &&
          !previous.last_value_hash.empty() &&
          previous.last_value_hash != next_value_hash);
}

AgentMonitorScheduler::AgentMonitorScheduler() = default;
AgentMonitorScheduler::~AgentMonitorScheduler() = default;

bool AgentMonitorScheduler::Upsert(AgentMonitorDefinition monitor) {
  if (!monitor.IsValid()) {
    return false;
  }
  monitors_.insert_or_assign(monitor.monitor_id, std::move(monitor));
  return true;
}

bool AgentMonitorScheduler::Remove(const std::string& monitor_id) {
  return monitors_.erase(monitor_id) == 1u;
}

void AgentMonitorScheduler::Restore(
    std::vector<AgentMonitorDefinition> monitors,
    base::Time now) {
  monitors_.clear();
  for (AgentMonitorDefinition& monitor : monitors) {
    if (!monitor.IsValid()) {
      continue;
    }
    if (monitor.enabled &&
        (monitor.next_run.is_null() || monitor.next_run < now)) {
      monitor.next_run = now;
    }
    Upsert(std::move(monitor));
  }
}

std::vector<AgentMonitorDefinition> AgentMonitorScheduler::ClaimDue(
    base::Time now) {
  std::vector<AgentMonitorDefinition*> due;
  for (auto& [id, monitor] : monitors_) {
    if (monitor.enabled && !monitor.next_run.is_null() &&
        monitor.next_run <= now) {
      due.push_back(&monitor);
    }
  }
  std::ranges::sort(due, [](const AgentMonitorDefinition* left,
                            const AgentMonitorDefinition* right) {
    if (left->next_run != right->next_run) {
      return left->next_run < right->next_run;
    }
    return left->monitor_id < right->monitor_id;
  });
  if (due.size() > 3u) {
    due.resize(3u);
  }
  std::vector<AgentMonitorDefinition> claimed;
  for (AgentMonitorDefinition* monitor : due) {
    monitor->last_run = now;
    monitor->next_run = now + monitor->interval;
    claimed.push_back(*monitor);
  }
  return claimed;
}

bool AgentMonitorScheduler::MarkFinished(const std::string& monitor_id,
                                         bool success,
                                         base::Time now,
                                         AgentMonitorCheckStatus status,
                                         int http_status) {
  auto it = monitors_.find(monitor_id);
  if (it == monitors_.end()) {
    return false;
  }
  AgentMonitorDefinition& monitor = it->second;
  if (status < AgentMonitorCheckStatus::kNotChecked ||
      status > AgentMonitorCheckStatus::kSummaryUnavailable ||
      (http_status != 0 && (http_status < 100 || http_status > 599))) {
    return false;
  }
  monitor.last_check_status =
      status == AgentMonitorCheckStatus::kNotChecked
          ? (success ? AgentMonitorCheckStatus::kSucceeded
                     : AgentMonitorCheckStatus::kCheckFailed)
          : status;
  monitor.last_http_status = http_status;
  monitor.last_run = now;
  if (success) {
    monitor.consecutive_failures = 0;
    monitor.next_run = now + monitor.interval;
    return true;
  }
  monitor.consecutive_failures = std::min(monitor.consecutive_failures + 1, 20);
  const int exponent = std::min(monitor.consecutive_failures, 6);
  const base::TimeDelta backoff =
      std::min(monitor.interval * (1 << exponent), base::Hours(24));
  monitor.next_run = now + backoff;
  return true;
}

std::vector<AgentMonitorDefinition> AgentMonitorScheduler::Snapshot() const {
  std::vector<AgentMonitorDefinition> result;
  result.reserve(monitors_.size());
  for (const auto& [id, monitor] : monitors_) {
    result.push_back(monitor);
  }
  return result;
}

}  // namespace aegis::agent
