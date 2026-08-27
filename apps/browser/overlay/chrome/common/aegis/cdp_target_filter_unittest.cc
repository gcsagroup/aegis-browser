// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/cdp_target_filter_unittest.cc

#include "chrome/common/aegis/cdp_target_filter.h"

#include <array>

#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace aegis {
namespace {

constexpr std::array kAllTargetOperations = {
    RemoteCdpTargetOperation::kEnumerate,
    RemoteCdpTargetOperation::kCreate,
    RemoteCdpTargetOperation::kWebSocketConnect,
    RemoteCdpTargetOperation::kGetInfo,
    RemoteCdpTargetOperation::kAttach,
    RemoteCdpTargetOperation::kNavigate,
    RemoteCdpTargetOperation::kActivate,
    RemoteCdpTargetOperation::kClose,
    RemoteCdpTargetOperation::kExposeDevToolsProtocol,
    RemoteCdpTargetOperation::kOpenDevTools,
};

}  // namespace

TEST(CdpTargetFilterTest, KeepsBrowserTarget) {
  EXPECT_TRUE(ShouldExposeRemoteCdpTarget("browser", GURL()));
  EXPECT_TRUE(ShouldExposeRemoteCdpTarget("browser", GURL("chrome://aegis")));
}

TEST(CdpTargetFilterTest, LimitsBrowserTargetToConnectionOperations) {
  EXPECT_TRUE(ShouldAllowRemoteCdpTargetOperation(
      RemoteCdpTargetOperation::kEnumerate, "browser", GURL()));
  EXPECT_TRUE(ShouldAllowRemoteCdpTargetOperation(
      RemoteCdpTargetOperation::kWebSocketConnect, "browser", GURL()));
  EXPECT_TRUE(ShouldAllowRemoteCdpTargetOperation(
      RemoteCdpTargetOperation::kGetInfo, "browser", GURL()));
  EXPECT_TRUE(ShouldAllowRemoteCdpTargetOperation(
      RemoteCdpTargetOperation::kAttach, "browser", GURL()));
  EXPECT_FALSE(ShouldAllowRemoteCdpTargetOperation(
      RemoteCdpTargetOperation::kCreate, "browser", GURL()));
  EXPECT_FALSE(ShouldAllowRemoteCdpTargetOperation(
      RemoteCdpTargetOperation::kNavigate, "browser", GURL()));
  EXPECT_FALSE(ShouldAllowRemoteCdpTargetOperation(
      RemoteCdpTargetOperation::kActivate, "browser", GURL()));
  EXPECT_FALSE(ShouldAllowRemoteCdpTargetOperation(
      RemoteCdpTargetOperation::kClose, "browser", GURL()));
  EXPECT_FALSE(ShouldAllowRemoteCdpTargetOperation(
      RemoteCdpTargetOperation::kExposeDevToolsProtocol, "browser", GURL()));
  EXPECT_FALSE(ShouldAllowRemoteCdpTargetOperation(
      RemoteCdpTargetOperation::kOpenDevTools, "browser", GURL()));
}

TEST(CdpTargetFilterTest, FiltersDiscoveryAndAutoAttachPerResolvedTarget) {
  // setDiscoverTargets/setAutoAttach 本身没有 target，不能用本策略拒绝。
  // 命令产出的 discovered target 走 kEnumerate，auto-attach 候选走 kAttach。
  EXPECT_TRUE(ShouldAllowRemoteCdpTargetOperation(
      RemoteCdpTargetOperation::kEnumerate, "page",
      GURL("https://example.test/discovered")));
  EXPECT_TRUE(ShouldAllowRemoteCdpTargetOperation(
      RemoteCdpTargetOperation::kAttach, "page",
      GURL("https://example.test/attached")));
  EXPECT_FALSE(ShouldAllowRemoteCdpTargetOperation(
      RemoteCdpTargetOperation::kEnumerate, "page", GURL("chrome://aegis")));
  EXPECT_TRUE(ShouldAllowRemoteCdpTargetOperation(
      RemoteCdpTargetOperation::kAttach, "service_worker",
      GURL("https://example.test/sw.js")));
}

TEST(CdpTargetFilterTest, KeepsHttpPages) {
  EXPECT_TRUE(
      ShouldExposeRemoteCdpTarget("page", GURL("https://example.com/path")));
  EXPECT_TRUE(
      ShouldExposeRemoteCdpTarget("tab", GURL("http://127.0.0.1:8080")));
  EXPECT_TRUE(ShouldExposeRemoteCdpTarget(
      "iframe", GURL("https://shop.example/checkout")));
}

TEST(CdpTargetFilterTest, KeepsWorkersFromPublicWebOrigins) {
  EXPECT_TRUE(ShouldExposeRemoteCdpTarget("service_worker",
                                          GURL("https://example.test/sw.js")));
  EXPECT_TRUE(ShouldExposeRemoteCdpTarget(
      "shared_worker", GURL("https://example.test/shared.js")));
  EXPECT_TRUE(ShouldExposeRemoteCdpTarget(
      "worker", GURL("blob:https://example.test/worker-id")));
  EXPECT_TRUE(ShouldExposeRemoteCdpTarget(
      "page", GURL("blob:https://example.test/document-id")));
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

TEST(CdpTargetFilterTest, AllowsOnlyCreationBootstrapForAboutBlank) {
  for (RemoteCdpTargetOperation operation : kAllTargetOperations) {
    EXPECT_EQ(operation == RemoteCdpTargetOperation::kCreate,
              ShouldAllowRemoteCdpTargetOperation(operation, "page",
                                                  GURL("about:blank")));
  }
}

TEST(CdpTargetFilterTest, AppliesSameBoundaryToEveryTargetOperation) {
  for (RemoteCdpTargetOperation operation : kAllTargetOperations) {
    const bool privileged_bridge =
        operation == RemoteCdpTargetOperation::kExposeDevToolsProtocol ||
        operation == RemoteCdpTargetOperation::kOpenDevTools;
    EXPECT_EQ(!privileged_bridge,
              ShouldAllowRemoteCdpTargetOperation(
                  operation, "page", GURL("https://example.test/path")));
    EXPECT_FALSE(ShouldAllowRemoteCdpTargetOperation(operation, "page",
                                                     GURL("chrome://aegis")));
    EXPECT_FALSE(ShouldAllowRemoteCdpTargetOperation(
        operation, "page", GURL("file:///tmp/private.txt")));
    EXPECT_FALSE(ShouldAllowRemoteCdpTargetOperation(
        operation, "browser_ui", GURL("https://example.test/fake")));
    EXPECT_FALSE(ShouldAllowRemoteCdpTargetOperation(
        operation, "new_unknown_type", GURL("https://example.test/fake")));
  }
}

TEST(CdpTargetFilterTest, RejectsPrivilegedBridgesForPublicPages) {
  EXPECT_FALSE(ShouldAllowRemoteCdpTargetOperation(
      RemoteCdpTargetOperation::kExposeDevToolsProtocol, "page",
      GURL("https://example.test/path")));
  EXPECT_FALSE(ShouldAllowRemoteCdpTargetOperation(
      RemoteCdpTargetOperation::kOpenDevTools, "page",
      GURL("https://example.test/path")));
}

TEST(CdpTargetFilterTest, RejectsWorkersFromSensitiveOriginsAndNonWebSchemes) {
  EXPECT_FALSE(ShouldExposeRemoteCdpTarget("service_worker",
                                           GURL("chrome://aegis/sw.js")));
  EXPECT_FALSE(ShouldExposeRemoteCdpTarget("shared_worker",
                                           GURL("file:///tmp/worker.js")));
  EXPECT_FALSE(ShouldExposeRemoteCdpTarget(
      "worker", GURL("blob:chrome://aegis/worker-id")));
  EXPECT_FALSE(ShouldExposeRemoteCdpTarget("worker", GURL("blob:null/id")));
  EXPECT_FALSE(
      ShouldExposeRemoteCdpTarget("other", GURL("https://example.test")));
}

}  // namespace aegis
