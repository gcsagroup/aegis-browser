// Copyright 2026 GCSA
#ifndef SERVICES_NETWORK_CORS_CORS_URL_LOADER_FACTORY_OWNER_H_
#define SERVICES_NETWORK_CORS_CORS_URL_LOADER_FACTORY_OWNER_H_

namespace network::cors {
class CorsURLLoaderFactory;

// Lifetime contract shared by ordinary prefetch factories and Browser-private
// factories. Neither owner may expose the other's receiver or request path.
class CorsURLLoaderFactoryOwner {
 public:
  virtual ~CorsURLLoaderFactoryOwner() = default;
  virtual bool HasAdditionalReferences() const = 0;
  // Called only after all child loaders and external references are gone.
  // This may synchronously destroy the calling factory and its owner.
  virtual void DestroyURLLoaderFactory(CorsURLLoaderFactory* factory) = 0;
};
}  // namespace network::cors

#endif  // SERVICES_NETWORK_CORS_CORS_URL_LOADER_FACTORY_OWNER_H_
