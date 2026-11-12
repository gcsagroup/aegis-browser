// Copyright 2026 GCSA
#include <atomic>
#include "base/functional/bind.h"
#include "base/test/task_environment.h"
#include "base/test/run_until.h"
#include "base/test/scoped_run_loop_timeout.h"
#include "base/time/time.h"
#include "net/test/embedded_test_server/controllable_http_response.h"
#include "mojo/core/embedder/embedder.h"
#include "mojo/public/cpp/test_support/test_utils.h"
#include "mojo/public/cpp/test_support/fake_message_dispatch_context.h"
#include "net/test/embedded_test_server/embedded_test_server.h"
#include "net/test/embedded_test_server/http_response.h"
#include "net/traffic_annotation/network_traffic_annotation_test_helper.h"
#include "base/test/test_future.h"
#include "components/aegis_access/access_route_types.h"
#include "services/network/public/mojom/aegis_access_route.mojom.h"
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
  s->incarnation = "template-incarnation";
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
class AccessNetworkContextIPCTest : public testing::Test {
 protected:
  void SetUp() override {
    mojo::core::Init();
    native_held_ = std::make_unique<net::test_server::ControllableHttpResponse>(
        &server_, "/hold-native");
    proxy_held_ = std::make_unique<net::test_server::ControllableHttpResponse>(
        &server_, "/hold-proxy");
    server_.RegisterRequestHandler(base::BindRepeating(
        &AccessNetworkContextIPCTest::Respond, base::Unretained(this)));
    ASSERT_TRUE(server_.Start());
    service_ = NetworkService::CreateForTesting();
    auto params = mojom::NetworkContextParams::New();
    params->cert_verifier_params = FakeTestCertVerifierParamsFactory::GetCertVerifierParams();
    params->initial_proxy_config = net::ProxyConfigWithAnnotation::CreateDirect();
    context_ = std::make_unique<NetworkContext>(service_.get(),
        context_remote_.BindNewPipeAndPassReceiver(), std::move(params));
    base::test::TestFuture<std::string> bind_future;
    context_remote_->BindAegisAccessContext(
        capability_.BindNewPipeAndPassReceiver(),
        bind_future.GetCallback<const std::string&>());
    incarnation_ = bind_future.Get();
    ASSERT_FALSE(incarnation_.empty());
    auto factory_params = mojom::URLLoaderFactoryParams::New();
    factory_params->process_id = OriginatingProcessId::FromUnsafeValue(42);
    factory_params->is_trusted = false;
    factory_params->request_initiator_origin_lock = initiator_;
    factory_params->isolation_info = net::IsolationInfo::CreateForInternalRequest(initiator_);
    auto snapshot = Snapshot();
    ASSERT_TRUE(Install(*snapshot));
    auto binding = mojom::AegisAccessFactoryBinding::New();
    binding->owner = snapshot->owner.Clone();
    binding->incarnation = incarnation_;
    binding->attribution = mojom::AegisAccessAttribution::kProfileOnly;
    ASSERT_TRUE(CreateFactory(std::move(factory_params), nullptr,
        std::move(binding), factory_remote_.BindNewPipeAndPassReceiver()));

  }
  void TearDown() override {
    loader_.reset();
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
             bool native_start = false, bool hold_for_reset = false) {
    loader_.reset();
    client_ = std::make_unique<TestURLLoaderClient>();
    ResourceRequest request;
    request.url = native_start
        ? server_.GetURL("localhost", hold_for_reset ? "/hold-native" : "/native")
        : GURL(hold_for_reset ? "http://destination.test/hold-proxy"
                             : "http://destination.test/resource");
    request.method = native_start || hold_for_reset ? "GET" : "PUT";
    request.mode = native_start || hold_for_reset ? mojom::RequestMode::kNoCors
                                                 : mojom::RequestMode::kCors;
    request.credentials_mode = mojom::CredentialsMode::kOmit;
    request.request_initiator = wrong_initiator
        ? url::Origin::Create(GURL("http://other.test")) : initiator_;
    if (!native_start && !hold_for_reset)
      request.headers.SetHeader("x-access-test", "1");
    if (fake_trusted) request.trusted_params.emplace();
    if (token.empty()) token = std::to_string(++request_sequence_);
    auto envelope = mojom::AegisAccessRequestEnvelope::New();
    envelope->request_token = token;
    envelope->incarnation = incarnation_;
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
  void ResetWhileRequestIsHeld(bool native, bool cancel_after_reset = false) {
    base::test::ScopedRunLoopTimeout timeout(FROM_HERE, base::Seconds(10));
    Start(false, false, "", false, native, true);
    auto& response = native ? *native_held_ : *proxy_held_;
    ASSERT_TRUE(base::test::RunUntil([&] {
      return response.has_received_request() || client_->has_received_completion() ||
             client_->has_received_disconnect();
    }));
    ASSERT_TRUE(response.has_received_request());
    response.WaitForRequest();
    ASSERT_TRUE(response.has_received_request());
    ASSERT_FALSE(client_->has_received_completion());
    context_remote_->ResetURLLoaderFactories();
    context_remote_.FlushForTesting();
    factory_remote_.FlushForTesting();
    EXPECT_FALSE(factory_remote_.is_connected());
    environment_.RunUntilIdle();
    // A factory binding reset must not close an already-started loader/client.
    ASSERT_FALSE(client_->has_received_disconnect());
    ASSERT_FALSE(client_->has_received_completion());
    if (cancel_after_reset) {
      loader_.reset();
      client_->RunUntilComplete();
      EXPECT_EQ(client_->completion_status().error_code, net::ERR_ABORTED);
      response.Done();
    } else {
      response.Send("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 8\r\n\r\nfinished");
      response.Done();
      client_->RunUntilComplete();
      EXPECT_EQ(client_->completion_status().error_code, net::OK);
      EXPECT_TRUE(client_->has_received_response());
    }
    environment_.RunUntilIdle();
  }
  bool Install(const mojom::AegisAccessSnapshot& snapshot) {
    base::test::TestFuture<mojom::AegisAccessSnapshotAckPtr> future;
    context_remote_->InstallAegisAccessSnapshot(snapshot.Clone(), future.GetCallback());
    last_ack_ = future.Take();
    return last_ack_->accepted;
  }
  bool EnterRestoring(const OwnershipKey&, std::string_view incarnation) {
    base::test::TestFuture<bool> future;
    context_remote_->BeginAegisAccessRestore(Snapshot()->owner.Clone(),
        std::string(incarnation), future.GetCallback());
    return future.Get();
  }
  bool CreateFactory(mojom::URLLoaderFactoryParamsPtr params,
      scoped_refptr<ResourceSchedulerClient>,
      mojom::AegisAccessFactoryBindingPtr binding,
      mojo::PendingReceiver<mojom::AegisAccessURLLoaderFactory> receiver) {
    base::test::TestFuture<bool> future;
    context_remote_->CreateAegisAccessURLLoaderFactory(std::move(receiver),
        std::move(params), std::move(binding), future.GetCallback());
    return future.Get();
  }
  mojom::AegisAccessSnapshotAckPtr last_ack_;
  mojom::AegisAccessSnapshotPtr Snapshot() {
    auto snapshot = WireSnapshot();
    snapshot->incarnation = incarnation_;
    snapshot->endpoints[0]->port = server_.port();
    snapshot->endpoints[0]->credentials.reset();
    return snapshot;
  }
  base::test::TaskEnvironment environment_{base::test::TaskEnvironment::MainThreadType::IO};
  mojo::FakeMessageDispatchContext mojo_context_;
  net::EmbeddedTestServer server_;
  std::unique_ptr<net::test_server::ControllableHttpResponse> native_held_;
  std::unique_ptr<net::test_server::ControllableHttpResponse> proxy_held_;
  std::atomic<int> preflights_{0}, actual_{0};
  std::atomic<bool> allow_cors_{true}, redirect_first_{false}, require_auth_{false};
  std::atomic<int> auth_challenges_{0}, authenticated_{0};
  uint64_t selection_generation_ = 1;
  std::string registration_id_ = "registration";
  const url::Origin initiator_ = url::Origin::Create(GURL("http://127.0.0.1:1234"));
  OwnershipKey key_{ChannelNamespace::kDev, "profile", "partition"};
  std::unique_ptr<NetworkService> service_;
  mojo::Remote<mojom::NetworkContext> context_remote_;
  mojo::Remote<mojom::AegisAccessContext> capability_;
  std::string incarnation_;
  std::unique_ptr<NetworkContext> context_;
  cors::OriginAccessList origin_access_list_;
  mojo::Remote<mojom::AegisAccessURLLoaderFactory> factory_remote_;
  mojo::Remote<mojom::AegisAccessURLLoaderControl> control_;
  int request_sequence_ = 0;
  mojo::Remote<mojom::URLLoader> loader_;
  std::unique_ptr<TestURLLoaderClient> client_;
};
TEST_F(AccessNetworkContextIPCTest, PreflightAndActualUseSameRegisteredProxy) {
  Start();
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 1);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessNetworkContextIPCTest, CorsFailureDoesNotSendActualRequest) {
  allow_cors_ = false;
  Start();
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_TRUE(client_->completion_status().cors_error_status.has_value());
  EXPECT_EQ(preflights_, 1);
  EXPECT_EQ(actual_, 0);
}
TEST_F(AccessNetworkContextIPCTest, ManagedPreflightDoesNotPopulateSharedCache) {
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
TEST_F(AccessNetworkContextIPCTest, RejectsEnvelopeTargetMismatchBeforeSend) {
  Start(false, false, "bad-target", true);
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 0);
  EXPECT_EQ(actual_, 0);
}
TEST_F(AccessNetworkContextIPCTest, RequestTokenCannotReplayAfterCompletion) {
  Start(false, false, "same-token");
  client_->RunUntilComplete();
  ASSERT_EQ(client_->completion_status().error_code, net::OK);
  Start(false, false, "same-token");
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 1);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessNetworkContextIPCTest, RestoringBlocksPrivateIPCRequestBeforeSend) {
  ASSERT_TRUE(EnterRestoring(key_, incarnation_));
  Start();
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 0);
  EXPECT_EQ(actual_, 0);
}
TEST_F(AccessNetworkContextIPCTest, PublicRedirectCannotApproveNextHop) {
  redirect_first_ = true;
  Start();
  client_->RunUntilRedirectReceived();
  loader_->FollowRedirect(HttpRequestHeadersUpdateParams(), std::nullopt);
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::ERR_BLOCKED_BY_CLIENT);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessNetworkContextIPCTest, PrivateRedirectApprovalRetainsCorsAndProxy) {
  redirect_first_ = true;
  Start(false, false, "redirect-token");
  client_->RunUntilRedirectReceived();
  auto envelope = mojom::AegisAccessRequestEnvelope::New();
  envelope->request_token = "redirect-token";
  envelope->incarnation = incarnation_;
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
TEST_F(AccessNetworkContextIPCTest, SameOriginEnvelopeCannotOverrideUnchangedUrl) {
  redirect_first_ = true;
  Start(false, false, "redirect-token");
  client_->RunUntilRedirectReceived();
  auto envelope = mojom::AegisAccessRequestEnvelope::New();
  envelope->request_token = "redirect-token";
  envelope->incarnation = incarnation_;
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
TEST_F(AccessNetworkContextIPCTest, NativeRedirectAlsoRequiresPrivateApproval) {
  redirect_first_ = true;
  Start(false, false, "native-token", false, true);
  client_->RunUntilRedirectReceived();
  loader_->FollowRedirect(HttpRequestHeadersUpdateParams(), std::nullopt);
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::ERR_BLOCKED_BY_CLIENT);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessNetworkContextIPCTest, ApprovedNativeRedirectAcquiresManagedRoute) {
  redirect_first_ = true;
  Start(false, false, "native-token", false, true);
  client_->RunUntilRedirectReceived();
  auto envelope = mojom::AegisAccessRequestEnvelope::New();
  envelope->request_token = "native-token";
  envelope->incarnation = incarnation_;
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
TEST_F(AccessNetworkContextIPCTest, LosingPrivateControlCancelsPendingRedirect) {
  redirect_first_ = true;
  Start();
  client_->RunUntilRedirectReceived();
  control_.reset();
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::ERR_ABORTED);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessNetworkContextIPCTest, CloneSharesBindingAndReplayProtection) {
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
TEST_F(AccessNetworkContextIPCTest, ForeignSnapshotCannotReplaceBoundOwner) {
  auto foreign = Snapshot();
  foreign->owner->profile_token = "other-profile";
  foreign->sequence = 2;
  EXPECT_FALSE(Install(*foreign));
  Start();
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessNetworkContextIPCTest, WrongIncarnationCannotRestoreOrCreateFactory) {
  EXPECT_FALSE(EnterRestoring(key_, "old"));
  auto binding = mojom::AegisAccessFactoryBinding::New();
  binding->owner = Snapshot()->owner.Clone();
  binding->incarnation = "old";
  binding->attribution = mojom::AegisAccessAttribution::kProfileOnly;
  auto params = mojom::URLLoaderFactoryParams::New();
  params->process_id = OriginatingProcessId::FromUnsafeValue(42);
  params->request_initiator_origin_lock = initiator_;
  mojo::Remote<mojom::AegisAccessURLLoaderFactory> wrong;
  EXPECT_FALSE(CreateFactory(std::move(params), nullptr,
      std::move(binding), wrong.BindNewPipeAndPassReceiver()));
}
TEST_F(AccessNetworkContextIPCTest, AuthenticatedSnapshotDrivesPreflightAndActual) {
  require_auth_ = true;
  auto snapshot = Snapshot();
  snapshot->sequence = 2;
  snapshot->endpoints[0]->credentials = net::AuthCredentials(u"local-user", u"local-secret");
  snapshot->endpoints[0]->registration_id = "authenticated-registration";
  snapshot->endpoints[0]->selection_generation = 2;
  ASSERT_TRUE(Install(*snapshot));
  registration_id_ = "authenticated-registration";
  selection_generation_ = 2;
  Start();
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 1);
  EXPECT_EQ(actual_, 1);
  EXPECT_EQ(authenticated_, 2);
}
TEST_F(AccessNetworkContextIPCTest, WrongLocalCredentialsNeverSendActualRequest) {
  require_auth_ = true;
  auto snapshot = Snapshot();
  snapshot->sequence = 2;
  snapshot->endpoints[0]->credentials = net::AuthCredentials(u"local-user", u"wrong");
  snapshot->endpoints[0]->registration_id = "wrong-auth-registration";
  snapshot->endpoints[0]->selection_generation = 2;
  ASSERT_TRUE(Install(*snapshot));
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
TEST_F(AccessNetworkContextIPCTest, AckBindsCompleteInstalledIdentityWithoutSecrets) {
  ASSERT_TRUE(last_ack_);
  EXPECT_TRUE(last_ack_->accepted);
  EXPECT_EQ(last_ack_->owner->profile_token, "profile");
  EXPECT_EQ(last_ack_->owner->storage_partition_token, "partition");
  EXPECT_EQ(last_ack_->incarnation, incarnation_);
  EXPECT_EQ(last_ack_->sequence, 1u);
  EXPECT_EQ(last_ack_->common_generations->policy_generation, 1u);
  ASSERT_EQ(last_ack_->registrations.size(), 1u);
  EXPECT_EQ(last_ack_->registrations[0]->proxy_group_id, "group");
  EXPECT_EQ(last_ack_->registrations[0]->registration_id, "registration");
  EXPECT_EQ(last_ack_->registrations[0]->selection_generation, 1u);
  auto old = Snapshot();
  EXPECT_FALSE(Install(*old));
  EXPECT_FALSE(last_ack_->accepted);
  EXPECT_EQ(last_ack_->sequence, 1u);
}
TEST_F(AccessNetworkContextIPCTest, ResetFactoriesRevokesAlreadyIssuedPrivateReceiver) {
  context_remote_->ResetURLLoaderFactories();
  context_remote_.FlushForTesting();
  factory_remote_.FlushForTesting();
  EXPECT_FALSE(factory_remote_.is_connected());
}
TEST_F(AccessNetworkContextIPCTest, FactoryResetPreservesInFlightNativeHttp) {
  ResetWhileRequestIsHeld(true);
}
TEST_F(AccessNetworkContextIPCTest, FactoryResetPreservesInFlightProxyHttp) {
  ResetWhileRequestIsHeld(false);
}
TEST_F(AccessNetworkContextIPCTest, InFlightRequestCanCancelAfterFactoryReset) {
  ResetWhileRequestIsHeld(true, true);
}
TEST_F(AccessNetworkContextIPCTest, RetainedPrivateContextUsesExactOriginalContext) {
  mojo::Remote<mojom::AegisAccessContext> capability;
  base::test::TestFuture<std::string> future;
  context_remote_->BindAegisAccessContext(
      capability.BindNewPipeAndPassReceiver(),
      future.GetCallback<const std::string&>());
  const auto incarnation = future.Get();
  EXPECT_FALSE(incarnation.empty());
  base::test::TestFuture<bool> restored;
  capability->BeginRestore(Snapshot()->owner.Clone(), incarnation,
                           restored.GetCallback());
  EXPECT_TRUE(restored.Get());
  Start();
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(actual_, 0);
}
TEST_F(AccessNetworkContextIPCTest, OriginalInitiatorLockStillRejectsMismatch) {
  mojo::test::BadMessageObserver observer;
  Start(true);
  EXPECT_FALSE(observer.WaitForBadMessage().empty());
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 0);
  EXPECT_EQ(actual_, 0);
}
TEST_F(AccessNetworkContextIPCTest, PrivateRouteDoesNotTrustRendererTrustedParams) {
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
