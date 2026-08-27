// Copyright 2026 GCSA

#include "chrome/common/aegis/site_control.h"

#include "testing/gtest/include/gtest/gtest.h"

namespace aegis {

TEST(SiteControlTest, NormalizesRegistrableDomains) {
  EXPECT_EQ("example.co.uk", SiteKeyForHost("Login.Example.Co.Uk."));
  EXPECT_EQ("127.0.0.1", SiteKeyForHost("127.0.0.1"));
  EXPECT_TRUE(SiteKeyForHost("https://example.test/path").empty());
}

TEST(SiteControlTest, PausesSubdomainsUntilExpiry) {
  const std::string paused = SetSitePaused("", "www.example.com", 200, 100);
  EXPECT_TRUE(IsSitePaused(paused, "cdn.example.com", 150));
  EXPECT_FALSE(IsSitePaused(paused, "cdn.example.com", 200));
  EXPECT_FALSE(IsSitePaused(paused, "other.test", 150));
}

TEST(SiteControlTest, DropsMalformedExpiredAndResumedEntries) {
  const std::string serialized =
      "bad\nexpired.test|90\nactive.test|200\nother.test|300";
  const std::string resumed = ResumeSite(serialized, "active.test", 100);
  EXPECT_FALSE(IsSitePaused(resumed, "active.test", 150));
  EXPECT_TRUE(IsSitePaused(resumed, "other.test", 150));
  EXPECT_EQ("other.test|300", resumed);
}

}  // namespace aegis
