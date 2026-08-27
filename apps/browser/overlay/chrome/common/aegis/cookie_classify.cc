// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/cookie_classify.cc

#include "chrome/common/aegis/cookie_classify.h"

#include <string>

#include "base/containers/span.h"
#include "base/strings/string_util.h"

namespace aegis {
namespace {

constexpr std::string_view kExactAdvertising[] = {
    "ide",
    "dsid",
    "anid",
    "fr",
    "_fbp",
    "_fbc",
    "personalization_id",
    "muc_ads",
    "muid",
    "muidb",
    "tuuid",
    "tuuid_lu",
    "cto_bundle",
    "_gcl_au",
    "_gcl_aw",
};

constexpr std::string_view kExactAnalytics[] = {
    "_ga",
    "_gid",
    "_gat",
    "__utma",
    "__utmb",
    "__utmc",
    "__utmz",
    "__utmt",
    "_hjid",
    "ajs_anonymous_id",
    "ajs_user_id",
    "ajs_group_id",
    "_clck",
    "_clsk",
    "_pk_id",
    "_pk_ses",
    "_ym_uid",
    "_ym_d",
    "_vwo_uuid",
};

constexpr std::string_view kPrefixAdvertising[] = {"_gcl_"};

constexpr std::string_view kPrefixAnalytics[] = {
    "_ga_", "_gat_", "__utm", "mp_", "_hj", "amp_",
};

constexpr std::string_view kAdNetworkDomains[] = {
    "doubleclick.net",      "googlesyndication.com", "adnxs.com",
    "criteo.com",           "taboola.com",           "outbrain.com",
    "amazon-adsystem.com",  "adsrvr.org",            "pubmatic.com",
    "casalemedia.com",      "scorecardresearch.com", "quantserve.com",
    "moatads.com",          "openx.net",             "rubiconproject.com",
};

constexpr std::string_view kAdHints[] = {
    "ads", "ad_", "_ad", "advert", "doubleclick", "personalization_id",
    "muc_ads",
};

constexpr std::string_view kAnalyticsHints[] = {
    "_ga", "_gid", "_gat", "mixpanel", "amplitude", "hotjar", "optimizely",
    "segment", "analytics",
};

constexpr std::string_view kFunctionalityHints[] = {
    "lang", "locale", "theme", "timezone", "prefs", "preference", "sidebar",
    "consent", "cookie_consent",
};

constexpr std::string_view kNecessaryHints[] = {
    "session", "sess", "csrf", "xsrf", "auth", "token", "sid", "login",
    "secure", "__host-", "__secure-",
};

constexpr std::string_view kLoginPreservedNames[] = {
    "c_user",
    "datr",
    "sb",
    "xs",
    "presence",
};

constexpr std::string_view kLoginPreservedDomains[] = {
    "facebook.com",
    "messenger.com",
};

int ScoreHints(std::string_view blob, base::span<const std::string_view> hints) {
  int score = 0;
  for (std::string_view hint : hints) {
    if (blob.find(hint) != std::string_view::npos) {
      ++score;
    }
  }
  return score;
}

bool NameIn(std::string_view name, base::span<const std::string_view> exact) {
  for (std::string_view item : exact) {
    if (name == item) {
      return true;
    }
  }
  return false;
}

bool NameHasPrefix(std::string_view name,
                   base::span<const std::string_view> prefixes) {
  for (std::string_view prefix : prefixes) {
    if (base::StartsWith(name, prefix)) {
      return true;
    }
  }
  return false;
}

bool IsAdNetworkDomain(std::string_view domain) {
  if (!domain.empty() && domain.front() == '.') {
    domain.remove_prefix(1);
  }
  for (std::string_view suffix : kAdNetworkDomains) {
    if (domain == suffix) {
      return true;
    }
    if (domain.size() > suffix.size() && base::EndsWith(domain, suffix) &&
        domain[domain.size() - suffix.size() - 1] == '.') {
      return true;
    }
  }
  return false;
}

bool MatchesLoginPreservedDomain(std::string_view domain) {
  if (!domain.empty() && domain.front() == '.') {
    domain.remove_prefix(1);
  }
  for (std::string_view suffix : kLoginPreservedDomains) {
    if (domain == suffix) {
      return true;
    }
    if (domain.size() > suffix.size() && base::EndsWith(domain, suffix) &&
        domain[domain.size() - suffix.size() - 1] == '.') {
      return true;
    }
  }
  return false;
}

}  // namespace

CookieCategory ClassifyCookie(std::string_view name,
                              std::string_view domain,
                              [[maybe_unused]] bool session,
                              [[maybe_unused]] std::optional<base::Time> expiry) {
  const std::string name_l = base::ToLowerASCII(name);
  const std::string domain_l = base::ToLowerASCII(domain);

  if (IsLoginPreservedCookie(name_l, domain_l)) {
    return CookieCategory::kNecessary;
  }
  if (NameIn(name_l, kExactAdvertising) ||
      NameHasPrefix(name_l, kPrefixAdvertising)) {
    return CookieCategory::kAdvertising;
  }
  if (NameIn(name_l, kExactAnalytics) ||
      NameHasPrefix(name_l, kPrefixAnalytics)) {
    return CookieCategory::kAnalytics;
  }
  if (IsAdNetworkDomain(domain_l)) {
    return CookieCategory::kAdvertising;
  }

  const std::string blob = name_l + " " + domain_l;
  int necessary = ScoreHints(blob, kNecessaryHints);
  int functionality = ScoreHints(blob, kFunctionalityHints);
  int analytics = ScoreHints(blob, kAnalyticsHints);
  int advertising = ScoreHints(blob, kAdHints);

  CookieCategory best = CookieCategory::kUnknown;
  int best_score = 0;
  auto consider = [&](CookieCategory cat, int score) {
    if (score > best_score) {
      best = cat;
      best_score = score;
    }
  };
  consider(CookieCategory::kNecessary, necessary);
  consider(CookieCategory::kFunctionality, functionality);
  consider(CookieCategory::kAnalytics, analytics);
  consider(CookieCategory::kAdvertising, advertising);

  if (best_score == 0) {
    return CookieCategory::kUnknown;
  }
  return best;
}

bool ShouldRejectCookie(CookieCategory category) {
  return category == CookieCategory::kAnalytics ||
         category == CookieCategory::kAdvertising;
}

const char* CookieCategoryToString(CookieCategory category) {
  switch (category) {
    case CookieCategory::kNecessary:
      return "necessary";
    case CookieCategory::kFunctionality:
      return "functionality";
    case CookieCategory::kAnalytics:
      return "analytics";
    case CookieCategory::kAdvertising:
      return "advertising";
    case CookieCategory::kUnknown:
      return "unknown";
  }
  return "unknown";
}

bool IsAdNetworkCookieDomain(std::string_view domain) {
  return IsAdNetworkDomain(base::ToLowerASCII(domain));
}

bool IsLoginPreservedCookie(std::string_view name, std::string_view domain) {
  const std::string name_l = base::ToLowerASCII(name);
  if (!NameIn(name_l, kLoginPreservedNames)) {
    return false;
  }
  return MatchesLoginPreservedDomain(base::ToLowerASCII(domain));
}

bool CookieNameHitsTrackingTable(std::string_view name) {
  const std::string name_l = base::ToLowerASCII(name);
  return NameIn(name_l, kExactAdvertising) ||
         NameIn(name_l, kExactAnalytics) ||
         NameHasPrefix(name_l, kPrefixAdvertising) ||
         NameHasPrefix(name_l, kPrefixAnalytics);
}

std::string FormatDeletedCookieDetail(std::string_view name,
                                      std::string_view domain,
                                      CookieCategory category) {
  std::string detail(CookieCategoryToString(category));
  if (IsAdNetworkCookieDomain(domain)) {
    detail += ", ad-network";
  } else {
    detail += ", first-party";
  }
  if (CookieNameHitsTrackingTable(name)) {
    detail += ", name-hit";
  }
  return detail;
}

}  // namespace aegis
