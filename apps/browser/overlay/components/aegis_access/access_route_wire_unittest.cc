// Copyright 2026 GCSA
#include "services/network/aegis/access_route_wire.h"
#include "net/http/http_auth_cache.h"
#include "services/network/public/mojom/aegis_access_route_types.mojom.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace network {
namespace {
mojom::AegisAccessSnapshotPtr WireSnapshot() {
  auto s = mojom::AegisAccessSnapshot::New();
  s->owner = mojom::AegisAccessOwner::New(mojom::AegisAccessChannel::kDev,
                                        "profile", "partition");
  s->incarnation = "incarnation";
  s->sequence = 1;
  s->common_generations = mojom::AegisAccessGenerations::New(1,1,0,1,1);
  auto rule = mojom::AegisAccessRule::New();
  rule->rule_id = "rule";
  rule->scope = mojom::AegisAccessRuleScope::kProfile;
  rule->destination_host = "destination.test";
  rule->schemes = {mojom::AegisAccessScheme::kHttp};
  rule->port_scope = mojom::AegisAccessPortScope::kAllBrowserPermitted;
  rule->mode = mojom::AegisAccessMode::kProxy;
  rule->proxy_group_id = "group";
  rule->protection_override = mojom::AegisAccessProtection::kNone;
  rule->row_revision = 1;
  rule->last_operation_sequence = 1;
  s->rules.push_back(std::move(rule));
  auto endpoint = mojom::AegisAccessHttpEndpoint::New();
  endpoint->proxy_group_id = "group";
  endpoint->registration_id = "registration";
  endpoint->selection_generation = 1;
  endpoint->numeric_loopback_host = "127.0.0.1";
  endpoint->port = 12345;
  endpoint->credentials = net::AuthCredentials(u"local-user", u"local-secret");
  s->endpoints.push_back(std::move(endpoint));
  return s;
}
TEST(AccessRouteWireTest, CompleteSnapshotInstallsWithPrivateLocalCredentials) {
  auto decoded = DecodeAccessRouteSnapshot(*WireSnapshot());
  ASSERT_TRUE(decoded);
  auto route = decoded->snapshot.routes.at("group");
  const url::SchemeHostPort proxy(GURL("http://127.0.0.1:12345"));
  auto* entry = route->proxy_auth_cache()->Lookup(proxy, net::HttpAuth::AUTH_PROXY,
      "proxy", net::HttpAuth::AUTH_SCHEME_BASIC, net::NetworkAnonymizationKey());
  ASSERT_TRUE(entry);
  EXPECT_TRUE(entry->credentials().Equals(
      net::AuthCredentials(u"local-user", u"local-secret")));
  AccessRouteRegistry registry(decoded->owner, decoded->incarnation);
  ASSERT_TRUE(registry.Install(decoded->sequence, std::move(decoded->snapshot)));
  aegis_access::BrowserOwnedRequestMetadata metadata{"request", decoded->owner,
      aegis_access::RequestAttributionKind::kProfileOnly, {}, {}, std::nullopt};
  EXPECT_EQ(registry.Resolve(metadata, GURL("http://destination.test/"),
      {"incarnation", {1,1,1,1,1}, "registration"}).net_error, net::OK);
}
TEST(AccessRouteWireTest, RejectsNonLoopbackAndDuplicateGroups) {
  auto s = WireSnapshot();
  for (const auto* host : {"example.test", "127.1", "8.8.8.8"}) {
    s->endpoints[0]->numeric_loopback_host = host;
    EXPECT_FALSE(DecodeAccessRouteSnapshot(*s));
  }
  s = WireSnapshot();
  s->endpoints.push_back(s->endpoints[0].Clone());
  EXPECT_FALSE(DecodeAccessRouteSnapshot(*s));
}
TEST(AccessRouteWireTest, RejectsMalformedPolicyAndIncompleteGenerations) {
  auto s = WireSnapshot();
  s->rules[0]->destination_host = "DESTINATION.test";
  EXPECT_FALSE(DecodeAccessRouteSnapshot(*s));
  s = WireSnapshot();
  s->common_generations->selection_generation = 1;
  EXPECT_FALSE(DecodeAccessRouteSnapshot(*s));
  s = WireSnapshot();
  s->owner->profile_token.clear();
  EXPECT_FALSE(DecodeAccessRouteSnapshot(*s));
}
TEST(AccessRouteWireTest, RegistrationCannotReplaceLocalCredentials) {
  auto wire = WireSnapshot();
  auto first = DecodeAccessRouteSnapshot(*wire);
  ASSERT_TRUE(first);
  AccessRouteRegistry registry(first->owner, first->incarnation);
  ASSERT_TRUE(registry.Install(first->sequence, std::move(first->snapshot)));
  wire->sequence = 2;
  wire->endpoints[0]->credentials = net::AuthCredentials(u"other", u"changed");
  auto changed = DecodeAccessRouteSnapshot(*wire);
  ASSERT_TRUE(changed);
  EXPECT_FALSE(registry.Install(changed->sequence, std::move(changed->snapshot)));
  wire->endpoints[0]->registration_id = "new-registration";
  wire->endpoints[0]->selection_generation = 2;
  auto replacement = DecodeAccessRouteSnapshot(*wire);
  ASSERT_TRUE(replacement);
  EXPECT_TRUE(registry.Install(replacement->sequence, std::move(replacement->snapshot)));
}
TEST(AccessRouteWireTest, EmptyPolicyRequiresExplicitValidSnapshot) {
  auto s = WireSnapshot();
  s->rules.clear();
  s->endpoints.clear();
  auto decoded = DecodeAccessRouteSnapshot(*s);
  ASSERT_TRUE(decoded);
  AccessRouteRegistry registry(decoded->owner, decoded->incarnation);
  ASSERT_TRUE(registry.Install(decoded->sequence, std::move(decoded->snapshot)));
  s->sequence = 0;
  EXPECT_FALSE(DecodeAccessRouteSnapshot(*s));
}
TEST(AccessRouteWireTest, UnavailableGroupPreservesProxyPolicyWithoutEndpoint) {
  auto wire = WireSnapshot();
  wire->endpoints.clear();
  wire->unavailable_groups.push_back(
      mojom::AegisAccessUnavailableGroup::New("group", 0));
  auto decoded = DecodeAccessRouteSnapshot(*wire);
  ASSERT_TRUE(decoded);
  EXPECT_TRUE(decoded->snapshot.routes.empty());
  EXPECT_EQ(decoded->snapshot.unavailable_groups.at("group"), 0u);
  AccessRouteRegistry registry(decoded->owner, decoded->incarnation);
  ASSERT_TRUE(registry.Install(decoded->sequence, std::move(decoded->snapshot)));
  aegis_access::BrowserOwnedRequestMetadata metadata{"request", decoded->owner,
      aegis_access::RequestAttributionKind::kProfileOnly, {}, {}, std::nullopt};
  EXPECT_EQ(registry.Resolve(metadata, GURL("http://destination.test/"),
      {"incarnation", {1,1,0,1,1}, {}}).net_error,
      net::ERR_PROXY_CONNECTION_FAILED);
  EXPECT_EQ(registry.Resolve(metadata, GURL("http://unmatched.test/"),
      {"incarnation", {1,1,0,1,1}, {}}).net_error, net::OK);
}
TEST(AccessRouteWireTest, UnavailableGroupMustBeExplicitUniqueAndNotReady) {
  auto wire = WireSnapshot();
  wire->endpoints.clear();
  EXPECT_FALSE(DecodeAccessRouteSnapshot(*wire));
  wire->unavailable_groups.push_back(
      mojom::AegisAccessUnavailableGroup::New("group", 0));
  wire->unavailable_groups.push_back(wire->unavailable_groups.front().Clone());
  EXPECT_FALSE(DecodeAccessRouteSnapshot(*wire));
  wire = WireSnapshot();
  wire->unavailable_groups.push_back(
      mojom::AegisAccessUnavailableGroup::New("group", 1));
  EXPECT_FALSE(DecodeAccessRouteSnapshot(*wire));
  wire = WireSnapshot();
  wire->unavailable_groups.push_back(
      mojom::AegisAccessUnavailableGroup::New("", 0));
  EXPECT_FALSE(DecodeAccessRouteSnapshot(*wire));
}
TEST(AccessRouteWireTest, WebsiteCdnIsIndependentlyMatchedAgainstBoundTopSite) {
  auto wire = WireSnapshot();
  wire->rules[0]->scope = mojom::AegisAccessRuleScope::kWebsite;
  wire->rules[0]->destination_host = "pinterest.com";
  wire->rules[0]->top_level_site = "https://pinterest.com";
  auto decoded = DecodeAccessRouteSnapshot(*wire);
  ASSERT_TRUE(decoded);
  const auto owner = decoded->owner;
  AccessRouteRegistry registry(owner, decoded->incarnation);
  ASSERT_TRUE(registry.Install(decoded->sequence, std::move(decoded->snapshot)));
  aegis_access::BrowserOwnedRequestMetadata metadata{"resource", owner,
      aegis_access::RequestAttributionKind::kDocument, "document", {},
      net::SchemefulSite(GURL("https://www.pinterest.com/"))};
  const GURL resource("http://s.pinimg.com/app.js");
  auto result = registry.Resolve(metadata, resource,
      {"incarnation", {1,1,1,1,1}, "registration"});
  EXPECT_EQ(result.net_error, net::OK);
  EXPECT_TRUE(result.route);
  metadata.top_frame_site = net::SchemefulSite(GURL("https://unrelated.test/"));
  result = registry.Resolve(metadata, resource,
      {"incarnation", {1,1,0,1,1}, {}});
  EXPECT_EQ(result.net_error, net::OK);
  EXPECT_FALSE(result.route);
  EXPECT_NE(registry.Resolve(metadata, resource,
      {"incarnation", {1,1,1,1,1}, "registration"}).net_error, net::OK);
}

}  // namespace
}  // namespace network
