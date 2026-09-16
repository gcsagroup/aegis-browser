// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_NETWORK_CONTEXT_TRANSPORT_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_NETWORK_CONTEXT_TRANSPORT_H_

#include <map>
#include <optional>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/supports_user_data.h"
#include "components/aegis_access/access_proxy_route_adapter.h"
#include "components/aegis_access/access_route_types.h"
#include "mojo/public/cpp/bindings/remote_set.h"
#include "services/network/public/mojom/network_context.mojom-forward.h"

class Profile;

namespace aegis::access {

// Profile-owned transport state for the first Network Service integration
// slice. This is deliberately not another KeyedService: its lifetime is the
// exact BrowserContext/Profile and it stores independent state per
// StoragePartition policy domain.
//
// The current slice supports one registered localhost HTTP entry per partition
// and an exact-host allowlist. Future per-request routing can replace this
// transport without changing the AccessRuleStore or RoutePlan contracts.
class AccessNetworkContextTransport : public base::SupportsUserData::Data {
 public:
  static AccessNetworkContextTransport* Get(Profile* profile);
  static AccessNetworkContextTransport* GetOrCreate(Profile* profile);

  AccessNetworkContextTransport(const AccessNetworkContextTransport&) = delete;
  AccessNetworkContextTransport& operator=(
      const AccessNetworkContextTransport&) = delete;
  ~AccessNetworkContextTransport() override;

  // Installs an initially inert CustomProxyConfig channel for this exact
  // Profile + StoragePartition. Existing custom-proxy ownership is never
  // overwritten. Returns true when Aegis owns the channel after the call.
  static bool ConfigureNetworkContext(
      Profile* profile,
      const base::FilePath& relative_partition_path,
      network::mojom::NetworkContextParams* network_context_params);

  // Returns the trusted runtime owner key for the partition. The Profile token
  // is unique to this Profile lifetime; the partition token is derived only
  // from the browser-owned relative partition path.
  std::optional<aegis_access::OwnershipKey> OwnerForPartition(
      aegis_access::ChannelNamespace channel,
      const base::FilePath& relative_partition_path) const;

  // Publishes one already-registered localhost HTTP entry for a set of exact
  // canonical hosts. Endpoint ownership must match OwnerForPartition().
  // Non-selected hosts keep Chromium's native proxy result.
  bool PublishProxySelection(
      const base::FilePath& relative_partition_path,
      std::vector<std::string> exact_hosts,
      const aegis_access::RegisteredProxyEndpoint& endpoint);

  // Clears the custom selection while keeping the update channel installed.
  // New requests then use Chromium's native proxy result again.
  bool ClearProxySelection(const base::FilePath& relative_partition_path);

  network::mojom::CustomProxyConfigPtr BuildConfigForTesting(
      const base::FilePath& relative_partition_path) const;
  void FlushClientsForTesting(const base::FilePath& relative_partition_path);

 private:
  struct PartitionState {
    std::optional<aegis_access::RegisteredProxyEndpoint> endpoint;
    std::vector<std::string> exact_hosts;
    mojo::RemoteSet<network::mojom::CustomProxyConfigClient> clients;
  };

  AccessNetworkContextTransport();

  static std::optional<std::string> PartitionKey(
      const base::FilePath& relative_partition_path);
  std::optional<std::string> PartitionToken(
      const base::FilePath& relative_partition_path) const;
  network::mojom::CustomProxyConfigPtr BuildConfig(
      const PartitionState& state) const;
  void Broadcast(PartitionState& state);

  std::string runtime_profile_token_;
  std::map<std::string, PartitionState> partitions_;
};

}  // namespace aegis::access

#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_NETWORK_CONTEXT_TRANSPORT_H_
