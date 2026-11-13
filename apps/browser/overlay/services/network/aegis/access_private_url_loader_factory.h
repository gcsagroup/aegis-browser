// Copyright 2026 GCSA
#ifndef SERVICES_NETWORK_AEGIS_ACCESS_PRIVATE_URL_LOADER_FACTORY_H_
#define SERVICES_NETWORK_AEGIS_ACCESS_PRIVATE_URL_LOADER_FACTORY_H_

#include <map>
#include <memory>
#include <set>
#include <string>
#include "base/functional/callback.h"
#include "base/component_export.h"
#include "base/memory/weak_ptr.h"
#include "mojo/public/cpp/bindings/receiver_set.h"
#include "services/network/aegis/access_request_route_state.h"
#include "services/network/cors/cors_url_loader_factory_owner.h"
#include "services/network/public/mojom/aegis_access_route.mojom.h"
#include "services/network/public/mojom/url_loader_factory.mojom.h"
#include "services/network/public/mojom/network_context.mojom-forward.h"

namespace network {
class NetworkContext;
class ResourceSchedulerClient;
namespace cors {
class CorsURLLoaderFactory;
class OriginAccessList;
}
// Created only by the Browser-owned NetworkContext API. Its fixed attribution
// and private receiver are never exposed through renderer URLLoaderFactory.
class COMPONENT_EXPORT(NETWORK_SERVICE) AccessPrivateURLLoaderFactory final
    : public mojom::AegisAccessURLLoaderFactory,
      public cors::CorsURLLoaderFactoryOwner {
 public:
  AccessPrivateURLLoaderFactory(NetworkContext* context,
      mojom::URLLoaderFactoryParamsPtr params,
      scoped_refptr<ResourceSchedulerClient> scheduler,
      const cors::OriginAccessList* origin_access_list,
      base::WeakPtr<AccessRouteRegistry> registry,
      aegis_access::BrowserOwnedRequestMetadata binding,
      std::string incarnation,
      mojo::PendingReceiver<mojom::AegisAccessURLLoaderFactory> receiver,
      base::OnceCallback<void(AccessPrivateURLLoaderFactory*)> on_destroy);
  ~AccessPrivateURLLoaderFactory() override;
  void CreateLoaderAndStartWithRoute(
      mojo::PendingReceiver<mojom::URLLoader> loader,
      mojo::PendingReceiver<mojom::AegisAccessURLLoaderControl> control,
      int32_t request_id, uint32_t options,
      mojom::AegisAccessRoutedRequestPtr request,
      mojo::PendingRemote<mojom::URLLoaderClient> client,
      const net::MutableNetworkTrafficAnnotationTag& annotation) override;
  void Clone(mojo::PendingReceiver<mojom::AegisAccessURLLoaderFactory> receiver)
      override;
  bool HasAdditionalReferences() const override;
  void DestroyURLLoaderFactory(cors::CorsURLLoaderFactory* factory) override;
  bool ignore_factory_reset() const { return ignore_factory_reset_; }
  void ClearBindings();

 private:
  class Request;
  void RemoveRequest(const std::string& token);
  void OnDisconnect();
  const base::WeakPtr<AccessRouteRegistry> registry_;
  const aegis_access::BrowserOwnedRequestMetadata binding_;
  const bool ignore_factory_reset_;
  const std::string incarnation_;
  base::OnceCallback<void(AccessPrivateURLLoaderFactory*)> on_destroy_;
  std::unique_ptr<cors::CorsURLLoaderFactory> cors_factory_;
  mojo::ReceiverSet<mojom::AegisAccessURLLoaderFactory> receivers_;
  std::set<std::string> used_tokens_;
  std::map<std::string, std::unique_ptr<Request>> requests_;
  base::WeakPtrFactory<AccessPrivateURLLoaderFactory> weak_factory_{this};
};
}  // namespace network
#endif  // SERVICES_NETWORK_AEGIS_ACCESS_PRIVATE_URL_LOADER_FACTORY_H_
