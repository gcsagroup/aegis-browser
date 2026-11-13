// Copyright 2026 GCSA
#ifndef SERVICES_NETWORK_AEGIS_ACCESS_ROUTE_REGISTRY_H_
#define SERVICES_NETWORK_AEGIS_ACCESS_ROUTE_REGISTRY_H_

#include <map>
#include <optional>
#include <string>
#include "base/sequence_checker.h"
#include "base/memory/weak_ptr.h"
#include "components/aegis_access/access_policy_evaluator.h"
#include "net/base/net_errors.h"
#include "net/base/auth.h"
#include "net/http/access_proxy_route.h"

namespace network {
// Owned by one NetworkContext and called only on its network sequence. Inputs
// come from the Browser-only factory/publication channel, never ResourceRequest
// fields. This registry does not confer Browser provenance on arbitrary values:
// the private factory must also enforce its process/document binding.
class AccessRouteRegistry {
 public:
  struct Snapshot {
    aegis_access::PublishedAccessPolicySnapshot policy;
    // Selection is per group and must be zero here. Other counters are live.
    aegis_access::GenerationTuple common_generations;
    std::map<std::string, scoped_refptr<net::AccessProxyRoute>> routes;
    // Explicit failed/not-yet-ready groups remain PROXY policy, without a
    // fabricated endpoint. Zero only precedes the first group selection.
    std::map<std::string, uint64_t> unavailable_groups;
  };
  struct Expectation {
    std::string incarnation;
    aegis_access::GenerationTuple generations;
    // Empty for native or an unavailable group; never interpreted as an endpoint.
    std::string registration_id;
  };
  struct Result {
    int net_error = net::ERR_BLOCKED_BY_CLIENT;
    scoped_refptr<net::AccessProxyRoute> route;
  };
  AccessRouteRegistry(aegis_access::OwnershipKey owner, std::string incarnation);
  ~AccessRouteRegistry();
  AccessRouteRegistry(const AccessRouteRegistry&) = delete;
  AccessRouteRegistry& operator=(const AccessRouteRegistry&) = delete;

  // Atomically installs a complete candidate. Failed installs leave the prior
  // snapshot intact; Browser publication barriers remain independently active.
  // Even an empty policy must be explicitly installed before native dispatch.
  bool Install(uint64_t sequence, Snapshot snapshot);
  void EnterRestoring();
  base::WeakPtr<AccessRouteRegistry> GetWeakPtr() {
    DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
    return weak_factory_.GetWeakPtr();
  }
  Result Resolve(const aegis_access::BrowserOwnedRequestMetadata& metadata,
                 const GURL& target, const Expectation& expected) const;

 private:
  const aegis_access::OwnershipKey owner_;
  const std::string incarnation_;
  uint64_t installed_sequence_ = 0;
  std::optional<aegis_access::GenerationTuple> high_water_generations_;
  std::optional<aegis_access::PublishedAccessPolicySnapshot> last_policy_;
  std::map<std::string, uint64_t> selection_high_water_;
  struct RegistrationBinding {
    std::string group;
    net::ProxyChain proxy_chain;
    // Process-local inbound secret binding; never serialized or logged.
    std::optional<net::AuthCredentials> local_credentials;
  };
  std::map<std::string, RegistrationBinding> registrations_;
  std::optional<Snapshot> snapshot_;
  SEQUENCE_CHECKER(sequence_checker_);
  base::WeakPtrFactory<AccessRouteRegistry> weak_factory_{this};
};
}  // namespace network
#endif  // SERVICES_NETWORK_AEGIS_ACCESS_ROUTE_REGISTRY_H_
