// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_PRIVATE_CONTEXT_CLIENT_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_PRIVATE_CONTEXT_CLIENT_H_

#include <map>
#include <string>
#include <optional>
#include <vector>
#include "base/functional/callback.h"
#include "base/memory/weak_ptr.h"
#include "base/sequence_checker.h"
#include "components/aegis_access/access_route_types.h"
#include "components/aegis_access/access_policy_evaluator.h"
#include "components/aegis_access/access_proxy_route_adapter.h"
#include "net/base/auth.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "services/network/public/mojom/network_context.mojom.h"
#include "services/network/public/mojom/aegis_access_route_types.mojom.h"

namespace aegis::access {
struct AccessPrivateEndpoint {
  aegis_access::RegisteredProxyEndpoint registration;
  std::optional<net::AuthCredentials> local_credentials;
};

// Browser-owned capability for the exact terminal NetworkContext. The raw
// NetworkContext proxy is used only during Initialize, never retained across
// a deferred document commit or Network Service restart.
class AccessPrivateContextClient {
 public:
  explicit AccessPrivateContextClient(aegis_access::OwnershipKey owner);
  ~AccessPrivateContextClient();
  void Initialize(network::mojom::NetworkContext* context,
                  base::OnceCallback<void(bool)> completion);
  void PublishSnapshot(network::mojom::AegisAccessSnapshotPtr snapshot,
                       base::OnceCallback<void(bool)> completion);
  // Encodes the whole validated Browser policy and all registered groups.
  // Network independently evaluates/validates the resulting immutable snapshot.
  void PublishPolicy(const aegis_access::PublishedAccessPolicySnapshot& policy,
      const aegis_access::GenerationTuple& common_generations,
      uint64_t publication_sequence,
      const std::vector<AccessPrivateEndpoint>& endpoints,
      base::OnceCallback<void(bool)> completion);
  void PublishPolicy(const aegis_access::PublishedAccessPolicySnapshot& policy,
      const aegis_access::GenerationTuple& common_generations,
      uint64_t publication_sequence,
      const std::vector<AccessPrivateEndpoint>& endpoints,
      const std::map<std::string, uint64_t>& unavailable_groups,
      base::OnceCallback<void(bool)> completion);
  void BeginRestore(base::OnceCallback<void(bool)> completion);
  void CreateFactory(network::mojom::URLLoaderFactoryParamsPtr params,
      network::mojom::AegisAccessFactoryBindingPtr binding,
      mojo::PendingReceiver<network::mojom::AegisAccessURLLoaderFactory> receiver,
      base::OnceCallback<void(bool)> completion);
  bool is_ready() const { return ready_; }
  network::mojom::AegisAccessOwnerPtr owner_for_binding() const { return owner_.Clone(); }
  const std::string& incarnation() const { return incarnation_; }
  uint64_t published_sequence() const { return published_sequence_; }

 private:
  void OnDisconnect();
  network::mojom::AegisAccessOwnerPtr owner_;
  std::string incarnation_;
  mojo::Remote<network::mojom::AegisAccessContext> context_;
  bool connected_ = false;
  bool ready_ = false;
  bool publication_pending_ = false;
  uint64_t operation_ = 0;
  uint64_t last_requested_sequence_ = 0;
  uint64_t published_sequence_ = 0;
  SEQUENCE_CHECKER(sequence_checker_);
  base::WeakPtrFactory<AccessPrivateContextClient> weak_factory_{this};
};
}  // namespace aegis::access
#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_PRIVATE_CONTEXT_CLIENT_H_
