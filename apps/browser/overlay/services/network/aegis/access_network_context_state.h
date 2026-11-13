// Copyright 2026 GCSA
#ifndef SERVICES_NETWORK_AEGIS_ACCESS_NETWORK_CONTEXT_STATE_H_
#define SERVICES_NETWORK_AEGIS_ACCESS_NETWORK_CONTEXT_STATE_H_
#include <memory>
#include <set>
#include <string_view>
#include "base/component_export.h"
#include "base/containers/unique_ptr_adapters.h"
#include "base/memory/raw_ptr.h"
#include "services/network/aegis/access_private_url_loader_factory.h"
#include "services/network/aegis/access_route_wire.h"

namespace network {
// One owner/incarnation per NetworkContext. Thin NetworkContext Mojo methods
// delegate here; neither the registry nor private factories are renderer APIs.
class COMPONENT_EXPORT(NETWORK_SERVICE) AccessNetworkContextState {
 public:
  AccessNetworkContextState(NetworkContext* context,
                           const cors::OriginAccessList* origin_access_list);
  ~AccessNetworkContextState();
  void ResetFactories();
  bool Install(const mojom::AegisAccessSnapshot& snapshot);
  bool EnterRestoring(const aegis_access::OwnershipKey& owner,
                      std::string_view incarnation);
  bool CreateFactory(mojom::URLLoaderFactoryParamsPtr params,
      scoped_refptr<ResourceSchedulerClient> scheduler,
      mojom::AegisAccessFactoryBindingPtr binding,
      mojo::PendingReceiver<mojom::AegisAccessURLLoaderFactory> receiver);
 private:
  void DestroyFactory(AccessPrivateURLLoaderFactory* factory);
  const raw_ptr<NetworkContext> context_;
  const raw_ptr<const cors::OriginAccessList> origin_access_list_;
  std::optional<aegis_access::OwnershipKey> owner_;
  std::string incarnation_;
  std::unique_ptr<AccessRouteRegistry> registry_;
  std::set<std::unique_ptr<AccessPrivateURLLoaderFactory>, base::UniquePtrComparator>
      factories_;
  base::WeakPtrFactory<AccessNetworkContextState> weak_factory_{this};
};
}  // namespace network
#endif  // SERVICES_NETWORK_AEGIS_ACCESS_NETWORK_CONTEXT_STATE_H_
