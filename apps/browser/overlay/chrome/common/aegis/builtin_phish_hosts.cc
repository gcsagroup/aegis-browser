// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/builtin_phish_hosts.cc

#include "chrome/common/aegis/builtin_phish_hosts.h"

#include <string_view>

#include "base/strings/string_util.h"
#include "url/gurl.h"

namespace aegis {
namespace {

// Generated from packages/core — regenerate via sync-core-snapshot.sh.
#include "chrome/common/aegis/generated/phish_hosts.inc"

bool RuleMatches(std::string_view rule, const GURL& url) {
  if (!url.is_valid() || !url.has_host()) {
    return false;
  }

  const size_t slash = rule.find('/');
  const std::string_view host =
      slash == std::string_view::npos ? rule : rule.substr(0, slash);
  if (host.empty() || !url.DomainIs(host)) {
    return false;
  }

  if (slash == std::string_view::npos) {
    return true;
  }

  const std::string_view path_suffix = rule.substr(slash);
  return base::StartsWith(url.path(), path_suffix);
}

}  // namespace

bool MatchesBuiltinPhishRule(const GURL& url) {
  for (std::string_view rule : kBuiltinPhishRules) {
    if (RuleMatches(rule, url)) {
      return true;
    }
  }
  return false;
}

}  // namespace aegis
