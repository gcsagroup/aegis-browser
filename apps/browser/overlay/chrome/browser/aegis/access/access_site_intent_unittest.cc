// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_site_intent.h"

#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::access {
namespace {

OwnershipKey TestOwner() {
  return {ChannelNamespace::kDev, "profile-token", "partition-token"};
}

AccessSiteHost Host(std::string_view value) {
  const auto result = MakeAccessSiteHost(value);
  EXPECT_EQ(result.status, AccessSiteHostStatus::kOk);
  EXPECT_TRUE(result.host.has_value());
  return *result.host;
}

TEST(AccessSiteIntentTest, ParsesOffAllowBlockOnly) {
  AccessSiteIntent intent = AccessSiteIntent::kOff;
  EXPECT_EQ(ParseAccessSiteIntent("off", &intent),
            AccessSiteIntentParseStatus::kOk);
  EXPECT_EQ(intent, AccessSiteIntent::kOff);
  EXPECT_EQ(ParseAccessSiteIntent("allow", &intent),
            AccessSiteIntentParseStatus::kOk);
  EXPECT_EQ(intent, AccessSiteIntent::kAllow);
  EXPECT_EQ(ParseAccessSiteIntent("block", &intent),
            AccessSiteIntentParseStatus::kOk);
  EXPECT_EQ(intent, AccessSiteIntent::kBlock);
  EXPECT_EQ(ParseAccessSiteIntent("proxy", &intent),
            AccessSiteIntentParseStatus::kUnknownIntent);
  EXPECT_EQ(ParseAccessSiteIntent("direct", &intent),
            AccessSiteIntentParseStatus::kUnknownIntent);
  EXPECT_EQ(AccessSiteIntentToString(AccessSiteIntent::kAllow), "allow");
}

TEST(AccessSiteIntentTest, NormalizesExactHostLikeSiteGroup) {
  const auto normalized =
      NormalizeAccessSiteHost("https://WWW.Example.COM:443/path?q=1");
  ASSERT_EQ(normalized.status, AccessSiteHostStatus::kOk);
  EXPECT_EQ(normalized.host->value, "www.example.com");

  EXPECT_EQ(MakeAccessSiteHost("WWW.Example.COM").status,
            AccessSiteHostStatus::kNotCanonical);
  EXPECT_EQ(MakeAccessSiteHost("www.example.com/path").status,
            AccessSiteHostStatus::kContainsSchemeOrPath);
  EXPECT_EQ(MakeAccessSiteHost("https://www.example.com").status,
            AccessSiteHostStatus::kContainsSchemeOrPath);
  EXPECT_EQ(MakeAccessSiteHost("").status, AccessSiteHostStatus::kEmpty);
}

TEST(AccessSiteIntentTest, KeepsCanonicalIpv6BracketsForTrustedSites) {
  const auto url = NormalizeAccessSiteHost("https://[2001:db8::1]:8443/path?q=1");
  ASSERT_EQ(url.status, AccessSiteHostStatus::kOk);
  EXPECT_EQ(url.host->value, "[2001:db8::1]");
  const auto local = NormalizeAccessSiteHost("[::1]:443");
  ASSERT_EQ(local.status, AccessSiteHostStatus::kOk);
  EXPECT_EQ(local.host->value, "[::1]");
}

TEST(AccessSiteIntentTest, DoesNotDiscardInvalidIpv6SuffixOrMissingBracket) {
  for (const auto* host : {"[::1]junk", "[::1]:wrong", "[::1", "2001:db8::1"}) {
    SCOPED_TRACE(host);
    EXPECT_NE(NormalizeAccessSiteHost(host).status, AccessSiteHostStatus::kOk);
  }
}

TEST(AccessSiteIntentTest, MapsIntentOntoOrdinaryCoordinatorModes) {
  EXPECT_EQ(OrdinaryAccessModeForIntent(AccessSiteIntent::kAllow),
            AccessMode::kProxy);
  EXPECT_EQ(OrdinaryAccessModeForIntent(AccessSiteIntent::kOff),
            AccessMode::kDirect);
  EXPECT_EQ(OrdinaryAccessModeForIntent(AccessSiteIntent::kBlock), std::nullopt);
}

TEST(AccessSiteIntentTest, BuildsAllowAndOffMutationsFailClosedForBlock) {
  AccessSiteIntentMutationInput input;
  input.host = Host("news.example");
  input.owner = TestOwner();
  input.site_toggle_id = "toggle";
  input.operation_id = "op-1";
  input.request_fingerprint = "fp-1";

  input.intent = AccessSiteIntent::kAllow;
  input.proxy_group_id = "proxy-group";
  auto allow = BuildOrdinarySiteGroupMutation(input);
  ASSERT_EQ(allow.status, AccessSiteIntentMutationStatus::kReady);
  ASSERT_TRUE(allow.request);
  EXPECT_EQ(allow.ordinary_mode, AccessMode::kProxy);
  EXPECT_EQ(allow.request->candidate_group.canonical_host, "news.example");
  ASSERT_EQ(allow.request->candidate_members.size(), 2u);
  EXPECT_EQ(allow.request->candidate_members[0].mode, AccessMode::kProxy);
  EXPECT_EQ(allow.request->candidate_members[0].proxy_group_id, "proxy-group");
  EXPECT_EQ(allow.request->candidate_members[1].mode, AccessMode::kProxy);

  input.intent = AccessSiteIntent::kOff;
  input.proxy_group_id.clear();
  auto off = BuildOrdinarySiteGroupMutation(input);
  ASSERT_EQ(off.status, AccessSiteIntentMutationStatus::kReady);
  ASSERT_TRUE(off.request);
  EXPECT_EQ(off.ordinary_mode, AccessMode::kDirect);
  EXPECT_TRUE(off.request->candidate_members[0].proxy_group_id.empty());
  EXPECT_EQ(off.request->candidate_members[0].mode, AccessMode::kDirect);

  input.intent = AccessSiteIntent::kBlock;
  auto block = BuildOrdinarySiteGroupMutation(input);
  EXPECT_EQ(block.status, AccessSiteIntentMutationStatus::kBlockNotOrdinary);
  EXPECT_FALSE(block.request.has_value());
  EXPECT_FALSE(block.ordinary_mode.has_value());

  input.intent = AccessSiteIntent::kAllow;
  input.proxy_group_id.clear();
  auto missing_group = BuildOrdinarySiteGroupMutation(input);
  EXPECT_EQ(missing_group.status,
            AccessSiteIntentMutationStatus::kMissingProxyGroup);
  EXPECT_FALSE(missing_group.request.has_value());
}

TEST(AccessSiteIntentTest, StoreDefaultsOffAndOmitsOffEntries) {
  AccessSiteIntentStore store;
  const AccessSiteHost host = Host("www.example.com");
  EXPECT_EQ(store.Get(host), AccessSiteIntent::kOff);

  store.Set(host, AccessSiteIntent::kAllow);
  EXPECT_EQ(store.Get(host), AccessSiteIntent::kAllow);
  EXPECT_EQ(store.All().at(host), AccessSiteIntent::kAllow);

  store.Set(host, AccessSiteIntent::kBlock);
  EXPECT_EQ(store.Get(host), AccessSiteIntent::kBlock);

  store.Set(host, AccessSiteIntent::kOff);
  EXPECT_EQ(store.Get(host), AccessSiteIntent::kOff);
  EXPECT_TRUE(store.All().empty());
}

TEST(AccessSiteIntentTest, SubdomainRulesUseCanonicalSitesButKeepExactHostScope) {
  struct Case {
    const char* host;
    const char* site_host;
  };
  for (const auto& [host, site_host] :
       {Case{"www.google.com", "google.com"},
        Case{"news.example.co.uk", "example.co.uk"},
        Case{"project.github.io", "project.github.io"},
        Case{"[::1]", "[::1]"}}) {
    SCOPED_TRACE(host);
    AccessSiteIntentMutationInput input;
    input.host = Host(host);
    input.owner = TestOwner();
    input.site_toggle_id = "toggle";
    input.operation_id = "op";
    input.request_fingerprint = "fingerprint";
    input.intent = AccessSiteIntent::kAllow;
    input.proxy_group_id = "proxy-group";
    auto result = BuildOrdinarySiteGroupMutation(input);
    ASSERT_EQ(result.status, AccessSiteIntentMutationStatus::kReady);
    ASSERT_TRUE(result.request);
    const auto& request = *result.request;
    EXPECT_EQ(request.candidate_group.canonical_host, host);
    EXPECT_EQ(request.candidate_group.http_top_level_site,
              "http://" + std::string(site_host));
    EXPECT_EQ(request.candidate_group.https_top_level_site,
              "https://" + std::string(site_host));
    ASSERT_EQ(request.candidate_members.size(), 2u);
    for (const auto& member : request.candidate_members) {
      EXPECT_EQ(member.exact_host, host);
      EXPECT_FALSE(member.include_subdomains);
    }
    EXPECT_EQ(request.candidate_members[0].top_level_site,
              request.candidate_group.http_top_level_site);
    EXPECT_EQ(request.candidate_members[1].top_level_site,
              request.candidate_group.https_top_level_site);
  }
}

TEST(AccessSiteIntentTest, WebsiteAnchorUsesPrivateSuffixAndIpBoundaries) {
  EXPECT_EQ(CanonicalWebsiteHost({"www.example.com"}).host, (AccessSiteHost{"example.com"}));
  EXPECT_EQ(CanonicalWebsiteHost({"sub.tenant.github.io"}).host,
            (AccessSiteHost{"tenant.github.io"}));
  EXPECT_EQ(CanonicalWebsiteHost({"127.0.0.1"}).host, (AccessSiteHost{"127.0.0.1"}));
  EXPECT_FALSE(CanonicalWebsiteHost({"https://example.com/path"}).host);
}

}  // namespace
}  // namespace aegis::access
