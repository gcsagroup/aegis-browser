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
#include "services/network/aegis/access_network_context_state.h"
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
class AccessNetworkContextStateTest : public testing::Test {
 protected:
  void SetUp() override {
    mojo::core::Init();
    server_.RegisterRequestHandler(base::BindRepeating(
        &AccessNetworkContextStateTest::Respond, base::Unretained(this)));
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
    owner_ = std::make_unique<AccessNetworkContextState>(context_.get(),
                                                       &origin_access_list_);
    auto snapshot = Snapshot();
    ASSERT_TRUE(owner_->Install(*snapshot));
    auto binding = mojom::AegisAccessFactoryBinding::New();
    binding->owner = snapshot->owner.Clone();
    binding->incarnation = "incarnation";
    binding->attribution = mojom::AegisAccessAttribution::kProfileOnly;
    ASSERT_TRUE(owner_->CreateFactory(std::move(factory_params), nullptr,
        std::move(binding), factory_remote_.BindNewPipeAndPassReceiver()));

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
    if (require_auth_) {
      auto found = request.headers.find("proxy-authorization");
      if (found == request.headers.end() ||
          found->second != "Basic bG9jYWwtdXNlcjpsb2NhbC1zZWNyZXQ=") {
        ++auth_challenges_;
        auto denied = std::make_unique<net::test_server::BasicHttpResponse>();
        denied->set_code(net::HTTP_PROXY_AUTHENTICATION_REQUIRED);
        denied->AddCustomHeader("Proxy-Authenticate", "Basic realm=\"proxy\"");
        return denied;
      }
      ++authenticated_;
    }
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
    envelope->generations = mojom::AegisAccessGenerations::New(1,1,
        native_start ? 0 : selection_generation_,1,1);
    envelope->registration_id = native_start ? "" : registration_id_;
    auto routed = mojom::AegisAccessRoutedRequest::New(request, std::move(envelope));
    control_.reset();
    factory_remote_->CreateLoaderAndStartWithRoute(
        loader_.BindNewPipeAndPassReceiver(), control_.BindNewPipeAndPassReceiver(),
        0, 0, std::move(routed), client_->CreateRemote(),
        net::MutableNetworkTrafficAnnotationTag(TRAFFIC_ANNOTATION_FOR_TESTS));

  }
  mojom::AegisAccessSnapshotPtr Snapshot() {
    auto snapshot = WireSnapshot();
    snapshot->endpoints[0]->port = server_.port();
    snapshot->endpoints[0]->credentials.reset();
    return snapshot;
  }
  base::test::TaskEnvironment environment_{base::test::TaskEnvironment::MainThreadType::IO};
  mojo::FakeMessageDispatchContext mojo_context_;
  net::EmbeddedTestServer server_;
  std::atomic<int> preflights_{0}, actual_{0};
  std::atomic<bool> allow_cors_{true}, redirect_first_{false}, require_auth_{false};
  std::atomic<int> auth_challenges_{0}, authenticated_{0};
  uint64_t selection_generation_ = 1;
  std::string registration_id_ = "registration";
  const url::Origin initiator_ = url::Origin::Create(GURL("http://127.0.0.1:1234"));
  OwnershipKey key_{ChannelNamespace::kDev, "profile", "partition"};
  std::unique_ptr<NetworkService> service_;
  mojo::Remote<mojom::NetworkContext> context_remote_;
  std::unique_ptr<NetworkContext> context_;
  cors::OriginAccessList origin_access_list_;
  mojo::Remote<mojom::AegisAccessURLLoaderFactory> factory_remote_;
  mojo::Remote<mojom::AegisAccessURLLoaderControl> control_;
  int request_sequence_ = 0;
  std::unique_ptr<AccessNetworkContextState> owner_;
  mojo::Remote<mojom::URLLoader> loader_;
  std::unique_ptr<TestURLLoaderClient> client_;
};
TEST_F(AccessNetworkContextStateTest, PreflightAndActualUseSameRegisteredProxy) {
  Start();
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 1);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessNetworkContextStateTest, CorsFailureDoesNotSendActualRequest) {
  allow_cors_ = false;
  Start();
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_TRUE(client_->completion_status().cors_error_status.has_value());
  EXPECT_EQ(preflights_, 1);
  EXPECT_EQ(actual_, 0);
}
TEST_F(AccessNetworkContextStateTest, ManagedPreflightDoesNotPopulateSharedCache) {
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
TEST_F(AccessNetworkContextStateTest, RejectsEnvelopeTargetMismatchBeforeSend) {
  Start(false, false, "bad-target", true);
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 0);
  EXPECT_EQ(actual_, 0);
}
TEST_F(AccessNetworkContextStateTest, RequestTokenCannotReplayAfterCompletion) {
  Start(false, false, "same-token");
  client_->RunUntilComplete();
  ASSERT_EQ(client_->completion_status().error_code, net::OK);
  Start(false, false, "same-token");
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 1);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessNetworkContextStateTest, RestoringBlocksPrivateIPCRequestBeforeSend) {
  ASSERT_TRUE(owner_->EnterRestoring(key_, "incarnation"));
  Start();
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 0);
  EXPECT_EQ(actual_, 0);
}
TEST_F(AccessNetworkContextStateTest, PublicRedirectCannotApproveNextHop) {
  redirect_first_ = true;
  Start();
  client_->RunUntilRedirectReceived();
  loader_->FollowRedirect(HttpRequestHeadersUpdateParams(), std::nullopt);
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::ERR_BLOCKED_BY_CLIENT);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessNetworkContextStateTest, PrivateRedirectApprovalRetainsCorsAndProxy) {
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
TEST_F(AccessNetworkContextStateTest, SameOriginEnvelopeCannotOverrideUnchangedUrl) {
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
TEST_F(AccessNetworkContextStateTest, NativeRedirectAlsoRequiresPrivateApproval) {
  redirect_first_ = true;
  Start(false, false, "native-token", false, true);
  client_->RunUntilRedirectReceived();
  loader_->FollowRedirect(HttpRequestHeadersUpdateParams(), std::nullopt);
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::ERR_BLOCKED_BY_CLIENT);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessNetworkContextStateTest, ApprovedNativeRedirectAcquiresManagedRoute) {
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
TEST_F(AccessNetworkContextStateTest, LosingPrivateControlCancelsPendingRedirect) {
  redirect_first_ = true;
  Start();
  client_->RunUntilRedirectReceived();
  control_.reset();
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::ERR_ABORTED);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessNetworkContextStateTest, CloneSharesBindingAndReplayProtection) {
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
TEST_F(AccessNetworkContextStateTest, ForeignSnapshotCannotReplaceBoundOwner) {
  auto foreign = Snapshot();
  foreign->owner->profile_token = "other-profile";
  foreign->sequence = 2;
  EXPECT_FALSE(owner_->Install(*foreign));
  Start();
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessNetworkContextStateTest, WrongIncarnationCannotRestoreOrCreateFactory) {
  EXPECT_FALSE(owner_->EnterRestoring(key_, "old"));
  auto binding = mojom::AegisAccessFactoryBinding::New();
  binding->owner = Snapshot()->owner.Clone();
  binding->incarnation = "old";
  binding->attribution = mojom::AegisAccessAttribution::kProfileOnly;
  auto params = mojom::URLLoaderFactoryParams::New();
  params->process_id = OriginatingProcessId::FromUnsafeValue(42);
  params->request_initiator_origin_lock = initiator_;
  mojo::Remote<mojom::AegisAccessURLLoaderFactory> wrong;
  EXPECT_FALSE(owner_->CreateFactory(std::move(params), nullptr,
      std::move(binding), wrong.BindNewPipeAndPassReceiver()));
}
TEST_F(AccessNetworkContextStateTest, AuthenticatedSnapshotDrivesPreflightAndActual) {
  require_auth_ = true;
  auto snapshot = Snapshot();
  snapshot->sequence = 2;
  snapshot->endpoints[0]->credentials = net::AuthCredentials(u"local-user", u"local-secret");
  snapshot->endpoints[0]->registration_id = "authenticated-registration";
  snapshot->endpoints[0]->selection_generation = 2;
  ASSERT_TRUE(owner_->Install(*snapshot));
  registration_id_ = "authenticated-registration";
  selection_generation_ = 2;
  Start();
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 1);
  EXPECT_EQ(actual_, 1);
  EXPECT_EQ(authenticated_, 2);
}
TEST_F(AccessNetworkContextStateTest, WrongLocalCredentialsNeverSendActualRequest) {
  require_auth_ = true;
  auto snapshot = Snapshot();
  snapshot->sequence = 2;
  snapshot->endpoints[0]->credentials = net::AuthCredentials(u"local-user", u"wrong");
  snapshot->endpoints[0]->registration_id = "wrong-auth-registration";
  snapshot->endpoints[0]->selection_generation = 2;
  ASSERT_TRUE(owner_->Install(*snapshot));
  registration_id_ = "wrong-auth-registration";
  selection_generation_ = 2;
  Start();
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(authenticated_, 0);
  EXPECT_GT(auth_challenges_, 0);
  EXPECT_EQ(preflights_, 0);
  EXPECT_EQ(actual_, 0);
}
TEST_F(AccessNetworkContextStateTest, OriginalInitiatorLockStillRejectsMismatch) {
  mojo::test::BadMessageObserver observer;
  Start(true);
  EXPECT_FALSE(observer.WaitForBadMessage().empty());
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 0);
  EXPECT_EQ(actual_, 0);
}
TEST_F(AccessNetworkContextStateTest, PrivateRouteDoesNotTrustRendererTrustedParams) {
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
