// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_proxying_url_loader_factory.h"
#include "chrome/browser/aegis/access/access_proxying_url_tracked_request.h"

#include <map>
#include <memory>
#include <optional>
#include <utility>

#include "base/check.h"
#include "base/functional/bind.h"
#include "base/memory/ptr_util.h"
#include "base/memory/weak_ptr.h"
#include "base/task/sequenced_task_runner.h"
#include "base/supports_user_data.h"
#include "chrome/browser/aegis/access/access_browser_request_adapter.h"
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
      mojo::PendingReceiver<network::mojom::URLLoaderFactory> receiver,
      mojo::PendingRemote<network::mojom::URLLoaderFactory> target,
      CompletionCallback on_complete)
      : content::WebContentsObserver(contents),
        profile_(profile),
        frame_id_(frame->GetGlobalId()),
        navigation_id_(navigation_id),
        owner_(std::move(owner)),
        receiver_(std::move(receiver)),
        target_(std::move(target)),
        on_complete_(std::move(on_complete)) {}

  PendingDocumentFactory(const PendingDocumentFactory&) = delete;
  PendingDocumentFactory& operator=(const PendingDocumentFactory&) = delete;
  ~PendingDocumentFactory() override = default;

  mojo::PendingReceiver<network::mojom::URLLoaderFactory> TakeReceiver() {
    return std::move(receiver_);
  }
  mojo::PendingRemote<network::mojom::URLLoaderFactory> TakeTarget() {
    return std::move(target_);
  }
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
  mojo::PendingReceiver<network::mojom::URLLoaderFactory> receiver_;
  mojo::PendingRemote<network::mojom::URLLoaderFactory> target_;
  CompletionCallback on_complete_;
};

class BrowserContextData : public base::SupportsUserData::Data {
 public:
  BrowserContextData(const BrowserContextData&) = delete;
  BrowserContextData& operator=(const BrowserContextData&) = delete;
  ~BrowserContextData() override = default;

  static void StartProxying(
      Profile* profile,
      content::FrameTreeNodeId frame_tree_node_id,
      std::optional<int64_t> navigation_id,
      std::optional<int> profile_only_render_process_id,
      content::StoragePartition* profile_only_storage_partition,
      aegis_access::BrowserOwnedRequestMetadata factory_metadata,
      network::URLLoaderFactoryBuilder& factory_builder) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    BrowserContextData* self = GetOrCreate(profile);
    std::optional<content::WeakDocumentPtr> document;
    if (factory_metadata.attribution_kind ==
        aegis_access::RequestAttributionKind::kDocument) {
      content::WebContents* contents =
          content::WebContents::FromFrameTreeNodeId(frame_tree_node_id);
      content::RenderFrameHost* frame =
          contents ? contents->UnsafeFindFrameByFrameTreeNodeId(
                         frame_tree_node_id)
                   : nullptr;
      if (!frame) {
        return;
      }
      document = frame->GetWeakDocumentPtr();
    }

    auto [receiver, target] = factory_builder.Append();
    const aegis_access::OwnershipKey owner = factory_metadata.owner;
    auto proxy = std::make_unique<AccessProxyingURLLoaderFactory>(
        profile, frame_tree_node_id, navigation_id,
        profile_only_render_process_id, profile_only_storage_partition,
        owner, std::move(factory_metadata), std::move(receiver),
        std::move(target),
        std::move(document),
        base::BindOnce(&BrowserContextData::RemoveProxy,
                       self->weak_factory_.GetWeakPtr()));
    self->proxies_.emplace(std::move(proxy));
  }

  static void StartPendingDocument(
      Profile* profile,
      content::WebContents* contents,
      content::RenderFrameHost* frame,
      int64_t navigation_id,
      aegis_access::OwnershipKey owner,
      network::URLLoaderFactoryBuilder& factory_builder) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    BrowserContextData* self = GetOrCreate(profile);
    auto [receiver, target] = factory_builder.Append();
    const uint64_t pending_id = ++self->next_pending_id_;
    self->pending_documents_.emplace(
        pending_id,
        std::make_unique<PendingDocumentFactory>(
            profile, contents, frame, navigation_id, std::move(owner),
            std::move(receiver),
            std::move(target),
            base::BindOnce(&BrowserContextData::CompletePendingDocument,
                           self->weak_factory_.GetWeakPtr(), pending_id)));
  }

  void RemoveProxy(AccessProxyingURLLoaderFactory* proxy) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    auto it = proxies_.find(proxy);
    CHECK(it != proxies_.end());
    proxies_.erase(it);
  }

  static void StartUnattributedDocument(
      Profile* profile,
      content::RenderFrameHost* frame,
      aegis_access::OwnershipKey owner,
      network::URLLoaderFactoryBuilder& factory_builder) {
    BrowserContextData* self = GetOrCreate(profile);
    auto [receiver, target] = factory_builder.Append();
    auto proxy = std::make_unique<AccessProxyingURLLoaderFactory>(
        profile, frame->GetFrameTreeNodeId(), std::nullopt, std::nullopt,
        /*profile_only_storage_partition=*/nullptr, std::move(owner),
        std::nullopt, std::move(receiver), std::move(target),
        frame->GetWeakDocumentPtr(),
        base::BindOnce(&BrowserContextData::RemoveProxy,
                       self->weak_factory_.GetWeakPtr()));
    self->proxies_.emplace(std::move(proxy));
  }

 private:
  static BrowserContextData* GetOrCreate(Profile* profile) {
    auto* self = static_cast<BrowserContextData*>(
        profile->GetUserData(kBrowserContextDataKey));
    if (!self) {
      self = new BrowserContextData(profile);
      profile->SetUserData(kBrowserContextDataKey, base::WrapUnique(self));
    }
    return self;
  }

  void CompletePendingDocument(
      uint64_t pending_id,
      std::optional<aegis_access::BrowserOwnedRequestMetadata> metadata,
      std::optional<content::WeakDocumentPtr> document) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    auto it = pending_documents_.find(pending_id);
    CHECK(it != pending_documents_.end());
    std::unique_ptr<PendingDocumentFactory> owned = std::move(it->second);
    pending_documents_.erase(it);
    content::RenderFrameHost* frame =
        document ? document->AsRenderFrameHostIfValid() : nullptr;
    if (!frame || !frame->GetPage().IsPrimary() ||
        frame->GetBrowserContext() != profile_) {
      return;  // Closing the unbound receiver fails any queued request.
    }
    if (metadata &&
        (metadata->attribution_kind !=
             aegis_access::RequestAttributionKind::kDocument ||
         metadata->owner != owned->owner())) {
      metadata.reset();
    }

    auto proxy = std::make_unique<AccessProxyingURLLoaderFactory>(
        profile_, frame->GetFrameTreeNodeId(), std::nullopt, std::nullopt,
        /*profile_only_storage_partition=*/nullptr, owned->owner(),
        std::move(metadata),
        owned->TakeReceiver(), owned->TakeTarget(), std::move(document),
        base::BindOnce(&BrowserContextData::RemoveProxy,
                       weak_factory_.GetWeakPtr()));
    proxies_.emplace(std::move(proxy));
  }

  explicit BrowserContextData(Profile* profile) : profile_(profile) {}

  const raw_ptr<Profile> profile_;
  std::set<std::unique_ptr<AccessProxyingURLLoaderFactory>,
           base::UniquePtrComparator>
      proxies_;
  std::map<uint64_t, std::unique_ptr<PendingDocumentFactory>>
      pending_documents_;
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
    DisconnectCallback on_disconnect)
    : profile_(profile),
      frame_tree_node_id_(frame_tree_node_id),
      navigation_id_(navigation_id),
      profile_only_render_process_id_(profile_only_render_process_id),
      profile_only_storage_partition_(profile_only_storage_partition),
      factory_owner_(std::move(factory_owner)),
      factory_metadata_(std::move(factory_metadata)),
      document_(std::move(document)),
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
  target_factory_.Bind(std::move(target_factory));
  target_factory_.set_disconnect_handler(base::BindOnce(
      &AccessProxyingURLLoaderFactory::OnTargetFactoryError,
      base::Unretained(this)));
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
void AccessProxyingURLLoaderFactory::MaybeProxyNavigation(
    Profile* profile,
    content::RenderFrameHost* frame,
    int64_t navigation_id,
    network::URLLoaderFactoryBuilder& factory_builder) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  std::optional<aegis_access::BrowserOwnedRequestMetadata> metadata =
      CaptureProxyFactoryMetadata(profile, frame, navigation_id);
  if (!metadata.has_value() ||
      metadata->attribution_kind !=
          aegis_access::RequestAttributionKind::kPendingNavigation) {
    return;
  }

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
    return factory_snapshot ? RequestDisposition::kBlock
                            : RequestDisposition::kPreserveNative;
  }

  AccessBrowserRequestMetadataResult metadata = CaptureCurrentMetadata();
  if (metadata.status != AccessBrowserRequestMetadataStatus::kOk ||
      !metadata.metadata.has_value()) {
    return factory_snapshot ? RequestDisposition::kBlock
                            : RequestDisposition::kPreserveNative;
  }

  aegis_access::BrowserOwnedRequestMetadata evaluated_metadata =
      std::move(*metadata.metadata);
  if (!SameAttributionScope(*factory_metadata_, evaluated_metadata)) {
    return factory_snapshot ? RequestDisposition::kBlock
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
    return RequestDisposition::kPreserveNative;
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
    return RequestDisposition::kPreserveNative;
  }
  if (policy_disposition == MatchedPolicyDisposition::kBlock) {
    return RequestDisposition::kBlock;
  }

  ProxyDispatchPreparation preparation = PrepareProxyDispatch(
      profile_, runtime, metadata, *snapshot, *context_result.context, match);
  if (!preparation.ownership_record.has_value()) {
    *net_error = preparation.net_error;
    return RequestDisposition::kBlock;
  }

  *ownership_record = std::move(*preparation.ownership_record);
  return RequestDisposition::kDispatchProxy;
}

void AccessProxyingURLLoaderFactory::CreateLoaderAndStart(
    mojo::PendingReceiver<network::mojom::URLLoader> loader_receiver,
    int32_t request_id,
    uint32_t options,
    const network::ResourceRequest& request,
    mojo::PendingRemote<network::mojom::URLLoaderClient> client,
    const net::MutableNetworkTrafficAnnotationTag& traffic_annotation) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!target_factory_.is_bound()) {
    BlockRequest(std::move(loader_receiver), std::move(client),
                 net::ERR_FAILED);
    return;
  }

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
    const net::MutableNetworkTrafficAnnotationTag& traffic_annotation) {
  ForwardNative(std::move(loader_receiver), request_id, options, request,
                std::move(client), traffic_annotation);
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
  proxy_receivers_.Clear();
  MaybeDestroySelf();
}

void AccessProxyingURLLoaderFactory::OnProxyBindingError() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  MaybeDestroySelf();
}

void AccessProxyingURLLoaderFactory::MaybeDestroySelf() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!proxy_receivers_.empty() || !requests_.empty() || !on_disconnect_) {
    return;
  }
  std::move(on_disconnect_).Run(this);
}

}  // namespace aegis::access
