// Copyright 2026 GCSA
#include "services/network/aegis/access_network_context_state.h"
#include <vector>
#include "base/check.h"
#include "base/functional/bind.h"
#include "services/network/public/mojom/network_context.mojom.h"
#include "services/network/resource_scheduler/resource_scheduler_client.h"

namespace network {
namespace {
aegis_access::OwnershipKey Owner(const mojom::AegisAccessOwner& wire) {
  using Channel = aegis_access::ChannelNamespace;
  Channel channel = Channel::kInvalid;
  switch (wire.channel) {
    case mojom::AegisAccessChannel::kDev: channel = Channel::kDev; break;
    case mojom::AegisAccessChannel::kAlpha: channel = Channel::kAlpha; break;
    case mojom::AegisAccessChannel::kBeta: channel = Channel::kBeta; break;
    case mojom::AegisAccessChannel::kRelease: channel = Channel::kRelease; break;
  }
  return {channel, wire.profile_token, wire.storage_partition_token};
}
}  // namespace
AccessNetworkContextState::AccessNetworkContextState(
    NetworkContext* context, const cors::OriginAccessList* origin_access_list)
    : context_(context), origin_access_list_(origin_access_list) {
  CHECK(context_);
  CHECK(origin_access_list_);
}
AccessNetworkContextState::~AccessNetworkContextState() {
  weak_factory_.InvalidateWeakPtrs();
  if (registry_) registry_->EnterRestoring();
  factories_.clear();
}
void AccessNetworkContextState::ResetFactories() {
  // Match NetworkContext's original factory contract, including extension
  // service-worker factories that must survive webRequest-triggered resets.
  // ClearBindings() may synchronously remove an idle factory. Match the
  // original NetworkContext iteration without invalidating this set's cursor.
  std::vector<AccessPrivateURLLoaderFactory*> reset;
  for (const auto& factory : factories_) {
    if (!factory->ignore_factory_reset()) reset.push_back(factory.get());
  }
  for (auto* factory : reset) factory->ClearBindings();
}
bool AccessNetworkContextState::Install(
    const mojom::AegisAccessSnapshot& snapshot) {
  auto decoded = DecodeAccessRouteSnapshot(snapshot);
  if (!decoded || (owner_ && (*owner_ != decoded->owner ||
                             incarnation_ != decoded->incarnation))) return false;
  if (registry_) {
    return registry_->Install(decoded->sequence, std::move(decoded->snapshot));
  }
  auto registry = std::make_unique<AccessRouteRegistry>(decoded->owner,
                                                       decoded->incarnation);
  if (!registry->Install(decoded->sequence, std::move(decoded->snapshot))) return false;
  owner_ = std::move(decoded->owner);
  incarnation_ = std::move(decoded->incarnation);
  registry_ = std::move(registry);
  return true;
}
bool AccessNetworkContextState::EnterRestoring(
    const aegis_access::OwnershipKey& owner, std::string_view incarnation) {
  if (!registry_ || !owner_ || *owner_ != owner || incarnation_ != incarnation)
    return false;
  registry_->EnterRestoring();
  return true;
}
bool AccessNetworkContextState::CreateFactory(
    mojom::URLLoaderFactoryParamsPtr params,
    scoped_refptr<ResourceSchedulerClient> scheduler,
    mojom::AegisAccessFactoryBindingPtr binding,
    mojo::PendingReceiver<mojom::AegisAccessURLLoaderFactory> receiver) {
  if (!registry_ || !binding || !binding->owner || !params ||
      !receiver.is_valid() || Owner(*binding->owner) != *owner_ ||
      binding->incarnation != incarnation_) return false;
  aegis_access::BrowserOwnedRequestMetadata metadata{
      "binding-validation", *owner_, aegis_access::RequestAttributionKind::kInvalid,
      binding->document_token, binding->pending_navigation_token, std::nullopt};
  switch (binding->attribution) {
    case mojom::AegisAccessAttribution::kDocument:
      metadata.attribution_kind = aegis_access::RequestAttributionKind::kDocument;
      break;
    case mojom::AegisAccessAttribution::kPendingNavigation:
      metadata.attribution_kind = aegis_access::RequestAttributionKind::kPendingNavigation;
      break;
    case mojom::AegisAccessAttribution::kProfileOnly:
      metadata.attribution_kind = aegis_access::RequestAttributionKind::kProfileOnly;
      break;
  }
  if (binding->top_frame_site)
    metadata.top_frame_site = net::SchemefulSite(*binding->top_frame_site);
  if (!aegis_access::CanonicalizeBrowserOwnedRequest(
          metadata, GURL("https://binding-validation.invalid/")).context) return false;
  metadata.request_id.clear();
  factories_.insert(std::make_unique<AccessPrivateURLLoaderFactory>(context_,
      std::move(params), std::move(scheduler), origin_access_list_,
      registry_->GetWeakPtr(), std::move(metadata), incarnation_,
      std::move(receiver), base::BindOnce(&AccessNetworkContextState::DestroyFactory,
                                        weak_factory_.GetWeakPtr())));
  return true;
}
void AccessNetworkContextState::DestroyFactory(
    AccessPrivateURLLoaderFactory* factory) {
  auto found = factories_.find(factory);
  CHECK(found != factories_.end());
  factories_.erase(found);
}
}  // namespace network
