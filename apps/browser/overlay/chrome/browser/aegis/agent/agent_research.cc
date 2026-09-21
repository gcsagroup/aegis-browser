// Copyright 2026 GCSA
#include "chrome/browser/aegis/agent/agent_research.h"

#include <algorithm>

#include "base/containers/flat_set.h"
#include "base/json/json_writer.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/time/time.h"
#include "crypto/sha2.h"

namespace aegis::agent {
namespace {
bool Text(const base::DictValue& value,
          std::string_view key,
          size_t limit,
          bool allow_empty = false) {
  const auto* text = value.FindString(key);
  return text && (allow_empty || !text->empty()) && text->size() <= limit &&
         base::IsStringUTF8(*text);
}
std::string Clip(std::string_view value, size_t limit) {
  return std::string(base::TruncateUTF8ToByteSize(value, limit));
}
}  // namespace

std::optional<std::string> AgentResearchContentHash(
    const AgentToolResult& result) {
  const auto* nodes = result.value.FindList("nodes");
  if (!result.ok || result.value.FindBool("untrusted") != true || !nodes ||
      result.value.FindBool("truncated") == true || nodes->size() > 512u) {
    return std::nullopt;
  }
  std::string content;
  for (const auto& node : *nodes) {
    const auto* value = node.GetIfDict();
    const auto* text = value ? value->FindString("text") : nullptr;
    if (!text) {
      continue;
    }
    const auto normalized = base::CollapseWhitespaceASCII(*text, false);
    if (!normalized.empty()) {
      content += normalized;
      content += '\n';
    }
    if (content.size() > 128u * 1024u) {
      return std::nullopt;
    }
  }
  if (content.empty() || !base::IsStringUTF8(content)) {
    return std::nullopt;
  }
  return base::HexEncode(crypto::SHA256HashString(content));
}

void NormalizeAgentResearchComparison(
    AgentCompletionSummary* completion,
    const AgentTask& task,
    base::span<const AgentExecutionEvidence> evidence,
    const std::map<int32_t, GURL>& selected_urls) {
  if (!completion || !task.scope().selected_pages_research) {
    return;
  }
  // 对照只认当前所选页面的最后一次完整观察，失败或换页不能沿用旧值。
  std::map<std::string, std::string> texts;
  std::map<std::string, int> source_numbers;
  std::string sources;
  for (const auto& [tab, url] : selected_urls) {
    const int number = static_cast<int>(source_numbers.size()) + 1;
    source_numbers.emplace(url.spec(), number);
    const AgentToolResult* observed = nullptr;
    for (const auto& item : evidence) {
      if (item.tool_name == "page.observe" &&
          item.result.value.FindInt("tab_id") == tab) {
        observed = &item.result;
      }
    }
    std::string text;
    std::string title;
    const auto* observed_url =
        observed ? observed->value.FindString("url") : nullptr;
    if (task.scope().AllowsTab(tab) && task.scope().AllowsOrigin(url) &&
        observed && observed_url && GURL(*observed_url) == url &&
        AgentResearchContentHash(*observed)) {
      if (const auto* value = observed->value.FindString("title")) {
        title = Clip(*value, 128);
      }
      for (const auto& node : *observed->value.FindList("nodes")) {
        if (const auto* value = node.GetIfDict()) {
          if (const auto* content = value->FindString("text")) {
            text += *content;
          }
        }
      }
    }
    texts.emplace(url.spec(), base::CollapseWhitespaceASCII(text, false));
    sources +=
        "\n[" + base::NumberToString(number) + "] " + title + " " + url.spec();
  }
  auto normalize_anchor = [](std::string_view value) {
    // 保留锚点边缘的空格，避免将“为 42”变成“为42”。
    auto normalized =
        base::CollapseWhitespaceASCII("X" + std::string(value) + "X", false);
    return normalized.substr(1, normalized.size() - 2);
  };
  auto token_joined = [](std::string_view left, std::string_view right) {
    return !left.empty() && !right.empty() &&
           base::IsAsciiAlphaNumeric(left.back()) &&
           base::IsAsciiAlphaNumeric(right.front());
  };
  std::string rendered =
      "按所列原文字段比较；相同值由浏览器合并计数，差异仅相"
      "对于多数来源的原文值，"
      "不代表多数值更真实，也不代表不同表述在语义上相同。";
  size_t verified_dimensions = 0;
  bool complete = selected_urls.size() >= 3u && selected_urls.size() <= 10u &&
                  selected_urls.size() == task.scope().allowed_tab_ids.size();
  base::flat_set<std::string> labels;
  for (const auto& dimension : completion->research_comparisons) {
    const auto label = normalize_anchor(dimension.label);
    const std::string prefix(base::TrimWhitespaceASCII(
        normalize_anchor(dimension.prefix), base::TRIM_TRAILING));
    const std::string suffix(base::TrimWhitespaceASCII(
        normalize_anchor(dimension.suffix), base::TRIM_LEADING));
    bool valid = !label.empty() && !prefix.empty() && prefix.contains(label) &&
                 labels.insert(label).second &&
                 dimension.values.size() == selected_urls.size();
    if (!valid) {
      complete = false;
      continue;
    }
    std::map<std::string, std::vector<int>> groups;
    base::flat_set<std::string> seen;
    std::vector<int> missing;
    for (const auto& cell : dimension.values) {
      const auto source = texts.find(cell.source_url);
      if (source == texts.end() || !seen.insert(cell.source_url).second) {
        valid = false;
        break;
      }
      const int number = source_numbers.at(cell.source_url);
      const std::string value(base::TrimWhitespaceASCII(
          normalize_anchor(cell.value), base::TRIM_ALL));
      if (value.empty() || source->second.empty()) {
        missing.push_back(number);
        continue;
      }
      // 同一字段在一页出现多次时，只有全部锚点都对应同一值才可比较。
      const std::string_view text(source->second);
      size_t at = text.find(prefix);
      if (at == std::string::npos) {
        valid = false;
        break;
      }
      for (; at != std::string::npos;
           at = text.find(prefix, at + prefix.size())) {
        // 只跳过字段边界空白，值和上下文内部仍须完整匹配。
        const size_t begin = text.find_first_not_of(' ', at + prefix.size());
        if (begin == std::string::npos ||
            text.substr(begin, value.size()) != value) {
          valid = false;
          break;
        }
        const size_t end = begin + value.size();
        const auto rest = text.substr(end);
        // 按原文位置检查词边界，防止把142截成42或把18.5截成18。
        if (token_joined(text.substr(0, begin), value) ||
            token_joined(value, rest) ||
            (base::IsAsciiDigit(value.back()) && rest.size() > 1u &&
             rest.front() == '.' && base::IsAsciiDigit(rest[1])) ||
            !base::TrimWhitespaceASCII(rest, base::TRIM_LEADING)
                 .starts_with(suffix)) {
          valid = false;
          break;
        }
      }
      groups[value].push_back(number);
    }
    if (!valid || groups.empty()) {
      complete = false;
      continue;
    }
    ++verified_dimensions;
    rendered +=
        "\n\n" + label + "（原文上下文：" + prefix + "〔值〕" + suffix + "）";
    auto numbers = [](const std::vector<int>& ids) {
      std::string result;
      for (int id : ids) {
        if (!result.empty())
          result += "、";
        result += "[" + base::NumberToString(id) + "]";
      }
      return result;
    };
    const auto largest = std::ranges::max_element(
        groups, {}, [](const auto& group) { return group.second.size(); });
    const bool majority = largest->second.size() * 2u > selected_urls.size();
    for (const auto& [value, ids] : groups) {
      rendered += "\n- “" + value + "”：" + base::NumberToString(ids.size()) +
                  " 个来源 " + numbers(ids);
      if (majority && groups.size() > 1u && value != largest->first) {
        rendered += "（与多数来源不同）";
      }
    }
    if (!majority && groups.size() > 1u) {
      rendered += "\n没有超过半数的相同值，不指定多数值或例外组。";
    }
    if (!missing.empty()) {
      complete = false;
      rendered += "\n待核实：" + numbers(missing) +
                  " 未取得该字段的可比值；不计为例外。";
    }
  }
  if (verified_dimensions == 0u) {
    complete = false;
    rendered =
        "尚未得到可按原文核对的比较字段。以下仅保留已读取的原文摘录，分"
        "类和数量尚未核实。";
    for (const auto& [url, text] : texts) {
      rendered += "\n[" + base::NumberToString(source_numbers.at(url)) + "] " +
                  (text.empty() ? "来源未完整读取" : Clip(text, 256));
    }
  }
  rendered += "\n\n来源：" + sources;
  if (rendered.size() > 30000u) {
    rendered = Clip(rendered, 30000);
    complete = false;
  }
  completion->summary = std::move(rendered);
  if (!complete || !completion->unfinished_items.empty()) {
    completion->outcome = "partial";
    const std::string pending =
        "部分比较字段或来源无法按共同原文上下文核对，需补齐后再完成比较。";
    if (!complete &&
        !std::ranges::contains(completion->unfinished_items, pending)) {
      completion->unfinished_items.push_back(pending);
    }
  }
}

bool CanSkipUnreadableResearchSource(const AgentTask& task,
                                     const AgentToolCall& call,
                                     const AgentToolResult& result,
                                     int attempts,
                                     bool selection_matches) {
  const auto tab = call.arguments.FindInt("tab_id");
  return task.scope().selected_pages_research && selection_matches &&
         (task.state() == AgentTaskState::kRunning ||
          task.state() == AgentTaskState::kReflecting) &&
         !task.HasExpired(base::Time::Now()) &&
         task.tool_calls_used() < task.scope().budgets.max_tool_calls &&
         attempts == 3 && call.tool_name == "page.observe" && tab &&
         task.scope().AllowsTab(*tab) && !result.ok &&
         result.error == AgentErrorCode::kVerificationFailed;
}

std::optional<AgentCompletionSummary> BuildPartialResearchCompletion(
    const base::DictValue& record) {
  if (!IsValidAgentResearchRecord(record)) {
    return std::nullopt;
  }
  AgentCompletionSummary result;
  result.outcome = "partial";
  result.summary =
      "部分来源不可读取。以下仅保留已读网页的原文摘录，未完成完整比较，也不代表"
      "事实核验。";
  bool missing = false;
  for (const auto& item : *record.FindList("sources")) {
    const auto& source = item.GetDict();
    const auto& url = *source.FindString("url");
    if (source.FindBool("available") != true ||
        base::CollapseWhitespaceASCII(*source.FindString("excerpt"), false)
            .empty()) {
      missing = true;
      result.unfinished_items.push_back("未读取来源：" + url);
      continue;
    }
    result.source_urls.push_back(url);
    result.summary +=
        "\n\n来源：" + url + "\n原文摘录：" + *source.FindString("excerpt");
  }
  if (!missing || result.source_urls.empty()) {
    return std::nullopt;
  }
  result.unfinished_items.push_back("需要补齐不可读来源后重新完成比较。");
  return result;
}

bool IsValidAgentResearchRecord(const base::DictValue& record) {
  if (record.size() != 8u || record.FindInt("version") != 1 ||
      !Text(record, "id", 64) || !Text(record, "goal", 4096) ||
      !Text(record, "summary", 32768) || !Text(record, "created_ms", 24) ||
      !Text(record, "outcome", 16)) {
    return false;
  }
  const auto& outcome = *record.FindString("outcome");
  if (outcome != "completed" && outcome != "partial") {
    return false;
  }
  int64_t captured = 0;
  if (!base::StringToInt64(*record.FindString("created_ms"), &captured) ||
      captured <= 0) {
    return false;
  }
  const auto* sources = record.FindList("sources");
  const auto* unfinished = record.FindList("unfinished");
  if (!sources || sources->size() < 3u || sources->size() > 10u ||
      !unfinished || unfinished->size() > 20u ||
      (outcome == "completed" && !unfinished->empty())) {
    return false;
  }
  for (const auto& item : *unfinished) {
    if (!item.is_string() || item.GetString().size() > 4096u ||
        !base::IsStringUTF8(item.GetString())) {
      return false;
    }
  }
  base::flat_set<std::string> urls;
  for (const auto& item : *sources) {
    const auto* source = item.GetIfDict();
    if (!source || source->size() != 6u || !Text(*source, "url", 8192) ||
        !Text(*source, "title", 512, true) ||
        !Text(*source, "excerpt", 512, true) ||
        !Text(*source, "content_hash", 64, true) ||
        !Text(*source, "captured_ms", 24, true) ||
        !source->FindBool("available").has_value()) {
      return false;
    }
    const GURL url(*source->FindString("url"));
    if (!url.SchemeIsHTTPOrHTTPS() || url.has_username() ||
        url.has_password() || !urls.insert(url.spec()).second) {
      return false;
    }
    const auto& hash = *source->FindString("content_hash");
    if (source->FindBool("available") == true) {
      if (hash.size() != 64u ||
          !std::ranges::all_of(hash,
                               [](char c) { return base::IsHexDigit(c); }) ||
          !base::StringToInt64(*source->FindString("captured_ms"), &captured) ||
          captured <= 0) {
        return false;
      }
    } else if (!hash.empty()) {
      return false;
    }
  }
  const auto json = base::WriteJson(record);
  return json && json->size() <= 65536u;
}

std::optional<base::DictValue> BuildAgentResearchRecord(
    const AgentTask& task,
    const AgentCompletionSummary& completion,
    base::span<const AgentExecutionEvidence> evidence,
    const std::map<int32_t, GURL>& selected_urls) {
  if (!task.scope().selected_pages_research ||
      selected_urls.size() != task.scope().allowed_tab_ids.size()) {
    return std::nullopt;
  }
  base::DictValue record;
  record.Set("version", 1);
  record.Set("id", task.id());
  record.Set("goal", task.goal());
  record.Set("summary", completion.summary);
  record.Set("outcome", completion.outcome);
  record.Set(
      "created_ms",
      base::NumberToString(base::Time::Now().InMillisecondsSinceUnixEpoch()));
  base::ListValue unfinished;
  for (const auto& item : completion.unfinished_items) {
    unfinished.Append(item);
  }
  record.Set("unfinished", std::move(unfinished));
  base::ListValue sources;
  for (const auto& [id, url] : selected_urls) {
    if (!task.scope().AllowsTab(id) || !task.scope().AllowsOrigin(url)) {
      return std::nullopt;
    }
    base::DictValue source;
    source.Set("url", url.spec());
    source.Set("title", "");
    source.Set("excerpt", "");
    source.Set("content_hash", "");
    source.Set("captured_ms", "");
    source.Set("available", false);
    for (const auto& item : evidence) {
      if (item.tool_name != "page.observe" ||
          item.result.value.FindInt("tab_id") != id) {
        continue;
      }
      auto hash = AgentResearchContentHash(item.result);
      const auto* captured = item.result.value.FindString("captured_at_ms");
      if (!hash || !captured) {
        continue;
      }
      source.Set("available", true);
      source.Set("content_hash", *hash);
      source.Set("captured_ms", *captured);
      if (const auto* title = item.result.value.FindString("title")) {
        source.Set("title", Clip(*title, 512));
      }
      // 行内加粗的数字可能是独立节点；截取第一节点会留下没有数值的半句。
      // 按观察顺序保留有界正文，不让模型补齐缺失片段。
      std::string excerpt;
      for (const auto& node : *item.result.value.FindList("nodes")) {
        const auto* value = node.GetIfDict();
        const auto* text = value ? value->FindString("text") : nullptr;
        if (!text || value->FindBool("text_is_heading") == true) {
          continue;
        }
        excerpt += Clip(*text, 512 - excerpt.size());
        if (excerpt.size() >= 512u) {
          break;
        }
      }
      source.Set("excerpt", Clip(excerpt, 512));
    }
    sources.Append(std::move(source));
  }
  record.Set("sources", std::move(sources));
  if (!IsValidAgentResearchRecord(record)) {
    return std::nullopt;
  }
  return record;
}
}  // namespace aegis::agent
