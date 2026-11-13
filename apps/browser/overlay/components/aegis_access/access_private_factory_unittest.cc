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
#include "services/network/aegis/access_private_url_loader_factory.h"
#include "services/network/public/mojom/aegis_access_route_types.mojom.h"
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
class AccessPrivateFactoryTest : public testing::Test {
 protected:
  void SetUp() override {
    mojo::core::Init();
    server_.RegisterRequestHandler(base::BindRepeating(
        &AccessPrivateFactoryTest::Respond, base::Unretained(this)));
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
    BrowserOwnedRequestMetadata binding{"", key_,
        RequestAttributionKind::kProfileOnly, {}, {}, std::nullopt};
    owner_ = std::make_unique<AccessPrivateURLLoaderFactory>(context_.get(),
        std::move(factory_params), nullptr, &origin_access_list_,
        registry_.GetWeakPtr(), binding, "incarnation",
        factory_remote_.BindNewPipeAndPassReceiver(), base::DoNothing());
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
    if (request.method != net::test_server::METHOD_OPTIONS &&
        redirect_first_.exchange(false)) {
      response->set_code(net::HTTP_TEMPORARY_REDIRECT);
      response->AddCustomHeader("Location", "http://destination.test/final");
    }
    if (allow_cors_) {
      response->AddCustomHeader("Access-Control-Allow-Origin", initiator_.Serialize());
      response->AddCustomHeader("Access-Control-Allow-Methods", "PUT");
      response->AddCustomHeader("Access-Control-Max-Age", "600");
      response->AddCustomHeader("Access-Control-Allow-Headers", "x-access-test");
    }
    return response;
  }
  void UseWebsiteFactory(bool matching_top_site = true) {
    owner_.reset();
    factory_remote_.reset();
    auto params = mojom::URLLoaderFactoryParams::New();
    params->process_id = OriginatingProcessId::FromUnsafeValue(42);
    params->is_trusted = false;
    params->request_initiator_origin_lock = initiator_;
    params->isolation_info = net::IsolationInfo::CreateForInternalRequest(initiator_);
    BrowserOwnedRequestMetadata binding{"", key_, RequestAttributionKind::kDocument,
        "website-document", {}, matching_top_site ? net::SchemefulSite(initiator_)
            : net::SchemefulSite(GURL("http://unrelated.test/"))};
    owner_ = std::make_unique<AccessPrivateURLLoaderFactory>(context_.get(),
        std::move(params), nullptr, &origin_access_list_, registry_.GetWeakPtr(),
        binding, "incarnation", factory_remote_.BindNewPipeAndPassReceiver(), base::DoNothing());
    AccessPolicyRule rule{"website", key_, PolicyScope::kWebsite, "http://127.0.0.1",
        "127.0.0.1", false, {RequestScheme::kHttp}, {PortScope::kAllBrowserPermitted, {}},
        AccessMode::kProxy, "group", ProtectionOverride::kNone, 1, 2};
    net::AccessRouteIsolationKey isolation{0, "profile", "partition", "group",
        "registration", "incarnation", 2, 1, 1, 1, 1};
    auto route = net::AccessProxyRoute::Create(isolation, net::ProxyChain(
        net::ProxyServer::FromSchemeHostAndPort(net::ProxyServer::SCHEME_HTTP,
                                               "127.0.0.1", server_.port())));
    ASSERT_TRUE(registry_.Install(2, {{key_, 2, {rule}}, {2, 1, 0, 1, 1},
                                     {{"group", route}}}));
    policy_generation_ = 2;
  }
  void Start(bool wrong_initiator = false, bool fake_trusted = false,
             std::string token = "", bool wrong_target = false,
             bool native_start = false) {
    loader_.reset();
    client_ = std::make_unique<TestURLLoaderClient>();
    ResourceRequest request;
    request.url = native_start ? server_.GetURL("localhost", "/native")
                               : GURL("http://destination.test/resource");
    request.method = native_start ? "GET" : "PUT";
    request.mode = native_start ? mojom::RequestMode::kNoCors
                                : mojom::RequestMode::kCors;
    request.credentials_mode = mojom::CredentialsMode::kOmit;
    request.request_initiator = wrong_initiator
        ? url::Origin::Create(GURL("http://other.test")) : initiator_;
    if (!native_start) request.headers.SetHeader("x-access-test", "1");
    if (fake_trusted) request.trusted_params.emplace();
    if (token.empty()) token = std::to_string(++request_sequence_);
    auto envelope = mojom::AegisAccessRequestEnvelope::New();
    envelope->request_token = token;
    envelope->incarnation = "incarnation";
    envelope->target = wrong_target ? GURL("http://other.test/") : request.url;
    envelope->method = request.method;
    envelope->generations = mojom::AegisAccessGenerations::New(policy_generation_,1,
        native_start ? 0 : 1,1,1);
    envelope->registration_id = native_start ? "" : "registration";
    auto routed = mojom::AegisAccessRoutedRequest::New(request, std::move(envelope));
    control_.reset();
    factory_remote_->CreateLoaderAndStartWithRoute(
        loader_.BindNewPipeAndPassReceiver(), control_.BindNewPipeAndPassReceiver(),
        0, 0, std::move(routed), client_->CreateRemote(),
        net::MutableNetworkTrafficAnnotationTag(TRAFFIC_ANNOTATION_FOR_TESTS));

  }
  base::test::TaskEnvironment environment_{base::test::TaskEnvironment::MainThreadType::IO};
  mojo::FakeMessageDispatchContext mojo_context_;
  net::EmbeddedTestServer server_;
  std::atomic<int> preflights_{0}, actual_{0};
  std::atomic<bool> allow_cors_{true}, redirect_first_{false};
  const url::Origin initiator_ = url::Origin::Create(GURL("http://127.0.0.1:1234"));
  OwnershipKey key_{ChannelNamespace::kDev, "profile", "partition"};
  AccessRouteRegistry registry_{key_, "incarnation"};
  std::unique_ptr<NetworkService> service_;
  mojo::Remote<mojom::NetworkContext> context_remote_;
  std::unique_ptr<NetworkContext> context_;
  cors::OriginAccessList origin_access_list_;
  mojo::Remote<mojom::AegisAccessURLLoaderFactory> factory_remote_;
  mojo::Remote<mojom::AegisAccessURLLoaderControl> control_;
  int request_sequence_ = 0;
  uint64_t policy_generation_ = 1;
  std::unique_ptr<AccessPrivateURLLoaderFactory> owner_;
  mojo::Remote<mojom::URLLoader> loader_;
  std::unique_ptr<TestURLLoaderClient> client_;
};
TEST_F(AccessPrivateFactoryTest, PreflightAndActualUseSameRegisteredProxy) {
  Start();
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 1);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessPrivateFactoryTest, WebsiteResourcePreflightAndActualRetainCors) {
  UseWebsiteFactory();
  Start();
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 1);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessPrivateFactoryTest, WebsitePermissionDoesNotBypassFailedCorsPreflight) {
  UseWebsiteFactory();
  allow_cors_ = false;
  Start();
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_TRUE(client_->completion_status().cors_error_status);
  EXPECT_EQ(preflights_, 1);
  EXPECT_EQ(actual_, 0);
}
TEST_F(AccessPrivateFactoryTest, WebsitePermissionCannotCrossFactoryTopSite) {
  UseWebsiteFactory(false);
  Start();
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 0);
  EXPECT_EQ(actual_, 0);
}
TEST_F(AccessPrivateFactoryTest, SuccessfulTerminalEventsSurviveControlPipeClosure) {
  for (int i = 0; i < 20; ++i) {
    SCOPED_TRACE(i);
    Start(false, false, "", false, i % 2 == 0);
    client_->RunUntilComplete();
    EXPECT_EQ(client_->completion_status().error_code, net::OK);
    environment_.RunUntilIdle();
  }
  EXPECT_EQ(actual_, 20);
}
TEST_F(AccessPrivateFactoryTest, CorsFailureDoesNotSendActualRequest) {
  allow_cors_ = false;
  Start();
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_TRUE(client_->completion_status().cors_error_status.has_value());
  EXPECT_EQ(preflights_, 1);
  EXPECT_EQ(actual_, 0);
}
TEST_F(AccessPrivateFactoryTest, ManagedPreflightDoesNotPopulateSharedCache) {
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
TEST_F(AccessPrivateFactoryTest, RejectsEnvelopeTargetMismatchBeforeSend) {
  Start(false, false, "bad-target", true);
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 0);
  EXPECT_EQ(actual_, 0);
}
TEST_F(AccessPrivateFactoryTest, RequestTokenCannotReplayAfterCompletion) {
  Start(false, false, "same-token");
  client_->RunUntilComplete();
  ASSERT_EQ(client_->completion_status().error_code, net::OK);
  Start(false, false, "same-token");
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 1);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessPrivateFactoryTest, RestoringBlocksPrivateIPCRequestBeforeSend) {
  registry_.EnterRestoring();
  Start();
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 0);
  EXPECT_EQ(actual_, 0);
}
TEST_F(AccessPrivateFactoryTest, PublicRedirectCannotApproveNextHop) {
  redirect_first_ = true;
  Start();
  client_->RunUntilRedirectReceived();
  loader_->FollowRedirect(HttpRequestHeadersUpdateParams(), std::nullopt);
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::ERR_BLOCKED_BY_CLIENT);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessPrivateFactoryTest, PrivateRedirectApprovalRetainsCorsAndProxy) {
  redirect_first_ = true;
  Start(false, false, "redirect-token");
  client_->RunUntilRedirectReceived();
  auto envelope = mojom::AegisAccessRequestEnvelope::New();
  envelope->request_token = "redirect-token";
  envelope->incarnation = "incarnation";
  envelope->hop = 1;
  envelope->target = client_->redirect_info().new_url;
  envelope->method = client_->redirect_info().new_method;
  envelope->generations = mojom::AegisAccessGenerations::New(1,1,1,1,1);
  envelope->registration_id = "registration";
  control_->FollowRedirectWithRoute(HttpRequestHeadersUpdateParams(),
                                    std::nullopt, std::move(envelope));
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(actual_, 2);
  EXPECT_EQ(preflights_, 2);
}
TEST_F(AccessPrivateFactoryTest, SameOriginEnvelopeCannotOverrideUnchangedUrl) {
  redirect_first_ = true;
  Start(false, false, "redirect-token");
  client_->RunUntilRedirectReceived();
  auto envelope = mojom::AegisAccessRequestEnvelope::New();
  envelope->request_token = "redirect-token";
  envelope->incarnation = "incarnation";
  envelope->hop = 1;
  envelope->target = GURL("http://destination.test/forged");
  envelope->method = client_->redirect_info().new_method;
  envelope->generations = mojom::AegisAccessGenerations::New(1,1,1,1,1);
  envelope->registration_id = "registration";
  control_->FollowRedirectWithRoute(HttpRequestHeadersUpdateParams(),
                                    std::nullopt, std::move(envelope));
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::ERR_BLOCKED_BY_CLIENT);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessPrivateFactoryTest, NativeRedirectAlsoRequiresPrivateApproval) {
  redirect_first_ = true;
  Start(false, false, "native-token", false, true);
  client_->RunUntilRedirectReceived();
  loader_->FollowRedirect(HttpRequestHeadersUpdateParams(), std::nullopt);
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::ERR_BLOCKED_BY_CLIENT);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessPrivateFactoryTest, ApprovedNativeRedirectAcquiresManagedRoute) {
  redirect_first_ = true;
  Start(false, false, "native-token", false, true);
  client_->RunUntilRedirectReceived();
  auto envelope = mojom::AegisAccessRequestEnvelope::New();
  envelope->request_token = "native-token";
  envelope->incarnation = "incarnation";
  envelope->hop = 1;
  envelope->target = client_->redirect_info().new_url;
  envelope->method = client_->redirect_info().new_method;
  envelope->generations = mojom::AegisAccessGenerations::New(1,1,1,1,1);
  envelope->registration_id = "registration";
  control_->FollowRedirectWithRoute(HttpRequestHeadersUpdateParams(),
                                    std::nullopt, std::move(envelope));
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(actual_, 2);
  EXPECT_EQ(preflights_, 0);
}
TEST_F(AccessPrivateFactoryTest, LosingPrivateControlCancelsPendingRedirect) {
  redirect_first_ = true;
  Start();
  client_->RunUntilRedirectReceived();
  control_.reset();
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::ERR_ABORTED);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessPrivateFactoryTest, CloneSharesBindingAndReplayProtection) {
  mojo::Remote<mojom::AegisAccessURLLoaderFactory> clone;
  factory_remote_->Clone(clone.BindNewPipeAndPassReceiver());
  factory_remote_.FlushForTesting();
  Start(false, false, "cloned-token");
  client_->RunUntilComplete();
  ASSERT_EQ(client_->completion_status().error_code, net::OK);
  factory_remote_ = std::move(clone);
  Start(false, false, "cloned-token");
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::ERR_BLOCKED_BY_CLIENT);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessPrivateFactoryTest, OriginalInitiatorLockStillRejectsMismatch) {
  mojo::test::BadMessageObserver observer;
  Start(true);
  EXPECT_FALSE(observer.WaitForBadMessage().empty());
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 0);
  EXPECT_EQ(actual_, 0);
}
TEST_F(AccessPrivateFactoryTest, PrivateRouteDoesNotTrustRendererTrustedParams) {
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
