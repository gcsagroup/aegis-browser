// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_ACCESS_POLICY_EVALUATOR_H_
#define COMPONENTS_AEGIS_ACCESS_ACCESS_POLICY_EVALUATOR_H_

#include <cstdint>
#include <string>
#include <vector>

#include "components/aegis_access/request_policy_context.h"

namespace aegis_access {

struct RulePortSelector {
  PortScope scope = PortScope::kInvalid;
  std::vector<uint16_t> explicit_ports;

  friend bool operator==(const RulePortSelector&,
                         const RulePortSelector&) = default;
};

struct AccessPolicyRule {
  std::string rule_id;
  OwnershipKey owner;
  PolicyScope scope = PolicyScope::kInvalid;
  std::string top_level_site;
  std::string destination_host;
  bool include_subdomains = false;
  std::vector<RequestScheme> schemes;
  RulePortSelector ports;
  AccessMode mode = AccessMode::kInvalid;
  std::string proxy_group_id;
  ProtectionOverride protection_override = ProtectionOverride::kInvalid;
  uint64_t row_revision = 0;
  uint64_t last_operation_sequence = 0;

  friend bool operator==(const AccessPolicyRule&,
                         const AccessPolicyRule&) = default;
};

struct PublishedAccessPolicySnapshot {
  OwnershipKey owner;
  uint64_t policy_generation = 0;
  std::vector<AccessPolicyRule> rules;

  friend bool operator==(const PublishedAccessPolicySnapshot&,
                         const PublishedAccessPolicySnapshot&) = default;
};

enum class PolicyMatchReason {
  kNone,
  kNoMatchingRule,
  kOwnershipMismatch,
  kInvalidSnapshot,
  kInvalidRule,
  kPolicyConflict,
};

struct PolicyMatchResult {
  PolicyState policy_state = PolicyState::kInvalid;
  AccessMode effective_mode = AccessMode::kInvalid;
  PolicyScope policy_scope = PolicyScope::kInvalid;
  std::string effective_proxy_group_id;
  std::string matched_rule_id;
  ProtectionOverride protection_override = ProtectionOverride::kInvalid;
  uint64_t policy_generation = 0;
  PolicyMatchReason reason = PolicyMatchReason::kInvalidSnapshot;

  friend bool operator==(const PolicyMatchResult&,
                         const PolicyMatchResult&) = default;
};

// Evaluates an immutable, already-published rule snapshot without I/O. It
// validates normalized rule shapes before matching and fails closed when the
// winning rule is ambiguous. Site rules are ignored when the browser-owned
// context cannot prove a top-level site; Profile rules may still match.
PolicyMatchResult EvaluateAccessPolicy(
    const RequestPolicyContext& request,
    const PublishedAccessPolicySnapshot& snapshot);

}  // namespace aegis_access

#endif  // COMPONENTS_AEGIS_ACCESS_ACCESS_POLICY_EVALUATOR_H_
