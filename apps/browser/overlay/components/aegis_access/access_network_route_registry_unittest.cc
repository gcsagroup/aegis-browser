// Copyright 2026 GCSA
#include "services/network/aegis/access_route_registry.h"
#include "net/base/net_errors.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace network {
namespace {
using namespace aegis_access;
OwnershipKey Owner() { return {ChannelNamespace::kDev, "profile", "partition"}; }
BrowserOwnedRequestMetadata Metadata(std::string site = "https://a.test") {
  return {"request", Owner(), RequestAttributionKind::kDocument, "document", {},
          net::SchemefulSite(GURL(site))};
}
GenerationTuple Common() { return {7, 3, 0, 4, 5}; }
scoped_refptr<net::AccessProxyRoute> Route(std::string group, uint64_t selection) {
  net::AccessRouteIsolationKey key{0, "profile", "partition", group,
                                 "registration-" + group, "incarnation", 7, 3,
                                 selection, 4, 5};
  return net::AccessProxyRoute::Create(std::move(key), net::ProxyChain(
      net::ProxyServer::FromSchemeHostAndPort(net::ProxyServer::SCHEME_HTTP,
                                             "127.0.0.1", 12345)));
}
AccessPolicyRule Rule(std::string site, std::string group) {
  return {site, Owner(), PolicyScope::kSite, site, "cdn.test", false,
          {RequestScheme::kHttps}, {PortScope::kAllBrowserPermitted, {}},
          AccessMode::kProxy, group, ProtectionOverride::kNone, 1, 1};
}
AccessRouteRegistry::Snapshot Snapshot() {
  return {{Owner(), 7, {Rule("https://a.test", "x"), Rule("https://b.test", "y")}},
          Common(), {{"x", Route("x", 8)}, {"y", Route("y", 11)}}};
}
AccessRouteRegistry::Expectation Expected(std::string group = "x",
                                        uint64_t selection = 8) {
  auto generations = Common();
  generations.selection_generation = selection;
  return {"incarnation", generations, "registration-" + group};
}
GURL Target() { return GURL("https://cdn.test/resource"); }

TEST(AccessNetworkRouteRegistryTest, UnavailableProxyGroupDoesNotBlockUnmatchedNativeTraffic) {
  AccessRouteRegistry registry(Owner(), "incarnation");
  auto snapshot = Snapshot();
  snapshot.routes.erase("x");
  snapshot.unavailable_groups.emplace("x", 8);
  ASSERT_TRUE(registry.Install(1, std::move(snapshot)));
  EXPECT_EQ(registry.Resolve(Metadata(), Target(), Expected()).net_error,
            net::ERR_PROXY_CONNECTION_FAILED);
  EXPECT_FALSE(registry.Resolve(Metadata(), Target(), Expected()).route);
  AccessRouteRegistry::Expectation native{"incarnation", Common(), {}};
  EXPECT_EQ(registry.Resolve(Metadata(), GURL("https://native.test/resource"),
                             native).net_error, net::OK);
  EXPECT_EQ(registry.Resolve(Metadata("https://b.test"), Target(),
                             Expected("y", 11)).net_error, net::OK);
}
TEST(AccessNetworkRouteRegistryTest, UnavailableGroupPreservesSelectionAndRegistrationHighWater) {
  AccessRouteRegistry registry(Owner(), "incarnation");
  ASSERT_TRUE(registry.Install(1, Snapshot()));
  auto unavailable = Snapshot();
  unavailable.routes.erase("x");
  unavailable.unavailable_groups.emplace("x", 8);
  ASSERT_TRUE(registry.Install(2, unavailable));
  registry.EnterRestoring();
  unavailable.unavailable_groups["x"] = 7;
  EXPECT_FALSE(registry.Install(3, unavailable));
  unavailable.unavailable_groups["x"] = 8;
  ASSERT_TRUE(registry.Install(3, unavailable));
  auto overlap = Snapshot();
  overlap.unavailable_groups.emplace("x", 8);
  EXPECT_FALSE(registry.Install(4, overlap));
  auto replaced = Snapshot();
  auto key = replaced.routes.at("x")->isolation_key();
  replaced.routes["x"] = net::AccessProxyRoute::Create(key, net::ProxyChain(
      net::ProxyServer::FromSchemeHostAndPort(net::ProxyServer::SCHEME_HTTP,
                                             "127.0.0.1", 54321)));
  EXPECT_FALSE(registry.Install(4, replaced));
  ASSERT_TRUE(registry.Install(4, Snapshot()));
  EXPECT_EQ(registry.Resolve(Metadata(), Target(), Expected()).net_error, net::OK);
}
TEST(AccessNetworkRouteRegistryTest, ExplicitUnavailableGroupAllowsUnselectedStartupOnly) {
  AccessRouteRegistry registry(Owner(), "incarnation");
  auto startup = Snapshot();
  startup.routes.erase("x");
  startup.unavailable_groups.emplace("x", 0);
  ASSERT_TRUE(registry.Install(1, startup));
  EXPECT_EQ(registry.Resolve(Metadata(), Target(), Expected()).net_error,
            net::ERR_PROXY_CONNECTION_FAILED);
  ASSERT_TRUE(registry.Install(2, Snapshot()));
  EXPECT_FALSE(registry.Install(3, startup));
}

TEST(AccessNetworkRouteRegistryTest, RestoringRequiresExplicitInstalledSnapshot) {
  AccessRouteRegistry registry(Owner(), "incarnation");
  AccessRouteRegistry::Expectation native{"incarnation", Common(), {}};
  EXPECT_NE(registry.Resolve(Metadata(), Target(), native).net_error, net::OK);
  AccessRouteRegistry::Snapshot empty{{Owner(), 7, {}}, Common(), {}};
  ASSERT_TRUE(registry.Install(1, std::move(empty)));
  auto result = registry.Resolve(Metadata(), Target(), native);
  EXPECT_EQ(result.net_error, net::OK);
  EXPECT_FALSE(result.route);
  registry.EnterRestoring();
  EXPECT_NE(registry.Resolve(Metadata(), Target(), native).net_error, net::OK);
}
TEST(AccessNetworkRouteRegistryTest, SameDestinationResolvesPerTrustedTopSite) {
  AccessRouteRegistry registry(Owner(), "incarnation");
  ASSERT_TRUE(registry.Install(1, Snapshot()));
  auto x = registry.Resolve(Metadata(), Target(), Expected());
  auto y = registry.Resolve(Metadata("https://b.test"), Target(), Expected("y", 11));
  ASSERT_EQ(x.net_error, net::OK);
  ASSERT_EQ(y.net_error, net::OK);
  ASSERT_TRUE(x.route);
  ASSERT_TRUE(y.route);
  EXPECT_NE(x.route->isolation_key(), y.route->isolation_key());
  EXPECT_NE(x.route->proxy_auth_cache(), y.route->proxy_auth_cache());
  EXPECT_EQ(registry.Resolve(Metadata("https://b.test"), Target(), Expected()).net_error,
            net::ERR_BLOCKED_BY_CLIENT);
}
TEST(AccessNetworkRouteRegistryTest, RejectsForeignOwnerAndStaleIncarnation) {
  AccessRouteRegistry registry(Owner(), "incarnation");
  ASSERT_TRUE(registry.Install(1, Snapshot()));
  auto metadata = Metadata();
  metadata.owner.profile_token = "other";
  EXPECT_NE(registry.Resolve(metadata, Target(), Expected()).net_error, net::OK);
  auto expected = Expected();
  expected.incarnation = "old";
  EXPECT_NE(registry.Resolve(Metadata(), Target(), expected).net_error, net::OK);
}
TEST(AccessNetworkRouteRegistryTest, EveryGenerationAndRegistrationIsBound) {
  AccessRouteRegistry registry(Owner(), "incarnation");
  ASSERT_TRUE(registry.Install(1, Snapshot()));
  for (auto field : {&GenerationTuple::policy_generation,
                     &GenerationTuple::identity_generation,
                     &GenerationTuple::selection_generation,
                     &GenerationTuple::network_epoch,
                     &GenerationTuple::base_proxy_config_generation}) {
    auto expected = Expected();
    ++(expected.generations.*field);
    EXPECT_NE(registry.Resolve(Metadata(), Target(), expected).net_error, net::OK);
  }
  auto expected = Expected();
  expected.registration_id = "unknown";
  EXPECT_NE(registry.Resolve(Metadata(), Target(), expected).net_error, net::OK);
}
TEST(AccessNetworkRouteRegistryTest, InvalidReplacementIsAtomicAndCannotReplay) {
  AccessRouteRegistry registry(Owner(), "incarnation");
  ASSERT_TRUE(registry.Install(2, Snapshot()));
  auto invalid = Snapshot();
  invalid.routes.erase("y");
  EXPECT_FALSE(registry.Install(3, std::move(invalid)));
  EXPECT_EQ(registry.Resolve(Metadata(), Target(), Expected()).net_error, net::OK);
  EXPECT_FALSE(registry.Install(1, Snapshot()));
  EXPECT_FALSE(registry.Install(2, Snapshot()));
}
TEST(AccessNetworkRouteRegistryTest, RestoringInvalidatesDispatchButNotInflightReference) {
  AccessRouteRegistry registry(Owner(), "incarnation");
  ASSERT_TRUE(registry.Install(1, Snapshot()));
  auto inflight = registry.Resolve(Metadata(), Target(), Expected()).route;
  ASSERT_TRUE(inflight);
  registry.EnterRestoring();
  EXPECT_NE(registry.Resolve(Metadata(), Target(), Expected()).net_error, net::OK);
  EXPECT_EQ(inflight->isolation_key().registration, "registration-x");
  EXPECT_FALSE(registry.Install(1, Snapshot()));
  ASSERT_TRUE(registry.Install(2, Snapshot()));
  EXPECT_EQ(registry.Resolve(Metadata(), Target(), Expected()).net_error, net::OK);
}
TEST(AccessNetworkRouteRegistryTest, RejectAndNativeCannotUseProxyExpectation) {
  AccessRouteRegistry registry(Owner(), "incarnation");
  auto snapshot = Snapshot();
  snapshot.policy.rules[0].mode = AccessMode::kReject;
  snapshot.policy.rules[0].proxy_group_id.clear();
  ASSERT_TRUE(registry.Install(1, std::move(snapshot)));
  EXPECT_EQ(registry.Resolve(Metadata(), Target(), Expected()).net_error,
            net::ERR_BLOCKED_BY_CLIENT);
  EXPECT_NE(registry.Resolve(Metadata("https://unknown.test"), Target(),
                            Expected()).net_error, net::OK);
  AccessRouteRegistry::Expectation native{"incarnation", Common(), {}};
  EXPECT_EQ(registry.Resolve(Metadata("https://unknown.test"), Target(),
                            native).net_error, net::OK);
}
TEST(AccessNetworkRouteRegistryTest, RejectsMalformedPolicyAndCrossGroupRoute) {
  AccessRouteRegistry registry(Owner(), "incarnation");
  auto invalid = Snapshot();
  invalid.policy.rules[0].destination_host = "cdn.test.";
  EXPECT_FALSE(registry.Install(1, std::move(invalid)));
  invalid = Snapshot();
  invalid.routes["x"] = Route("y", 8);
  EXPECT_FALSE(registry.Install(2, std::move(invalid)));
}
TEST(AccessNetworkRouteRegistryTest, PolicyCannotChangeUnderSameGeneration) {
  AccessRouteRegistry registry(Owner(), "incarnation");
  ASSERT_TRUE(registry.Install(1, Snapshot()));
  auto replacement = Snapshot();
  replacement.policy.rules.clear();
  EXPECT_FALSE(registry.Install(2, std::move(replacement)));
  registry.EnterRestoring();
  replacement = Snapshot();
  replacement.policy.rules.clear();
  EXPECT_FALSE(registry.Install(3, std::move(replacement)));
}
TEST(AccessNetworkRouteRegistryTest, SelectionCannotRollBackAfterRestore) {
  AccessRouteRegistry registry(Owner(), "incarnation");
  ASSERT_TRUE(registry.Install(1, Snapshot()));
  registry.EnterRestoring();
  auto replacement = Snapshot();
  replacement.routes["y"] = Route("y", 10);
  EXPECT_FALSE(registry.Install(2, std::move(replacement)));
}
TEST(AccessNetworkRouteRegistryTest, RegistrationCannotChangeEndpoint) {
  AccessRouteRegistry registry(Owner(), "incarnation");
  ASSERT_TRUE(registry.Install(1, Snapshot()));
  auto replacement = Snapshot();
  auto key = replacement.routes["x"]->isolation_key();
  replacement.routes["x"] = net::AccessProxyRoute::Create(key, net::ProxyChain(
      net::ProxyServer::FromSchemeHostAndPort(net::ProxyServer::SCHEME_HTTP,
                                             "127.0.0.1", 23456)));
  EXPECT_FALSE(registry.Install(2, std::move(replacement)));
}
}  // namespace
}  // namespace network
