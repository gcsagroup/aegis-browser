// Copyright 2026 GCSA

#ifndef NET_HTTP_ACCESS_PROXY_ROUTE_H_
#define NET_HTTP_ACCESS_PROXY_ROUTE_H_

#include "base/memory/ref_counted.h"
#include "base/sequence_checker.h"
#include "net/base/access_route_isolation_key.h"
#include "net/base/net_export.h"
#include "net/base/proxy_chain.h"
#include "net/http/http_auth_cache.h"

namespace net {

// Network-sequence transport state for one installed Access route. The private
// Network Service registry must authorize owner, incarnation, policy and
// endpoint before attaching this object to a request. This value constructor
// is NOT an authorization or listener-health check.
//
// The installed route and its in-flight requests share a reference. Replacing
// the installed route creates a fresh cache; credentials are never inserted in
// the session's native proxy cache or copied across route incarnations.
class NET_EXPORT AccessProxyRoute : public base::RefCounted<AccessProxyRoute> {
 public:
  // An invalid requested proxy returns null. Callers must fail that request,
  // not interpret this failure as permission to use a native/DIRECT route.
  static scoped_refptr<AccessProxyRoute> Create(
      AccessRouteIsolationKey isolation_key,
      ProxyChain proxy_chain);

  AccessProxyRoute(const AccessProxyRoute&) = delete;
  AccessProxyRoute& operator=(const AccessProxyRoute&) = delete;

  const AccessRouteIsolationKey& isolation_key() const { return isolation_key_; }
  const ProxyChain& proxy_chain() const { return proxy_chain_; }

  // For AUTH_PROXY controllers on this route only. Origin authentication
  // continues to use the native session cache and its existing NAK semantics.
  HttpAuthCache* proxy_auth_cache();

 private:
  friend class base::RefCounted<AccessProxyRoute>;
  AccessProxyRoute(AccessRouteIsolationKey isolation_key, ProxyChain proxy_chain);
  ~AccessProxyRoute();

  const AccessRouteIsolationKey isolation_key_;
  const ProxyChain proxy_chain_;
  HttpAuthCache proxy_auth_cache_;
  SEQUENCE_CHECKER(sequence_checker_);
};

}  // namespace net

#endif  // NET_HTTP_ACCESS_PROXY_ROUTE_H_
