// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/cdp_target_filter.cc

#include "chrome/common/aegis/cdp_target_filter.h"

#include "url/gurl.h"

namespace aegis {

bool ShouldExposeRemoteCdpTarget(std::string_view type, const GURL& url) {
  // Playwright 需要 browser target；其 URL 常为空。
  if (type == "browser") {
    return true;
  }
  // 只暴露普通网页。隐藏 chrome://、file://、data:、扩展页等。
  return url.is_valid() && url.SchemeIsHTTPOrHTTPS();
}

}  // namespace aegis
