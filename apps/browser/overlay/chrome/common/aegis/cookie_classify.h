// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/cookie_classify.h
// Keep aligned with packages/core/src/tracker/cookie-classify.ts.

#ifndef CHROME_COMMON_AEGIS_COOKIE_CLASSIFY_H_
#define CHROME_COMMON_AEGIS_COOKIE_CLASSIFY_H_

#include <optional>
#include <string>
#include <string_view>

#include "base/time/time.h"

namespace aegis {

enum class CookieCategory {
  kNecessary,
  kFunctionality,
  kAnalytics,
  kAdvertising,
  kUnknown,
};

CookieCategory ClassifyCookie(std::string_view name,
                              std::string_view domain,
                              bool session,
                              std::optional<base::Time> expiry);

// Default policy matches packages/core DEFAULT_SETTINGS.rejectedCookieCategories.
bool ShouldRejectCookie(CookieCategory category);

const char* CookieCategoryToString(CookieCategory category);

// facebook.com 不是广告网络；c_user / datr 等登录 Cookie 强制保留。
bool IsAdNetworkCookieDomain(std::string_view domain);
bool IsLoginPreservedCookie(std::string_view name, std::string_view domain);
bool CookieNameHitsTrackingTable(std::string_view name);

// 会话清单用：例如 "analytics, first-party, name-hit"。
std::string FormatDeletedCookieDetail(std::string_view name,
                                      std::string_view domain,
                                      CookieCategory category);

}  // namespace aegis

#endif  // CHROME_COMMON_AEGIS_COOKIE_CLASSIFY_H_
