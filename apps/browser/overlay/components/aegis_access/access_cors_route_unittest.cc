// Copyright 2026 GCSA
#include <atomic>
#include "base/functional/bind.h"
#include "base/test/task_environment.h"
#include "mojo/core/embedder/embedder.h"
#include "mojo/public/cpp/test_support/test_utils.h"
#include "mojo/public/cpp/test_support/fake_message_dispatch_context.h"
#include "net/test/embedded_test_server/embedded_test_server.h"
#include "net/test/embedded_test_server/http_response.h"
#include "net/traffic_annotation/network_traffic_annotation_test_helper.h"
#include "services/network/aegis/access_request_route_state.h"
#include "services/network/cors/cors_url_loader_factory.h"
#include "services/network/cors/cors_url_loader_factory_owner.h"
#include "services/network/network_context.h"
#include "services/network/network_service.h"
#include "services/network/resource_scheduler/resource_scheduler_client.h"
#include "services/network/prefetch_matching_url_loader_factory.h"
#include "services/network/test/fake_test_cert_verifier_params_factory.h"
#include "services/network/test/test_url_loader_client.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace network {
namespace {
using namespace aegis_access;
class AccessCorsRouteTest : public testing::Test {
 protected:
  void SetUp() override {
    mojo::core::Init();
    server_.RegisterRequestHandler(base::BindRepeating(
        &AccessCorsRouteTest::Respond, base::Unretained(this)));
    ASSERT_TRUE(server_.Start());
    service_ = NetworkService::CreateForTesting();
    auto params = mojom::NetworkContextParams::New();
    params->cert_verifier_params = FakeTestCertVerifierParamsFactory::GetCertVerifierParams();
    params->initial_proxy_config = net::ProxyConfigWithAnnotation::CreateDirect();
    context_ = std::make_unique<NetworkContext>(service_.get(),
        context_remote_.BindNewPipeAndPassReceiver(), std::move(params));
    auto factory_params = mojom::URLLoaderFactoryParams::New();
    factory_params->process_id = OriginatingProcessId::FromUnsafeValue(42);
    factory_params->is_trusted = false;
    factory_params->request_initiator_origin_lock = initiator_;
    factory_params->isolation_info = net::IsolationInfo::CreateForInternalRequest(initiator_);
    owner_ = std::make_unique<PrefetchMatchingURLLoaderFactory>(context_.get(),
        std::move(factory_params), nullptr,
        factory_remote_.BindNewPipeAndPassReceiver(), &origin_access_list_, nullptr);
    AccessPolicyRule rule{"rule", key_, PolicyScope::kProfile, {}, "destination.test",
        false, {RequestScheme::kHttp}, {PortScope::kAllBrowserPermitted, {}},
        AccessMode::kProxy, "group", ProtectionOverride::kNone, 1, 1};
    net::AccessRouteIsolationKey isolation{0, "profile", "partition", "group",
        "registration", "incarnation", 1, 1, 1, 1, 1};
    auto route = net::AccessProxyRoute::Create(isolation, net::ProxyChain(
        net::ProxyServer::FromSchemeHostAndPort(net::ProxyServer::SCHEME_HTTP,
                                               "127.0.0.1", server_.port())));
    ASSERT_TRUE(registry_.Install(1, {{key_, 1, {rule}}, {1, 1, 0, 1, 1},
                                     {{"group", route}}}));
  }
  void TearDown() override {
    loader_.reset();
    owner_.reset();
    factory_remote_.reset();
    context_.reset();
    context_remote_.reset();
    service_.reset();
  }
  std::unique_ptr<net::test_server::HttpResponse> Respond(
      const net::test_server::HttpRequest& request) {
    if (request.method == net::test_server::METHOD_OPTIONS) ++preflights_;
    else ++actual_;
    auto response = std::make_unique<net::test_server::BasicHttpResponse>();
    response->set_code(net::HTTP_NO_CONTENT);
    if (allow_cors_) {
      response->AddCustomHeader("Access-Control-Allow-Origin", initiator_.Serialize());
      response->AddCustomHeader("Access-Control-Allow-Methods", "PUT");
      response->AddCustomHeader("Access-Control-Max-Age", "600");
      response->AddCustomHeader("Access-Control-Allow-Headers", "x-access-test");
    }
    return response;
  }
  void Start(bool wrong_initiator = false, bool fake_trusted = false) {
    loader_.reset();
    client_ = std::make_unique<TestURLLoaderClient>();
    ResourceRequest request;
    request.url = GURL("http://destination.test/resource");
    request.method = "PUT";
    request.mode = mojom::RequestMode::kCors;
    request.credentials_mode = mojom::CredentialsMode::kOmit;
    request.request_initiator = wrong_initiator
        ? url::Origin::Create(GURL("http://other.test")) : initiator_;
    request.headers.SetHeader("x-access-test", "1");
    if (fake_trusted) request.trusted_params.emplace();
    BrowserOwnedRequestMetadata metadata{"request", key_,
        RequestAttributionKind::kProfileOnly, {}, {}, std::nullopt};
    auto state = AccessRequestRouteState::Create(registry_.GetWeakPtr(), metadata,
        request.url, request.method, {"incarnation", {1,1,1,1,1}, "registration"});
    ASSERT_TRUE(state);
    owner_->GetCorsURLLoaderFactoryForTesting()->CreateLoaderAndStartWithAccessRoute(
        loader_.BindNewPipeAndPassReceiver(), 0, 0, request, client_->CreateRemote(),
        net::MutableNetworkTrafficAnnotationTag(TRAFFIC_ANNOTATION_FOR_TESTS), state);
  }
  base::test::TaskEnvironment environment_{base::test::TaskEnvironment::MainThreadType::IO};
  mojo::FakeMessageDispatchContext mojo_context_;
  net::EmbeddedTestServer server_;
  std::atomic<int> preflights_{0}, actual_{0};
  std::atomic<bool> allow_cors_{true};
  const url::Origin initiator_ = url::Origin::Create(GURL("http://127.0.0.1:1234"));
  OwnershipKey key_{ChannelNamespace::kDev, "profile", "partition"};
  AccessRouteRegistry registry_{key_, "incarnation"};
  std::unique_ptr<NetworkService> service_;
  mojo::Remote<mojom::NetworkContext> context_remote_;
  std::unique_ptr<NetworkContext> context_;
  cors::OriginAccessList origin_access_list_;
  mojo::Remote<mojom::URLLoaderFactory> factory_remote_;
  std::unique_ptr<PrefetchMatchingURLLoaderFactory> owner_;
  mojo::Remote<mojom::URLLoader> loader_;
  std::unique_ptr<TestURLLoaderClient> client_;
};
TEST_F(AccessCorsRouteTest, IndependentOwnerControlsFactoryLifetime) {
  class PrivateOwner final : public cors::CorsURLLoaderFactoryOwner {
   public:
    bool HasAdditionalReferences() const override { return has_receiver; }
    void DestroyURLLoaderFactory(cors::CorsURLLoaderFactory* factory) override {
      EXPECT_EQ(factory, child.get());
      child.reset();
      destroyed = true;
    }
    bool has_receiver = true;
    bool destroyed = false;
    std::unique_ptr<cors::CorsURLLoaderFactory> child;
  } private_owner;
  auto params = mojom::URLLoaderFactoryParams::New();
  params->process_id = OriginatingProcessId::FromUnsafeValue(42);
  params->is_trusted = false;
  params->request_initiator_origin_lock = initiator_;
  params->isolation_info = net::IsolationInfo::CreateForInternalRequest(initiator_);
  private_owner.child = std::make_unique<cors::CorsURLLoaderFactory>(
      context_.get(), std::move(params), nullptr, &origin_access_list_,
      &private_owner);
  private_owner.child->DeleteIfNeeded();
  EXPECT_FALSE(private_owner.destroyed);
  private_owner.has_receiver = false;
  private_owner.child->DeleteIfNeeded();
  EXPECT_TRUE(private_owner.destroyed);
  EXPECT_FALSE(private_owner.child);
}
TEST_F(AccessCorsRouteTest, PreflightAndActualUseSameRegisteredProxy) {
  Start();
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 1);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessCorsRouteTest, CorsFailureDoesNotSendActualRequest) {
  allow_cors_ = false;
  Start();
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_TRUE(client_->completion_status().cors_error_status.has_value());
  EXPECT_EQ(preflights_, 1);
  EXPECT_EQ(actual_, 0);
}
TEST_F(AccessCorsRouteTest, ManagedPreflightDoesNotPopulateSharedCache) {
  Start();
  client_->RunUntilComplete();
  ASSERT_EQ(client_->completion_status().error_code, net::OK);
  allow_cors_ = false;
  Start();
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 2);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessCorsRouteTest, OriginalInitiatorLockStillRejectsMismatch) {
  mojo::test::BadMessageObserver observer;
  Start(true);
  EXPECT_FALSE(observer.WaitForBadMessage().empty());
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 0);
  EXPECT_EQ(actual_, 0);
}
TEST_F(AccessCorsRouteTest, PrivateRouteDoesNotTrustRendererTrustedParams) {
  mojo::test::BadMessageObserver observer;
  Start(false, true);
  EXPECT_FALSE(observer.WaitForBadMessage().empty());
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 0);
  EXPECT_EQ(actual_, 0);
}
}  // namespace
}  // namespace network
