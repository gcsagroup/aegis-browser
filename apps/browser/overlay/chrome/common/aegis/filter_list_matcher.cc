// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/filter_list_matcher.cc

#include "chrome/common/aegis/filter_list_matcher.h"

#include <algorithm>
#include <utility>

#include "base/strings/string_util.h"
#include "chrome/common/aegis/builtin_tracker_hosts.h"
#include "chrome/common/aegis/first_party_collect.h"
#include "url/gurl.h"

namespace aegis {

// static
FilterListMatcher* FilterListMatcher::GetInstance() {
  return base::Singleton<FilterListMatcher>::get();
}

FilterListMatcher::FilterListMatcher() = default;
FilterListMatcher::~FilterListMatcher() = default;

void FilterListMatcher::ReplaceCompiledList(CompiledFilterList list) {
  base::flat_set<std::string> hosts(list.hosts.begin(), list.hosts.end());
  base::flat_set<std::string> exceptions(list.exceptions.begin(),
                                         list.exceptions.end());
  std::vector<std::pair<std::string, std::string>> parsed_path_rules;
  parsed_path_rules.reserve(list.path_rules.size());
  for (const std::string& rule : list.path_rules) {
    const size_t slash = rule.find('/');
    if (slash == std::string::npos || slash == 0) {
      continue;
    }
    parsed_path_rules.emplace_back(rule.substr(0, slash), rule.substr(slash));
  }
  std::sort(parsed_path_rules.begin(), parsed_path_rules.end());

  using PathRuleEntry = std::pair<std::string, std::vector<std::string>>;
  std::vector<PathRuleEntry> path_rule_entries;
  path_rule_entries.reserve(parsed_path_rules.size());
  for (auto& [host, path] : parsed_path_rules) {
    if (path_rule_entries.empty() || path_rule_entries.back().first != host) {
      path_rule_entries.emplace_back(std::move(host),
                                     std::vector<std::string>());
    }
    path_rule_entries.back().second.push_back(std::move(path));
  }
  base::flat_map<std::string, std::vector<std::string>> path_rules(
      base::sorted_unique, std::move(path_rule_entries));

  {
    base::AutoLock lock(lock_);
    hosts_.swap(hosts);
    exceptions_.swap(exceptions);
    path_rules_.swap(path_rules);
    std::swap(list_, list);
  }
  // 旧容器已交换到局部变量，离开锁后再析构，避免阻塞请求分类。
}

CompiledFilterList FilterListMatcher::CurrentList() const {
  base::AutoLock lock(lock_);
  return list_;
}

bool FilterListMatcher::ShouldBlock(const GURL& url) const {
  return ClassifyBlock(url) != BlockReason::kNone;
}

BlockReason FilterListMatcher::ClassifyBlock(const GURL& url) const {
  if (!url.is_valid() || !url.has_host()) {
    return BlockReason::kNone;
  }
  if (MatchesBuiltinTrackerRule(url)) {
    return BlockReason::kEasyList;
  }
  if (IsFirstPartyCollectUrl(url)) {
    return BlockReason::kFirstPartyCollect;
  }

  const std::string_view host = url.host();
  base::AutoLock lock(lock_);
  if (MatchesException(host)) {
    return BlockReason::kNone;
  }
  if (MatchesCompiledHost(host) || MatchesPathRule(host, url.path())) {
    return BlockReason::kEasyList;
  }
  return BlockReason::kNone;
}

const char* BlockReasonToString(BlockReason reason) {
  switch (reason) {
    case BlockReason::kEasyList:
      return "easylist";
    case BlockReason::kFirstPartyCollect:
      return "collect";
    case BlockReason::kNone:
      return "none";
  }
  return "none";
}

size_t FilterListMatcher::compiled_host_count() const {
  base::AutoLock lock(lock_);
  return list_.hosts.size() + list_.path_rules.size();
}

bool FilterListMatcher::MatchesCompiledHost(std::string_view host) const {
  std::string_view current = host;
  if (!current.empty() && current.back() == '.') {
    current.remove_suffix(1);
  }
  while (!current.empty()) {
    if (hosts_.contains(current)) {
      return true;
    }
    const size_t dot = current.find('.');
    if (dot == std::string::npos) {
      break;
    }
    current.remove_prefix(dot + 1);
  }
  return false;
}

bool FilterListMatcher::MatchesException(std::string_view host) const {
  std::string_view current = host;
  if (!current.empty() && current.back() == '.') {
    current.remove_suffix(1);
  }
  while (!current.empty()) {
    if (exceptions_.contains(current)) {
      return true;
    }
    const size_t dot = current.find('.');
    if (dot == std::string::npos) {
      break;
    }
    current.remove_prefix(dot + 1);
  }
  return false;
}

bool FilterListMatcher::MatchesPathRule(std::string_view host,
                                        std::string_view path) const {
  std::string_view current = host;
  if (!current.empty() && current.back() == '.') {
    current.remove_suffix(1);
  }
  while (!current.empty()) {
    const auto it = path_rules_.find(current);
    if (it != path_rules_.end()) {
      for (const std::string& prefix : it->second) {
        if (base::StartsWith(path, prefix)) {
          return true;
        }
      }
    }
    const size_t dot = current.find('.');
    if (dot == std::string::npos) {
      break;
    }
    current.remove_prefix(dot + 1);
  }
  return false;
}

}  // namespace aegis
