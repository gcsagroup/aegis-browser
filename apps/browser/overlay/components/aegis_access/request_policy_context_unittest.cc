// Copyright 2026 GCSA

#include "components/aegis_access/request_policy_context.h"

#include <optional>
#include <string>

#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace aegis_access {
namespace {

OwnershipKey TestOwner() {
  return OwnershipKey{ChannelNamespace::kBeta, "profile-beta",
                      "partition-main"};
}

BrowserOwnedRequestMetadata DocumentMetadata(const GURL& top_frame_url) {
  return BrowserOwnedRequestMetadata{
      "request-document", TestOwner(), RequestAttributionKind::kDocument,
      "document-token", {}, net::SchemefulSite(top_frame_url)};
}

TEST(RequestPolicyContextTest, CanonicalizesDocumentRequestWithPrivatePsl) {
  const BrowserOwnedRequestMetadata metadata =
      DocumentMetadata(GURL("https://shop.foo.appspot.com/page"));
  const RequestPolicyContextResult result = CanonicalizeBrowserOwnedRequest(
      metadata,
      GURL("https://B%C3%9CCHER.example:8443/path?secret=yes#fragment"));

  ASSERT_EQ(result.error, RequestContextError::kNone);
  ASSERT_TRUE(result.context.has_value());
  EXPECT_EQ(result.context->request_id(), "request-document");
  EXPECT_EQ(result.context->owner(), TestOwner());
  EXPECT_EQ(result.context->attribution_kind(),
            RequestAttributionKind::kDocument);
  EXPECT_EQ(result.context->document_token(), "document-token");
  EXPECT_TRUE(result.context->pending_navigation_token().empty());
  EXPECT_TRUE(result.context->site_ownership_reliable());
  EXPECT_EQ(result.context->top_level_site(),
            "https://foo.appspot.com");
  EXPECT_EQ(result.context->exact_host(), "xn--bcher-kva.example");
  EXPECT_EQ(result.context->registrable_domain(),
            "xn--bcher-kva.example");
  EXPECT_EQ(result.context->scheme(), RequestScheme::kHttps);
  EXPECT_EQ(result.context->port(), 8443u);
}

TEST(RequestPolicyContextTest, DerivesPendingNavigationSiteFromTarget) {
  const BrowserOwnedRequestMetadata metadata{
      "request-navigation", TestOwner(),
      RequestAttributionKind::kPendingNavigation, {}, "navigation-token",
      std::nullopt};
  const RequestPolicyContextResult result = CanonicalizeBrowserOwnedRequest(
      metadata, GURL("http://deep.example.test:8080/path?q=ignored"));

  ASSERT_EQ(result.error, RequestContextError::kNone);
  ASSERT_TRUE(result.context.has_value());
  EXPECT_TRUE(result.context->site_ownership_reliable());
  EXPECT_EQ(result.context->top_level_site(), "http://example.test");
  EXPECT_EQ(result.context->exact_host(), "deep.example.test");
  EXPECT_EQ(result.context->scheme(), RequestScheme::kHttp);
  EXPECT_EQ(result.context->port(), 8080u);
}

TEST(RequestPolicyContextTest, PreservesProfileOnlyOwnershipWithoutSite) {
  const BrowserOwnedRequestMetadata metadata{
      "request-profile", TestOwner(), RequestAttributionKind::kProfileOnly,
      {}, {}, std::nullopt};
  const RequestPolicyContextResult result =
      CanonicalizeBrowserOwnedRequest(metadata, GURL("wss://socket.example/"));

  ASSERT_EQ(result.error, RequestContextError::kNone);
  ASSERT_TRUE(result.context.has_value());
  EXPECT_FALSE(result.context->site_ownership_reliable());
  EXPECT_TRUE(result.context->top_level_site().empty());
  EXPECT_EQ(result.context->scheme(), RequestScheme::kWss);
  EXPECT_EQ(result.context->port(), 443u);
}

TEST(RequestPolicyContextTest, RejectsUntrustedOrAmbiguousShapes) {
  BrowserOwnedRequestMetadata metadata =
      DocumentMetadata(GURL("https://top.example/"));

  metadata.owner.profile_token.clear();
  EXPECT_EQ(CanonicalizeBrowserOwnedRequest(metadata,
                                             GURL("https://target.example/"))
                .error,
            RequestContextError::kInvalidOwner);

  metadata = DocumentMetadata(GURL("https://top.example/"));
  metadata.request_id.clear();
  EXPECT_EQ(CanonicalizeBrowserOwnedRequest(metadata,
                                             GURL("https://target.example/"))
                .error,
            RequestContextError::kInvalidRequestId);

  metadata = DocumentMetadata(GURL("https://top.example/"));
  metadata.pending_navigation_token = "unexpected";
  const RequestPolicyContextResult ambiguous = CanonicalizeBrowserOwnedRequest(
      metadata, GURL("https://target.example/"));
  EXPECT_EQ(ambiguous.error, RequestContextError::kInvalidAttribution);
  EXPECT_FALSE(ambiguous.context.has_value());

  metadata = DocumentMetadata(GURL("https://top.example/"));
  metadata.attribution_kind = static_cast<RequestAttributionKind>(99);
  const RequestPolicyContextResult unknown_attribution =
      CanonicalizeBrowserOwnedRequest(metadata,
                                      GURL("https://target.example/"));
  EXPECT_EQ(unknown_attribution.error,
            RequestContextError::kInvalidAttribution);
  EXPECT_FALSE(unknown_attribution.context.has_value());

  metadata = DocumentMetadata(GURL("data:text/plain,opaque"));
  EXPECT_EQ(CanonicalizeBrowserOwnedRequest(metadata,
                                             GURL("https://target.example/"))
                .error,
            RequestContextError::kInvalidTopLevelSite);

  metadata = DocumentMetadata(GURL("https://top.example/"));
  EXPECT_EQ(CanonicalizeBrowserOwnedRequest(metadata,
                                             GURL("ftp://target.example/"))
                .error,
            RequestContextError::kUnsupportedScheme);
  EXPECT_EQ(CanonicalizeBrowserOwnedRequest(metadata, GURL("not a url"))
                .error,
            RequestContextError::kInvalidUrl);
  EXPECT_EQ(CanonicalizeBrowserOwnedRequest(metadata,
                                             GURL("https://target.example:0/"))
                .error,
            RequestContextError::kInvalidPort);
}

TEST(RequestPolicyContextTest, RejectsWebSocketAsPendingTopLevelNavigation) {
  const BrowserOwnedRequestMetadata metadata{
      "request-navigation", TestOwner(),
      RequestAttributionKind::kPendingNavigation, {}, "navigation-token",
      std::nullopt};
  EXPECT_EQ(CanonicalizeBrowserOwnedRequest(
                metadata, GURL("wss://socket.example/path"))
                .error,
            RequestContextError::kInvalidTopLevelSite);
}

}  // namespace
}  // namespace aegis_access
