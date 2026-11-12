// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_site_proxy_bubble_controller.h"
#include "chrome/browser/aegis/access/access_async_rule_store.h"
#include "chrome/browser/aegis/access/access_browser_request_adapter.h"
#include "chrome/browser/aegis/access/access_build_channel.h"
#include "chrome/browser/aegis/access/access_buildflags.h"
#include "chrome/browser/aegis/access/access_navigation_retry_tab_helper.h"
#include "chrome/browser/aegis/access/access_proxying_url_loader_factory.h"

#include <string_view>

#include "base/command_line.h"
#include "base/files/scoped_temp_dir.h"
#include "base/functional/bind.h"
#include "base/pending_task.h"
#include "base/task/current_thread.h"
#include "base/task/task_observer.h"
#include "base/test/bind.h"
#include "base/test/run_until.h"
#include "base/test/scoped_run_loop_timeout.h"
#include "base/test/test_future.h"
#include "chrome/browser/aegis/access/access_network_context_transport.h"
#include "chrome/browser/aegis/access/access_published_request_runtime.h"
#include "chrome/browser/net/profile_network_context_service.h"
#include "chrome/browser/net/profile_network_context_service_factory.h"
#include "chrome/test/base/testing_profile.h"
#include "chrome/test/base/chrome_render_view_host_test_harness.h"
#include "components/prefs/pref_service.h"
#include "components/proxy_config/proxy_config_pref_names.h"
#include "components/proxy_config/proxy_config_dictionary.h"
#include "content/public/test/browser_task_environment.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/navigation_simulator.h"
#include "net/base/net_errors.h"
#include "net/url_request/redirect_info.h"
#include "net/traffic_annotation/network_traffic_annotation_test_helper.h"
#include "mojo/public/cpp/bindings/receiver_set.h"
#include "services/network/public/cpp/url_loader_completion_status.h"
#include "services/network/public/mojom/url_response_head.mojom.h"
#include "services/network/test/test_network_context.h"
#include "services/network/test/test_url_loader_client.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::access {
class AccessSiteProxyProductTestPeer {
 public:
  static void LoseRuntime(AccessSiteProxyBubbleController* bubble,
                          const std::string& registration) {
    bubble->local_core_.reset();
    bubble->OnLocalCoreStopped(registration);
  }
  static bool HasCore(AccessSiteProxyBubbleController* bubble) {
    return !!bubble->local_core_;
  }
  static bool IsPreparing(AccessSiteProxyBubbleController* bubble) {
    return bubble->publication_in_flight_;
  }
  static void StopCore(AccessSiteProxyBubbleController* bubble,
                       base::OnceClosure completion) {
    bubble->local_core_->Stop(std::move(completion));
  }
};
class AccessServiceCoordinatorTestPeer {
 public:
  static base::OneShotTimer& PublicationTimer(AccessServiceCoordinator* coordinator) {
    return coordinator->publication_timeout_;
  }

  static void SetFailure(AccessServiceCoordinator* coordinator,
                        AccessRuleStore::FailurePointForTesting point) {
    CHECK(coordinator->async_store_);
    coordinator->async_store_->SetFailurePointForTesting(point);
  }
};
class AccessNetworkContextTransportTestPeer {
 public:
  static void AdvanceNetwork(AccessNetworkContextTransport* transport) {
    transport->OnNetworkChanged(net::NetworkChangeNotifier::CONNECTION_WIFI);
  }
};
namespace {

// Cancel after the real transport has queued its ready callback, immediately
// before it is delivered. The Mojo disconnect notification cannot run between
// closing the caller and resuming that callback on this sequence.
class CancelAtQueuedPolicyCompletion final : public base::TaskObserver {
 public:
  explicit CancelAtQueuedPolicyCompletion(base::OnceClosure cancel)
      : cancel_(std::move(cancel)) {
    base::CurrentThread::Get()->AddTaskObserver(this);
  }
  ~CancelAtQueuedPolicyCompletion() override {
    base::CurrentThread::Get()->RemoveTaskObserver(this);
  }
  void WillProcessTask(const base::PendingTask& task, bool) override {
    if (cancel_ && std::string_view(task.posted_from.function_name()).find(
                       "SettlePrivatePublication") != std::string_view::npos) {
      cancelled_ = true;
      std::move(cancel_).Run();
    }
  }
  void DidProcessTask(const base::PendingTask&) override {}
  bool cancelled() const { return cancelled_; }

 private:
  base::OnceClosure cancel_;
  bool cancelled_ = false;
};

// Act after the enable transaction's UI task commits ON and starts its
// asynchronous verification, before another UI task can finish that recheck.
class DisableDuringCommittedVerification final : public base::TaskObserver {
 public:
  DisableDuringCommittedVerification(base::RepeatingCallback<bool()> committed,
                                      base::OnceClosure disable)
      : committed_(std::move(committed)), disable_(std::move(disable)) {
    base::CurrentThread::Get()->AddTaskObserver(this);
  }
  ~DisableDuringCommittedVerification() override {
    base::CurrentThread::Get()->RemoveTaskObserver(this);
  }
  void WillProcessTask(const base::PendingTask&, bool) override {}
  void DidProcessTask(const base::PendingTask&) override {
    if (disable_ && committed_.Run()) {
      disabled_ = true;
      std::move(disable_).Run();
    }
  }
  bool disabled() const { return disabled_; }

 private:
  base::RepeatingCallback<bool()> committed_;
  base::OnceClosure disable_;
  bool disabled_ = false;
};

class CountingPrivateFactory final
    : public network::mojom::AegisAccessURLLoaderFactory {
 public:
  mojo::PendingRemote<network::mojom::AegisAccessURLLoaderFactory> Bind() {
    mojo::PendingRemote<network::mojom::AegisAccessURLLoaderFactory> remote;
    Clone(remote.InitWithNewPipeAndPassReceiver());
    return remote;
  }
  void Clone(mojo::PendingReceiver<network::mojom::AegisAccessURLLoaderFactory>
                 receiver) override {
    receivers_.Add(this, std::move(receiver));
  }
  void CreateLoaderAndStartWithRoute(
      mojo::PendingReceiver<network::mojom::URLLoader>,
      mojo::PendingReceiver<network::mojom::AegisAccessURLLoaderControl>,
      int32_t, uint32_t, network::mojom::AegisAccessRoutedRequestPtr request,
      mojo::PendingRemote<network::mojom::URLLoaderClient> client,
      const net::MutableNetworkTrafficAnnotationTag&) override {
    ++starts;
    method = request->request.method;
    mojo::Remote<network::mojom::URLLoaderClient>(std::move(client))
        ->OnComplete(network::URLLoaderCompletionStatus(net::OK));
  }
  int starts = 0;
  std::string method;

 private:
  mojo::ReceiverSet<network::mojom::AegisAccessURLLoaderFactory> receivers_;
};

// Real public/private Mojo pipes through the production Browser wrapper. The
// controlled target counts attempted dispatch, without sending business bytes.
struct HeldBrowserRequest {
  HeldBrowserRequest(Profile* profile, content::FrameTreeNodeId frame,
      const OwnershipKey& owner,
      std::shared_ptr<AccessPrivateContextClient> context) {
    wrapper = std::make_unique<AccessProxyingURLLoaderFactory>(
        profile, frame, std::nullopt, std::nullopt, nullptr, owner, std::nullopt,
        factory.BindNewPipeAndPassReceiver(),
        mojo::PendingRemote<network::mojom::URLLoaderFactory>(), std::nullopt,
        base::BindOnce([](HeldBrowserRequest* self,
                          AccessProxyingURLLoaderFactory*) {
          self->wrapper.reset();
        }, base::Unretained(this)), target.Bind(), std::move(context));
  }
  void StartPost() {
    network::ResourceRequest request;
    request.url = GURL("https://resource.example/late-post?q=original");
    request.method = "POST";
    mojo::PendingRemote<network::mojom::URLLoaderClient> client_remote;
    client_receiver.Bind(client_remote.InitWithNewPipeAndPassReceiver());
    factory->CreateLoaderAndStart(loader.BindNewPipeAndPassReceiver(), 1, 0,
        request, std::move(client_remote),
        net::MutableNetworkTrafficAnnotationTag(TRAFFIC_ANNOTATION_FOR_TESTS));
  }
  CountingPrivateFactory target;
  mojo::Remote<network::mojom::URLLoaderFactory> factory;
  network::TestURLLoaderClient client;
  mojo::Receiver<network::mojom::URLLoaderClient> client_receiver{&client};
  mojo::Remote<network::mojom::URLLoader> loader;
  std::unique_ptr<AccessProxyingURLLoaderFactory> wrapper;
};

// Factory admission can close while an already-created request is waiting at
// a redirect. Its loader/client/private-control pipes remain independently live.
class RedirectingPrivateFactory final
    : public network::mojom::AegisAccessURLLoaderFactory,
      public network::mojom::URLLoader,
      public network::mojom::AegisAccessURLLoaderControl {
 public:
  mojo::PendingRemote<network::mojom::AegisAccessURLLoaderFactory> Bind() {
    mojo::PendingRemote<network::mojom::AegisAccessURLLoaderFactory> remote;
    Clone(remote.InitWithNewPipeAndPassReceiver());
    return remote;
  }
  void Clone(mojo::PendingReceiver<network::mojom::AegisAccessURLLoaderFactory>
                 receiver) override {
    factories_.Add(this, std::move(receiver));
  }
  void CreateLoaderAndStartWithRoute(
      mojo::PendingReceiver<network::mojom::URLLoader> loader,
      mojo::PendingReceiver<network::mojom::AegisAccessURLLoaderControl> control,
      int32_t, uint32_t, network::mojom::AegisAccessRoutedRequestPtr request,
      mojo::PendingRemote<network::mojom::URLLoaderClient> client,
      const net::MutableNetworkTrafficAnnotationTag&) override {
    initial = std::move(request->envelope);
    loader_.Bind(std::move(loader));
    control_.Bind(std::move(control));
    client_.Bind(std::move(client));
    net::RedirectInfo redirect;
    redirect.status_code = 302;
    redirect.new_method = "GET";
    redirect.new_url = GURL("https://cdn.example/redirect-final");
    client_->OnReceiveRedirect(redirect, network::mojom::URLResponseHead::New());
  }
  void ResetAdmission() { factories_.Clear(); }
  void FollowRedirect(network::HttpRequestHeadersUpdateParams,
                      const std::optional<GURL>&) override {
    ++public_follows;
  }
  void FollowRedirectWithRoute(
      network::HttpRequestHeadersUpdateParams, const std::optional<GURL>&,
      network::mojom::AegisAccessRequestEnvelopePtr envelope) override {
    followed = std::move(envelope);
    client_->OnComplete(network::URLLoaderCompletionStatus(net::OK));
  }
  void SetPriority(net::RequestPriority, int32_t) override {}

  network::mojom::AegisAccessRequestEnvelopePtr initial;
  network::mojom::AegisAccessRequestEnvelopePtr followed;
  int public_follows = 0;

 private:
  mojo::ReceiverSet<network::mojom::AegisAccessURLLoaderFactory> factories_;
  mojo::Receiver<network::mojom::URLLoader> loader_{this};
  mojo::Receiver<network::mojom::AegisAccessURLLoaderControl> control_{this};
  mojo::Remote<network::mojom::URLLoaderClient> client_;
};

struct HeldRedirectBrowserRequest {
  HeldRedirectBrowserRequest(Profile* profile, content::RenderFrameHost* frame,
      const OwnershipKey& owner,
      aegis_access::BrowserOwnedRequestMetadata metadata,
      std::shared_ptr<AccessPrivateContextClient> context,
      std::optional<int64_t> navigation_id = std::nullopt) {
    std::optional<content::WeakDocumentPtr> document;
    if (!navigation_id) document = frame->GetWeakDocumentPtr();
    wrapper = std::make_unique<AccessProxyingURLLoaderFactory>(
        profile, frame->GetFrameTreeNodeId(), navigation_id, std::nullopt,
        nullptr, owner, std::move(metadata),
        factory.BindNewPipeAndPassReceiver(),
        mojo::PendingRemote<network::mojom::URLLoaderFactory>(),
        std::move(document),
        base::BindOnce([](HeldRedirectBrowserRequest* self,
                          AccessProxyingURLLoaderFactory*) {
          self->wrapper.reset();
        }, base::Unretained(this)), target.Bind(), std::move(context));
  }
  void Start() {
    network::ResourceRequest request;
    request.url = GURL("https://news.example/redirect");
    factory->CreateLoaderAndStart(loader.BindNewPipeAndPassReceiver(), 1, 0,
        request, client.CreateRemote(),
        net::MutableNetworkTrafficAnnotationTag(TRAFFIC_ANNOTATION_FOR_TESTS));
  }
  RedirectingPrivateFactory target;
  mojo::Remote<network::mojom::URLLoaderFactory> factory;
  network::TestURLLoaderClient client;
  mojo::Remote<network::mojom::URLLoader> loader;
  std::unique_ptr<AccessProxyingURLLoaderFactory> wrapper;
};

// Real Mojo ACK with an explicit hold at the product PREPARED boundary. The
// core is not mocked: these tests require the authorized local DEV inputs.
class ProductAckContext final : public network::TestNetworkContext,
                                public network::mojom::AegisAccessContext {
 public:
  void BindAegisAccessContext(
      mojo::PendingReceiver<network::mojom::AegisAccessContext> receiver,
      BindAegisAccessContextCallback callback) override {
    receivers_.Add(this, std::move(receiver));
    std::move(callback).Run(incarnation);
  }
  void InstallSnapshot(network::mojom::AegisAccessSnapshotPtr snapshot,
                       InstallSnapshotCallback callback) override {
    auto ack = network::mojom::AegisAccessSnapshotAck::New();
    ack->accepted = true;
    ack->owner = snapshot->owner.Clone();
    ack->incarnation = snapshot->incarnation;
    ack->sequence = snapshot->sequence;
    ack->common_generations = snapshot->common_generations.Clone();
    for (const auto& endpoint : snapshot->endpoints)
      ack->registrations.push_back(
          network::mojom::AegisAccessRegistrationAck::New(
              endpoint->proxy_group_id, endpoint->registration_id,
              endpoint->selection_generation));
    for (const auto& group : snapshot->unavailable_groups)
      ack->unavailable_groups.push_back(group.Clone());
    if (hold_next) {
      hold_next = false;
      held_ack_ = std::move(ack);
      held_reply_ = std::move(callback);
    } else {
      std::move(callback).Run(std::move(ack));
    }
  }
  bool has_reply() const { return !!held_reply_; }
  void Reply(bool accepted) {
    CHECK(held_reply_);
    held_ack_->accepted = accepted;
    std::move(held_reply_).Run(std::move(held_ack_));
  }
  void BeginRestore(network::mojom::AegisAccessOwnerPtr, const std::string&,
                    BeginRestoreCallback callback) override {
    std::move(callback).Run(true);
  }
  void CreateFactory(
      mojo::PendingReceiver<network::mojom::AegisAccessURLLoaderFactory>,
      network::mojom::URLLoaderFactoryParamsPtr,
      network::mojom::AegisAccessFactoryBindingPtr,
      CreateFactoryCallback callback) override {
    std::move(callback).Run(true);
  }
  bool hold_next = false;
  std::string incarnation = "product-test-context";
  void Disconnect() { receivers_.Clear(); }

 private:
  network::mojom::AegisAccessSnapshotAckPtr held_ack_;
  InstallSnapshotCallback held_reply_;
  mojo::ReceiverSet<network::mojom::AegisAccessContext> receivers_;
};

class AccessSiteProxyProductTest : public testing::Test {
 protected:
  void SetUp() override {
#if !BUILDFLAG(AEGIS_PRIVATE_TEST_NODE_ENABLED)
    const auto* command = base::CommandLine::ForCurrentProcess();
    if (command->GetSwitchValuePath("aegis-access-dev-core-manifest").empty() ||
        command->GetSwitchValuePath("aegis-access-dev-node-config").empty()) {
      GTEST_SKIP() << "Real product core tests require authorized DEV inputs.";
    }
#endif
    ASSERT_TRUE(directory_.CreateUniqueTempDir());
    profile_ = TestingProfile::Builder()
        .SetPath(directory_.GetPath())
        .AddTestingFactory(ProfileNetworkContextServiceFactory::GetInstance(),
            base::BindRepeating([](content::BrowserContext* context)
                -> std::unique_ptr<KeyedService> {
              return std::make_unique<ProfileNetworkContextService>(
                  Profile::FromBrowserContext(context));
            }))
        .Build();
    ASSERT_TRUE(ProfileNetworkContextServiceFactory::GetForContext(profile_.get()));
    // TestingProfile disables this service by default. Publish an actual
    // native DIRECT preference change so its monitor owns the C generation.
    profile_->GetPrefs()->SetDict(proxy_config::prefs::kProxy,
                                  ProxyConfigDictionary::CreateDirect());
    environment_.RunUntilIdle();
    network::mojom::NetworkContextParams params;
    ASSERT_TRUE(AccessNetworkContextTransport::ConfigureNetworkContext(
        profile_.get(), {}, &params));
    transport_ = AccessNetworkContextTransport::Get(profile_.get());
    owner_ = *transport_->OwnerForPartition(AccessChannelForCurrentBuild(), {});
    coordinator_ = AccessServiceCoordinator::GetOrCreate(profile_.get());
    base::test::TestFuture<bool> restored;
    coordinator_->InitializeForProfile(owner_, restored.GetCallback());
    ASSERT_TRUE(restored.Get());
    base::test::TestFuture<AccessNetworkContextTransport::PrivateContext> bound;
    transport_->BindPrivateContext(owner_, &context_, bound.GetCallback());
    ASSERT_TRUE(bound.Get());
    auto* runtime = AccessPublishedRequestRuntime::Get(profile_.get());
    const auto common = runtime->CaptureCommonGenerationTupleOnUiThread(owner_);
    ASSERT_TRUE(common);
    base::test::TestFuture<bool> published;
    transport_->PublishPrivatePolicy(*runtime->GetPublishedPolicySnapshot(owner_),
                                    *common, published.GetCallback());
    ASSERT_TRUE(published.Get());
    bubble_ = AccessSiteProxyBubbleController::GetOrCreate(profile_.get());
    ASSERT_TRUE(bubble_);
  }
  AccessSiteProxyBubbleSnapshot Snapshot(const char* host = "news.example") {
    return bubble_->SnapshotForCommittedUrl(GURL(std::string("https://") + host));
  }
  void WaitFor(AccessSiteConnectionState state, const char* host = "news.example") {
    ASSERT_TRUE(base::test::RunUntil([&] { return Snapshot(host).connection == state; }));
  }
  void Enable() {
    context_.hold_next = true;
    ASSERT_TRUE(bubble_->RequestHostProxySession({"news.example"}, true));
    ASSERT_TRUE(base::test::RunUntil([&] { return context_.has_reply(); }));
    EXPECT_EQ(Snapshot().connection, AccessSiteConnectionState::kConnecting);
    context_.Reply(true);
    WaitFor(AccessSiteConnectionState::kReady);
  }

  content::BrowserTaskEnvironment environment_;
  base::test::ScopedRunLoopTimeout timeout_{FROM_HERE, base::Seconds(90)};
  base::ScopedTempDir directory_;
  ProductAckContext context_;
  std::unique_ptr<TestingProfile> profile_;
  raw_ptr<AccessNetworkContextTransport> transport_ = nullptr;
  raw_ptr<AccessServiceCoordinator> coordinator_ = nullptr;
  raw_ptr<AccessSiteProxyBubbleController> bubble_ = nullptr;
  OwnershipKey owner_;
};

TEST_F(AccessSiteProxyProductTest, RecoveryTimesOutWhileCandidateAckIsStillHeld) {
  context_.hold_next = true;
  ASSERT_TRUE(bubble_->RequestHostProxySession({"news.example"}, true));
  ASSERT_TRUE(base::test::RunUntil([&] { return context_.has_reply(); }));

  auto& timer = AccessServiceCoordinatorTestPeer::PublicationTimer(coordinator_);
  ASSERT_TRUE(timer.IsRunning());
  timer.FireNow();
  // The store restores its committed state on a worker. Hold the original
  // NetworkContext reply through both publication deadlines.
  ASSERT_TRUE(base::test::RunUntil([&] { return timer.IsRunning(); }));
  EXPECT_FALSE(coordinator_->CanDispatch(owner_));
  timer.FireNow();
  WaitFor(AccessSiteConnectionState::kUnavailable);
  EXPECT_TRUE(coordinator_->CanDispatch(owner_));
  EXPECT_EQ(Snapshot().intent, AccessSiteIntent::kOff);

  context_.Reply(true);
  environment_.RunUntilIdle();
  EXPECT_EQ(Snapshot().intent, AccessSiteIntent::kOff);
  Enable();
}

TEST_F(AccessSiteProxyProductTest, CandidateReadFailureRecoversPreparedWithoutRestart) {
  AccessServiceCoordinatorTestPeer::SetFailure(coordinator_,
      AccessRuleStore::FailurePointForTesting::kBuildPreparedCandidateBeforeRead);
  ASSERT_TRUE(bubble_->RequestHostProxySession({"news.example"}, true));
  WaitFor(AccessSiteConnectionState::kUnavailable);
  EXPECT_EQ(Snapshot().intent, AccessSiteIntent::kOff);
  AccessServiceCoordinatorTestPeer::SetFailure(coordinator_,
      AccessRuleStore::FailurePointForTesting::kNone);
  // The next operation must prepare and commit in the same Profile/process.
  // An orphaned durable PREPARED would instead report pending_mutation_exists.
  Enable();
  EXPECT_EQ(Snapshot().intent, AccessSiteIntent::kAllow);
}

TEST_F(AccessSiteProxyProductTest, OnOffOnUsesRealCoreAndCommittedRevision) {
  uint64_t previous = 0;
  for (bool enabled : {true, false, true}) {
    context_.hold_next = true;
    ASSERT_TRUE(bubble_->RequestHostProxySession({"news.example"}, enabled));
    ASSERT_TRUE(base::test::RunUntil([&] { return context_.has_reply(); }));
    EXPECT_EQ(Snapshot().connection, AccessSiteConnectionState::kConnecting);
    context_.Reply(true);
    WaitFor(enabled ? AccessSiteConnectionState::kReady : AccessSiteConnectionState::kIdle);
    EXPECT_TRUE(Snapshot().failure_reason.empty());
    const auto stored = coordinator_->ReadCommittedSnapshot(owner_.storage_partition_token);
    ASSERT_TRUE(stored.value);
    EXPECT_GT(stored.value->policy_generation, previous);
    previous = stored.value->policy_generation;
    EXPECT_EQ(Snapshot().intent, enabled ? AccessSiteIntent::kAllow : AccessSiteIntent::kOff);
  }
}

TEST_F(AccessSiteProxyProductTest,
       DevPreviewDoesNotRewriteCommittedWebsiteIntentOrConnection) {
  ASSERT_TRUE(bubble_->IsDevAllowBlockPanelRegistered());
  Enable();
  const auto stored = coordinator_->ReadCommittedSnapshot(owner_.storage_partition_token);
  ASSERT_TRUE(stored.value);
  const auto endpoint = transport_->CaptureSelectedProxyEndpoint(
      owner_, AccessSiteProxyBubbleController::LocalProxyGroup(owner_), "news.example");
  ASSERT_TRUE(endpoint);
  for (const auto action : {AccessDevAllowBlockAction::kOff,
                            AccessDevAllowBlockAction::kBlock}) {
    ASSERT_EQ(bubble_->ApplyDevAllowBlock("news.example", action).status,
              AccessDevAllowBlockApplyStatus::kApplied);
    EXPECT_EQ(bubble_->DevAllowBlockSnapshotForCommittedUrl(
                  GURL("https://news.example")).intent,
              action == AccessDevAllowBlockAction::kOff
                  ? AccessSiteIntent::kOff : AccessSiteIntent::kBlock);
    EXPECT_EQ(Snapshot().intent, AccessSiteIntent::kAllow);
    EXPECT_TRUE(Snapshot().toggle_on);
    EXPECT_EQ(Snapshot().connection, AccessSiteConnectionState::kReady);
    const auto current = coordinator_->ReadCommittedSnapshot(owner_.storage_partition_token);
    ASSERT_TRUE(current.value);
    EXPECT_EQ(current.value->policy_generation, stored.value->policy_generation);
    const auto selected = transport_->CaptureSelectedProxyEndpoint(
        owner_, endpoint->proxy_group_id, "news.example");
    ASSERT_TRUE(selected);
    EXPECT_EQ(selected->registration_id, endpoint->registration_id);
  }
}

TEST_F(AccessSiteProxyProductTest, FailedAckPreservesOffAndExplicitRecoveryRepublishes) {
  context_.hold_next = true;
  ASSERT_TRUE(bubble_->RequestHostProxySession({"news.example"}, true));
  ASSERT_TRUE(base::test::RunUntil([&] { return context_.has_reply(); }));
  context_.Reply(false);
  WaitFor(AccessSiteConnectionState::kUnavailable);
  EXPECT_EQ(Snapshot().intent, AccessSiteIntent::kOff);
  ASSERT_TRUE(coordinator_->has_retained_store());
  Enable();
  ASSERT_TRUE(bubble_->NotifyHostProxyRuntimeFault({"news.example"}, false));
  EXPECT_EQ(Snapshot().intent, AccessSiteIntent::kAllow);
  Enable();
}

TEST_F(AccessSiteProxyProductTest, RetainedProductStoreSurvivesPrepareFailure) {
  auto plan = BuildSiteProxySessionMutationPlan(
      {"news.example"}, AccessSiteIntent::kAllow, owner_,
      "dev-authorized-local-node", "invalid-stale-revision", 99);
  ASSERT_TRUE(plan.mutation.request);
  base::test::TestFuture<AccessMutationTransactionResult> failed;
  coordinator_->CommitSiteGroupMutation(nullptr, std::move(*plan.mutation.request),
                                       plan.selector, failed.GetCallback());
  EXPECT_EQ(failed.Get().status, AccessMutationTransactionStatus::kPrepareFailed);
  ASSERT_TRUE(coordinator_->has_retained_store());
  Enable();
}

TEST_F(AccessSiteProxyProductTest, CanDisableAfterEndpointBecomesUnavailable) {
  Enable();
  ASSERT_TRUE(transport_->ClearProxySelection({}));
  context_.hold_next = true;
  ASSERT_TRUE(bubble_->RequestHostProxySession({"news.example"}, false));
  ASSERT_TRUE(base::test::RunUntil([&] { return context_.has_reply(); }));
  context_.Reply(true);
  WaitFor(AccessSiteConnectionState::kIdle);
  EXPECT_EQ(Snapshot().intent, AccessSiteIntent::kOff);
  const auto stored = coordinator_->ReadCommittedSnapshot(owner_.storage_partition_token);
  ASSERT_TRUE(stored.value);
  ASSERT_EQ(stored.value->site_groups.size(), 1u);
  EXPECT_EQ(stored.value->site_groups[0].members[0].policy.mode, AccessMode::kDirect);
}

TEST_F(AccessSiteProxyProductTest, HostFailuresRemainIndependent) {
  context_.hold_next = true;
  ASSERT_TRUE(bubble_->RequestHostProxySession({"news.example"}, true));
  ASSERT_TRUE(base::test::RunUntil([&] { return context_.has_reply(); }));
  context_.Reply(false);
  WaitFor(AccessSiteConnectionState::kUnavailable);
  const auto failed = Snapshot();
  ASSERT_FALSE(failed.failure_reason.empty());
  context_.hold_next = true;
  ASSERT_TRUE(bubble_->RequestHostProxySession({"other.example"}, false));
  ASSERT_TRUE(base::test::RunUntil([&] { return context_.has_reply(); }));
  context_.Reply(true);
  WaitFor(AccessSiteConnectionState::kIdle, "other.example");
  EXPECT_EQ(Snapshot().connection, failed.connection);
  EXPECT_EQ(Snapshot().failure_reason, failed.failure_reason);
  EXPECT_EQ(Snapshot().intent, AccessSiteIntent::kOff);
}

TEST_F(AccessSiteProxyProductTest, SubdomainEnablePersistsCanonicalSites) {
  context_.hold_next = true;
  ASSERT_TRUE(bubble_->RequestHostProxySession({"www.example.com"}, true));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return context_.has_reply() ||
           Snapshot("www.example.com").connection ==
               AccessSiteConnectionState::kUnavailable;
  }));
  ASSERT_TRUE(context_.has_reply())
      << Snapshot("www.example.com").failure_reason;
  context_.Reply(true);
  WaitFor(AccessSiteConnectionState::kReady, "www.example.com");
  const auto stored =
      coordinator_->ReadCommittedSnapshot(owner_.storage_partition_token);
  ASSERT_TRUE(stored.value);
  ASSERT_EQ(stored.value->site_groups.size(), 1u);
  const auto& group = stored.value->site_groups[0];
  EXPECT_EQ(group.group.canonical_host, "example.com");
  EXPECT_TRUE(group.group.website_context);
  EXPECT_EQ(group.group.http_top_level_site, "http://example.com");
  EXPECT_EQ(group.group.https_top_level_site, "https://example.com");
  ASSERT_EQ(group.members.size(), 2u);
  for (const auto& member : group.members) {
    EXPECT_EQ(member.policy.destination_host, "example.com");
    EXPECT_EQ(member.policy.scope, PolicyScope::kWebsite);
    EXPECT_FALSE(member.policy.include_subdomains);
  }
}

TEST_F(AccessSiteProxyProductTest, RestoredCoreWaitsForAckWithoutChangingSavedIntent) {
  Enable();
  const auto before = coordinator_->ReadCommittedSnapshot(owner_.storage_partition_token);
  ASSERT_TRUE(before.value);
  const auto previous = transport_->CurrentEndpoint(owner_);
  ASSERT_TRUE(previous);
  AccessSiteProxyProductTestPeer::LoseRuntime(bubble_, previous->registration_id);
  environment_.RunUntilIdle();
  EXPECT_EQ(Snapshot().intent, AccessSiteIntent::kAllow);
  EXPECT_EQ(Snapshot().connection, AccessSiteConnectionState::kUnavailable);
  EXPECT_FALSE(transport_->CurrentEndpoint(owner_));

  context_.hold_next = true;
  base::test::TestFuture<bool> first, second;
  bubble_->EnsureLocalCoreForRequest(owner_, previous->proxy_group_id, first.GetCallback());
  bubble_->EnsureLocalCoreForRequest(owner_, previous->proxy_group_id, second.GetCallback());
  ASSERT_TRUE(base::test::RunUntil([&] { return context_.has_reply(); }));
  EXPECT_FALSE(first.IsReady());
  EXPECT_FALSE(second.IsReady());
  EXPECT_EQ(Snapshot().connection, AccessSiteConnectionState::kConnecting);
  const auto prepared = transport_->CurrentEndpoint(owner_);
  ASSERT_TRUE(prepared);
  EXPECT_NE(prepared->registration_id, previous->registration_id);
  EXPECT_GT(prepared->generations.selection_generation,
            previous->generations.selection_generation);
  context_.Reply(true);
  ASSERT_TRUE(first.Get());
  ASSERT_TRUE(second.Get());
  EXPECT_EQ(Snapshot().connection, AccessSiteConnectionState::kReady);
  EXPECT_EQ(Snapshot().intent, AccessSiteIntent::kAllow);
  const auto after = coordinator_->ReadCommittedSnapshot(owner_.storage_partition_token);
  ASSERT_TRUE(after.value);
  EXPECT_EQ(after.value->policy_generation, before.value->policy_generation);
  EXPECT_EQ(after.value->site_groups, before.value->site_groups);
}

TEST_F(AccessSiteProxyProductTest, FailedRestoreAckRetainsAllowAndCanRecover) {
  Enable();
  const auto endpoint = transport_->CurrentEndpoint(owner_);
  ASSERT_TRUE(endpoint);
  const auto before = coordinator_->ReadCommittedSnapshot(owner_.storage_partition_token);
  AccessSiteProxyProductTestPeer::LoseRuntime(bubble_, endpoint->registration_id);
  environment_.RunUntilIdle();
  context_.hold_next = true;
  base::test::TestFuture<bool> rejected;
  bubble_->EnsureLocalCoreForRequest(owner_, endpoint->proxy_group_id, rejected.GetCallback());
  ASSERT_TRUE(base::test::RunUntil([&] { return context_.has_reply(); }));
  context_.Reply(false);
  EXPECT_FALSE(rejected.Get());
  EXPECT_EQ(Snapshot().intent, AccessSiteIntent::kAllow);
  EXPECT_EQ(Snapshot().connection, AccessSiteConnectionState::kUnavailable);
  base::test::TestFuture<bool> recovered;
  bubble_->EnsureLocalCoreForRequest(owner_, endpoint->proxy_group_id, recovered.GetCallback());
  EXPECT_TRUE(recovered.Get());
  const auto after = coordinator_->ReadCommittedSnapshot(owner_.storage_partition_token);
  ASSERT_TRUE(before.value);
  ASSERT_TRUE(after.value);
  EXPECT_EQ(before.value->site_groups, after.value->site_groups);
  EXPECT_EQ(before.value->policy_generation, after.value->policy_generation);
}

TEST_F(AccessSiteProxyProductTest, RequestReadinessRejectsForeignOwnerOrGroup) {
  EXPECT_FALSE(AccessSiteProxyProductTestPeer::HasCore(bubble_));
  auto foreign = owner_;
  foreign.profile_token += "-foreign";
  for (const auto& owner : {foreign, owner_}) {
    base::test::TestFuture<bool> denied;
    bubble_->EnsureLocalCoreForRequest(owner,
        owner == foreign ? AccessSiteProxyBubbleController::LocalProxyGroup(owner_)
                         : "unowned-group", denied.GetCallback());
    EXPECT_FALSE(denied.Get());
  }
  EXPECT_FALSE(AccessSiteProxyProductTestPeer::HasCore(bubble_));
}

TEST_F(AccessSiteProxyProductTest, CanDisableOneWebsiteWhileOtherSavedProxyHasNoCore) {
  Enable();
  ASSERT_TRUE(bubble_->RequestHostProxySession({"second.example"}, true));
  WaitFor(AccessSiteConnectionState::kReady, "second.example");
  const auto endpoint = transport_->CurrentEndpoint(owner_);
  ASSERT_TRUE(endpoint);
  AccessSiteProxyProductTestPeer::LoseRuntime(bubble_, endpoint->registration_id);
  environment_.RunUntilIdle();
  ASSERT_FALSE(transport_->CurrentEndpoint(owner_));
  ASSERT_TRUE(bubble_->RequestHostProxySession({"news.example"}, false));
  WaitFor(AccessSiteConnectionState::kIdle);
  EXPECT_EQ(Snapshot().intent, AccessSiteIntent::kOff);
  EXPECT_EQ(Snapshot("second.example").intent, AccessSiteIntent::kAllow);
  EXPECT_EQ(Snapshot("second.example").connection, AccessSiteConnectionState::kUnavailable);
  const auto stored = coordinator_->ReadCommittedSnapshot(owner_.storage_partition_token);
  ASSERT_TRUE(stored.value);
  ASSERT_EQ(stored.value->site_groups.size(), 2u);
  EXPECT_FALSE(transport_->CurrentEndpoint(owner_));
}

TEST_F(AccessSiteProxyProductTest, ReadyUiRequiresCurrentContextAckAfterDisconnect) {
  Enable();
  context_.Disconnect();
  environment_.RunUntilIdle();
  EXPECT_EQ(Snapshot().intent, AccessSiteIntent::kAllow);
  EXPECT_EQ(Snapshot().connection, AccessSiteConnectionState::kUnavailable);
  EXPECT_FALSE(Snapshot().failure_reason.empty());
  ProductAckContext replacement;
  replacement.incarnation = "replacement-context";
  base::test::TestFuture<AccessNetworkContextTransport::PrivateContext> bound;
  transport_->BindPrivateContext(owner_, &replacement, bound.GetCallback());
  ASSERT_TRUE(bound.Get());
  auto* runtime = AccessPublishedRequestRuntime::Get(profile_.get());
  const auto common = runtime->CaptureCommonGenerationTupleOnUiThread(owner_);
  ASSERT_TRUE(common);
  replacement.hold_next = true;
  base::test::TestFuture<bool> ack;
  transport_->PublishPrivatePolicy(*runtime->GetPublishedPolicySnapshot(owner_),
                                   *common, ack.GetCallback());
  ASSERT_TRUE(base::test::RunUntil([&] { return replacement.has_reply(); }));
  EXPECT_FALSE(ack.IsReady());
  EXPECT_EQ(Snapshot().connection, AccessSiteConnectionState::kUnavailable);
  replacement.Reply(true);
  ASSERT_TRUE(ack.Get());
  EXPECT_EQ(Snapshot().connection, AccessSiteConnectionState::kReady);
}

// Unlike the helper-only tests, this fixture uses the production retry handler,
// a real pinned core, the Profile transaction and the private Mojo ACK path.
class AccessRetryNavigationProductTest : public ChromeRenderViewHostTestHarness {
 protected:
  std::unique_ptr<TestingProfile> CreateTestingProfile() override {
    return TestingProfile::Builder().SetPath(directory_.GetPath()).Build();
  }
  void SetUp() override {
    ASSERT_TRUE(directory_.CreateUniqueTempDir());
    ChromeRenderViewHostTestHarness::SetUp();
    // Let the RVH harness create its default test NetworkContext first.
    // TestingBrowserProcess intentionally has no SystemNetworkContextManager;
    // the Access policy ACK in this fixture belongs to context_ below.
    ProfileNetworkContextServiceFactory::GetInstance()->SetTestingFactoryAndUse(
        profile(), base::BindRepeating([](content::BrowserContext* context)
            -> std::unique_ptr<KeyedService> {
          return std::make_unique<ProfileNetworkContextService>(
              Profile::FromBrowserContext(context));
        }));
#if !BUILDFLAG(AEGIS_PRIVATE_TEST_NODE_ENABLED)
    const auto* command = base::CommandLine::ForCurrentProcess();
    if (command->GetSwitchValuePath("aegis-access-dev-core-manifest").empty() ||
        command->GetSwitchValuePath("aegis-access-dev-node-config").empty())
      GTEST_SKIP() << "Real product retry requires authorized private inputs.";
#endif
    ASSERT_TRUE(ProfileNetworkContextServiceFactory::GetForContext(profile()));
    profile()->GetPrefs()->SetDict(proxy_config::prefs::kProxy,
                                  ProxyConfigDictionary::CreateDirect());
    task_environment()->RunUntilIdle();
    network::mojom::NetworkContextParams params;
    ASSERT_TRUE(AccessNetworkContextTransport::ConfigureNetworkContext(profile(), {}, &params));
    transport_ = AccessNetworkContextTransport::Get(profile());
    owner_ = *transport_->OwnerForPartition(AccessChannelForCurrentBuild(), {});
    coordinator_ = AccessServiceCoordinator::GetOrCreate(profile());
    base::test::TestFuture<bool> restored;
    coordinator_->InitializeForProfile(owner_, restored.GetCallback());
    ASSERT_TRUE(restored.Get());
    base::test::TestFuture<AccessNetworkContextTransport::PrivateContext> bound;
    transport_->BindPrivateContext(owner_, &context_, bound.GetCallback());
    ASSERT_TRUE(bound.Get());
    auto* runtime = AccessPublishedRequestRuntime::Get(profile());
    const auto common = runtime->CaptureCommonGenerationTupleOnUiThread(owner_);
    ASSERT_TRUE(common);
    base::test::TestFuture<bool> published;
    transport_->PublishPrivatePolicy(*runtime->GetPublishedPolicySnapshot(owner_),
                                    *common, published.GetCallback());
    ASSERT_TRUE(published.Get());
    bubble_ = AccessSiteProxyBubbleController::GetOrCreate(profile());
    AccessNavigationRetryTabHelper::CreateForWebContents(web_contents());
    helper()->SetProxyRetryHandler(bubble_->GetFailedNavigationRetryHandler());
  }
  void TearDown() override {
    transport_ = nullptr;
    coordinator_ = nullptr;
    bubble_ = nullptr;
    context_.Disconnect();
    ChromeRenderViewHostTestHarness::TearDown();
  }
  AccessNavigationRetryTabHelper* helper() {
    return AccessNavigationRetryTabHelper::FromWebContents(web_contents());
  }
  void BeginHeldRetry() {
    content::NavigationSimulator::NavigateAndFailFromBrowser(
        web_contents(), failed_, net::ERR_CONNECTION_RESET);
    // The first simulated navigation creates its default NetworkContext and
    // replaces the fixture's setup-time binding. Bind and ACK that current
    // context before testing transaction completion rather than scope failure.
    task_environment()->RunUntilIdle();
    base::test::TestFuture<AccessNetworkContextTransport::PrivateContext> bound;
    transport_->BindPrivateContext(owner_, &context_, bound.GetCallback());
    ASSERT_TRUE(bound.Get());
    auto* runtime = AccessPublishedRequestRuntime::Get(profile());
    const auto common = runtime->CaptureCommonGenerationTupleOnUiThread(owner_);
    ASSERT_TRUE(common);
    base::test::TestFuture<bool> published;
    transport_->PublishPrivatePolicy(*runtime->GetPublishedPolicySnapshot(owner_),
                                    *common, published.GetCallback());
    ASSERT_TRUE(published.Get());
    context_.hold_next = true;
    ASSERT_TRUE(helper()->RequestProxyRetry(completed_.GetCallback()));
    ASSERT_TRUE(base::test::RunUntil([&] {
      return context_.has_reply() || completed_.IsReady();
    }));
    ASSERT_TRUE(context_.has_reply())
        << bubble_->SnapshotForCommittedUrl(failed_).failure_reason;
    EXPECT_FALSE(controller().GetPendingEntry());
    EXPECT_FALSE(completed_.IsReady());
    EXPECT_EQ(bubble_->SnapshotForCommittedUrl(failed_).connection,
              AccessSiteConnectionState::kConnecting);
  }
  void DrainHeldRetry() {
    context_.Reply(true);
    // Cancellation tests must await the late transaction and core verification,
    // including an unavailable outcome if navigation changed their binding.
    ASSERT_TRUE(base::test::RunUntil([&] {
      return !AccessSiteProxyProductTestPeer::IsPreparing(bubble_);
    }));
    EXPECT_NE(bubble_->SnapshotForCommittedUrl(failed_).connection,
              AccessSiteConnectionState::kConnecting);
  }
  std::unique_ptr<HeldBrowserRequest> StartPostWaitingForAck() {
    base::test::TestFuture<AccessNetworkContextTransport::PrivateContext> bound;
    transport_->BindPrivateContext(owner_, &context_, bound.GetCallback());
    auto client = bound.Take();
    EXPECT_TRUE(client);
    auto request = std::make_unique<HeldBrowserRequest>(
        profile(), main_rfh()->GetFrameTreeNodeId(), owner_, std::move(client));
    AccessNetworkContextTransportTestPeer::AdvanceNetwork(transport_);
    context_.hold_next = true;
    request->StartPost();
    EXPECT_TRUE(base::test::RunUntil([&] { return context_.has_reply(); }));
    EXPECT_EQ(request->target.starts, 0);
    return request;
  }
  std::unique_ptr<HeldRedirectBrowserRequest> StartHeldRedirect(bool proxy) {
    content::NavigationSimulator::NavigateAndCommitFromBrowser(
        web_contents(), GURL("https://news.example"));
    if (proxy) {
      EXPECT_TRUE(bubble_->RequestHostProxySession({"news.example"}, true));
      EXPECT_TRUE(base::test::RunUntil([&] {
        return bubble_->SnapshotForCommittedUrl(GURL("https://news.example"))
                   .connection == AccessSiteConnectionState::kReady;
      }));
    }
    auto metadata = BuildBrowserOwnedRequestMetadata(profile(),
        base::BindRepeating([](content::WebContents* contents) { return contents; },
                            base::Unretained(web_contents())),
        main_rfh()->GetFrameTreeNodeId(), std::nullopt);
    CHECK(metadata.metadata);
    base::test::TestFuture<AccessNetworkContextTransport::PrivateContext> bound;
    transport_->BindPrivateContext(owner_, &context_, bound.GetCallback());
    auto request = std::make_unique<HeldRedirectBrowserRequest>(
        profile(), main_rfh(), owner_, std::move(*metadata.metadata), bound.Take());
    request->Start();
    EXPECT_TRUE(base::test::RunUntil([&] {
      return request->client.has_received_redirect() ||
             request->client.has_received_completion();
    }));
    return request;
  }
  void SaveRedirectWebsiteAndStopCore() {
    const GURL target("https://cdn.example/redirect-final");
    ASSERT_TRUE(bubble_->RequestHostProxySession({"cdn.example"}, true));
    ASSERT_TRUE(base::test::RunUntil([&] {
      return bubble_->SnapshotForCommittedUrl(target).connection ==
             AccessSiteConnectionState::kReady;
    }));
    const auto endpoint = transport_->CurrentEndpoint(owner_);
    ASSERT_TRUE(endpoint);
    AccessSiteProxyProductTestPeer::LoseRuntime(bubble_, endpoint->registration_id);
    task_environment()->RunUntilIdle();
    ASSERT_FALSE(AccessSiteProxyProductTestPeer::HasCore(bubble_));
    ASSERT_FALSE(transport_->CurrentEndpoint(owner_));
    ASSERT_EQ(bubble_->SnapshotForCommittedUrl(target).intent,
              AccessSiteIntent::kAllow);
  }
  std::unique_ptr<HeldRedirectBrowserRequest> StartPendingNavigationRedirect(
      content::NavigationSimulator* navigation) {
    navigation->Start();
    const int64_t navigation_id =
        navigation->GetNavigationHandle()->GetNavigationId();
    auto metadata = BuildBrowserOwnedRequestMetadata(profile(),
        base::BindRepeating([](content::WebContents* contents) { return contents; },
                            base::Unretained(web_contents())),
        main_rfh()->GetFrameTreeNodeId(), navigation_id);
    CHECK(metadata.metadata);
    base::test::TestFuture<AccessNetworkContextTransport::PrivateContext> bound;
    transport_->BindPrivateContext(owner_, &context_, bound.GetCallback());
    auto request = std::make_unique<HeldRedirectBrowserRequest>(
        profile(), main_rfh(), owner_, std::move(*metadata.metadata), bound.Take(),
        navigation_id);
    request->Start();
    EXPECT_TRUE(base::test::RunUntil([&] {
      return request->client.has_received_redirect() ||
             request->client.has_received_completion();
    }));
    if (request->client.has_received_redirect())
      navigation->Redirect(GURL("https://cdn.example/redirect-final"));
    return request;
  }
  base::ScopedTempDir directory_;
  ProductAckContext context_;
  raw_ptr<AccessNetworkContextTransport> transport_ = nullptr;
  raw_ptr<AccessServiceCoordinator> coordinator_ = nullptr;
  raw_ptr<AccessSiteProxyBubbleController> bubble_ = nullptr;
  OwnershipKey owner_;
  const GURL failed_{"https://failed.example/path?q=original#fragment"};
  base::test::TestFuture<bool> completed_;
};

TEST_F(AccessRetryNavigationProductTest,
       OffDuringCommittedVerificationRevokesRetryAndPersistsOff) {
  BeginHeldRetry();
  bool accepted = false;
  DisableDuringCommittedVerification disable(base::BindLambdaForTesting([&] {
    return bubble_->SnapshotForCommittedUrl(failed_).intent ==
               AccessSiteIntent::kAllow &&
           AccessSiteProxyProductTestPeer::IsPreparing(bubble_);
  }), base::BindLambdaForTesting([&] {
    EXPECT_EQ(bubble_->SnapshotForCommittedUrl(failed_).intent,
              AccessSiteIntent::kAllow);
    EXPECT_TRUE(AccessSiteProxyProductTestPeer::IsPreparing(bubble_));
    const auto host = ResolveTrustedNavigationHost(failed_);
    ASSERT_TRUE(host.host);
    accepted = bubble_->RequestHostProxySession(*host.host, false);
  }));
  context_.Reply(true);
  ASSERT_TRUE(completed_.Wait());
  ASSERT_TRUE(disable.disabled())
      << bubble_->SnapshotForCommittedUrl(failed_).failure_reason;
  EXPECT_TRUE(accepted);
  EXPECT_FALSE(completed_.Get());
  ASSERT_TRUE(base::test::RunUntil([&] {
    return !AccessSiteProxyProductTestPeer::IsPreparing(bubble_);
  }));
  // Stop runs on the core sequence after Verify. Its reply reaches UI after
  // that older Verify result, including when Stop must cancel a live probe.
  base::test::TestFuture<void> stopped;
  AccessSiteProxyProductTestPeer::StopCore(bubble_, stopped.GetCallback());
  ASSERT_TRUE(stopped.Wait());
  EXPECT_FALSE(controller().GetPendingEntry());
  EXPECT_EQ(web_contents()->GetLastCommittedURL(), failed_);
  const auto state = bubble_->SnapshotForCommittedUrl(failed_);
  EXPECT_EQ(state.intent, AccessSiteIntent::kOff);
  EXPECT_EQ(state.connection, AccessSiteConnectionState::kIdle);
  EXPECT_TRUE(state.failure_reason.empty());
}

TEST_F(AccessRetryNavigationProductTest, NewNavigationBeforeRealAckIsNotReloaded) {
  BeginHeldRetry();
  const GURL replacement("https://replacement.example/keep");
  content::NavigationSimulator::NavigateAndCommitFromBrowser(web_contents(), replacement);
  const int entries = controller().GetEntryCount();
  DrainHeldRetry();
  EXPECT_FALSE(controller().GetPendingEntry());
  EXPECT_EQ(web_contents()->GetLastCommittedURL(), replacement);
  EXPECT_EQ(controller().GetEntryCount(), entries);
}

TEST_F(AccessRetryNavigationProductTest, ClosedTabBeforeRealAckDoesNotReloadOtherTab) {
  BeginHeldRetry();
  auto other = CreateTestWebContents();
  const GURL replacement("https://other.example/unchanged");
  content::NavigationSimulator::NavigateAndCommitFromBrowser(other.get(), replacement);
  DeleteContents();
  const bool replied_on_close = completed_.IsReady();
  DrainHeldRetry();
  EXPECT_TRUE(replied_on_close);
  ASSERT_TRUE(completed_.IsReady());
  EXPECT_FALSE(completed_.Get());
  EXPECT_FALSE(other->GetController().GetPendingEntry());
  EXPECT_EQ(other->GetLastCommittedURL(), replacement);
}

TEST_F(AccessRetryNavigationProductTest, ImmediateReclickWaitsForItsOwnAck) {
  BeginHeldRetry();
  web_contents()->Stop();
  ASSERT_TRUE(completed_.IsReady());
  EXPECT_FALSE(completed_.Get());
  base::test::TestFuture<bool> fresh;
  ASSERT_TRUE(helper()->RequestProxyRetry(fresh.GetCallback()));
  ASSERT_FALSE(fresh.IsReady());
  context_.hold_next = true;
  context_.Reply(true);
  ASSERT_TRUE(base::test::RunUntil([&] {
    return context_.has_reply() || fresh.IsReady();
  }));
  ASSERT_TRUE(context_.has_reply());
  EXPECT_FALSE(fresh.IsReady());
  EXPECT_FALSE(controller().GetPendingEntry());
  context_.Reply(true);
  ASSERT_TRUE(fresh.Get());
  ASSERT_TRUE(controller().GetPendingEntry());
  EXPECT_EQ(controller().GetPendingEntry()->GetURL(), failed_);
  content::NavigationSimulator::CreateFromPending(controller())->Commit();
  EXPECT_FALSE(controller().GetPendingEntry());
}

TEST_F(AccessRetryNavigationProductTest, SecondStopRevokesQueuedReclick) {
  BeginHeldRetry();
  web_contents()->Stop();
  base::test::TestFuture<bool> fresh;
  ASSERT_TRUE(helper()->RequestProxyRetry(fresh.GetCallback()));
  ASSERT_FALSE(fresh.IsReady());
  web_contents()->Stop();
  ASSERT_TRUE(fresh.IsReady());
  EXPECT_FALSE(fresh.Get());
  DrainHeldRetry();
  EXPECT_FALSE(controller().GetPendingEntry());
  EXPECT_EQ(web_contents()->GetLastCommittedURL(), failed_);
}

TEST_F(AccessRetryNavigationProductTest, StopBeforeRealAckRevokesOriginalRetry) {
  BeginHeldRetry();
  web_contents()->Stop();
  const bool replied_on_stop = completed_.IsReady();
  EXPECT_FALSE(helper()->FailureForRetry());
  DrainHeldRetry();
  EXPECT_TRUE(replied_on_stop);
  ASSERT_TRUE(completed_.IsReady());
  EXPECT_FALSE(completed_.Get());
  EXPECT_FALSE(controller().GetPendingEntry());
  EXPECT_EQ(web_contents()->GetLastCommittedURL(), failed_);

  base::test::TestFuture<bool> fresh_click;
  ASSERT_TRUE(helper()->RequestProxyRetry(fresh_click.GetCallback()));
  ASSERT_TRUE(fresh_click.Get());
  ASSERT_TRUE(controller().GetPendingEntry());
  EXPECT_EQ(controller().GetPendingEntry()->GetURL(), failed_);
  content::NavigationSimulator::CreateFromPending(controller())->Commit();
  EXPECT_FALSE(helper()->FailureForRetry());
  EXPECT_FALSE(controller().GetPendingEntry());
}

TEST_F(AccessRetryNavigationProductTest,
       DurableCommitFailureAfterRealAckCannotReloadAndCanRecover) {
  BeginHeldRetry();
  const auto before = coordinator_->ReadCommittedSnapshot(owner_.storage_partition_token);
  ASSERT_TRUE(before.value);
  AccessServiceCoordinatorTestPeer::SetFailure(coordinator_,
      AccessRuleStore::FailurePointForTesting::kCommitAfterFirstMemberInsert);
  context_.Reply(true);
  ASSERT_TRUE(completed_.Wait());
  EXPECT_FALSE(completed_.Get());
  EXPECT_FALSE(controller().GetPendingEntry());
  EXPECT_EQ(web_contents()->GetLastCommittedURL(), failed_);
  const auto snapshot = bubble_->SnapshotForCommittedUrl(failed_);
  EXPECT_EQ(snapshot.intent, AccessSiteIntent::kOff);
  EXPECT_EQ(snapshot.connection, AccessSiteConnectionState::kUnavailable);
  const auto after = coordinator_->ReadCommittedSnapshot(owner_.storage_partition_token);
  ASSERT_TRUE(after.value);
  EXPECT_EQ(after.value->site_groups, before.value->site_groups);
  EXPECT_EQ(after.value->independent_rules, before.value->independent_rules);

  AccessServiceCoordinatorTestPeer::SetFailure(coordinator_,
      AccessRuleStore::FailurePointForTesting::kNone);
  base::test::TestFuture<bool> recovered;
  ASSERT_TRUE(helper()->RequestProxyRetry(recovered.GetCallback()));
  ASSERT_TRUE(recovered.Get());
  ASSERT_TRUE(controller().GetPendingEntry());
  EXPECT_EQ(controller().GetPendingEntry()->GetURL(), failed_);
  content::NavigationSimulator::CreateFromPending(controller())->Commit();
  EXPECT_EQ(web_contents()->GetLastCommittedURL(), failed_);
  base::test::TestFuture<bool> duplicate;
  EXPECT_FALSE(helper()->RequestProxyRetry(duplicate.GetCallback()));
  EXPECT_FALSE(duplicate.Get());
  EXPECT_FALSE(controller().GetPendingEntry());
}

TEST_F(AccessRetryNavigationProductTest,
       CancelledLoaderBeforePrivateAckNeverSendsPost) {
  auto request = StartPostWaitingForAck();
  request->loader.reset();
  // Release immediately: dispatch must also notice a closed peer before the
  // queued disconnect notification runs.
  context_.Reply(true);
  task_environment()->RunUntilIdle();
  EXPECT_EQ(request->target.starts, 0);
}

TEST_F(AccessRetryNavigationProductTest,
       CancelledClientBeforePrivateAckNeverSendsPost) {
  auto request = StartPostWaitingForAck();
  request->client_receiver.reset();
  context_.Reply(true);
  task_environment()->RunUntilIdle();
  EXPECT_EQ(request->target.starts, 0);
}

TEST_F(AccessRetryNavigationProductTest,
       LivePostWaitsForPrivateAckThenSendsOnce) {
  auto request = StartPostWaitingForAck();
  context_.Reply(true);
  task_environment()->RunUntilIdle();
  EXPECT_EQ(request->target.starts, 1);
  EXPECT_EQ(request->target.method, "POST");
}

TEST_F(AccessRetryNavigationProductTest,
       CancelledPendingRequestReleasesFactoryBeforeAck) {
  auto request = StartPostWaitingForAck();
  request->factory.reset();
  request->loader.reset();
  task_environment()->RunUntilIdle();
  EXPECT_FALSE(request->wrapper);
  context_.Reply(true);
  task_environment()->RunUntilIdle();
  EXPECT_EQ(request->target.starts, 0);
}

TEST_F(AccessRetryNavigationProductTest,
       RedirectToSavedWebsitePreparesMissingCoreAndWaitsForAck) {
  SaveRedirectWebsiteAndStopCore();
  auto navigation = content::NavigationSimulator::CreateBrowserInitiated(
      GURL("https://news.example/redirect"), web_contents());
  auto request = StartPendingNavigationRedirect(navigation.get());
  ASSERT_TRUE(request->client.has_received_redirect());
  ASSERT_TRUE(request->target.initial);
  EXPECT_TRUE(request->target.initial->registration_id.empty());
  EXPECT_FALSE(AccessSiteProxyProductTestPeer::HasCore(bubble_));

  context_.hold_next = true;
  request->loader->FollowRedirect({}, std::nullopt);
  ASSERT_TRUE(base::test::RunUntil([&] {
    return context_.has_reply() || request->client.has_received_completion();
  }));
  ASSERT_TRUE(context_.has_reply())
      << "Redirect completed before preparing its saved proxy: "
      << request->client.completion_status().error_code;
  EXPECT_FALSE(request->client.has_received_completion());
  EXPECT_FALSE(request->target.followed);
  context_.Reply(true);
  ASSERT_TRUE(base::test::RunUntil([&] {
    return request->client.has_received_completion();
  }));
  EXPECT_EQ(request->client.completion_status().error_code, net::OK);
  ASSERT_TRUE(request->target.followed);
  EXPECT_FALSE(request->target.followed->registration_id.empty());
  EXPECT_EQ(request->target.followed->hop, 1u);
  EXPECT_EQ(request->target.followed->request_token,
            request->target.initial->request_token);
  EXPECT_EQ(request->target.public_follows, 0);
  navigation->Commit();
}

TEST_F(AccessRetryNavigationProductTest,
       SavedWebsiteRedirectCancelledDuringCoreAckIsNotFollowed) {
  SaveRedirectWebsiteAndStopCore();
  auto navigation = content::NavigationSimulator::CreateBrowserInitiated(
      GURL("https://news.example/redirect"), web_contents());
  auto request = StartPendingNavigationRedirect(navigation.get());
  ASSERT_TRUE(request->client.has_received_redirect());
  context_.hold_next = true;
  request->loader->FollowRedirect({}, std::nullopt);
  ASSERT_TRUE(base::test::RunUntil([&] {
    return context_.has_reply() || request->client.has_received_completion();
  }));
  ASSERT_TRUE(context_.has_reply());
  request->loader.reset();
  context_.Reply(true);
  ASSERT_TRUE(base::test::RunUntil([&] {
    return bubble_->SnapshotForCommittedUrl(
               GURL("https://cdn.example/redirect-final")).connection ==
           AccessSiteConnectionState::kReady;
  }));
  task_environment()->RunUntilIdle();
  EXPECT_FALSE(request->target.followed);
  EXPECT_EQ(request->target.public_follows, 0);
}

TEST_F(AccessRetryNavigationProductTest,
       SavedWebsiteRedirectRejectsNetworkChangeDuringCoreAck) {
  SaveRedirectWebsiteAndStopCore();
  auto navigation = content::NavigationSimulator::CreateBrowserInitiated(
      GURL("https://news.example/redirect"), web_contents());
  auto request = StartPendingNavigationRedirect(navigation.get());
  ASSERT_TRUE(request->client.has_received_redirect());
  context_.hold_next = true;
  request->loader->FollowRedirect({}, std::nullopt);
  ASSERT_TRUE(base::test::RunUntil([&] {
    return context_.has_reply() || request->client.has_received_completion();
  }));
  ASSERT_TRUE(context_.has_reply());
  AccessNetworkContextTransportTestPeer::AdvanceNetwork(transport_);
  context_.Reply(true);
  ASSERT_TRUE(base::test::RunUntil([&] {
    return request->client.has_received_completion();
  }));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return bubble_->SnapshotForCommittedUrl(
               GURL("https://cdn.example/redirect-final")).connection !=
           AccessSiteConnectionState::kConnecting;
  }));
  EXPECT_NE(request->client.completion_status().error_code, net::OK);
  EXPECT_FALSE(request->target.followed);
  EXPECT_EQ(request->target.public_follows, 0);
}

TEST_F(AccessRetryNavigationProductTest,
       RedirectLoaderCancelledAtQueuedReadyIsNotFollowed) {
  auto request = StartHeldRedirect(true);
  ASSERT_TRUE(request->client.has_received_redirect());
  ASSERT_TRUE(request->target.initial);
  ASSERT_FALSE(request->target.initial->registration_id.empty());
  CancelAtQueuedPolicyCompletion cancel(base::BindOnce(
      [](HeldRedirectBrowserRequest* request) { request->loader.reset(); },
      base::Unretained(request.get())));
  request->loader->FollowRedirect({}, std::nullopt);
  ASSERT_TRUE(base::test::RunUntil([&] { return cancel.cancelled(); }));
  task_environment()->RunUntilIdle();
  EXPECT_FALSE(request->target.followed);
  EXPECT_EQ(request->target.public_follows, 0);
}

TEST_F(AccessRetryNavigationProductTest,
       RedirectClientCancelledAtQueuedReadyIsNotFollowed) {
  auto request = StartHeldRedirect(true);
  ASSERT_TRUE(request->client.has_received_redirect());
  ASSERT_TRUE(request->target.initial);
  ASSERT_FALSE(request->target.initial->registration_id.empty());
  CancelAtQueuedPolicyCompletion cancel(base::BindOnce(
      [](HeldRedirectBrowserRequest* request) { request->client.Unbind(); },
      base::Unretained(request.get())));
  request->loader->FollowRedirect({}, std::nullopt);
  ASSERT_TRUE(base::test::RunUntil([&] { return cancel.cancelled(); }));
  task_environment()->RunUntilIdle();
  EXPECT_FALSE(request->target.followed);
  EXPECT_EQ(request->target.public_follows, 0);
}

TEST_F(AccessRetryNavigationProductTest,
       NativeRedirectSurvivesPrivateFactoryAdmissionReset) {
  auto request = StartHeldRedirect(false);
  ASSERT_TRUE(request->client.has_received_redirect());
  ASSERT_TRUE(request->target.initial);
  EXPECT_TRUE(request->target.initial->registration_id.empty());
  request->target.ResetAdmission();
  task_environment()->RunUntilIdle();
  EXPECT_FALSE(request->factory.is_connected());
  ASSERT_TRUE(request->wrapper);
  request->loader->FollowRedirect({}, std::nullopt);
  ASSERT_TRUE(base::test::RunUntil([&] {
    return request->client.has_received_completion();
  }));
  EXPECT_EQ(request->client.completion_status().error_code, net::OK);
  ASSERT_TRUE(request->target.followed);
  EXPECT_TRUE(request->target.followed->registration_id.empty());
  EXPECT_EQ(request->target.followed->hop, 1u);
  EXPECT_EQ(request->target.followed->request_token,
            request->target.initial->request_token);
  EXPECT_EQ(request->target.public_follows, 0);
}

TEST_F(AccessRetryNavigationProductTest,
       ProxyRedirectSurvivesPrivateFactoryAdmissionReset) {
  auto request = StartHeldRedirect(true);
  ASSERT_TRUE(request->client.has_received_redirect());
  ASSERT_TRUE(request->target.initial);
  ASSERT_FALSE(request->target.initial->registration_id.empty());
  request->target.ResetAdmission();
  task_environment()->RunUntilIdle();
  EXPECT_FALSE(request->factory.is_connected());
  ASSERT_TRUE(request->wrapper);
  request->loader->FollowRedirect({}, std::nullopt);
  ASSERT_TRUE(base::test::RunUntil([&] {
    return request->client.has_received_completion();
  }));
  EXPECT_EQ(request->client.completion_status().error_code, net::OK);
  ASSERT_TRUE(request->target.followed);
  EXPECT_EQ(request->target.followed->registration_id,
            request->target.initial->registration_id);
  EXPECT_EQ(request->target.followed->hop, 1u);
  EXPECT_EQ(request->target.followed->request_token,
            request->target.initial->request_token);
  EXPECT_EQ(request->target.public_follows, 0);
}

TEST_F(AccessRetryNavigationProductTest,
       RedirectAfterAdmissionResetStillRejectsChangedNetworkEpoch) {
  auto request = StartHeldRedirect(true);
  ASSERT_TRUE(request->client.has_received_redirect());
  request->target.ResetAdmission();
  task_environment()->RunUntilIdle();
  AccessNetworkContextTransportTestPeer::AdvanceNetwork(transport_);
  task_environment()->RunUntilIdle();
  request->loader->FollowRedirect({}, std::nullopt);
  ASSERT_TRUE(base::test::RunUntil([&] {
    return request->client.has_received_completion();
  }));
  EXPECT_NE(request->client.completion_status().error_code, net::OK);
  EXPECT_FALSE(request->target.followed);
  EXPECT_EQ(request->target.public_follows, 0);
}

}  // namespace
}  // namespace aegis::access
