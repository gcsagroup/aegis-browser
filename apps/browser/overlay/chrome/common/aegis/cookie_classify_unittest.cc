// Copyright 2026 GCSA

#include "chrome/common/aegis/cookie_classify.h"

#include "testing/gtest/include/gtest/gtest.h"

namespace aegis {
namespace {

TEST(CookieClassifyTest, ClassifiesExactAndPrefixTrackingNames) {
  EXPECT_EQ(ClassifyCookie("_GA", "example.com", false, std::nullopt),
            CookieCategory::kAnalytics);
  EXPECT_EQ(ClassifyCookie("_ga_property", "example.com", false, std::nullopt),
            CookieCategory::kAnalytics);
  EXPECT_EQ(ClassifyCookie("IDE", ".doubleclick.net", false, std::nullopt),
            CookieCategory::kAdvertising);
  EXPECT_EQ(ClassifyCookie("_gcl_custom", "shop.example", false, std::nullopt),
            CookieCategory::kAdvertising);
}

TEST(CookieClassifyTest, PreservesLoginAndNecessaryCookies) {
  EXPECT_TRUE(IsLoginPreservedCookie("C_USER", ".FACEBOOK.COM"));
  EXPECT_EQ(ClassifyCookie("c_user", ".facebook.com", false, std::nullopt),
            CookieCategory::kNecessary);
  EXPECT_EQ(ClassifyCookie("session_ads", "shop.example", true, std::nullopt),
            CookieCategory::kNecessary);
  EXPECT_FALSE(ShouldRejectCookie(CookieCategory::kNecessary));
  EXPECT_FALSE(ShouldRejectCookie(CookieCategory::kFunctionality));
  EXPECT_FALSE(ShouldRejectCookie(CookieCategory::kUnknown));
}

TEST(CookieClassifyTest, EnforcesDomainSuffixBoundaries) {
  EXPECT_TRUE(IsAdNetworkCookieDomain("ads.doubleclick.net"));
  EXPECT_FALSE(IsAdNetworkCookieDomain("doubleclick.net.evil.example"));
  EXPECT_FALSE(IsAdNetworkCookieDomain("notdoubleclick.net"));
  EXPECT_FALSE(IsAdNetworkCookieDomain("facebook.com"));
  EXPECT_FALSE(IsLoginPreservedCookie("c_user", "facebook.com.evil.example"));
}

TEST(CookieClassifyTest, RejectsOnlyAnalyticsAndAdvertisingByDefault) {
  EXPECT_TRUE(ShouldRejectCookie(CookieCategory::kAnalytics));
  EXPECT_TRUE(ShouldRejectCookie(CookieCategory::kAdvertising));
  EXPECT_EQ(FormatDeletedCookieDetail("_ga", "shop.example",
                                      CookieCategory::kAnalytics),
            "analytics, first-party, name-hit");
  EXPECT_EQ(FormatDeletedCookieDetail("IDE", ".doubleclick.net",
                                      CookieCategory::kAdvertising),
            "advertising, ad-network, name-hit");
}

}  // namespace
}  // namespace aegis
