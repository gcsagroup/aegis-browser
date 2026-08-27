// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/tracking_query_params.cc

#include "chrome/common/aegis/tracking_query_params.h"

#include <string>
#include <vector>

#include "base/strings/string_util.h"
#include "net/base/url_util.h"
#include "url/gurl.h"

namespace aegis {
namespace {

#include "chrome/common/aegis/generated/tracking_query_params.inc"

bool LooksLikeTrackingHash(std::string_view ref) {
  return base::StartsWith(ref, "utm_", base::CompareCase::INSENSITIVE_ASCII) ||
         base::StartsWith(ref, "fbclid",
                          base::CompareCase::INSENSITIVE_ASCII) ||
         base::StartsWith(ref, "gclid", base::CompareCase::INSENSITIVE_ASCII) ||
         ref.find("utm_") != std::string_view::npos ||
         ref.find("fbclid") != std::string_view::npos ||
         ref.find("gclid") != std::string_view::npos;
}

}  // namespace

bool IsTrackingQueryParam(std::string_view name) {
  for (std::string_view param : kTrackingQueryParams) {
    if (base::EqualsCaseInsensitiveASCII(name, param)) {
      return true;
    }
  }
  return false;
}

GURL SanitizeTrackingDecorations(const GURL& url,
                                 std::vector<std::string>* removed) {
  if (!url.is_valid() || (!url.has_query() && !url.has_ref())) {
    return url;
  }

  std::string kept_query;
  for (net::QueryIterator it(url); !it.IsAtEnd(); it.Advance()) {
    const std::string_view key = it.GetKey();
    if (IsTrackingQueryParam(key)) {
      if (removed) {
        removed->emplace_back(key);
      }
      continue;
    }
    if (!kept_query.empty()) {
      kept_query += "&";
    }
    kept_query.append(key);
    const std::string_view value = it.GetValue();
    if (!value.empty()) {
      kept_query += "=";
      kept_query.append(value);
    }
  }

  GURL::Replacements replacements;
  if (url.has_query()) {
    if (kept_query.empty()) {
      replacements.ClearQuery();
    } else {
      replacements.SetQueryStr(kept_query);
    }
  }

  bool clear_ref = false;
  if (url.has_ref() && LooksLikeTrackingHash(url.ref())) {
    clear_ref = true;
    replacements.ClearRef();
    if (removed) {
      removed->emplace_back("#tracking-hash");
    }
  }

  if (!url.has_query() && !clear_ref) {
    return url;
  }
  return url.ReplaceComponents(replacements);
}

}  // namespace aegis
