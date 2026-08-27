// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/cdp_target_filter_unittest.cc

#include "chrome/common/aegis/cdp_target_filter.h"

#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace aegis {

TEST(CdpTargetFilterTest, KeepsBrowserTarget) {
  EXPECT_TRUE(ShouldExposeRemoteCdpTarget("browser", GURL()));
  EXPECT_TRUE(ShouldExposeRemoteCdpTarget("browser", GURL("chrome://aegis")));
}

TEST(CdpTargetFilterTest, KeepsHttpPages) {
  EXPECT_TRUE(ShouldExposeRemoteCdpTarget(
      "page", GURL("https://example.com/path")));
  EXPECT_TRUE(ShouldExposeRemoteCdpTarget("tab", GURL("http://127.0.0.1:8080")));
  EXPECT_TRUE(ShouldExposeRemoteCdpTarget(
      "iframe", GURL("https://shop.example/checkout")));
}

TEST(CdpTargetFilterTest, HidesInternalAndLocalFiles) {
  EXPECT_FALSE(ShouldExposeRemoteCdpTarget("page", GURL("chrome://aegis")));
  EXPECT_FALSE(ShouldExposeRemoteCdpTarget("page", GURL("chrome://settings")));
  EXPECT_FALSE(
      ShouldExposeRemoteCdpTarget("browser_ui", GURL("chrome://inspect")));
  EXPECT_FALSE(ShouldExposeRemoteCdpTarget("page", GURL("file:///tmp/x.html")));
  EXPECT_FALSE(ShouldExposeRemoteCdpTarget("page", GURL("about:blank")));
  EXPECT_FALSE(ShouldExposeRemoteCdpTarget("page", GURL("data:text/html,hi")));
  EXPECT_FALSE(ShouldExposeRemoteCdpTarget(
      "page", GURL("chrome-extension://abc/popup.html")));
  EXPECT_FALSE(ShouldExposeRemoteCdpTarget("other", GURL()));
}

}  // namespace aegis
