// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/filter_list_matcher.cc

#include "chrome/common/aegis/filter_list_matcher.h"

#include "base/strings/string_util.h"
#include "chrome/common/aegis/builtin_tracker_hosts.h"
#include "chrome/common/aegis/first_party_collect.h"
#include "url/gurl.h"

namespace aegis {
namespace {

bool PathRuleMatches(std::string_view rule, const GURL& url) {
  if (!url.is_valid() || !url.has_host()) {
    return false;
  }
  const size_t slash = rule.find('/');
  if (slash == std::string_view::npos) {
    return false;
  }
  const std::string_view host = rule.substr(0, slash);
  if (host.empty() || !url.DomainIs(host)) {
    return false;
  }
  return base::StartsWith(url.path(), rule.substr(slash));
}

}  // namespace

// static
FilterListMatcher* FilterListMatcher::GetInstance() {
  return base::Singleton<FilterListMatcher>::get();
}

FilterListMatcher::FilterListMatcher() = default;
FilterListMatcher::~FilterListMatcher() = default;

void FilterListMatcher::ReplaceCompiledList(CompiledFilterList list) {
  base::AutoLock lock(lock_);
  hosts_.clear();
  exceptions_.clear();
  hosts_.insert(list.hosts.begin(), list.hosts.end());
  exceptions_.insert(list.exceptions.begin(), list.exceptions.end());
  list_ = std::move(list);
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

  const std::string host = base::ToLowerASCII(url.host());
  base::AutoLock lock(lock_);
  if (MatchesException(host)) {
    return BlockReason::kNone;
  }
  if (MatchesCompiledHost(host) || MatchesPathRule(url)) {
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
  std::string current(host);
  while (!current.empty()) {
    if (hosts_.contains(current)) {
      return true;
    }
    const size_t dot = current.find('.');
    if (dot == std::string::npos) {
      break;
    }
    current = current.substr(dot + 1);
  }
  return false;
}

bool FilterListMatcher::MatchesException(std::string_view host) const {
  std::string current(host);
  while (!current.empty()) {
    if (exceptions_.contains(current)) {
      return true;
    }
    const size_t dot = current.find('.');
    if (dot == std::string::npos) {
      break;
    }
    current = current.substr(dot + 1);
  }
  return false;
}

bool FilterListMatcher::MatchesPathRule(const GURL& url) const {
  for (const std::string& rule : list_.path_rules) {
    if (PathRuleMatches(rule, url)) {
      return true;
    }
  }
  return false;
}

}  // namespace aegis
