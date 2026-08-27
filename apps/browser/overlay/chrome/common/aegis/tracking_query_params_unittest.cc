// Copyright 2026 GCSA

#include "chrome/common/aegis/tracking_query_params.h"

#include <string>
#include <vector>

#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace aegis {
namespace {

TEST(TrackingQueryParamsTest, MatchesNamesCaseInsensitively) {
  EXPECT_TRUE(IsTrackingQueryParam("utm_source"));
  EXPECT_TRUE(IsTrackingQueryParam("UTM_SOURCE"));
  EXPECT_TRUE(IsTrackingQueryParam("FbClId"));
  EXPECT_FALSE(IsTrackingQueryParam("campaign"));
  EXPECT_FALSE(IsTrackingQueryParam("utm_source_extra"));
}

TEST(TrackingQueryParamsTest, RemovesOnlyTrackingQueryParameters) {
  const GURL input(
      "https://news.example/article?UTM_SOURCE=mail&keep=1&fbclid=abc&keep=2"
      "#section");
  std::vector<std::string> removed;

  const GURL cleaned = SanitizeTrackingDecorations(input, &removed);

  EXPECT_EQ(cleaned.spec(),
            "https://news.example/article?keep=1&keep=2#section");
  EXPECT_EQ(removed, (std::vector<std::string>{"UTM_SOURCE", "fbclid"}));
}

TEST(TrackingQueryParamsTest, ClearsTrackingHashAndEmptyTrackingQuery) {
  const GURL input(
      "https://news.example/article?gclid=abc#utm_campaign=spring");
  std::vector<std::string> removed;

  const GURL cleaned = SanitizeTrackingDecorations(input, &removed);

  EXPECT_EQ(cleaned.spec(), "https://news.example/article");
  EXPECT_EQ(removed, (std::vector<std::string>{"gclid", "#tracking-hash"}));
}

TEST(TrackingQueryParamsTest, LeavesInvalidOrUndecoratedUrlUnchanged) {
  const GURL invalid("http://[");
  const GURL plain("https://example.com/path#section");

  EXPECT_EQ(SanitizeTrackingDecorations(invalid), invalid);
  EXPECT_EQ(SanitizeTrackingDecorations(plain), plain);
}

}  // namespace
}  // namespace aegis
