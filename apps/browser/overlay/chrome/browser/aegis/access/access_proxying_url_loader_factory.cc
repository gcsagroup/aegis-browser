// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_proxying_url_loader_factory.h"
#include "chrome/browser/aegis/access/access_proxying_url_tracked_request.h"

#include <memory>
#include <optional>
#include <utility>

#include "base/check.h"
#include "base/functional/bind.h"
#include "base/memory/ptr_util.h"
#include "base/memory/weak_ptr.h"
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
#include "content/public/browser/page.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "net/base/net_errors.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/url_loader_completion_status.h"

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

class BrowserContextData : public base::SupportsUserData::Data {
 public:
  BrowserContextData(const BrowserContextData&) = delete;
  BrowserContextData& operator=(const BrowserContextData&) = delete;
  ~BrowserContextData() override = default;

  static void StartProxying(
      Profile* profile,
      content::FrameTreeNodeId frame_tree_node_id,
      std::optional<int64_t> navigation_id,
      aegis_access::BrowserOwnedRequestMetadata factory_metadata,
      network::URLLoaderFactoryBuilder& factory_builder) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    auto* self =
        static_cast<BrowserContextData*>(profile->GetUserData(kBrowserContextDataKey));
    if (!self) {
      self = new BrowserContextData();
      profile->SetUserData(kBrowserContextDataKey, base::WrapUnique(self));
    }

    auto proxy = std::make_unique<AccessProxyingURLLoaderFactory>(
        profile, frame_tree_node_id, navigation_id, std::move(factory_metadata),
        factory_builder,
        base::BindOnce(&BrowserContextData::RemoveProxy,
                       self->weak_factory_.GetWeakPtr()));
    self->proxies_.emplace(std::move(proxy));
  }

  void RemoveProxy(AccessProxyingURLLoaderFactory* proxy) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    auto it = proxies_.find(proxy);
    CHECK(it != proxies_.end());
    proxies_.erase(it);
  }

 private:
  BrowserContextData() = default;

  std::set<std::unique_ptr<AccessProxyingURLLoaderFactory>,
           base::UniquePtrComparator>
      proxies_;
  base::WeakPtrFactory<BrowserContextData> weak_factory_{this};
};

}  // namespace

AccessProxyingURLLoaderFactory::AccessProxyingURLLoaderFactory(
    Profile* profile,
    content::FrameTreeNodeId frame_tree_node_id,
    std::optional<int64_t> navigation_id,
    aegis_access::BrowserOwnedRequestMetadata factory_metadata,
    network::URLLoaderFactoryBuilder& factory_builder,
    DisconnectCallback on_disconnect)
    : profile_(profile),
      frame_tree_node_id_(frame_tree_node_id),
      navigation_id_(navigation_id),
      factory_metadata_(std::move(factory_metadata)),
      on_disconnect_(std::move(on_disconnect)) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto [loader_receiver, target_factory] = factory_builder.Append();
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
    network::URLLoaderFactoryBuilder& factory_builder) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  std::optional<aegis_access::BrowserOwnedRequestMetadata> metadata =
      CaptureProxyFactoryMetadata(profile, frame, std::nullopt);
  if (!metadata.has_value()) {
    return;
  }

  BrowserContextData::StartProxying(
      profile, frame->GetFrameTreeNodeId(), std::nullopt, std::move(*metadata),
      factory_builder);
}

// static
void AccessProxyingURLLoaderFactory::MaybeProxyWorkerMainResource(
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
      profile, frame->GetFrameTreeNodeId(), std::nullopt, std::move(*metadata),
      factory_builder);
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

  BrowserContextData::StartProxying(profile, frame->GetFrameTreeNodeId(),
                                    navigation_id, std::move(*metadata),
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

  AccessPublishedRequestRuntime* runtime =
      AccessPublishedRequestRuntime::Get(profile_);
  const aegis_access::PublishedAccessPolicySnapshot* factory_snapshot =
      runtime ? runtime->GetPublishedPolicySnapshot(factory_metadata_.owner)
              : nullptr;

  auto wc_getter =
      base::BindRepeating(&content::WebContents::FromFrameTreeNodeId,
                          frame_tree_node_id_);
  AccessBrowserRequestMetadataResult metadata = BuildBrowserOwnedRequestMetadata(
      profile_, wc_getter, frame_tree_node_id_, navigation_id_);
  if (metadata.status != AccessBrowserRequestMetadataStatus::kOk ||
      !metadata.metadata.has_value()) {
    return factory_snapshot ? RequestDisposition::kBlock
                            : RequestDisposition::kPreserveNative;
  }

  aegis_access::BrowserOwnedRequestMetadata evaluated_metadata =
      std::move(*metadata.metadata);
  if (!SameAttributionScope(factory_metadata_, evaluated_metadata)) {
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
