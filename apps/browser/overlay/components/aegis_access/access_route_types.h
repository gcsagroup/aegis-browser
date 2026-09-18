// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_ACCESS_ROUTE_TYPES_H_
#define COMPONENTS_AEGIS_ACCESS_ACCESS_ROUTE_TYPES_H_

#include <cstdint>
#include <optional>
#include <string>

namespace aegis_access {

enum class ChannelNamespace {
  kDev,
  kAlpha,
  kBeta,
  kRelease,
  kInvalid,
};

struct OwnershipKey {
  ChannelNamespace channel = ChannelNamespace::kInvalid;
  std::string profile_token;
  std::string storage_partition_token;

  friend bool operator==(const OwnershipKey&, const OwnershipKey&) = default;
};


inline bool IsKnownChannel(ChannelNamespace channel) {
  switch (channel) {
    case ChannelNamespace::kDev:
    case ChannelNamespace::kAlpha:
    case ChannelNamespace::kBeta:
    case ChannelNamespace::kRelease:
      return true;
    case ChannelNamespace::kInvalid:
      return false;
  }
  return false;
}

inline bool IsCompleteOwner(const OwnershipKey& owner) {
  return IsKnownChannel(owner.channel) && !owner.profile_token.empty() &&
         !owner.storage_partition_token.empty();
}

struct GenerationTuple {
  // Zero is reserved for "not published / not initialized". Browser-owned
  // generation sources publish live counters starting at 1 and increment from
  // there, so consumers may treat any zero field as an incomplete tuple.
  uint64_t policy_generation = 0;
  uint64_t identity_generation = 0;
  uint64_t selection_generation = 0;
  uint64_t network_epoch = 0;
  uint64_t base_proxy_config_generation = 0;

  friend bool operator==(const GenerationTuple&, const GenerationTuple&) =
      default;
};

enum class RequestScheme {
  kHttp,
  kHttps,
  kWs,
  kWss,
  kInvalid,
};

enum class AccessMode {
  kNone,
  kDirect,
  kProxy,
  kReject,
  kInvalid,
};

enum class PolicyState {
  kAbsent,
  kValid,
  kConflict,
  kInvalid,
};

enum class PolicyScope {
  kNone,
  kSite,
  kProfile,
  kInvalid,
};

enum class SnapshotState {
  kMissing,
  kRestoring,
  kPublished,
  kCorrupt,
  kInvalid,
};

enum class ProtectionRestriction {
  kNone,
  kDeny,
  kInvalid,
};

enum class ManagedRestriction {
  kNone,
  kForceProxy,
  kForceDirect,
  kCustomProxyForbidden,
  kInvalid,
};

enum class ProxyRuntimeState {
  kStopped,
  kPreparing,
  kReady,
  kRecovering,
  kOffline,
  kQuotaExhausted,
  kSignedOut,
  kUnavailable,
  kInvalid,
};

struct RegisteredProxyEntry {
  std::string registration_id;
  std::string proxy_group_id;
  OwnershipKey owner;
  GenerationTuple generations;

  friend bool operator==(const RegisteredProxyEntry&,
                         const RegisteredProxyEntry&) = default;
};

enum class RouteAction {
  kPreserveNative,
  kUseRegisteredProxy,
  kWait,
  kDeny,
  kFail,
};

enum class RouteReason {
  kNone,
  kMissingSnapshot,
  kSnapshotNotReady,
  kStaleGeneration,
  kOwnershipMismatch,
  kSiteOwnershipUnavailable,
  kInvalidPolicy,
  kPolicyConflict,
  kManagedRestriction,
  kProtectionRestriction,
  kProxyUnavailable,
  kQuotaExhausted,
  kSignedOut,
};

struct RouteInput {
  PolicyState policy_state = PolicyState::kInvalid;
  AccessMode effective_mode = AccessMode::kInvalid;
  PolicyScope policy_scope = PolicyScope::kInvalid;
  std::string effective_proxy_group_id;
  bool require_proxy_intent = false;
  bool site_ownership_reliable = false;

  OwnershipKey request_owner;
  SnapshotState snapshot_state = SnapshotState::kInvalid;
  OwnershipKey snapshot_owner;
  GenerationTuple request_generations;
  GenerationTuple snapshot_generations;

  ProtectionRestriction protection_restriction =
      ProtectionRestriction::kInvalid;
  ManagedRestriction managed_restriction = ManagedRestriction::kInvalid;
  ProxyRuntimeState runtime_state = ProxyRuntimeState::kInvalid;
  std::optional<RegisteredProxyEntry> registered_proxy_entry;

  friend bool operator==(const RouteInput&, const RouteInput&) = default;
};

struct RoutePlan {
  RouteAction action = RouteAction::kFail;
  AccessMode effective_mode = AccessMode::kInvalid;
  RouteReason reason = RouteReason::kInvalidPolicy;
  GenerationTuple generations;
  std::optional<RegisteredProxyEntry> registered_proxy_entry;

  friend bool operator==(const RoutePlan&, const RoutePlan&) = default;
};

}  // namespace aegis_access

#endif  // COMPONENTS_AEGIS_ACCESS_ACCESS_ROUTE_TYPES_H_
