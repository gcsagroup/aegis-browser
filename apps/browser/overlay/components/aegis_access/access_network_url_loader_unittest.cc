// Copyright 2026 GCSA
#include <atomic>
#include "base/functional/bind.h"
#include "base/test/bind.h"
#include "base/test/task_environment.h"
#include "mojo/core/embedder/embedder.h"
#include "net/base/load_flags.h"
#include "net/test/embedded_test_server/embedded_test_server.h"
#include "net/test/embedded_test_server/http_response.h"
#include "net/traffic_annotation/network_traffic_annotation_test_helper.h"
#include "net/url_request/url_request_context.h"
#include "net/url_request/url_request_context_builder.h"
#include "services/network/aegis/access_request_route_state.h"
#include "services/network/cookie_settings.h"
#include "services/network/devtools_durable_msg_writer.h"
#include "services/network/shared_dictionary/shared_dictionary_access_checker.h"
#include "services/network/pervasive_resources/shared_resource_checker.h"
#include "services/network/test/test_url_loader_client.h"
#include "services/network/test/url_loader_context_for_tests.h"
#include "services/network/trust_tokens/trust_token_request_helper_factory.h"
#include "services/network/url_loader.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace network {
namespace {
using namespace aegis_access;
class AccessNetworkURLLoaderTest : public testing::Test {
 protected:
  void SetUp() override {
    mojo::core::Init();
    proxy_.RegisterRequestHandler(base::BindRepeating(
        &AccessNetworkURLLoaderTest::ProxyResponse, base::Unretained(this)));
    origin_.RegisterRequestHandler(base::BindRepeating(
        &AccessNetworkURLLoaderTest::OriginResponse, base::Unretained(this)));
    ASSERT_TRUE(proxy_.Start());
    ASSERT_TRUE(origin_.Start());
    net_context_ = net::URLRequestContextBuilder().Build();
    context_.set_url_request_context(net_context_.get());
    context_.mutable_factory_params().is_orb_enabled = false;
    context_.mutable_factory_params().process_id = OriginatingProcessId::browser();
  }
  void TearDown() override {
    loader_.reset();
    context_.Detach();
    net_context_.reset();
  }
  std::unique_ptr<net::test_server::HttpResponse> ProxyResponse(
      const net::test_server::HttpRequest&) {
    ++proxy_hits_;
    auto response = std::make_unique<net::test_server::BasicHttpResponse>();
    response->set_code(net::HTTP_NO_CONTENT);
    return response;
  }
  std::unique_ptr<net::test_server::HttpResponse> OriginResponse(
      const net::test_server::HttpRequest& request) {
    ++origin_hits_;
    auto response = std::make_unique<net::test_server::BasicHttpResponse>();
    if (request.relative_url == "/redirect") {
      response->set_code(net::HTTP_FOUND);
      response->AddCustomHeader("Location", origin_.GetURL("/final").spec());
    } else {
      response->set_code(net::HTTP_NO_CONTENT);
    }
    return response;
  }
  void Install(bool with_proxy) {
    AccessRouteRegistry::Snapshot snapshot{{owner_, 1, {}}, common_, {}};
    if (with_proxy) {
      snapshot.policy.rules.push_back({"rule", owner_, PolicyScope::kProfile, {},
          "127.0.0.1", false, {RequestScheme::kHttp},
          {PortScope::kAllBrowserPermitted, {}}, AccessMode::kProxy, "group",
          ProtectionOverride::kNone, 1, 1});
      net::AccessRouteIsolationKey key{0, "profile", "partition", "group",
                                     "registration", "incarnation", 1, 1, 1, 1, 1};
      snapshot.routes["group"] = net::AccessProxyRoute::Create(key,
          net::ProxyChain(net::ProxyServer::FromSchemeHostAndPort(
              net::ProxyServer::SCHEME_HTTP, "127.0.0.1", proxy_.port())));
    }
    ASSERT_TRUE(registry_.Install(1, std::move(snapshot)));
  }
  AccessRouteRegistry::Expectation Expected(bool proxy) {
    auto generations = common_;
    generations.selection_generation = proxy ? 1 : 0;
    return {"incarnation", generations, proxy ? "registration" : ""};
  }
  scoped_refptr<AccessRequestRouteState> State(const GURL& url, bool proxy) {
    BrowserOwnedRequestMetadata metadata{"request", owner_,
        RequestAttributionKind::kProfileOnly, {}, {}, std::nullopt};
    return AccessRequestRouteState::Create(registry_.GetWeakPtr(), metadata,
                                           url, "GET", Expected(proxy));
  }
  void Start(const GURL& url, scoped_refptr<AccessRequestRouteState> state,
             int flags = 0) {
    ResourceRequest request;
    request.url = url;
    request.method = "GET";
    request.load_flags = flags;
    loader_.reset(new URLLoader(context_, base::BindLambdaForTesting(
        [&](URLLoader*) { loader_.reset(); }), remote_.BindNewPipeAndPassReceiver(),
        0, request, client_.CreateRemote(), {}, TRAFFIC_ANNOTATION_FOR_TESTS,
        0, 0, {}, nullptr, nullptr, nullptr, {}, {}, {}, {}, {}, {}, checker_,
        nullptr, {}, std::move(state)));
  }
  base::test::TaskEnvironment environment_{
      base::test::TaskEnvironment::MainThreadType::IO};
  net::EmbeddedTestServer proxy_, origin_;
  std::atomic<int> proxy_hits_{0}, origin_hits_{0};
  OwnershipKey owner_{ChannelNamespace::kDev, "profile", "partition"};
  GenerationTuple common_{1, 1, 0, 1, 1};
  AccessRouteRegistry registry_{owner_, "incarnation"};
  CookieSettings cookies_;
  SharedResourceChecker checker_{cookies_};
  std::unique_ptr<net::URLRequestContext> net_context_;
  URLLoaderContextForTests context_;
  TestURLLoaderClient client_;
  mojo::Remote<mojom::URLLoader> remote_;
  std::unique_ptr<URLLoader> loader_;
};
TEST_F(AccessNetworkURLLoaderTest, ManagedRouteCannotAdvertiseNativeDictionary) {
  Install(true);
  const auto url = origin_.GetURL("/final");
  Start(url, State(url, true), net::LOAD_CAN_USE_SHARED_DICTIONARY);
  ASSERT_EQ(net_context_->url_requests()->size(), 1u);
  EXPECT_FALSE((*net_context_->url_requests()->begin())->load_flags() &
               net::LOAD_CAN_USE_SHARED_DICTIONARY);
  client_.RunUntilComplete();
  EXPECT_EQ(client_.completion_status().error_code, net::OK);
  EXPECT_EQ(proxy_hits_, 1);
}
TEST_F(AccessNetworkURLLoaderTest, OrdinaryNativeLoaderRetainsDictionaryCapability) {
  const auto url = origin_.GetURL("/final");
  Start(url, nullptr, net::LOAD_CAN_USE_SHARED_DICTIONARY);
  ASSERT_EQ(net_context_->url_requests()->size(), 1u);
  EXPECT_TRUE((*net_context_->url_requests()->begin())->load_flags() &
              net::LOAD_CAN_USE_SHARED_DICTIONARY);
  client_.RunUntilComplete();
  EXPECT_EQ(client_.completion_status().error_code, net::OK);
  EXPECT_EQ(origin_hits_, 1);
}
TEST_F(AccessNetworkURLLoaderTest, ManagedRequestUsesPrivateRoute) {
  Install(true);
  const auto url = origin_.GetURL("/final");
  auto state = State(url, true);
  ASSERT_TRUE(state);
  Start(url, std::move(state));
  client_.RunUntilComplete();
  EXPECT_EQ(client_.completion_status().error_code, net::OK);
  EXPECT_EQ(proxy_hits_, 1);
  EXPECT_EQ(origin_hits_, 0);
}
TEST_F(AccessNetworkURLLoaderTest, RestoringBeforeStartSendsNothing) {
  Install(true);
  const auto url = origin_.GetURL("/final");
  auto state = State(url, true);
  ASSERT_TRUE(state);
  registry_.EnterRestoring();
  Start(url, std::move(state));
  client_.RunUntilComplete();
  EXPECT_EQ(client_.completion_status().error_code, net::ERR_BLOCKED_BY_CLIENT);
  EXPECT_EQ(proxy_hits_, 0);
  EXPECT_EQ(origin_hits_, 0);
}
TEST_F(AccessNetworkURLLoaderTest, PublicNativeRedirectCannotBypassRouteApproval) {
  Install(false);
  const auto url = origin_.GetURL("localhost", "/redirect");
  auto state = State(url, false);
  ASSERT_TRUE(state);
  Start(url, state);
  client_.RunUntilRedirectReceived();
  remote_->FollowRedirect({}, std::nullopt);
  client_.RunUntilComplete();
  EXPECT_EQ(client_.completion_status().error_code, net::ERR_BLOCKED_BY_CLIENT);
  EXPECT_EQ(origin_hits_, 1);
  EXPECT_EQ(proxy_hits_, 0);
}
TEST_F(AccessNetworkURLLoaderTest, ApprovedNativeRedirectSwitchesToManagedProxy) {
  Install(true);
  const auto url = origin_.GetURL("localhost", "/redirect");
  auto state = State(url, false);
  ASSERT_TRUE(state);
  Start(url, state);
  client_.RunUntilRedirectReceived();
  ASSERT_TRUE(state->ApproveRedirect(1, client_.redirect_info().new_url,
                                     "GET", Expected(true)));
  remote_->FollowRedirect({}, std::nullopt);
  client_.RunUntilComplete();
  EXPECT_EQ(client_.completion_status().error_code, net::OK);
  EXPECT_EQ(origin_hits_, 1);
  EXPECT_EQ(proxy_hits_, 1);
}
}  // namespace
}  // namespace network
