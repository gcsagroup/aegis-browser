// Copyright 2026 GCSA

#include "components/aegis_access/access_proxy_route_adapter.h"

#include "net/base/proxy_chain.h"

#include "net/proxy_resolution/proxy_info.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis_access {
namespace {

OwnershipKey TestOwner() {
  return OwnershipKey{ChannelNamespace::kDev, "profile-dev", "partition-main"};
}

GenerationTuple TestGenerations() {
  return GenerationTuple{1, 2, 3, 4, 5};
}

RegisteredProxyEntry TestRegistration() {
  return RegisteredProxyEntry{"registration-local", "proxy-group-local",
                              TestOwner(), TestGenerations()};
}

RegisteredProxyEndpoint TestEndpoint() {
  return RegisteredProxyEndpoint{"registration-local",
                                 "proxy-group-local",
                                 TestOwner(),
                                 TestGenerations(),
                                 RegisteredProxyTransport::kHttp,
                                 "127.0.0.1",
                                 18080};
}

RoutePlan TestPlan(RouteAction action) {
  RoutePlan plan;
  plan.action = action;
  plan.reason = RouteReason::kNone;
  plan.generations = TestGenerations();
  switch (action) {
    case RouteAction::kPreserveNative:
      plan.effective_mode = AccessMode::kDirect;
      break;
    case RouteAction::kUseRegisteredProxy:
      plan.effective_mode = AccessMode::kProxy;
      plan.registered_proxy_entry = TestRegistration();
      break;
    case RouteAction::kWait:
    case RouteAction::kFail:
      plan.effective_mode = AccessMode::kProxy;
      break;
    case RouteAction::kDeny:
      plan.effective_mode = AccessMode::kReject;
      break;
  }
  return plan;
}

void ExpectInvalidEndpointFailsClosed(
    const RoutePlan& plan,
    const RegisteredProxyEndpoint* endpoint) {
  net::ProxyInfo info;
  info.UseNamedProxy("http://native.example:3128;direct://");
  EXPECT_EQ(ApplyRoutePlanToProxyInfo(plan, endpoint, &info),
            ProxyRouteApplyStatus::kInvalidEndpoint);
  EXPECT_TRUE(info.is_empty());
  EXPECT_FALSE(info.is_direct());
}

TEST(AccessProxyRouteAdapterTest, PreserveNativeLeavesExistingProxyUntouched) {
  RoutePlan direct = TestPlan(RouteAction::kPreserveNative);
  net::ProxyInfo info;
  info.UseNamedProxy("http://native.example:3128;direct://");
  const std::string before = info.proxy_list().ToPacString();

  EXPECT_EQ(ApplyRoutePlanToProxyInfo(direct, nullptr, &info),
            ProxyRouteApplyStatus::kPreservedNative);
  EXPECT_EQ(info.proxy_list().ToPacString(), before);
}

TEST(AccessProxyRouteAdapterTest, PreserveNativeAlsoAllowsInheritedNoneMode) {
  RoutePlan inherited = TestPlan(RouteAction::kPreserveNative);
  inherited.effective_mode = AccessMode::kNone;
  net::ProxyInfo info;
  info.UseNamedProxy("http://native.example:3128;direct://");
  const std::string before = info.proxy_list().ToPacString();

  EXPECT_EQ(ApplyRoutePlanToProxyInfo(inherited, nullptr, &info),
            ProxyRouteApplyStatus::kPreservedNative);
  EXPECT_EQ(info.proxy_list().ToPacString(), before);
}

TEST(AccessProxyRouteAdapterTest, MalformedPreserveNativeFailsClosed) {
  RoutePlan malformed = TestPlan(RouteAction::kPreserveNative);
  malformed.effective_mode = AccessMode::kProxy;
  net::ProxyInfo info;
  info.UseNamedProxy("http://native.example:3128;direct://");

  EXPECT_EQ(ApplyRoutePlanToProxyInfo(malformed, nullptr, &info),
            ProxyRouteApplyStatus::kInvalidEndpoint);
  EXPECT_TRUE(info.is_empty());
  EXPECT_FALSE(info.is_direct());
}

TEST(AccessProxyRouteAdapterTest, ProxyUsesOnlyRegisteredLoopbackEndpoint) {
  net::ProxyInfo info;
  info.UseNamedProxy("http://native.example:3128;direct://");
  const RegisteredProxyEndpoint endpoint = TestEndpoint();

  EXPECT_EQ(ApplyRoutePlanToProxyInfo(TestPlan(RouteAction::kUseRegisteredProxy),
                                      &endpoint, &info),
            ProxyRouteApplyStatus::kAppliedProxy);
  ASSERT_EQ(info.proxy_list().size(), 1u);
  EXPECT_FALSE(info.is_direct());
  EXPECT_EQ(info.proxy_chain().First().GetHost(), "127.0.0.1");
  EXPECT_EQ(info.proxy_chain().First().GetPort(), 18080u);
}

TEST(AccessProxyRouteAdapterTest, FailureStatesRemoveDirectFallback) {
  for (RouteAction action :
       {RouteAction::kWait, RouteAction::kDeny, RouteAction::kFail}) {
    SCOPED_TRACE(static_cast<int>(action));
    net::ProxyInfo info;
    info.UseNamedProxy("http://native.example:3128;direct://");

    EXPECT_EQ(ApplyRoutePlanToProxyInfo(TestPlan(action), nullptr, &info),
              ProxyRouteApplyStatus::kMustAbort);
    EXPECT_TRUE(info.is_empty());
    EXPECT_FALSE(info.is_direct());
  }
}

TEST(AccessProxyRouteAdapterTest, InvalidOrUntrustedEndpointFailsClosed) {
  RoutePlan malformed_mode = TestPlan(RouteAction::kUseRegisteredProxy);
  malformed_mode.effective_mode = AccessMode::kDirect;
  RoutePlan stale_plan = TestPlan(RouteAction::kUseRegisteredProxy);
  stale_plan.generations.network_epoch++;

  for (const RoutePlan* malformed : {&malformed_mode, &stale_plan}) {
    const RegisteredProxyEndpoint endpoint = TestEndpoint();
    net::ProxyInfo info;
    info.UseNamedProxy("http://native.example:3128;direct://");
    EXPECT_EQ(ApplyRoutePlanToProxyInfo(*malformed, &endpoint, &info),
              ProxyRouteApplyStatus::kInvalidEndpoint);
    EXPECT_TRUE(info.is_empty());
    EXPECT_FALSE(info.is_direct());
  }

  RegisteredProxyEndpoint remote = TestEndpoint();
  remote.host = "proxy.example";

  RegisteredProxyEndpoint missing_port = TestEndpoint();
  missing_port.port = 0;

  RegisteredProxyEndpoint invalid_transport = TestEndpoint();
  invalid_transport.transport = RegisteredProxyTransport::kInvalid;

  RegisteredProxyEndpoint mismatched = TestEndpoint();
  mismatched.registration_id = "different-registration";

  for (const RegisteredProxyEndpoint* endpoint :
       {&remote, &missing_port, &invalid_transport, &mismatched}) {
    net::ProxyInfo info;
    info.UseNamedProxy("http://native.example:3128;direct://");
    EXPECT_EQ(ApplyRoutePlanToProxyInfo(TestPlan(RouteAction::kUseRegisteredProxy),
                                        endpoint, &info),
              ProxyRouteApplyStatus::kInvalidEndpoint);
    EXPECT_TRUE(info.is_empty());
    EXPECT_FALSE(info.is_direct());
  }
}

TEST(AccessProxyRouteAdapterTest, MissingRegistrationIdentityFailsClosed) {
  const RegisteredProxyEndpoint endpoint = TestEndpoint();

  RoutePlan missing = TestPlan(RouteAction::kUseRegisteredProxy);
  missing.registered_proxy_entry.reset();
  ExpectInvalidEndpointFailsClosed(missing, &endpoint);

  RoutePlan empty_registration = TestPlan(RouteAction::kUseRegisteredProxy);
  empty_registration.registered_proxy_entry->registration_id.clear();
  ExpectInvalidEndpointFailsClosed(empty_registration, &endpoint);

  RoutePlan empty_group = TestPlan(RouteAction::kUseRegisteredProxy);
  empty_group.registered_proxy_entry->proxy_group_id.clear();
  ExpectInvalidEndpointFailsClosed(empty_group, &endpoint);
}

TEST(AccessProxyRouteAdapterTest, EndpointIdentityTupleMismatchFailsClosed) {
  RegisteredProxyEndpoint wrong_group = TestEndpoint();
  wrong_group.proxy_group_id = "proxy-group-other";

  RegisteredProxyEndpoint wrong_owner = TestEndpoint();
  wrong_owner.owner.profile_token = "profile-other";

  RegisteredProxyEndpoint wrong_partition = TestEndpoint();
  wrong_partition.owner.storage_partition_token = "partition-other";

  RegisteredProxyEndpoint stale_endpoint = TestEndpoint();
  stale_endpoint.generations.network_epoch++;

  const RoutePlan plan = TestPlan(RouteAction::kUseRegisteredProxy);
  for (const RegisteredProxyEndpoint* endpoint :
       {&wrong_group, &wrong_owner, &wrong_partition, &stale_endpoint}) {
    SCOPED_TRACE(endpoint->registration_id + ":" + endpoint->proxy_group_id +
                 ":" + endpoint->owner.profile_token + ":" +
                 endpoint->owner.storage_partition_token);
    ExpectInvalidEndpointFailsClosed(plan, endpoint);
  }
}

TEST(AccessProxyRouteAdapterTest, NullProxyInfoIsRejected) {
  const RegisteredProxyEndpoint endpoint = TestEndpoint();
  EXPECT_EQ(ApplyRoutePlanToProxyInfo(
                TestPlan(RouteAction::kUseRegisteredProxy), &endpoint, nullptr),
            ProxyRouteApplyStatus::kInvalidEndpoint);
}

TEST(AccessProxyRouteAdapterTest, SupportsNumericIpv6HttpLoopback) {
  RegisteredProxyEndpoint endpoint = TestEndpoint();
  endpoint.host = "::1";
  endpoint.port = 19090;
  net::ProxyInfo info;
  info.UseDirect();

  EXPECT_EQ(ApplyRoutePlanToProxyInfo(TestPlan(RouteAction::kUseRegisteredProxy),
                                      &endpoint, &info),
            ProxyRouteApplyStatus::kAppliedProxy);
  ASSERT_EQ(info.proxy_list().size(), 1u);
  EXPECT_TRUE(info.proxy_chain().First().is_http());
  EXPECT_EQ(info.proxy_chain().First().GetHost(), "[::1]");
  EXPECT_EQ(info.proxy_chain().First().GetPort(), 19090u);
}

TEST(AccessProxyRouteAdapterTest, SupportsBracketedIpv6HttpLoopback) {
  RegisteredProxyEndpoint endpoint = TestEndpoint();
  endpoint.host = "[::1]";
  endpoint.port = 19091;
  net::ProxyInfo info;
  info.UseDirect();

  EXPECT_EQ(ApplyRoutePlanToProxyInfo(TestPlan(RouteAction::kUseRegisteredProxy),
                                      &endpoint, &info),
            ProxyRouteApplyStatus::kAppliedProxy);
  ASSERT_EQ(info.proxy_list().size(), 1u);
  EXPECT_TRUE(info.proxy_chain().First().is_http());
  EXPECT_EQ(info.proxy_chain().First().GetHost(), "[::1]");
  EXPECT_EQ(info.proxy_chain().First().GetPort(), 19091u);
}

}  // namespace
}  // namespace aegis_access
