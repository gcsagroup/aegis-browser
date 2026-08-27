// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/first_party_collect.cc

#include "chrome/common/aegis/first_party_collect.h"

#include <string_view>

#include "base/strings/string_util.h"
#include "net/base/url_util.h"
#include "url/gurl.h"

namespace aegis {
namespace {

#include "chrome/common/aegis/generated/first_party_collect_paths.inc"

bool PathMatchesCollect(std::string_view path, std::string_view rule) {
  if (path == rule) {
    return true;
  }
  if (path.size() > rule.size() && base::StartsWith(path, rule) &&
      path[rule.size()] == '/') {
    return true;
  }
  return (base::EndsWith(rule, ".js") || base::EndsWith(rule, ".php")) &&
         base::EndsWith(path, rule);
}

bool LooksLikeGa4CollectQuery(const GURL& url) {
  std::string v;
  std::string tid;
  std::string en;
  std::string cid;
  if (!net::GetValueForKeyInQuery(url, "v", &v) || v != "2") {
    return false;
  }
  if (!net::GetValueForKeyInQuery(url, "tid", &tid)) {
    return false;
  }
  const std::string tid_l = base::ToLowerASCII(tid);
  if (!base::StartsWith(tid_l, "g-") && !base::StartsWith(tid_l, "gt-")) {
    return false;
  }
  // 自定义路径上同时要求 en/cid，避免把普通 API 误判成 GA4。
  if (!net::GetValueForKeyInQuery(url, "en", &en) || en.empty()) {
    return false;
  }
  if (!net::GetValueForKeyInQuery(url, "cid", &cid) || cid.empty()) {
    return false;
  }
  return true;
}

}  // namespace

bool IsFirstPartyCollectUrl(const GURL& url) {
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS() || !url.has_path()) {
    return false;
  }
  if (LooksLikeGa4CollectQuery(url)) {
    return true;
  }
  const std::string path = base::ToLowerASCII(url.path());
  for (std::string_view rule : kFirstPartyCollectPaths) {
    if (PathMatchesCollect(path, rule)) {
      return true;
    }
  }
  return false;
}

}  // namespace aegis
