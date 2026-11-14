// Copyright 2026 GCSA
#ifndef SERVICES_NETWORK_AEGIS_ACCESS_REQUEST_ROUTE_STATE_H_
#define SERVICES_NETWORK_AEGIS_ACCESS_REQUEST_ROUTE_STATE_H_

#include "base/memory/ref_counted.h"
#include "services/network/aegis/access_route_registry.h"

namespace network {
// One private-factory request, shared only by its CORS loader, internal
// preflight and net loader. No fields are stored in renderer ResourceRequest.
// The factory validates the original Browser binding before constructing this.
class AccessRequestRouteState : public base::RefCounted<AccessRequestRouteState> {
 public:
  static scoped_refptr<AccessRequestRouteState> Create(
      base::WeakPtr<AccessRouteRegistry> registry,
      aegis_access::BrowserOwnedRequestMetadata metadata, GURL target,
      std::string method, AccessRouteRegistry::Expectation expected,
      int* initial_error = nullptr);
  AccessRouteRegistry::Result BeginSend(const GURL& target,
                                        const std::string& method,
                                        bool is_internal_preflight);
  // Called for the actual request, never its OPTIONS child. Merely seeing a
  // redirect revokes the old decision, including when that decision was native.
  bool ObserveRedirect(const GURL& target, const std::string& method);
  // Called only by the private Browser control. The CORS URLLoader still
  // validates headers and new_url before the underlying redirect can proceed.
  bool ApproveRedirect(uint32_t hop, const GURL& target,
                       const std::string& method,
                       AccessRouteRegistry::Expectation expected);
  uint32_t hop() const { return hop_; }
  // Cache policy only; BeginSend still validates authority at dispatch.
  bool uses_managed_route() const { return !expected_.registration_id.empty(); }

 private:
  friend class base::RefCounted<AccessRequestRouteState>;
  AccessRequestRouteState(base::WeakPtr<AccessRouteRegistry> registry,
      aegis_access::BrowserOwnedRequestMetadata metadata, GURL target,
      std::string method, AccessRouteRegistry::Expectation expected);
  ~AccessRequestRouteState();

  base::WeakPtr<AccessRouteRegistry> registry_;
  const aegis_access::BrowserOwnedRequestMetadata metadata_;
  GURL target_;
  std::string method_;
  AccessRouteRegistry::Expectation expected_;
  uint32_t hop_ = 0;
  bool sent_for_hop_ = false;
  struct PendingRedirect {
    GURL target;
    std::string method;
  };
  std::optional<PendingRedirect> pending_redirect_;
  SEQUENCE_CHECKER(sequence_checker_);
};
}  // namespace network
#endif  // SERVICES_NETWORK_AEGIS_ACCESS_REQUEST_ROUTE_STATE_H_
