// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_proxying_url_loader_factory.h"
#include "chrome/browser/aegis/access/access_proxying_url_tracked_request.h"

#include <map>
#include <memory>
#include <optional>
#include <utility>

#include "base/check.h"
#include "base/uuid.h"
#include "base/functional/bind.h"
#include "base/memory/ptr_util.h"
#include "base/memory/weak_ptr.h"
#include "base/task/sequenced_task_runner.h"
#include "base/supports_user_data.h"
#include "chrome/browser/aegis/access/access_browser_request_adapter.h"
#include "chrome/browser/aegis/access/access_navigation_retry_tab_helper.h"
#include "chrome/browser/aegis/access/access_site_proxy_bubble_controller.h"
#include "chrome/browser/aegis/access/access_service_coordinator.h"
#include "chrome/browser/aegis/access/access_network_context_transport.h"
#include "chrome/browser/aegis/access/access_published_request_runtime.h"
#include "chrome/browser/aegis/access/access_request_dispatch_state.h"
#include "chrome/browser/aegis/aegis_profile_support.h"
#include "chrome/browser/profiles/profile.h"
#include "components/aegis_access/access_policy_evaluator.h"
#include "components/aegis_access/published_request_runtime.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/global_routing_id.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/page.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "mojo/public/cpp/system/simple_watcher.h"
#include "net/base/net_errors.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/url_loader_completion_status.h"
#include "url/origin.h"

namespace aegis::access {
namespace {

const void* const kBrowserContextDataKey = &kBrowserContextDataKey;

bool SameAttributionScope(
    const aegis_access::BrowserOwnedRequestMetadata& expected,
    const aegis_access::BrowserOwnedRequestMetadata& current) {
  return expected.owner == current.owner &&
         expected.attribution_kind == current.attribution_kind &&
         expected.document_token == current.document_token &&
         expected.pending_navigation_token == current.pending_navigation_token &&
         expected.top_frame_site == current.top_frame_site;
}

aegis_access::RegisteredProxyEntry EntryForEndpoint(
    const aegis_access::RegisteredProxyEndpoint& endpoint) {
  return {endpoint.registration_id, endpoint.proxy_group_id, endpoint.owner,
          endpoint.generations};
}

enum class MatchedPolicyDisposition {
  kPreserveNative,
  kProxy,
  kBlock,
};

MatchedPolicyDisposition ClassifyPolicyMatch(
    const aegis_access::PolicyMatchResult& match) {
  if (match.policy_state == aegis_access::PolicyState::kAbsent) {
    return MatchedPolicyDisposition::kPreserveNative;
  }
  if (match.policy_state != aegis_access::PolicyState::kValid) {
    return MatchedPolicyDisposition::kBlock;
  }
  if (match.effective_mode == aegis_access::AccessMode::kNone ||
      match.effective_mode == aegis_access::AccessMode::kDirect) {
    return MatchedPolicyDisposition::kPreserveNative;
  }
  if (match.effective_mode == aegis_access::AccessMode::kProxy &&
      !match.effective_proxy_group_id.empty()) {
    return MatchedPolicyDisposition::kProxy;
  }
  return MatchedPolicyDisposition::kBlock;
}

int NetErrorForDispatchResult(
    const aegis_access::PublishedRequestRuntimeResult& result) {
  return result.status == aegis_access::PublishedRequestRuntimeStatus::kDeny ||
                 result.status ==
                     aegis_access::PublishedRequestRuntimeStatus::kBlockedByBarrier
             ? net::ERR_BLOCKED_BY_CLIENT
             : net::ERR_PROXY_CONNECTION_FAILED;
}

struct ProxyDispatchPreparation {
  int net_error = net::ERR_PROXY_CONNECTION_FAILED;
  std::optional<aegis_access::RequestOwnershipRecord> ownership_record;
};

ProxyDispatchPreparation PrepareProxyDispatch(
    Profile* profile,
    AccessPublishedRequestRuntime* runtime,
    const aegis_access::BrowserOwnedRequestMetadata& metadata,
    const aegis_access::PublishedAccessPolicySnapshot& snapshot,
    const aegis_access::RequestPolicyContext& context,
    const aegis_access::PolicyMatchResult& match) {
  if (!runtime) {
    return {};
  }

  const aegis_access::RequestGenerationTupleBuildResult tuple =
      runtime->CaptureProxyGenerationTupleOnUiThread(
          metadata.owner, match.effective_proxy_group_id);
  if (!tuple.generations.has_value()) {
    return {};
  }

  AccessNetworkContextTransport* transport =
      AccessNetworkContextTransport::Get(profile);
  const std::optional<aegis_access::RegisteredProxyEndpoint> endpoint =
      transport ? transport->CaptureSelectedProxyEndpoint(
                      metadata.owner, match.effective_proxy_group_id,
                      context.exact_host())
                : std::nullopt;
  if (!endpoint.has_value()) {
    return {};
  }

  AccessRequestDispatchState* dispatch_state =
      AccessRequestDispatchState::GetOrCreate(profile);
  if (!dispatch_state) {
    return {};
  }

  aegis_access::PublishedRequestRuntimeInput input;
  input.request = context.ToOwnershipRecord(*tuple.generations);
  input.policy_state = match.policy_state;
  input.effective_mode = match.effective_mode;
  input.policy_scope = match.policy_scope;
  input.effective_proxy_group_id = match.effective_proxy_group_id;
  input.matched_policy_generation = match.policy_generation;
  input.require_proxy_intent = true;
  input.snapshot_state = aegis_access::SnapshotState::kPublished;
  input.snapshot_owner = snapshot.owner;
  input.snapshot_generations = *tuple.generations;
  input.protection_restriction = aegis_access::ProtectionRestriction::kNone;
  input.managed_restriction = aegis_access::ManagedRestriction::kNone;
  input.runtime_state = aegis_access::ProxyRuntimeState::kReady;
  input.registered_proxy_entry = EntryForEndpoint(*endpoint);

  const aegis_access::PublishedRequestRuntimeResult result =
      aegis_access::EvaluatePublishedRequestForDispatch(
          input, dispatch_state->barriers(), dispatch_state->ownership());
  if (result.status !=
          aegis_access::PublishedRequestRuntimeStatus::kDispatchRegistered ||
      result.route_plan.action !=
          aegis_access::RouteAction::kUseRegisteredProxy) {
    return {NetErrorForDispatchResult(result), std::nullopt};
  }

  return {net::OK, input.request};
}

std::optional<aegis_access::BrowserOwnedRequestMetadata>
CaptureProxyFactoryMetadata(
    Profile* profile,
    content::RenderFrameHost* frame,
    std::optional<int64_t> navigation_id) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!aegis::IsAegisProfileSupported(profile) || !frame ||
      frame->GetBrowserContext() != profile || !frame->GetPage().IsPrimary()) {
    return std::nullopt;
  }

  const content::FrameTreeNodeId frame_tree_node_id =
      frame->GetFrameTreeNodeId();
  auto wc_getter =
      base::BindRepeating(&content::WebContents::FromFrameTreeNodeId,
                          frame_tree_node_id);
  AccessBrowserRequestMetadataResult metadata = BuildBrowserOwnedRequestMetadata(
      profile, wc_getter, frame_tree_node_id, navigation_id);
  if (metadata.status != AccessBrowserRequestMetadataStatus::kOk ||
      !metadata.metadata.has_value()) {
    return std::nullopt;
  }
  return std::move(*metadata.metadata);
}

std::optional<aegis_access::BrowserOwnedRequestMetadata>
ValidateAndExtractProfileOnlyMetadata(
    AccessBrowserRequestMetadataResult metadata) {
  if (metadata.status != AccessBrowserRequestMetadataStatus::kOk ||
      !metadata.metadata.has_value() ||
      metadata.metadata->attribution_kind !=
          aegis_access::RequestAttributionKind::kProfileOnly) {
    return std::nullopt;
  }
  return std::move(*metadata.metadata);
}

std::optional<aegis_access::BrowserOwnedRequestMetadata>
CaptureProfileOnlyProxyFactoryMetadata(Profile* profile,
                                       int render_process_id) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!aegis::IsAegisProfileSupported(profile)) {
    return std::nullopt;
  }
  return ValidateAndExtractProfileOnlyMetadata(
      BuildBrowserOwnedProfileOnlyRequestMetadata(profile, render_process_id));
}

std::optional<aegis_access::BrowserOwnedRequestMetadata>
CaptureProfileOnlyProxyFactoryMetadata(Profile* profile,
                                       content::StoragePartition* partition) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!aegis::IsAegisProfileSupported(profile) || !partition) {
    return std::nullopt;
  }
  return ValidateAndExtractProfileOnlyMetadata(
      BuildBrowserOwnedProfileRequestMetadata(profile, partition));
}

struct PrivateTerminal : public std::enable_shared_from_this<PrivateTerminal> {
  mojo::PendingReceiver<network::mojom::URLLoaderFactory> receiver;
  network::mojom::URLLoaderFactoryParamsPtr params;
  std::shared_ptr<AccessPrivateContextClient> context;
  bool context_done = false;
  bool restoration_done = false;
  bool document_done = false;
  bool failed = false;
  base::OnceCallback<void(std::shared_ptr<PrivateTerminal>)> on_ready;
  void MaybeReady() {
    if (!context_done || !restoration_done || !document_done || !on_ready) return;
    if (failed || !context) {
      receiver.reset();
      params.reset();
      on_ready.Reset();
      return;
    }
    std::move(on_ready).Run(shared_from_this());
  }
};

// CommitNavigation constructs and clones this factory before the new document
// is active. Keep the wrapper endpoint unbound until the exact navigation
// commits, so queued parser requests cannot be attributed to the old document.
class PendingDocumentFactory : public content::WebContentsObserver {
 public:
  using CompletionCallback = base::OnceCallback<void(
      std::optional<aegis_access::BrowserOwnedRequestMetadata>,
      std::optional<content::WeakDocumentPtr>)>;

  PendingDocumentFactory(
      Profile* profile,
      content::WebContents* contents,
      content::RenderFrameHost* frame,
      int64_t navigation_id,
      aegis_access::OwnershipKey owner,
      std::shared_ptr<PrivateTerminal> terminal,
      CompletionCallback on_complete)
      : content::WebContentsObserver(contents),
        profile_(profile),
        frame_id_(frame->GetGlobalId()),
        navigation_id_(navigation_id),
        owner_(std::move(owner)),
        terminal_(std::move(terminal)),
        on_complete_(std::move(on_complete)) {}

  PendingDocumentFactory(const PendingDocumentFactory&) = delete;
  PendingDocumentFactory& operator=(const PendingDocumentFactory&) = delete;
  ~PendingDocumentFactory() override = default;

  std::shared_ptr<PrivateTerminal> TakeTerminal() { return std::move(terminal_); }
  const aegis_access::OwnershipKey& owner() const { return owner_; }

  void DidFinishNavigation(content::NavigationHandle* navigation) override {
    if (navigation->GetNavigationId() != navigation_id_) {
      return;
    }
    content::RenderFrameHost* frame =
        navigation->HasCommitted() && !navigation->IsSameDocument() &&
                !navigation->IsErrorPage()
            ? navigation->GetRenderFrameHost()
            : nullptr;
    if (!frame || frame->GetGlobalId() != frame_id_ ||
        !frame->GetPage().IsPrimary()) {
      Finish(std::nullopt, std::nullopt);
      return;
    }

    auto metadata = CaptureProxyFactoryMetadata(profile_, frame, std::nullopt);
    if (metadata &&
        (metadata->attribution_kind !=
             aegis_access::RequestAttributionKind::kDocument ||
         metadata->owner != owner_)) {
      metadata.reset();
    }
    Finish(std::move(metadata), frame->GetWeakDocumentPtr());
  }

  void RenderFrameDeleted(content::RenderFrameHost* frame) override {
    if (frame->GetGlobalId() == frame_id_) {
      Finish(std::nullopt, std::nullopt);
    }
  }

  void WebContentsDestroyed() override { Finish(std::nullopt, std::nullopt); }

 private:
  void Finish(
      std::optional<aegis_access::BrowserOwnedRequestMetadata> metadata,
      std::optional<content::WeakDocumentPtr> document) {
    Observe(nullptr);
    // Erasing this observer inside its notification would destroy the active
    // callback frame. Completing on the next UI task also keeps queued Mojo
    // requests unbound until the document identity has been captured.
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(std::move(on_complete_),
                                  std::move(metadata), std::move(document)));
  }

  const raw_ptr<Profile> profile_;
  const content::GlobalRenderFrameHostId frame_id_;
  const int64_t navigation_id_;
  const aegis_access::OwnershipKey owner_;
  std::shared_ptr<PrivateTerminal> terminal_;
  CompletionCallback on_complete_;
};

class BrowserContextData : public base::SupportsUserData::Data {
 public:
  BrowserContextData(const BrowserContextData&) = delete;
  BrowserContextData& operator=(const BrowserContextData&) = delete;
  ~BrowserContextData() override = default;

  static void StartProxying(Profile* profile,
      content::FrameTreeNodeId frame_tree_node_id,
      std::optional<int64_t> navigation_id,
      std::optional<int> profile_only_render_process_id,
      content::StoragePartition* profile_only_storage_partition,
      aegis_access::BrowserOwnedRequestMetadata metadata,
      network::URLLoaderFactoryBuilder& builder) {
    auto* self = GetOrCreate(profile);
    std::optional<content::WeakDocumentPtr> document;
    if (metadata.attribution_kind == aegis_access::RequestAttributionKind::kDocument) {
      auto* contents = content::WebContents::FromFrameTreeNodeId(frame_tree_node_id);
      auto* frame = contents ? contents->UnsafeFindFrameByFrameTreeNodeId(frame_tree_node_id) : nullptr;
      if (!frame) return;
      document = frame->GetWeakDocumentPtr();
    }
    const auto owner = metadata.owner;
    builder.SetTerminalFactoryInterceptor(base::BindOnce(
        &BrowserContextData::BeginImmediateTerminal, self->weak_factory_.GetWeakPtr(),
        frame_tree_node_id, navigation_id, profile_only_render_process_id,
        profile_only_storage_partition, owner, std::move(metadata), std::move(document)));
  }

  static void StartUnattributedDocument(Profile* profile, content::RenderFrameHost* frame,
      aegis_access::OwnershipKey owner, network::URLLoaderFactoryBuilder& builder) {
    auto* self = GetOrCreate(profile);
    builder.SetTerminalFactoryInterceptor(base::BindOnce(
        &BrowserContextData::BeginImmediateTerminal, self->weak_factory_.GetWeakPtr(),
        frame->GetFrameTreeNodeId(), std::nullopt, std::nullopt,
        static_cast<content::StoragePartition*>(nullptr), owner,
        std::optional<aegis_access::BrowserOwnedRequestMetadata>(),
        std::make_optional(frame->GetWeakDocumentPtr())));
  }

  static void StartPendingDocument(Profile* profile, content::WebContents* contents,
      content::RenderFrameHost* frame, int64_t navigation_id,
      aegis_access::OwnershipKey owner, network::URLLoaderFactoryBuilder& builder) {
    auto* self = GetOrCreate(profile);
    auto terminal = std::make_shared<PrivateTerminal>();
    const auto pending_id = ++self->next_pending_id_;
    self->pending_documents_.emplace(pending_id, std::make_unique<PendingDocumentFactory>(
        profile, contents, frame, navigation_id, owner, terminal,
        base::BindOnce(&BrowserContextData::CompletePendingDocument,
                       self->weak_factory_.GetWeakPtr(), pending_id)));
    builder.SetTerminalFactoryInterceptor(base::BindOnce(
        [](base::WeakPtr<BrowserContextData> self, aegis_access::OwnershipKey owner,
           std::shared_ptr<PrivateTerminal> terminal,
           mojo::PendingReceiver<network::mojom::URLLoaderFactory> receiver,
           network::mojom::NetworkContext* context,
           network::mojom::URLLoaderFactoryParamsPtr params) {
          if (!self) return;
          terminal->receiver = std::move(receiver);
          terminal->params = std::move(params);
          self->BeginTerminal(terminal, owner, context);
        }, self->weak_factory_.GetWeakPtr(), owner, terminal));
  }

  void RemoveProxy(AccessProxyingURLLoaderFactory* proxy) {
    auto it = proxies_.find(proxy);
    CHECK(it != proxies_.end());
    proxies_.erase(it);
  }

 private:
  explicit BrowserContextData(Profile* profile) : profile_(profile) {}
  static BrowserContextData* GetOrCreate(Profile* profile) {
    auto* self = static_cast<BrowserContextData*>(profile->GetUserData(kBrowserContextDataKey));
    if (!self) {
      self = new BrowserContextData(profile);
      profile->SetUserData(kBrowserContextDataKey, base::WrapUnique(self));
    }
    return self;
  }
  void BeginImmediateTerminal(content::FrameTreeNodeId frame_id,
      std::optional<int64_t> navigation_id, std::optional<int> process,
      content::StoragePartition* partition, aegis_access::OwnershipKey owner,
      std::optional<aegis_access::BrowserOwnedRequestMetadata> metadata,
      std::optional<content::WeakDocumentPtr> document,
      mojo::PendingReceiver<network::mojom::URLLoaderFactory> receiver,
      network::mojom::NetworkContext* context,
      network::mojom::URLLoaderFactoryParamsPtr params) {
    auto terminal = std::make_shared<PrivateTerminal>();
    terminal->receiver = std::move(receiver);
    terminal->params = std::move(params);
    terminal->document_done = true;
    terminal->on_ready = base::BindOnce(&BrowserContextData::PublishAndCreateFactory,
        weak_factory_.GetWeakPtr(), frame_id, navigation_id, process, partition,
        owner, std::move(metadata), std::move(document));
    BeginTerminal(terminal, owner, context);
  }
  void BeginTerminal(std::shared_ptr<PrivateTerminal> terminal,
      const aegis_access::OwnershipKey& owner, network::mojom::NetworkContext* context) {
    auto* transport = AccessNetworkContextTransport::Get(profile_);
    auto* coordinator = AccessServiceCoordinator::GetOrCreate(profile_);
    if (!transport || !coordinator) {
      terminal->failed = terminal->context_done = terminal->restoration_done = true;
      terminal->MaybeReady();
      return;
    }
    // The raw Context is used now, never retained across a deferred commit.
    transport->BindPrivateContext(owner, context, base::BindOnce(
        [](std::shared_ptr<PrivateTerminal> terminal,
           std::shared_ptr<AccessPrivateContextClient> context) {
          terminal->context = std::move(context);
          terminal->context_done = true;
          terminal->MaybeReady();
        }, terminal));
    coordinator->InitializeForProfile(owner, base::BindOnce(
        [](std::shared_ptr<PrivateTerminal> terminal, bool restored) {
          terminal->restoration_done = true;
          terminal->failed |= !restored;
          terminal->MaybeReady();
        }, terminal));
  }
  void CompletePendingDocument(uint64_t pending_id,
      std::optional<aegis_access::BrowserOwnedRequestMetadata> metadata,
      std::optional<content::WeakDocumentPtr> document) {
    auto it = pending_documents_.find(pending_id);
    CHECK(it != pending_documents_.end());
    auto pending = std::move(it->second);
    pending_documents_.erase(it);
    auto terminal = pending->TakeTerminal();
    auto* frame = document ? document->AsRenderFrameHostIfValid() : nullptr;
    if (!frame || !frame->GetPage().IsPrimary() || frame->GetBrowserContext() != profile_) {
      terminal->receiver.reset();
      return;
    }
    if (metadata && (metadata->attribution_kind != aegis_access::RequestAttributionKind::kDocument ||
                     metadata->owner != pending->owner())) metadata.reset();
    terminal->document_done = true;
    terminal->on_ready = base::BindOnce(&BrowserContextData::PublishAndCreateFactory,
        weak_factory_.GetWeakPtr(), frame->GetFrameTreeNodeId(), std::nullopt,
        std::nullopt, static_cast<content::StoragePartition*>(nullptr), pending->owner(),
        std::move(metadata), std::move(document));
    terminal->MaybeReady();
  }
  void PublishAndCreateFactory(content::FrameTreeNodeId frame_id,
      std::optional<int64_t> navigation_id, std::optional<int> process,
      content::StoragePartition* partition, aegis_access::OwnershipKey owner,
      std::optional<aegis_access::BrowserOwnedRequestMetadata> metadata,
      std::optional<content::WeakDocumentPtr> document,
      std::shared_ptr<PrivateTerminal> terminal) {
    auto* runtime = AccessPublishedRequestRuntime::Get(profile_);
    auto* transport = AccessNetworkContextTransport::Get(profile_);
    const auto* policy = runtime ? runtime->GetPublishedPolicySnapshot(owner) : nullptr;
    const auto common = runtime ? runtime->CaptureCommonGenerationTupleOnUiThread(owner)
                                : std::nullopt;
    if (!transport || !policy || !common ||
        (document && !document->AsRenderFrameHostIfValid())) return;
    transport->PublishPrivatePolicy(*policy, *common, base::BindOnce(
        &BrowserContextData::OnTerminalPolicyReady, weak_factory_.GetWeakPtr(),
        frame_id, navigation_id, process, partition, owner,
        std::move(metadata), std::move(document), terminal));
  }
  void OnTerminalPolicyReady(content::FrameTreeNodeId frame_id,
      std::optional<int64_t> navigation_id, std::optional<int> process,
      content::StoragePartition* partition, aegis_access::OwnershipKey owner,
      std::optional<aegis_access::BrowserOwnedRequestMetadata> metadata,
      std::optional<content::WeakDocumentPtr> document,
      std::shared_ptr<PrivateTerminal> terminal, bool accepted) {
    if (!accepted || (document && !document->AsRenderFrameHostIfValid())) return;
    auto binding = network::mojom::AegisAccessFactoryBinding::New();
    binding->owner = terminal->context->owner_for_binding();
    binding->attribution = network::mojom::AegisAccessAttribution::kProfileOnly;
    if (metadata) {
      binding->document_token = metadata->document_token;
      binding->pending_navigation_token = metadata->pending_navigation_token;
      if (metadata->top_frame_site) binding->top_frame_site = metadata->top_frame_site->GetURL();
      switch (metadata->attribution_kind) {
        case aegis_access::RequestAttributionKind::kDocument:
          binding->attribution = network::mojom::AegisAccessAttribution::kDocument; break;
        case aegis_access::RequestAttributionKind::kPendingNavigation:
          binding->attribution = network::mojom::AegisAccessAttribution::kPendingNavigation; break;
        case aegis_access::RequestAttributionKind::kProfileOnly: break;
        case aegis_access::RequestAttributionKind::kInvalid: return;
      }
    }
    mojo::PendingRemote<network::mojom::AegisAccessURLLoaderFactory> target;
    auto receiver = target.InitWithNewPipeAndPassReceiver();
    terminal->context->CreateFactory(std::move(terminal->params), std::move(binding),
        std::move(receiver), base::BindOnce(
            [](base::WeakPtr<BrowserContextData> self, content::FrameTreeNodeId frame_id,
               std::optional<int64_t> navigation_id, std::optional<int> process,
               content::StoragePartition* partition, aegis_access::OwnershipKey owner,
               std::optional<aegis_access::BrowserOwnedRequestMetadata> metadata,
               std::optional<content::WeakDocumentPtr> document,
               std::shared_ptr<PrivateTerminal> terminal,
               mojo::PendingRemote<network::mojom::AegisAccessURLLoaderFactory> target,
               bool created) {
              if (!self || !created) return;
              auto proxy = std::make_unique<AccessProxyingURLLoaderFactory>(
                  self->profile_, frame_id, navigation_id, process, partition, owner,
                  std::move(metadata), std::move(terminal->receiver),
                  mojo::PendingRemote<network::mojom::URLLoaderFactory>(), std::move(document),
                  base::BindOnce(&BrowserContextData::RemoveProxy, self),
                  std::move(target), terminal->context);
              self->proxies_.emplace(std::move(proxy));
            }, weak_factory_.GetWeakPtr(), frame_id, navigation_id, process, partition,
            owner, std::move(metadata), std::move(document), terminal, std::move(target)));
  }

  const raw_ptr<Profile> profile_;
  std::set<std::unique_ptr<AccessProxyingURLLoaderFactory>, base::UniquePtrComparator> proxies_;
  std::map<uint64_t, std::unique_ptr<PendingDocumentFactory>> pending_documents_;
  uint64_t next_pending_id_ = 0;
  base::WeakPtrFactory<BrowserContextData> weak_factory_{this};
};

void MaybeProxyFrameOwnedFactory(
    Profile* profile,
    content::RenderFrameHost* frame,
    network::URLLoaderFactoryBuilder& factory_builder) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!frame) {
    return;
  }

  std::optional<aegis_access::BrowserOwnedRequestMetadata> metadata =
      CaptureProxyFactoryMetadata(profile, frame, std::nullopt);
  if (!metadata.has_value() ||
      metadata->attribution_kind !=
          aegis_access::RequestAttributionKind::kDocument) {
    return;
  }

  BrowserContextData::StartProxying(
      profile, frame->GetFrameTreeNodeId(), std::nullopt, std::nullopt,
      /*profile_only_storage_partition=*/nullptr, std::move(*metadata),
      factory_builder);
}

void MaybeProxyProfileOnlyFactory(
    Profile* profile,
    int render_process_id,
    network::URLLoaderFactoryBuilder& factory_builder) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  std::optional<aegis_access::BrowserOwnedRequestMetadata> metadata =
      CaptureProfileOnlyProxyFactoryMetadata(profile, render_process_id);
  if (!metadata.has_value()) {
    return;
  }

  BrowserContextData::StartProxying(
      profile, content::FrameTreeNodeId(), std::nullopt, render_process_id,
      /*profile_only_storage_partition=*/nullptr, std::move(*metadata),
      factory_builder);
}

}  // namespace

// Observe both IPC peers before waiting for core readiness or snapshot ACK.
// Keeping the pipes unbound preserves queued URLLoader methods for the normal
// tracked request. A synchronous signal check also catches cancellation whose
// notification has not run yet when a readiness callback arrives.
struct AccessProxyingURLLoaderFactory::PendingStart {
  PendingStart(AccessProxyingURLLoaderFactory* factory,
               mojo::PendingReceiver<network::mojom::URLLoader> loader,
               int32_t id,
               uint32_t flags,
               const network::ResourceRequest& value,
               mojo::PendingRemote<network::mojom::URLLoaderClient> client,
               const net::MutableNetworkTrafficAnnotationTag& annotation)
      : factory(factory),
        request_id(id),
        options(flags),
        request(value),
        traffic_annotation(annotation),
        loader_pipe(loader.PassPipe()),
        client_version(client.version()),
        client_pipe(client.PassPipe()) {}

  bool IsConnected() const {
    return loader_pipe.is_valid() && client_pipe.is_valid() &&
           !loader_pipe->QuerySignalsState().peer_closed() &&
           !client_pipe->QuerySignalsState().peer_closed();
  }
  bool Observe() {
    if (!IsConnected()) {
      return false;
    }
    auto disconnected = base::BindRepeating(&PendingStart::OnDisconnected,
                                           weak_factory.GetWeakPtr());
    return loader_watch.Watch(loader_pipe.get(), MOJO_HANDLE_SIGNAL_PEER_CLOSED,
                              MOJO_WATCH_CONDITION_SATISFIED, disconnected) ==
               MOJO_RESULT_OK &&
           client_watch.Watch(client_pipe.get(), MOJO_HANDLE_SIGNAL_PEER_CLOSED,
                              MOJO_WATCH_CONDITION_SATISFIED, disconnected) ==
               MOJO_RESULT_OK;
  }
  auto TakeEndpoints() {
    loader_watch.Cancel();
    client_watch.Cancel();
    return std::make_pair(
        mojo::PendingReceiver<network::mojom::URLLoader>(std::move(loader_pipe)),
        mojo::PendingRemote<network::mojom::URLLoaderClient>(
            std::move(client_pipe), client_version));
  }
  void OnDisconnected(MojoResult, const mojo::HandleSignalsState&) {
    factory->FinishPendingStart(this);
  }

  const raw_ptr<AccessProxyingURLLoaderFactory> factory;
  const int32_t request_id;
  const uint32_t options;
  const network::ResourceRequest request;
  const net::MutableNetworkTrafficAnnotationTag traffic_annotation;
  mojo::ScopedMessagePipeHandle loader_pipe;
  const uint32_t client_version;
  mojo::ScopedMessagePipeHandle client_pipe;
  mojo::SimpleWatcher loader_watch{
      FROM_HERE, mojo::SimpleWatcher::ArmingPolicy::AUTOMATIC};
  mojo::SimpleWatcher client_watch{
      FROM_HERE, mojo::SimpleWatcher::ArmingPolicy::AUTOMATIC};
  base::WeakPtrFactory<PendingStart> weak_factory{this};
};

AccessProxyingURLLoaderFactory::AccessProxyingURLLoaderFactory(
    Profile* profile,
    content::FrameTreeNodeId frame_tree_node_id,
    std::optional<int64_t> navigation_id,
    std::optional<int> profile_only_render_process_id,
    content::StoragePartition* profile_only_storage_partition,
    aegis_access::OwnershipKey factory_owner,
    std::optional<aegis_access::BrowserOwnedRequestMetadata> factory_metadata,
    mojo::PendingReceiver<network::mojom::URLLoaderFactory> loader_receiver,
    mojo::PendingRemote<network::mojom::URLLoaderFactory> target_factory,
    std::optional<content::WeakDocumentPtr> document,
    DisconnectCallback on_disconnect,
    mojo::PendingRemote<network::mojom::AegisAccessURLLoaderFactory> private_target,
    std::shared_ptr<AccessPrivateContextClient> private_context)
    : profile_(profile),
      frame_tree_node_id_(frame_tree_node_id),
      navigation_id_(navigation_id),
      profile_only_render_process_id_(profile_only_render_process_id),
      profile_only_storage_partition_(profile_only_storage_partition),
      factory_owner_(std::move(factory_owner)),
      factory_metadata_(std::move(factory_metadata)),
      document_(std::move(document)),
      is_private_factory_(private_target.is_valid()),
      private_context_(std::move(private_context)),
      on_disconnect_(std::move(on_disconnect)) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  const bool is_profile_only = factory_metadata_.has_value() &&
      factory_metadata_->attribution_kind ==
      aegis_access::RequestAttributionKind::kProfileOnly;
  CHECK(aegis_access::IsCompleteOwner(factory_owner_));
  CHECK(!factory_metadata_ || factory_metadata_->owner == factory_owner_);
  const bool has_profile_only_process =
      profile_only_render_process_id_.has_value();
  const bool has_profile_only_partition =
      profile_only_storage_partition_ != nullptr;
  CHECK(!(has_profile_only_process && has_profile_only_partition));
  CHECK_EQ(is_profile_only,
           has_profile_only_process || has_profile_only_partition);
  if (is_profile_only) {
    CHECK(!frame_tree_node_id_);
    CHECK(!navigation_id_.has_value());
  } else {
    CHECK(frame_tree_node_id_);
  }
  if (private_target.is_valid()) {
    CHECK(private_context_);
    private_target_factory_.Bind(std::move(private_target));
    private_target_factory_.set_disconnect_handler(base::BindOnce(
        &AccessProxyingURLLoaderFactory::OnTargetFactoryError, base::Unretained(this)));
  } else {
    target_factory_.Bind(std::move(target_factory));
    target_factory_.set_disconnect_handler(base::BindOnce(
        &AccessProxyingURLLoaderFactory::OnTargetFactoryError, base::Unretained(this)));
  }
  proxy_receivers_.Add(this, std::move(loader_receiver));
  proxy_receivers_.set_disconnect_handler(base::BindRepeating(
      &AccessProxyingURLLoaderFactory::OnProxyBindingError,
      base::Unretained(this)));
}

AccessProxyingURLLoaderFactory::~AccessProxyingURLLoaderFactory() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
}

// static
void AccessProxyingURLLoaderFactory::MaybeProxyDocumentSubresource(
    Profile* profile,
    content::RenderFrameHost* frame,
    std::optional<int64_t> navigation_id,
    network::URLLoaderFactoryBuilder& factory_builder) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  // Content supplies this hook only for Network Service-backed document
  // factories. Non-network WebUI and scheme-specific terminals keep their
  // original restricted behavior and never reach this wrapper.
  if (!aegis::IsAegisProfileSupported(profile) || !frame ||
      frame->GetBrowserContext() != profile) {
    return;
  }
  // This fixed owner is browser-owned even when a sandboxed document's
  // top-level site is opaque and document attribution cannot be captured.
  const AccessBrowserRequestMetadataResult partition_metadata =
      BuildBrowserOwnedProfileRequestMetadata(profile,
                                              frame->GetStoragePartition());
  if (partition_metadata.status != AccessBrowserRequestMetadataStatus::kOk ||
      !partition_metadata.metadata.has_value()) {
    return;
  }
  aegis_access::OwnershipKey owner = partition_metadata.metadata->owner;

  if (navigation_id.has_value()) {
    content::WebContents* contents =
        content::WebContents::FromRenderFrameHost(frame);
    if (!contents || contents->GetBrowserContext() != profile ||
        !frame->GetMainFrame() || !contents->GetPrimaryMainFrame() ||
        frame->GetMainFrame()->GetFrameTreeNodeId() !=
            contents->GetPrimaryMainFrame()->GetFrameTreeNodeId()) {
      return;
    }
    BrowserContextData::StartPendingDocument(
        profile, contents, frame, *navigation_id, std::move(owner),
        factory_builder);
    return;
  }
  if (!frame->GetPage().IsPrimary()) {
    return;
  }
  std::optional<aegis_access::BrowserOwnedRequestMetadata> metadata =
      CaptureProxyFactoryMetadata(profile, frame, std::nullopt);
  if (metadata &&
      metadata->attribution_kind ==
          aegis_access::RequestAttributionKind::kDocument &&
      metadata->owner == owner) {
    BrowserContextData::StartProxying(
        profile, frame->GetFrameTreeNodeId(), std::nullopt, std::nullopt,
        /*profile_only_storage_partition=*/nullptr, std::move(*metadata),
        factory_builder);
    return;
  }
  BrowserContextData::StartUnattributedDocument(
      profile, frame, std::move(owner), factory_builder);
}

// static
void AccessProxyingURLLoaderFactory::MaybeProxyWorkerMainResource(
    Profile* profile,
    content::RenderFrameHost* frame,
    network::URLLoaderFactoryBuilder& factory_builder) {
  MaybeProxyFrameOwnedFactory(profile, frame, factory_builder);
}

// static
void AccessProxyingURLLoaderFactory::MaybeProxyWorkerSubResource(
    Profile* profile,
    content::RenderFrameHost* frame,
    int render_process_id,
    network::URLLoaderFactoryBuilder& factory_builder) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (frame) {
    MaybeProxyFrameOwnedFactory(profile, frame, factory_builder);
    return;
  }

  MaybeProxyProfileOnlyFactory(profile, render_process_id, factory_builder);
}

// static
void AccessProxyingURLLoaderFactory::MaybeProxyServiceWorkerSubResource(
    Profile* profile,
    int render_process_id,
    network::URLLoaderFactoryBuilder& factory_builder) {
  MaybeProxyProfileOnlyFactory(profile, render_process_id, factory_builder);
}

// static
void AccessProxyingURLLoaderFactory::MaybeProxyServiceWorkerScript(
    Profile* profile,
    int render_process_id,
    network::URLLoaderFactoryBuilder& factory_builder) {
  MaybeProxyProfileOnlyFactory(profile, render_process_id, factory_builder);
}

// static
void AccessProxyingURLLoaderFactory::MaybeProxyPrefetch(
    Profile* profile,
    content::RenderFrameHost* frame,
    network::URLLoaderFactoryBuilder& factory_builder) {
  MaybeProxyFrameOwnedFactory(profile, frame, factory_builder);
}

// static
void AccessProxyingURLLoaderFactory::MaybeProxyBrowserProcessPrefetch(
    Profile* profile,
    content::StoragePartition* partition,
    network::URLLoaderFactoryBuilder& factory_builder) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!profile || !partition ||
      partition != profile->GetDefaultStoragePartition()) {
    return;
  }

  std::optional<aegis_access::BrowserOwnedRequestMetadata> metadata =
      CaptureProfileOnlyProxyFactoryMetadata(profile, partition);
  if (!metadata.has_value()) {
    return;
  }

  BrowserContextData::StartProxying(
      profile, content::FrameTreeNodeId(), std::nullopt, std::nullopt,
      partition, std::move(*metadata), factory_builder);
}

// static
bool AccessProxyingURLLoaderFactory::CanOfferProxyRetry(
    content::WebContents* contents) {
  auto* helper = AccessNavigationRetryTabHelper::FromWebContents(contents);
  return helper && helper->HasProxyRetryHandler();
}

// static
void AccessProxyingURLLoaderFactory::MaybeProxyNavigation(
    Profile* profile,
    content::RenderFrameHost* frame,
    int64_t navigation_id,
    network::URLLoaderFactoryBuilder& factory_builder) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  // Observe native failures too: the user may enable a proxy only after this
  // navigation fails. The identity comes from the browser navigation hook.
  VLOG(1) << "Aegis proxy retry factory: id=" << navigation_id
          << " frame=" << !!frame
          << " primary_main=" << (frame && frame->IsInPrimaryMainFrame());
  if (frame && frame->IsInPrimaryMainFrame() && navigation_id > 0) {
    AccessNavigationRetryTabHelper::ObservePendingNavigation(
        content::WebContents::FromRenderFrameHost(frame), navigation_id);
    auto* helper = AccessNavigationRetryTabHelper::FromWebContents(
        content::WebContents::FromRenderFrameHost(frame));
    if (auto* controller = AccessSiteProxyBubbleController::GetOrCreate(profile)) {
      helper->SetProxyRetryHandler(controller->GetFailedNavigationRetryHandler());
    }
  }

  std::optional<aegis_access::BrowserOwnedRequestMetadata> metadata =
      CaptureProxyFactoryMetadata(profile, frame, navigation_id);
  if (!metadata.has_value() ||
      metadata->attribution_kind !=
          aegis_access::RequestAttributionKind::kPendingNavigation) {
    return;
  }
  if (auto* controller = AccessSiteProxyBubbleController::GetOrCreate(profile))
    controller->EnsureProfileRestored(metadata->owner);

  BrowserContextData::StartProxying(
      profile, frame->GetFrameTreeNodeId(), navigation_id, std::nullopt,
      /*profile_only_storage_partition=*/nullptr, std::move(*metadata),
      factory_builder);
}

AccessProxyingURLLoaderFactory::RequestDisposition
AccessProxyingURLLoaderFactory::EvaluateRequest(
    const network::ResourceRequest& request,
    int* net_error,
    aegis_access::RequestOwnershipRecord* ownership_record) {
  return EvaluateUrl(request.url, std::nullopt, net_error, ownership_record);
}

AccessProxyingURLLoaderFactory::RequestDisposition
AccessProxyingURLLoaderFactory::EvaluateRedirect(
    const GURL& redirect_url,
    const std::string& stable_request_id,
    int* net_error,
    aegis_access::RequestOwnershipRecord* ownership_record) {
  if (stable_request_id.empty()) {
    CHECK(net_error);
    *net_error = net::ERR_BLOCKED_BY_CLIENT;
    return RequestDisposition::kBlock;
  }
  return EvaluateUrl(redirect_url, stable_request_id, net_error,
                     ownership_record);
}

AccessBrowserRequestMetadataResult
AccessProxyingURLLoaderFactory::CaptureCurrentMetadata() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  CHECK(factory_metadata_);
  if (factory_metadata_->attribution_kind ==
      aegis_access::RequestAttributionKind::kProfileOnly) {
    if (profile_only_render_process_id_.has_value()) {
      return BuildBrowserOwnedProfileOnlyRequestMetadata(
          profile_, *profile_only_render_process_id_);
    }
    CHECK(profile_only_storage_partition_);
    return BuildBrowserOwnedProfileRequestMetadata(
        profile_, profile_only_storage_partition_);
  }

  auto wc_getter =
      base::BindRepeating(&content::WebContents::FromFrameTreeNodeId,
                          frame_tree_node_id_);
  return BuildBrowserOwnedRequestMetadata(profile_, wc_getter,
                                          frame_tree_node_id_, navigation_id_);
}

AccessProxyingURLLoaderFactory::RequestDisposition
AccessProxyingURLLoaderFactory::EvaluateUrl(
    const GURL& request_url,
    const std::optional<std::string>& stable_request_id,
    int* net_error,
    aegis_access::RequestOwnershipRecord* ownership_record) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  CHECK(net_error);
  CHECK(ownership_record);
  *net_error = net::ERR_BLOCKED_BY_CLIENT;

  if (auto* coordinator = AccessServiceCoordinator::Get(profile_);
      coordinator && !coordinator->CanDispatch(factory_owner_)) {
    *net_error = net::ERR_NETWORK_CHANGED;
    return RequestDisposition::kBlock;
  }

  if (document_.has_value() &&
      !document_->AsRenderFrameHostIfValid()) {
    *net_error = net::ERR_ABORTED;
    return RequestDisposition::kBlock;
  }

  AccessPublishedRequestRuntime* runtime =
      AccessPublishedRequestRuntime::Get(profile_);
  const aegis_access::PublishedAccessPolicySnapshot* factory_snapshot =
      runtime ? runtime->GetPublishedPolicySnapshot(factory_owner_)
              : nullptr;

  // A sandboxed HTTP document can have an opaque top-level site. Preserve
  // native behavior without a published policy, but never let a published
  // policy fall through to DIRECT when attribution cannot be established.
  if (!factory_metadata_) {
    if (factory_snapshot && !factory_snapshot->rules.empty()) return RequestDisposition::kBlock;
    if (is_private_factory_) {
      aegis_access::BrowserOwnedRequestMetadata native{
          stable_request_id.value_or(base::Uuid::GenerateRandomV4().AsLowercaseString()),
          factory_owner_, aegis_access::RequestAttributionKind::kProfileOnly, {}, {}, std::nullopt};
      return EvaluatePreparedMetadata(request_url, runtime, std::move(native),
                                      net_error, ownership_record);
    }
    return (factory_snapshot || is_private_factory_) ? RequestDisposition::kBlock : RequestDisposition::kPreserveNative;
  }

  AccessBrowserRequestMetadataResult metadata = CaptureCurrentMetadata();
  if (metadata.status != AccessBrowserRequestMetadataStatus::kOk ||
      !metadata.metadata.has_value()) {
    return (factory_snapshot || is_private_factory_) ? RequestDisposition::kBlock
                            : RequestDisposition::kPreserveNative;
  }

  aegis_access::BrowserOwnedRequestMetadata evaluated_metadata =
      std::move(*metadata.metadata);
  if (!SameAttributionScope(*factory_metadata_, evaluated_metadata)) {
    return (factory_snapshot || is_private_factory_) ? RequestDisposition::kBlock
                            : RequestDisposition::kPreserveNative;
  }
  if (stable_request_id.has_value()) {
    evaluated_metadata.request_id = *stable_request_id;
  }

  return EvaluatePreparedMetadata(request_url, runtime,
                                  std::move(evaluated_metadata), net_error,
                                  ownership_record);
}

AccessProxyingURLLoaderFactory::RequestDisposition
AccessProxyingURLLoaderFactory::EvaluatePreparedMetadata(
    const GURL& request_url,
    AccessPublishedRequestRuntime* runtime,
    aegis_access::BrowserOwnedRequestMetadata metadata,
    int* net_error,
    aegis_access::RequestOwnershipRecord* ownership_record) {
  const aegis_access::PublishedAccessPolicySnapshot* snapshot =
      runtime ? runtime->GetPublishedPolicySnapshot(metadata.owner) : nullptr;
  if (!snapshot) {
    return is_private_factory_ ? RequestDisposition::kBlock
                                             : RequestDisposition::kPreserveNative;
  }

  if (is_private_factory_) {
    auto* transport = AccessNetworkContextTransport::Get(profile_);
    const auto common =
        runtime->CaptureCommonGenerationTupleOnUiThread(metadata.owner);
    if (!transport || !common ||
        !transport->HasCurrentPrivatePolicy(metadata.owner, *common)) {
      *net_error = net::ERR_NETWORK_CHANGED;
      return RequestDisposition::kBlock;
    }
  }

  aegis_access::RequestPolicyContextResult context_result =
      aegis_access::CanonicalizeBrowserOwnedRequest(metadata, request_url);
  if (!context_result.context.has_value()) {
    return RequestDisposition::kBlock;
  }

  const aegis_access::PolicyMatchResult match =
      aegis_access::EvaluateAccessPolicy(*context_result.context, *snapshot);
  const MatchedPolicyDisposition policy_disposition =
      ClassifyPolicyMatch(match);
  if (policy_disposition == MatchedPolicyDisposition::kPreserveNative) {
    if (!is_private_factory_) return RequestDisposition::kPreserveNative;
    auto common = runtime->CaptureCommonGenerationTupleOnUiThread(metadata.owner);
    auto* dispatch = AccessRequestDispatchState::GetOrCreate(profile_);
    if (!common || !dispatch) return RequestDisposition::kBlock;
    auto record = context_result.context->ToOwnershipRecord(*common);
    record.route = aegis_access::RequestOwnershipRoute::kNative;
    const auto barrier = dispatch->barriers().EvaluateRequest(record);
    if (barrier.status != aegis_access::RequestDispatchBarrierStatus::kOk ||
        barrier.decision != aegis_access::RequestDispatchDecision::kAllow ||
        dispatch->ownership().Register(record) != aegis_access::RequestOwnershipStatus::kOk)
      return RequestDisposition::kBlock;
    *ownership_record = std::move(record);
    return RequestDisposition::kDispatchControlled;
  }
  if (policy_disposition == MatchedPolicyDisposition::kBlock) {
    return RequestDisposition::kBlock;
  }
  auto* transport = AccessNetworkContextTransport::Get(profile_);
  if (transport && !transport->PrivateEndpoints(metadata.owner).empty() &&
      !is_private_factory_) {
    *net_error = net::ERR_PROXY_CONNECTION_FAILED;
    return RequestDisposition::kBlock;
  }

  ProxyDispatchPreparation preparation = PrepareProxyDispatch(
      profile_, runtime, metadata, *snapshot, *context_result.context, match);
  if (!preparation.ownership_record.has_value()) {
    *net_error = preparation.net_error;
    return RequestDisposition::kBlock;
  }

  *ownership_record = std::move(*preparation.ownership_record);
  return RequestDisposition::kDispatchControlled;
}

void AccessProxyingURLLoaderFactory::CreateLoaderAndStart(
    mojo::PendingReceiver<network::mojom::URLLoader> loader_receiver,
    int32_t request_id,
    uint32_t options,
    const network::ResourceRequest& request,
    mojo::PendingRemote<network::mojom::URLLoaderClient> client,
    const net::MutableNetworkTrafficAnnotationTag& traffic_annotation) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!target_factory_.is_bound() && !private_target_factory_.is_bound()) {
    BlockRequest(std::move(loader_receiver), std::move(client),
                 net::ERR_FAILED);
    return;
  }

  if (private_target_factory_.is_bound()) {
    auto start = std::make_unique<PendingStart>(
        this, std::move(loader_receiver), request_id, options, request,
        std::move(client), traffic_annotation);
    auto pending = start->weak_factory.GetWeakPtr();
    pending_starts_.insert(std::move(start));
    if (!pending->Observe()) {
      FinishPendingStart(pending.get());
      return;
    }
    const auto local_group = SelectedLocalCoreGroup(request.url);
    if (local_group) {
      auto* controller = AccessSiteProxyBubbleController::GetOrCreate(profile_);
      auto* runtime = AccessPublishedRequestRuntime::Get(profile_);
      const auto* policy = runtime->GetPublishedPolicySnapshot(factory_owner_);
      controller->EnsureLocalCoreForRequest(
          factory_owner_, *local_group,
          base::BindOnce(&AccessProxyingURLLoaderFactory::OnRequestCoreReady,
                         weak_factory_.GetWeakPtr(), pending,
                         policy->policy_generation, *local_group));
      return;
    }
    PublishRequestPolicy(pending);
    return;
  }
  StartEvaluatedRequest(std::move(loader_receiver), request_id, options, request,
                         std::move(client), traffic_annotation);
}

std::optional<std::string> AccessProxyingURLLoaderFactory::SelectedLocalCoreGroup(
    const GURL& target) {
  if (!factory_metadata_ || (document_ && !document_->AsRenderFrameHostIfValid()))
    return std::nullopt;
  const auto metadata = CaptureCurrentMetadata();
  if (!metadata.metadata || !SameAttributionScope(*factory_metadata_, *metadata.metadata))
    return std::nullopt;
  auto* runtime = AccessPublishedRequestRuntime::Get(profile_);
  const auto* policy = runtime ? runtime->GetPublishedPolicySnapshot(factory_owner_) : nullptr;
  const auto request = aegis_access::CanonicalizeBrowserOwnedRequest(*metadata.metadata, target);
  if (!policy || !request.context) return std::nullopt;
  const auto match = aegis_access::EvaluateAccessPolicy(*request.context, *policy);
  if (ClassifyPolicyMatch(match) != MatchedPolicyDisposition::kProxy ||
      match.effective_proxy_group_id != AccessSiteProxyBubbleController::LocalProxyGroup(factory_owner_))
    return std::nullopt;
  return match.effective_proxy_group_id;
}

void AccessProxyingURLLoaderFactory::OnRequestCoreReady(
    base::WeakPtr<PendingStart> pending,
    uint64_t expected_policy_generation,
    std::string expected_group,
    bool ready) {
  if (!pending) {
    return;
  }
  if (!pending->IsConnected()) {
    FinishPendingStart(pending.get());
    return;
  }
  auto* runtime = AccessPublishedRequestRuntime::Get(profile_);
  const auto* policy = runtime ? runtime->GetPublishedPolicySnapshot(factory_owner_) : nullptr;
  // A pending readiness callback grants no route to a replacement document,
  // a new navigation, or a policy that changed while the core was preparing.
  if (!ready || !policy ||
      policy->policy_generation != expected_policy_generation ||
      SelectedLocalCoreGroup(pending->request.url) != expected_group ||
      !private_target_factory_.is_bound()) {
    auto endpoints = pending->TakeEndpoints();
    BlockRequest(std::move(endpoints.first), std::move(endpoints.second),
                 ready ? net::ERR_NETWORK_CHANGED
                       : net::ERR_PROXY_CONNECTION_FAILED);
    FinishPendingStart(pending.get());
    return;
  }
  PublishRequestPolicy(pending);
}

void AccessProxyingURLLoaderFactory::PublishRequestPolicy(
    base::WeakPtr<PendingStart> pending) {
  if (!pending) {
    return;
  }
  if (!pending->IsConnected()) {
    FinishPendingStart(pending.get());
    return;
  }
  auto* runtime = AccessPublishedRequestRuntime::Get(profile_);
  auto* transport = AccessNetworkContextTransport::Get(profile_);
  const auto* policy =
      runtime ? runtime->GetPublishedPolicySnapshot(factory_owner_) : nullptr;
  const auto common = runtime
      ? runtime->CaptureCommonGenerationTupleOnUiThread(factory_owner_)
      : std::nullopt;
  if (!transport || !policy || !common) {
    auto endpoints = pending->TakeEndpoints();
    BlockRequest(std::move(endpoints.first), std::move(endpoints.second),
                 net::ERR_NETWORK_CHANGED);
    FinishPendingStart(pending.get());
    return;
  }
  // An open document keeps its factory across network/identity/config
  // changes. Publish the new tuple and wait for the exact ACK before
  // stamping either native or proxy requests with that tuple.
  transport->PublishPrivatePolicy(
      *policy, *common,
      base::BindOnce(&AccessProxyingURLLoaderFactory::OnRequestPolicyReady,
                     weak_factory_.GetWeakPtr(), pending, *common));
}

void AccessProxyingURLLoaderFactory::OnRequestPolicyReady(
    base::WeakPtr<PendingStart> pending,
    aegis_access::GenerationTuple expected,
    bool accepted) {
  if (!pending) {
    return;
  }
  if (!pending->IsConnected()) {
    FinishPendingStart(pending.get());
    return;
  }
  auto* runtime = AccessPublishedRequestRuntime::Get(profile_);
  const auto current = runtime
      ? runtime->CaptureCommonGenerationTupleOnUiThread(factory_owner_)
      : std::nullopt;
  if (!accepted || !current || *current != expected ||
      !private_target_factory_.is_bound()) {
    auto endpoints = pending->TakeEndpoints();
    BlockRequest(std::move(endpoints.first), std::move(endpoints.second),
                 net::ERR_NETWORK_CHANGED);
  } else {
    auto endpoints = pending->TakeEndpoints();
    StartEvaluatedRequest(
        std::move(endpoints.first), pending->request_id, pending->options,
        pending->request, std::move(endpoints.second), pending->traffic_annotation);
  }
  FinishPendingStart(pending.get());
}

void AccessProxyingURLLoaderFactory::FinishPendingStart(PendingStart* pending) {
  // Keep the factory alive while StartEvaluatedRequest can remove a failed
  // tracked request, including when its public factory receiver has closed.
  const auto found = pending_starts_.find(pending);
  CHECK(found != pending_starts_.end());
  pending_starts_.erase(found);
  MaybeDestroySelf();
}

void AccessProxyingURLLoaderFactory::PrepareRedirectPolicy(
    const GURL& redirect_url, aegis_access::GenerationTuple expected,
    base::OnceCallback<void(bool)> completion) {
  // A redirect may select a saved Website whose core was not needed for the
  // initial native URL. Preserve the request's common generation while waiting.
  expected.selection_generation = 0;
  auto* runtime = AccessPublishedRequestRuntime::Get(profile_);
  auto* transport = AccessNetworkContextTransport::Get(profile_);
  const auto current = runtime
      ? runtime->CaptureCommonGenerationTupleOnUiThread(factory_owner_)
      : std::nullopt;
  if (!is_private_factory_ || !transport || !current || *current != expected) {
    std::move(completion).Run(false);
    return;
  }
  const auto local_group = SelectedLocalCoreGroup(redirect_url);
  if (!local_group) {
    std::move(completion).Run(
        transport->HasCurrentPrivatePolicy(factory_owner_, *current));
    return;
  }
  auto* controller = AccessSiteProxyBubbleController::GetOrCreate(profile_);
  if (!controller) {
    std::move(completion).Run(false);
    return;
  }
  controller->EnsureLocalCoreForRequest(
      factory_owner_, *local_group,
      base::BindOnce(&AccessProxyingURLLoaderFactory::OnRedirectCoreReady,
                     weak_factory_.GetWeakPtr(), redirect_url, expected,
                     *local_group, std::move(completion)));
}

void AccessProxyingURLLoaderFactory::OnRedirectCoreReady(
    GURL redirect_url, aegis_access::GenerationTuple expected,
    std::string expected_group, base::OnceCallback<void(bool)> completion,
    bool ready) {
  auto* runtime = AccessPublishedRequestRuntime::Get(profile_);
  auto* transport = AccessNetworkContextTransport::Get(profile_);
  const auto* policy = runtime
      ? runtime->GetPublishedPolicySnapshot(factory_owner_) : nullptr;
  const auto current = runtime
      ? runtime->CaptureCommonGenerationTupleOnUiThread(factory_owner_)
      : std::nullopt;
  if (!ready || !transport || !policy || !current || *current != expected ||
      SelectedLocalCoreGroup(redirect_url) != expected_group) {
    std::move(completion).Run(false);
    return;
  }
  // Existing request/control pipes can outlive factory admission. Publish on
  // the private Context without requiring its factory admission pipe to live.
  transport->PublishPrivatePolicy(
      *policy, *current,
      base::BindOnce(&AccessProxyingURLLoaderFactory::OnRedirectPolicyReady,
                     weak_factory_.GetWeakPtr(), std::move(redirect_url),
                     expected, std::move(expected_group),
                     std::move(completion)));
}

void AccessProxyingURLLoaderFactory::OnRedirectPolicyReady(
    GURL redirect_url, aegis_access::GenerationTuple expected,
    std::string expected_group, base::OnceCallback<void(bool)> completion,
    bool accepted) {
  auto* runtime = AccessPublishedRequestRuntime::Get(profile_);
  auto* transport = AccessNetworkContextTransport::Get(profile_);
  const auto current = runtime
      ? runtime->CaptureCommonGenerationTupleOnUiThread(factory_owner_)
      : std::nullopt;
  std::move(completion).Run(
      accepted && current && *current == expected && transport &&
      SelectedLocalCoreGroup(redirect_url) == expected_group &&
      transport->HasCurrentPrivatePolicy(factory_owner_, expected));
}

void AccessProxyingURLLoaderFactory::StartEvaluatedRequest(
    mojo::PendingReceiver<network::mojom::URLLoader> loader_receiver,
    int32_t request_id, uint32_t options,
    const network::ResourceRequest& request,
    mojo::PendingRemote<network::mojom::URLLoaderClient> client,
    const net::MutableNetworkTrafficAnnotationTag& traffic_annotation) {

  int net_error = net::ERR_BLOCKED_BY_CLIENT;
  aegis_access::RequestOwnershipRecord ownership_record;
  const RequestDisposition disposition =
      EvaluateRequest(request, &net_error, &ownership_record);
  if (disposition == RequestDisposition::kPreserveNative) {
    ForwardNative(std::move(loader_receiver), request_id, options, request,
                  std::move(client), traffic_annotation);
    return;
  }
  if (disposition == RequestDisposition::kBlock) {
    BlockRequest(std::move(loader_receiver), std::move(client), net_error);
    return;
  }

  AccessRequestDispatchState* dispatch_state =
      AccessRequestDispatchState::Get(profile_);
  CHECK(dispatch_state);

  auto tracked = std::make_unique<AccessProxyingURLTrackedRequest>(
      this, dispatch_state, ownership_record);
  AccessProxyingURLTrackedRequest* tracked_ptr = tracked.get();
  requests_.emplace(std::move(tracked));

  const aegis_access::RequestOwnershipStatus dispatch_status =
      tracked_ptr->MarkDispatched();
  if (dispatch_status != aegis_access::RequestOwnershipStatus::kOk) {
    dispatch_state->ownership().Complete(
        ownership_record.request_id, ownership_record.owner,
        ownership_record.generations);
    BlockRequest(std::move(loader_receiver), std::move(client),
                 net::ERR_PROXY_CONNECTION_FAILED);
    RemoveRequest(tracked_ptr);
    return;
  }

  tracked_ptr->Start(std::move(loader_receiver), request_id, options, request,
                     std::move(client), traffic_annotation);
}

void AccessProxyingURLLoaderFactory::Clone(
    mojo::PendingReceiver<network::mojom::URLLoaderFactory> loader_receiver) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  proxy_receivers_.Add(this, std::move(loader_receiver));
}

void AccessProxyingURLLoaderFactory::StartTargetRequest(
    mojo::PendingReceiver<network::mojom::URLLoader> loader_receiver,
    int32_t request_id,
    uint32_t options,
    const network::ResourceRequest& request,
    mojo::PendingRemote<network::mojom::URLLoaderClient> client,
    const net::MutableNetworkTrafficAnnotationTag& traffic_annotation,
    const aegis_access::RequestOwnershipRecord& ownership,
    mojo::PendingReceiver<network::mojom::AegisAccessURLLoaderControl> control) {
  if (private_target_factory_.is_bound()) {
    auto envelope = BuildEnvelope(ownership, request.url, request.method, 0);
    if (!envelope) {
      BlockRequest(std::move(loader_receiver), std::move(client), net::ERR_BLOCKED_BY_CLIENT);
      return;
    }
    auto routed_request = network::mojom::AegisAccessRoutedRequest::New();
    routed_request->request = request;
    routed_request->envelope = std::move(envelope);
    private_target_factory_->CreateLoaderAndStartWithRoute(std::move(loader_receiver),
        std::move(control), request_id, options,
        std::move(routed_request),
        std::move(client), traffic_annotation);
    return;
  }
  ForwardNative(std::move(loader_receiver), request_id, options, request,
                std::move(client), traffic_annotation);
}

network::mojom::AegisAccessRequestEnvelopePtr AccessProxyingURLLoaderFactory::BuildEnvelope(
    const aegis_access::RequestOwnershipRecord& ownership, const GURL& target,
    const std::string& method, uint32_t hop) {
  if (!private_context_ || private_context_->incarnation().empty()) return nullptr;
  auto* runtime = AccessPublishedRequestRuntime::Get(profile_);
  const auto* policy = runtime ? runtime->GetPublishedPolicySnapshot(ownership.owner) : nullptr;
  if (!policy || policy->policy_generation != ownership.generations.policy_generation) return nullptr;
  auto attribution = !ownership.document_token.empty()
      ? aegis_access::RequestAttributionKind::kDocument
      : !ownership.pending_navigation_token.empty()
          ? aegis_access::RequestAttributionKind::kPendingNavigation
          : aegis_access::RequestAttributionKind::kProfileOnly;
  aegis_access::BrowserOwnedRequestMetadata metadata{ownership.request_id, ownership.owner,
      attribution, ownership.document_token, ownership.pending_navigation_token, std::nullopt};
  if (ownership.site_ownership_reliable)
    metadata.top_frame_site = net::SchemefulSite(GURL(ownership.top_level_site));
  auto canonical = aegis_access::CanonicalizeBrowserOwnedRequest(metadata, target);
  if (!canonical.context) return nullptr;
  const auto match = aegis_access::EvaluateAccessPolicy(*canonical.context, *policy);
  auto envelope = network::mojom::AegisAccessRequestEnvelope::New();
  envelope->request_token = ownership.request_id;
  envelope->incarnation = private_context_->incarnation();
  envelope->hop = hop;
  envelope->target = target;
  envelope->method = method;
  const auto& g = ownership.generations;
  envelope->generations = network::mojom::AegisAccessGenerations::New(
      g.policy_generation, g.identity_generation, g.selection_generation,
      g.network_epoch, g.base_proxy_config_generation);
  if (match.effective_mode == aegis_access::AccessMode::kProxy) {
    auto* transport = AccessNetworkContextTransport::Get(profile_);
    const auto endpoint = transport ? transport->CaptureSelectedProxyEndpoint(
        ownership.owner, match.effective_proxy_group_id, canonical.context->exact_host())
        : std::nullopt;
    if (!endpoint || endpoint->generations != g) return nullptr;
    envelope->registration_id = endpoint->registration_id;
  } else if ((match.effective_mode != aegis_access::AccessMode::kNone &&
              match.effective_mode != aegis_access::AccessMode::kDirect) || g.selection_generation) {
    return nullptr;
  }
  return envelope;
}

void AccessProxyingURLLoaderFactory::ForwardNative(
    mojo::PendingReceiver<network::mojom::URLLoader> loader_receiver,
    int32_t request_id,
    uint32_t options,
    const network::ResourceRequest& request,
    mojo::PendingRemote<network::mojom::URLLoaderClient> client,
    const net::MutableNetworkTrafficAnnotationTag& traffic_annotation) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  DCHECK(target_factory_.is_bound());
  target_factory_->CreateLoaderAndStart(
      std::move(loader_receiver), request_id, options, request,
      std::move(client), traffic_annotation);
}

// static
void AccessProxyingURLLoaderFactory::BlockRequest(
    mojo::PendingReceiver<network::mojom::URLLoader> loader_receiver,
    mojo::PendingRemote<network::mojom::URLLoaderClient> client,
    int net_error) {
  loader_receiver.reset();
  mojo::Remote<network::mojom::URLLoaderClient> client_remote(std::move(client));
  if (client_remote.is_bound()) {
    client_remote->OnComplete(network::URLLoaderCompletionStatus(net_error));
  }
}

void AccessProxyingURLLoaderFactory::RemoveRequest(AccessProxyingURLTrackedRequest* request) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto it = requests_.find(request);
  CHECK(it != requests_.end());
  requests_.erase(it);
  MaybeDestroySelf();
}

void AccessProxyingURLLoaderFactory::OnTargetFactoryError() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  target_factory_.reset();
  private_target_factory_.reset();
  proxy_receivers_.Clear();
  MaybeDestroySelf();
}

void AccessProxyingURLLoaderFactory::OnProxyBindingError() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  MaybeDestroySelf();
}

void AccessProxyingURLLoaderFactory::MaybeDestroySelf() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!proxy_receivers_.empty() || !requests_.empty() || !pending_starts_.empty() ||
      !on_disconnect_) {
    return;
  }
  std::move(on_disconnect_).Run(this);
}

}  // namespace aegis::access
