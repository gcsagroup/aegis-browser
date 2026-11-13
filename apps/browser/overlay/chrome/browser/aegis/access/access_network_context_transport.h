// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_NETWORK_CONTEXT_TRANSPORT_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_NETWORK_CONTEXT_TRANSPORT_H_

#include <cstddef>
#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "build/build_config.h"
#include "mojo/public/cpp/bindings/struct_ptr.h"
#include "base/functional/callback_forward.h"
#include "base/supports_user_data.h"
#include "base/memory/weak_ptr.h"
#include "components/aegis_access/access_proxy_route_adapter.h"
#include "components/aegis_access/policy_publication_ack_tracker.h"
#include "components/aegis_access/access_route_types.h"
#include "chrome/browser/aegis/access/access_private_context_client.h"
#include "mojo/public/cpp/bindings/remote_set.h"
#include "net/base/network_change_notifier.h"
#include "services/network/public/mojom/network_context.mojom-forward.h"

class Profile;

namespace aegis::access {

enum class AccessNetworkConfigAckStatus {
  kStarted,
  kMissingTransport,
  kInvalidOwner,
  kMissingPartition,
  kNoClients,
  kBuildFailed,
  kInvalidPublication,
};

struct AccessNetworkConfigAckResult {
  AccessNetworkConfigAckStatus status = AccessNetworkConfigAckStatus::kBuildFailed;
  size_t required_client_acks = 0;
};

struct AccessTransportSelection {
  std::optional<aegis_access::RegisteredProxyEndpoint> endpoint;
  std::vector<std::string> exact_hosts;
  friend bool operator==(const AccessTransportSelection&,
                         const AccessTransportSelection&) = default;
};

// Profile-owned transport state for the first Network Service integration
// slice. This is deliberately not another KeyedService: its lifetime is the
// exact BrowserContext/Profile and it stores independent state per
// StoragePartition policy domain.
//
// The current slice supports one registered localhost HTTP entry per partition
// and an exact-host allowlist. Future per-request routing can replace this
// transport without changing the AccessRuleStore or RoutePlan contracts.
class AccessNetworkContextTransport
    : public base::SupportsUserData::Data,
      public net::NetworkChangeNotifier::NetworkChangeObserver {
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

  // Browser-owned network generation for this Profile lifetime. It starts at
  // one because zero is the GenerationTuple "not published" sentinel, and
  // advances only from actual NetworkChangeNotifier callbacks.
  uint64_t network_epoch() const { return network_epoch_; }

  // True only when |owner| identifies a StoragePartition already configured
  // by this exact Profile-owned transport.
  bool OwnsConfiguredPartition(
      const aegis_access::OwnershipKey& owner) const;

  // Publishes one already-registered localhost HTTP entry for a set of exact
  // canonical hosts. Endpoint ownership must match OwnerForPartition().
  // Non-selected hosts keep Chromium's native proxy result.
  bool PublishProxySelection(
      const base::FilePath& relative_partition_path,
      std::vector<std::string> exact_hosts,
      const aegis_access::RegisteredProxyEndpoint& endpoint);
  // Records a real prepared child for private per-request publication. This
  // does not alter native proxy settings or publish the user's site intent.
  bool RegisterPreparedProxy(const AccessPrivateEndpoint& endpoint);
  // Revokes only the named private child. Intent and native proxy settings
  // remain intact; the next full snapshot marks this group unavailable.
  bool ForgetPreparedProxy(const aegis_access::OwnershipKey& owner,
      const std::string& group, const std::string& registration_id);
  std::vector<AccessPrivateEndpoint> PrivateEndpoints(
      const aegis_access::OwnershipKey& owner) const;
  bool HasReadyPrivateContext(const aegis_access::OwnershipKey& owner) const;
  bool HasCurrentPrivatePolicy(const aegis_access::OwnershipKey& owner,
      const aegis_access::GenerationTuple& common) const;
  using PrivateContext = std::shared_ptr<AccessPrivateContextClient>;
  void BindPrivateContext(const aegis_access::OwnershipKey& owner,
      network::mojom::NetworkContext* context,
      base::OnceCallback<void(PrivateContext)> completion);
  AccessNetworkConfigAckResult PublishPrivatePolicy(
      const aegis_access::PublishedAccessPolicySnapshot& policy,
      const aegis_access::GenerationTuple& common,
      base::OnceCallback<void(bool)> completion);

#if BUILDFLAG(IS_MAC)
  bool AccountDispatchBlocked(const GURL& url) const;
  const std::vector<std::string>& AccountSites() const;
  // Default partition only. A selected site with no credential stays blocked.
  bool SetAccountNodeSites(const std::vector<std::string>& sites, const std::string& host,
                          uint16_t port, const std::string& authorization);
#endif

  // Clears the custom selection while keeping the update channel installed.
  // New requests then use Chromium's native proxy result again.
  bool ClearProxySelection(const base::FilePath& relative_partition_path);

  // Captures the exact registered endpoint that Network Service will use for
  // |exact_host|. The returned endpoint is browser-owned by-value state and is
  // available only when owner, proxy group, host selection, and network epoch
  // still match the currently published CustomProxyConfig.
  std::optional<aegis_access::RegisteredProxyEndpoint>
  CaptureSelectedProxyEndpoint(
      const aegis_access::OwnershipKey& owner,
      const std::string& proxy_group_id,
      const std::string& exact_host) const;

  // Re-publishes the currently committed custom proxy config and completes
  // |all_clients_settled| only after every currently attached NetworkContext
  // has either acknowledged Chromium's real CustomProxyConfigClient Mojo call
  // or dropped its callback. The bool is true only when every client ACKed.
  AccessNetworkConfigAckResult RepublishCurrentConfigWithAck(
      const aegis_access::OwnershipKey& owner,
      base::OnceCallback<void(bool)> all_clients_settled);

  // Publishes only the exact PREPARED policy identity/version to every owning
  // NetworkContext. This is a candidate-specific execution ACK and deliberately
  // does not reuse custom-proxy config re-publication as policy proof.
  AccessNetworkConfigAckResult PublishPolicyCandidateWithAck(
      const aegis_access::PolicyPublicationIdentity& identity,
      const aegis_access::OwnershipKey& owner,
      base::OnceCallback<void(bool)> all_clients_settled);

  std::optional<aegis_access::RegisteredProxyEndpoint> CurrentEndpoint(
      const aegis_access::OwnershipKey& owner) const;
  std::optional<AccessTransportSelection> CurrentSelection(
      const aegis_access::OwnershipKey& owner) const;
  bool ReplaceSelection(const aegis_access::OwnershipKey& owner,
                        const AccessTransportSelection& expected,
                        const AccessTransportSelection& replacement);

  network::mojom::CustomProxyConfigPtr BuildConfigForTesting(
      const base::FilePath& relative_partition_path) const;
  void FlushClientsForTesting(const base::FilePath& relative_partition_path);

 private:
  friend class AccessNetworkContextTransportTestPeer;

  struct PrivatePublication {
    aegis_access::PublishedAccessPolicySnapshot policy;
    aegis_access::GenerationTuple common;
    std::vector<AccessPrivateEndpoint> endpoints;
    std::map<std::string, uint64_t> unavailable;
  };
  struct PrivateContextEntry {
    PrivateContext client;
    uint64_t sequence = 0;
    uint64_t applied_revision = 0;
    bool publishing = false;
  };
  struct PartitionState {
    // A partition that uses trusted per-request routing must never reinstall
    // destination-host-global proxying, including while its Context reconnects.
    bool private_routing = false;
    std::map<std::string, AccessPrivateEndpoint> private_endpoints;
    std::map<std::string, uint64_t> private_unavailable_generations;
    std::map<std::string, PrivateContextEntry> private_contexts;
    std::optional<PrivatePublication> private_publication;
    uint64_t private_revision = 0;
    std::vector<base::OnceCallback<void(bool)>> private_publication_waiters;
    std::optional<aegis_access::RegisteredProxyEndpoint> endpoint;
    std::vector<std::string> exact_hosts;
#if BUILDFLAG(IS_MAC)
    network::mojom::CustomProxyConfigPtr account_config;
    std::vector<std::string> account_sites;
    std::set<std::string> account_fenced;
    uint64_t account_publication = 0;
#endif
    mojo::RemoteSet<network::mojom::CustomProxyConfigClient> clients;
    uint64_t clients_generation = 0;
  };

  AccessNetworkContextTransport();

  void OnNetworkChanged(
      net::NetworkChangeNotifier::ConnectionType type) override;

  static std::optional<std::string> PartitionKey(
      const base::FilePath& relative_partition_path);
  std::optional<std::string> PartitionToken(
      const base::FilePath& relative_partition_path) const;
  bool IsEndpointCurrentForPartition(
      const base::FilePath& relative_partition_path,
      const aegis_access::RegisteredProxyEndpoint& endpoint) const;
  network::mojom::CustomProxyConfigPtr BuildConfig(
      const PartitionState& state) const;
  void UpdateClientConfigs(
      PartitionState& state,
      const network::mojom::CustomProxyConfigPtr& config,
      base::OnceCallback<void(bool)> all_clients_settled);
  static bool SelectionMatchesIdentity(
      const PartitionState& state,
      const aegis_access::PolicyPublicationIdentity& identity);
  bool PublicationStillCurrent(
      const aegis_access::PolicyPublicationIdentity& identity,
      uint64_t clients_generation,
      size_t client_count) const;
  void PublishPolicyCandidateToClients(
      PartitionState& state,
      const aegis_access::PolicyPublicationIdentity& identity,
      const aegis_access::OwnershipKey& owner,
      base::OnceCallback<void(bool)> all_clients_settled);
#if BUILDFLAG(IS_MAC)
  void PublishAccountConfig(PartitionState& state);
#endif
  void Broadcast(PartitionState& state);
  void PublishPrivateContext(const aegis_access::OwnershipKey& owner,
                             const std::string& incarnation);
  void OnPrivateContextPublished(aegis_access::OwnershipKey owner,
      std::string incarnation, uint64_t revision, bool accepted);
  void SettlePrivatePublication(PartitionState& state, bool accepted);
  static bool SamePrivatePublication(const PrivatePublication& a,
                                     const PrivatePublication& b);

  std::string runtime_profile_token_;
  uint64_t network_epoch_ = 1;
  std::map<std::string, PartitionState> partitions_;
  base::WeakPtrFactory<AccessNetworkContextTransport> weak_factory_{this};
};

}  // namespace aegis::access

#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_NETWORK_CONTEXT_TRANSPORT_H_
