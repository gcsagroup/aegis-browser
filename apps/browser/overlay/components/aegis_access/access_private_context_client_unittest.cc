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
#include "base/test/test_future.h"
#include "chrome/browser/aegis/access/access_private_context_client.h"
#include "components/aegis_access/access_proxy_route_adapter.h"
#include "components/aegis_access/access_policy_evaluator.h"
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
#include "services/network/test/test_network_context.h"
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
class AckContext final : public TestNetworkContext,
                         public mojom::AegisAccessContext {
 public:
  void BindAegisAccessContext(
      mojo::PendingReceiver<mojom::AegisAccessContext> receiver,
      BindAegisAccessContextCallback callback) override {
    receivers_.Add(this, std::move(receiver));
    std::move(callback).Run("ack-context");
  }
  void InstallSnapshot(mojom::AegisAccessSnapshotPtr snapshot,
                       InstallSnapshotCallback callback) override {
    auto ack = mojom::AegisAccessSnapshotAck::New();
    ack->accepted = true;
    ack->owner = snapshot->owner.Clone();
    ack->incarnation = snapshot->incarnation;
    ack->sequence = snapshot->sequence;
    ack->common_generations = snapshot->common_generations.Clone();
    for (const auto& endpoint : snapshot->endpoints) {
      ack->registrations.push_back(mojom::AegisAccessRegistrationAck::New(
          endpoint->proxy_group_id, endpoint->registration_id,
          endpoint->selection_generation));
    }
    for (const auto& group : snapshot->unavailable_groups) {
      ack->unavailable_groups.push_back(group.Clone());
    }
    switch (mutation) {
      case 0: ack->owner->channel = mojom::AegisAccessChannel::kAlpha; break;
      case 1: ack->owner->profile_token = "foreign"; break;
      case 2: ack->owner->storage_partition_token = "foreign"; break;
      case 3: ack->incarnation = "old"; break;
      case 4: ++ack->sequence; break;
      case 5: ++ack->common_generations->policy_generation; break;
      case 6: ++ack->common_generations->identity_generation; break;
      case 7: ++ack->common_generations->selection_generation; break;
      case 8: ++ack->common_generations->network_epoch; break;
      case 9: ++ack->common_generations->base_proxy_config_generation; break;
      case 10: ack->registrations[0]->proxy_group_id = "foreign"; break;
      case 11: ack->registrations[0]->registration_id = "foreign"; break;
      case 12: ++ack->registrations[0]->selection_generation; break;
      case 13: ack->registrations.clear(); break;
      case 14: ack->unavailable_groups[0]->proxy_group_id = "foreign"; break;
      case 15: ++ack->unavailable_groups[0]->selection_generation; break;
      case 16: ack->unavailable_groups.clear(); break;
    }
    if (hold_ack) {
      held_ack = std::move(ack);
      held_callback = std::move(callback);
    } else {
      std::move(callback).Run(std::move(ack));
    }
  }
  void BeginRestore(mojom::AegisAccessOwnerPtr, const std::string&,
                    BeginRestoreCallback callback) override {
    std::move(callback).Run(true);
  }
  void CreateFactory(mojo::PendingReceiver<mojom::AegisAccessURLLoaderFactory>,
      mojom::URLLoaderFactoryParamsPtr, mojom::AegisAccessFactoryBindingPtr,
      CreateFactoryCallback callback) override {
    std::move(callback).Run(true);
  }
  int mutation = -1;
  bool hold_ack = false;
  mojom::AegisAccessSnapshotAckPtr held_ack;
  InstallSnapshotCallback held_callback;
  mojo::ReceiverSet<mojom::AegisAccessContext> receivers_;
};
class AccessPrivateContextAckTest : public testing::Test {
 protected:
  void SetUp() override { mojo::core::Init(); }
  std::unique_ptr<aegis::access::AccessPrivateContextClient> Client() {
    auto client = std::make_unique<aegis::access::AccessPrivateContextClient>(
        OwnershipKey{ChannelNamespace::kDev, "profile", "partition"});
    base::test::TestFuture<bool> future;
    client->Initialize(&context_, future.GetCallback());
    EXPECT_TRUE(future.Get());
    return client;
  }
  mojom::AegisAccessSnapshotPtr Snapshot() {
    auto snapshot = WireSnapshot();
    snapshot->incarnation.clear();
    return snapshot;
  }
  base::test::TaskEnvironment environment_{base::test::TaskEnvironment::MainThreadType::IO};
  AckContext context_;
};
TEST_F(AccessPrivateContextAckTest, EveryAckIdentityFieldMustMatchCompleteCandidate) {
  for (int mutation = 0; mutation < 14; ++mutation) {
    SCOPED_TRACE(mutation);
    auto client = Client();
    context_.mutation = mutation;
    base::test::TestFuture<bool> future;
    client->PublishSnapshot(Snapshot(), future.GetCallback());
    EXPECT_FALSE(future.Get());
    EXPECT_FALSE(client->is_ready());
    EXPECT_EQ(client->published_sequence(), 0u);
  }
}
TEST_F(AccessPrivateContextAckTest, LateAckCannotReleaseRestoringBarrier) {
  auto client = Client();
  context_.hold_ack = true;
  base::test::TestFuture<bool> published;
  client->PublishSnapshot(Snapshot(), published.GetCallback());
  base::test::TestFuture<bool> restoring;
  client->BeginRestore(restoring.GetCallback());
  ASSERT_TRUE(restoring.Get());
  ASSERT_TRUE(context_.held_callback);
  std::move(context_.held_callback).Run(std::move(context_.held_ack));
  EXPECT_FALSE(published.Get());
  EXPECT_FALSE(client->is_ready());
}
TEST_F(AccessPrivateContextAckTest, UnavailableGroupAckMustMatchCompleteCandidate) {
  for (int mutation = 14; mutation < 17; ++mutation) {
    SCOPED_TRACE(mutation);
    auto client = Client();
    context_.mutation = mutation;
    auto snapshot = Snapshot();
    snapshot->endpoints.clear();
    snapshot->unavailable_groups.push_back(
        mojom::AegisAccessUnavailableGroup::New("group", 0));
    base::test::TestFuture<bool> future;
    client->PublishSnapshot(std::move(snapshot), future.GetCallback());
    EXPECT_FALSE(future.Get());
    EXPECT_FALSE(client->is_ready());
    EXPECT_EQ(client->published_sequence(), 0u);
  }
}
TEST_F(AccessPrivateContextAckTest, DisconnectedCapabilityCannotReuseReadyState) {
  auto client = Client();
  base::test::TestFuture<bool> published;
  client->PublishSnapshot(Snapshot(), published.GetCallback());
  ASSERT_TRUE(published.Get());
  context_.receivers_.Clear();
  environment_.RunUntilIdle();
  EXPECT_FALSE(client->is_ready());
  base::test::TestFuture<bool> again;
  auto next = Snapshot();
  next->sequence = 2;
  client->PublishSnapshot(std::move(next), again.GetCallback());
  EXPECT_FALSE(again.Get());
}

class AccessPrivateContextClientTest : public testing::Test {
 protected:
  void SetUp() override {
    mojo::core::Init();
    server_.RegisterRequestHandler(base::BindRepeating(
        &AccessPrivateContextClientTest::Respond, base::Unretained(this)));
    ASSERT_TRUE(server_.Start());
    service_ = NetworkService::CreateForTesting();
    auto params = mojom::NetworkContextParams::New();
    params->cert_verifier_params = FakeTestCertVerifierParamsFactory::GetCertVerifierParams();
    params->initial_proxy_config = net::ProxyConfigWithAnnotation::CreateDirect();
    context_ = std::make_unique<NetworkContext>(service_.get(),
        context_remote_.BindNewPipeAndPassReceiver(), std::move(params));
    context_client_ = std::make_unique<aegis::access::AccessPrivateContextClient>(key_);
    base::test::TestFuture<bool> bind_future;
    context_client_->Initialize(context_remote_.get(), bind_future.GetCallback());
    ASSERT_TRUE(bind_future.Get());
    incarnation_ = context_client_->incarnation();
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
    context_client_.reset();
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
    envelope->incarnation = incarnation_;
    envelope->target = wrong_target ? GURL("http://other.test/") : request.url;
    envelope->method = request.method;
    envelope->generations = mojom::AegisAccessGenerations::New(policy_generation_,1,
        native_start ? 0 : selection_generation_,1,1);
    envelope->registration_id = native_start ? "" : registration_id_;
    auto routed = mojom::AegisAccessRoutedRequest::New(request, std::move(envelope));
    control_.reset();
    factory_remote_->CreateLoaderAndStartWithRoute(
        loader_.BindNewPipeAndPassReceiver(), control_.BindNewPipeAndPassReceiver(),
        0, 0, std::move(routed), client_->CreateRemote(),
        net::MutableNetworkTrafficAnnotationTag(TRAFFIC_ANNOTATION_FOR_TESTS));

  }
  bool Install(const mojom::AegisAccessSnapshot& snapshot) {
    base::test::TestFuture<bool> future;
    context_client_->PublishSnapshot(snapshot.Clone(), future.GetCallback());
    return future.Get();
  }
  bool EnterRestoring(const OwnershipKey&, std::string_view incarnation) {
    if (incarnation != incarnation_) return false;
    base::test::TestFuture<bool> future;
    context_client_->BeginRestore(future.GetCallback());
    return future.Get();
  }
  bool CreateFactory(mojom::URLLoaderFactoryParamsPtr params,
      scoped_refptr<ResourceSchedulerClient>,
      mojom::AegisAccessFactoryBindingPtr binding,
      mojo::PendingReceiver<mojom::AegisAccessURLLoaderFactory> receiver) {
    base::test::TestFuture<bool> future;
    context_client_->CreateFactory(std::move(params), std::move(binding),
        std::move(receiver), future.GetCallback());
    return future.Get();
  }
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
  std::atomic<int> preflights_{0}, actual_{0};
  std::atomic<bool> allow_cors_{true}, redirect_first_{false}, require_auth_{false};
  std::atomic<int> auth_challenges_{0}, authenticated_{0};
  uint64_t selection_generation_ = 1;
  uint64_t policy_generation_ = 1;
  std::string registration_id_ = "registration";
  const url::Origin initiator_ = url::Origin::Create(GURL("http://127.0.0.1:1234"));
  OwnershipKey key_{ChannelNamespace::kDev, "profile", "partition"};
  std::unique_ptr<NetworkService> service_;
  mojo::Remote<mojom::NetworkContext> context_remote_;
  std::unique_ptr<aegis::access::AccessPrivateContextClient> context_client_;
  std::string incarnation_;
  std::unique_ptr<NetworkContext> context_;
  cors::OriginAccessList origin_access_list_;
  mojo::Remote<mojom::AegisAccessURLLoaderFactory> factory_remote_;
  mojo::Remote<mojom::AegisAccessURLLoaderControl> control_;
  int request_sequence_ = 0;
  mojo::Remote<mojom::URLLoader> loader_;
  std::unique_ptr<TestURLLoaderClient> client_;
};
TEST_F(AccessPrivateContextClientTest, PreflightAndActualUseSameRegisteredProxy) {
  Start();
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 1);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessPrivateContextClientTest, CorsFailureDoesNotSendActualRequest) {
  allow_cors_ = false;
  Start();
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_TRUE(client_->completion_status().cors_error_status.has_value());
  EXPECT_EQ(preflights_, 1);
  EXPECT_EQ(actual_, 0);
}
TEST_F(AccessPrivateContextClientTest, ManagedPreflightDoesNotPopulateSharedCache) {
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
TEST_F(AccessPrivateContextClientTest, RejectsEnvelopeTargetMismatchBeforeSend) {
  Start(false, false, "bad-target", true);
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 0);
  EXPECT_EQ(actual_, 0);
}
TEST_F(AccessPrivateContextClientTest, RequestTokenCannotReplayAfterCompletion) {
  Start(false, false, "same-token");
  client_->RunUntilComplete();
  ASSERT_EQ(client_->completion_status().error_code, net::OK);
  Start(false, false, "same-token");
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 1);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessPrivateContextClientTest, RestoringBlocksPrivateIPCRequestBeforeSend) {
  ASSERT_TRUE(EnterRestoring(key_, incarnation_));
  Start();
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 0);
  EXPECT_EQ(actual_, 0);
}
TEST_F(AccessPrivateContextClientTest, PublicRedirectCannotApproveNextHop) {
  redirect_first_ = true;
  Start();
  client_->RunUntilRedirectReceived();
  loader_->FollowRedirect(HttpRequestHeadersUpdateParams(), std::nullopt);
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::ERR_BLOCKED_BY_CLIENT);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessPrivateContextClientTest, PrivateRedirectApprovalRetainsCorsAndProxy) {
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
TEST_F(AccessPrivateContextClientTest, SameOriginEnvelopeCannotOverrideUnchangedUrl) {
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
TEST_F(AccessPrivateContextClientTest, NativeRedirectAlsoRequiresPrivateApproval) {
  redirect_first_ = true;
  Start(false, false, "native-token", false, true);
  client_->RunUntilRedirectReceived();
  loader_->FollowRedirect(HttpRequestHeadersUpdateParams(), std::nullopt);
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::ERR_BLOCKED_BY_CLIENT);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessPrivateContextClientTest, ApprovedNativeRedirectAcquiresManagedRoute) {
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
TEST_F(AccessPrivateContextClientTest, LosingPrivateControlCancelsPendingRedirect) {
  redirect_first_ = true;
  Start();
  client_->RunUntilRedirectReceived();
  control_.reset();
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::ERR_ABORTED);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessPrivateContextClientTest, CloneSharesBindingAndReplayProtection) {
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
TEST_F(AccessPrivateContextClientTest, ForeignSnapshotCannotReplaceBoundOwner) {
  auto foreign = Snapshot();
  foreign->owner->profile_token = "other-profile";
  foreign->sequence = 2;
  EXPECT_FALSE(Install(*foreign));
  Start();
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessPrivateContextClientTest, WrongIncarnationCannotRestoreOrCreateFactory) {
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
TEST_F(AccessPrivateContextClientTest, AuthenticatedSnapshotDrivesPreflightAndActual) {
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
TEST_F(AccessPrivateContextClientTest, WrongLocalCredentialsNeverSendActualRequest) {
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
TEST_F(AccessPrivateContextClientTest, AcknowledgedSnapshotIsRequiredForFactoryCreation) {
  EXPECT_TRUE(context_client_->is_ready());
  EXPECT_EQ(context_client_->published_sequence(), 1u);
  ASSERT_TRUE(EnterRestoring(key_, incarnation_));
  EXPECT_FALSE(context_client_->is_ready());
  auto binding = mojom::AegisAccessFactoryBinding::New();
  binding->owner = Snapshot()->owner.Clone();
  binding->incarnation = incarnation_;
  binding->attribution = mojom::AegisAccessAttribution::kProfileOnly;
  mojo::Remote<mojom::AegisAccessURLLoaderFactory> remote;
  auto params = mojom::URLLoaderFactoryParams::New();
  params->process_id = OriginatingProcessId::FromUnsafeValue(42);
  EXPECT_FALSE(CreateFactory(std::move(params), nullptr, std::move(binding),
                             remote.BindNewPipeAndPassReceiver()));
}
TEST_F(AccessPrivateContextClientTest, ResetFactoriesRevokesAlreadyIssuedPrivateReceiver) {
  context_remote_->ResetURLLoaderFactories();
  context_remote_.FlushForTesting();
  factory_remote_.FlushForTesting();
  EXPECT_FALSE(factory_remote_.is_connected());
}
TEST_F(AccessPrivateContextClientTest, ResetPreservesExemptServiceWorkerFactory) {
  auto params = mojom::URLLoaderFactoryParams::New();
  params->process_id = OriginatingProcessId::FromUnsafeValue(42);
  params->ignore_factory_reset = true;
  params->request_initiator_origin_lock = initiator_;
  params->isolation_info = net::IsolationInfo::CreateForInternalRequest(initiator_);
  auto binding = mojom::AegisAccessFactoryBinding::New();
  binding->owner = Snapshot()->owner.Clone();
  binding->incarnation = incarnation_;
  binding->attribution = mojom::AegisAccessAttribution::kProfileOnly;
  mojo::Remote<mojom::AegisAccessURLLoaderFactory> exempt;
  ASSERT_TRUE(CreateFactory(std::move(params), nullptr, std::move(binding),
                            exempt.BindNewPipeAndPassReceiver()));
  context_remote_->ResetURLLoaderFactories();
  context_remote_.FlushForTesting();
  exempt.FlushForTesting();
  factory_remote_.FlushForTesting();
  EXPECT_TRUE(exempt.is_connected());
  EXPECT_FALSE(factory_remote_.is_connected());
  factory_remote_.reset();
  factory_remote_.Bind(exempt.Unbind());
  Start();
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessPrivateContextClientTest, RetainedPrivateContextUsesExactOriginalContext) {
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
TEST_F(AccessPrivateContextClientTest, TypedPolicyPublicationIncludesCompleteRulesAndEndpoint) {
  AccessPolicyRule rule{"rule", key_, PolicyScope::kProfile, {}, "destination.test",
      false, {RequestScheme::kHttp}, {PortScope::kAllBrowserPermitted, {}},
      AccessMode::kProxy, "group", ProtectionOverride::kNone, 1, 2};
  RegisteredProxyEndpoint endpoint{"registration", "group", key_, {2,1,1,1,1},
      RegisteredProxyTransport::kHttp, "127.0.0.1", server_.port()};
  base::test::TestFuture<bool> published;
  context_client_->PublishPolicy({key_, 2, {rule}}, {2,1,0,1,1}, 2,
      {{endpoint, std::nullopt}}, published.GetCallback());
  ASSERT_TRUE(published.Get());
  Start();
  client_->RunUntilComplete();
  // Start still carries the old policy generation; the new policy must not
  // accept that stale envelope, even though its endpoint address is unchanged.
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(actual_, 0);
  policy_generation_ = 2;
  Start();
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(actual_, 1);
}
TEST_F(AccessPrivateContextClientTest, TypedEmptyPolicyIsExplicitAndDoesNotInventProxySelection) {
  base::test::TestFuture<bool> published;
  context_client_->PublishPolicy({key_, 2, {}}, {2,1,0,1,1}, 2, {},
                                 published.GetCallback());
  ASSERT_TRUE(published.Get());
  EXPECT_TRUE(context_client_->is_ready());
  EXPECT_EQ(context_client_->published_sequence(), 2u);
  policy_generation_ = 2;
  Start(false, false, "native-empty", false, true);
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(actual_, 1);
  EXPECT_EQ(preflights_, 0);
}
TEST_F(AccessPrivateContextClientTest, UnavailableProxyFailsWhileNativeAndLaterRecoveryWork) {
  AccessPolicyRule rule{"rule", key_, PolicyScope::kProfile, {}, "destination.test",
      false, {RequestScheme::kHttp}, {PortScope::kAllBrowserPermitted, {}},
      AccessMode::kProxy, "group", ProtectionOverride::kNone, 1, 2};
  base::test::TestFuture<bool> unavailable;
  context_client_->PublishPolicy({key_, 2, {rule}}, {2,1,0,1,1}, 2, {},
      {{"group", 1}}, unavailable.GetCallback());
  ASSERT_TRUE(unavailable.Get());
  policy_generation_ = 2;
  Start();
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code,
            net::ERR_PROXY_CONNECTION_FAILED);
  EXPECT_EQ(preflights_, 0);
  EXPECT_EQ(actual_, 0);
  Start(false, false, "unmatched-native", false, true);
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(actual_, 1);
  RegisteredProxyEndpoint endpoint{"replacement", "group", key_, {2,1,2,1,1},
      RegisteredProxyTransport::kHttp, "127.0.0.1", server_.port()};
  base::test::TestFuture<bool> recovered;
  context_client_->PublishPolicy({key_, 2, {rule}}, {2,1,0,1,1}, 3,
      {{endpoint, std::nullopt}}, recovered.GetCallback());
  ASSERT_TRUE(recovered.Get());
  selection_generation_ = 2;
  registration_id_ = "replacement";
  Start();
  client_->RunUntilComplete();
  EXPECT_EQ(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(actual_, 2);
}
TEST_F(AccessPrivateContextClientTest, OriginalInitiatorLockStillRejectsMismatch) {
  mojo::test::BadMessageObserver observer;
  Start(true);
  EXPECT_FALSE(observer.WaitForBadMessage().empty());
  client_->RunUntilComplete();
  EXPECT_NE(client_->completion_status().error_code, net::OK);
  EXPECT_EQ(preflights_, 0);
  EXPECT_EQ(actual_, 0);
}
TEST_F(AccessPrivateContextClientTest, PrivateRouteDoesNotTrustRendererTrustedParams) {
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
