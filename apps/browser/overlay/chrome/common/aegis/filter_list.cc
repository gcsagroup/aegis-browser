// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/filter_list.cc

#include "chrome/common/aegis/filter_list.h"

#include <algorithm>
#include <optional>
#include <set>
#include <utility>

#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "base/values.h"

namespace aegis {
namespace {

bool IsPlausibleHost(std::string_view host) {
  if (host.size() < 3 || host.size() > 253) {
    return false;
  }
  if (host.find('.') == std::string_view::npos) {
    return false;
  }
  if (host.front() == '.' || host.back() == '.' ||
      host.find("..") != std::string_view::npos) {
    return false;
  }
  for (char c : host) {
    if (!base::IsAsciiAlphaNumeric(c) && c != '.' && c != '-') {
      return false;
    }
  }
  return true;
}

bool LooksCosmetic(std::string_view line) {
  return line.find("##") != std::string_view::npos ||
         line.find("#@#") != std::string_view::npos ||
         line.find("#?#") != std::string_view::npos;
}

void UniqueSorted(std::vector<std::string>* values) {
  std::sort(values->begin(), values->end());
  values->erase(std::unique(values->begin(), values->end()), values->end());
}

std::vector<std::string> ListToStrings(const base::ListValue* list) {
  std::vector<std::string> out;
  if (!list) {
    return out;
  }
  out.reserve(list->size());
  for (const base::Value& value : *list) {
    if (value.is_string()) {
      out.push_back(value.GetString());
    }
  }
  return out;
}

}  // namespace

bool ParseEasyListRule(std::string_view line,
                       bool* is_exception,
                       std::string* rule,
                       bool* is_path) {
  std::string_view s = base::TrimWhitespaceASCII(line, base::TRIM_ALL);
  if (s.empty() || s.front() == '!' || s.front() == '[' || s.front() == '#') {
    return false;
  }
  if (LooksCosmetic(s)) {
    return false;
  }

  bool exception = false;
  if (s.starts_with("@@")) {
    exception = true;
    s.remove_prefix(2);
  }
  if (!s.starts_with("||")) {
    return false;
  }
  s.remove_prefix(2);

  const size_t dollar = s.find('$');
  if (dollar != std::string_view::npos) {
    const std::string_view options = s.substr(dollar + 1);
    s = s.substr(0, dollar);
    for (std::string_view opt :
         base::SplitStringPiece(options, ",", base::TRIM_WHITESPACE,
                                base::SPLIT_WANT_NONEMPTY)) {
      if (opt.starts_with("domain=") || opt.starts_with("~domain=")) {
        return false;
      }
    }
  }

  if (s.ends_with("^")) {
    s.remove_suffix(1);
  }
  if (s.find('*') != std::string_view::npos ||
      s.find('^') != std::string_view::npos ||
      s.find('|') != std::string_view::npos) {
    return false;
  }

  const size_t slash = s.find('/');
  const std::string_view host = slash == std::string_view::npos
                                    ? s
                                    : s.substr(0, slash);
  std::string host_lower = base::ToLowerASCII(host);
  if (!IsPlausibleHost(host_lower)) {
    return false;
  }
  const bool path = slash != std::string_view::npos;
  *is_exception = exception;
  *is_path = path;
  *rule = path ? host_lower + std::string(s.substr(slash)) : host_lower;
  return true;
}

CompiledFilterList CompileEasyList(std::string_view text,
                                   std::string_view source) {
  CompiledFilterList out;
  out.source = std::string(source);
  std::set<std::string> hosts;
  std::set<std::string> path_rules;
  std::set<std::string> exceptions;

  for (std::string_view line : base::SplitStringPiece(
           text, "\n", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY)) {
    if (!line.empty() && line.back() == '\r') {
      line.remove_suffix(1);
    }
    bool is_exception = false;
    bool is_path = false;
    std::string rule;
    if (!ParseEasyListRule(line, &is_exception, &rule, &is_path)) {
      out.skipped++;
      continue;
    }
    out.parsed++;
    if (is_exception) {
      const size_t slash = rule.find('/');
      exceptions.insert(slash == std::string::npos ? rule
                                                   : rule.substr(0, slash));
      continue;
    }
    if (is_path) {
      path_rules.insert(std::move(rule));
    } else {
      hosts.insert(std::move(rule));
    }
  }

  out.hosts.assign(hosts.begin(), hosts.end());
  out.path_rules.assign(path_rules.begin(), path_rules.end());
  out.exceptions.assign(exceptions.begin(), exceptions.end());
  return out;
}

CompiledFilterList MergeCompiledFilterLists(
    const std::vector<CompiledFilterList>& lists,
    std::string_view source) {
  CompiledFilterList out;
  out.source = std::string(source);
  for (const CompiledFilterList& list : lists) {
    out.hosts.insert(out.hosts.end(), list.hosts.begin(), list.hosts.end());
    out.path_rules.insert(out.path_rules.end(), list.path_rules.begin(),
                          list.path_rules.end());
    out.exceptions.insert(out.exceptions.end(), list.exceptions.begin(),
                          list.exceptions.end());
    out.parsed += list.parsed;
    out.skipped += list.skipped;
  }
  UniqueSorted(&out.hosts);
  UniqueSorted(&out.path_rules);
  UniqueSorted(&out.exceptions);
  return out;
}

std::string CompiledFilterListToJson(const CompiledFilterList& list) {
  base::DictValue dict;
  dict.Set("cacheFormat", kCompiledCacheFormat);
  dict.Set("version", list.version);
  dict.Set("source", list.source);
  dict.Set("generatedAt", list.generated_at);
  dict.Set("parsed", list.parsed);
  dict.Set("skipped", list.skipped);

  base::ListValue hosts;
  for (const std::string& host : list.hosts) {
    hosts.Append(host);
  }
  dict.Set("hosts", std::move(hosts));

  base::ListValue path_rules;
  for (const std::string& rule : list.path_rules) {
    path_rules.Append(rule);
  }
  dict.Set("pathRules", std::move(path_rules));

  base::ListValue exceptions;
  for (const std::string& host : list.exceptions) {
    exceptions.Append(host);
  }
  dict.Set("exceptions", std::move(exceptions));

  std::string json;
  // 紧凑 JSON：profile 缓存每次启动都要解析，不必 pretty-print。
  base::JSONWriter::Write(dict, &json);
  return json;
}

bool CompiledFilterListFromJson(std::string_view json,
                                CompiledFilterList* list) {
  std::optional<base::Value> parsed = base::JSONReader::Read(
      json, base::JSON_PARSE_CHROMIUM_EXTENSIONS);
  if (!parsed || !parsed->is_dict()) {
    return false;
  }
  const base::DictValue& dict = parsed->GetDict();
  const int cache_format = dict.FindInt("cacheFormat").value_or(1);
  if (cache_format != kCompiledCacheFormat) {
    return false;
  }
  list->version = dict.FindInt("version").value_or(1);
  list->source = dict.FindString("source") ? *dict.FindString("source") : "";
  list->generated_at =
      dict.FindString("generatedAt") ? *dict.FindString("generatedAt") : "";
  list->parsed = dict.FindInt("parsed").value_or(0);
  list->skipped = dict.FindInt("skipped").value_or(0);
  list->hosts = ListToStrings(dict.FindList("hosts"));
  list->path_rules = ListToStrings(dict.FindList("pathRules"));
  list->exceptions = ListToStrings(dict.FindList("exceptions"));
  return true;
}

std::string JoinNewline(const std::vector<std::string>& values) {
  return base::JoinString(values, "\n");
}

std::vector<std::string> SplitNewline(std::string_view blob) {
  return base::SplitString(blob, "\n", base::TRIM_WHITESPACE,
                           base::SPLIT_WANT_NONEMPTY);
}

}  // namespace aegis
