// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_POLICY_PUBLICATION_ACK_TRACKER_H_
#define COMPONENTS_AEGIS_ACCESS_POLICY_PUBLICATION_ACK_TRACKER_H_

#include <cstddef>
#include <cstdint>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "components/aegis_access/request_ownership_registry.h"

namespace aegis_access {

enum class PolicyPublicationAckStatus {
  kPending,
  kReady,
  kFinalized,
  kFailed,
  kInvalidOperation,
  kCapacityExceeded,
  kStaleOperation,
  kStaleGeneration,
  kVersionMismatch,
  kUnexpectedAck,
  kDuplicateAck,
  kNotFound,
  kNotReady,
};

struct PolicyPublicationIdentity {
  std::string operation_id;
  uint64_t operation_sequence = 0;
  uint64_t policy_generation = 0;
  // Exact request-runtime versions published with this candidate. A DIRECT
  // candidate has no proxy selection and therefore keeps selection_generation
  // at zero; network_epoch must always identify the owning NetworkContext era.
  uint64_t selection_generation = 0;
  uint64_t network_epoch = 0;
  RequestCancellationSelector selector;

  friend bool operator==(const PolicyPublicationIdentity&,
                         const PolicyPublicationIdentity&) = default;
};

struct PolicyPublicationAckRequirements {
  PolicyPublicationIdentity identity;
  std::vector<std::string> required_ack_tokens;
  bool require_termination = true;
};

struct PolicyPublicationAckSnapshot {
  PolicyPublicationIdentity identity;
  size_t required_acks = 0;
  size_t received_acks = 0;
  bool termination_complete = false;
  bool durable_committed = false;
  bool failed = false;
  bool ready = false;
};

struct PolicyPublicationAckResult {
  PolicyPublicationAckStatus status = PolicyPublicationAckStatus::kNotFound;
  std::optional<PolicyPublicationAckSnapshot> snapshot;
};

// Bounded neutral state for one publication operation per exact request scope.
// A newer operationSequence supersedes an older operation for the same selector.
// Delayed ACKs from the old operation therefore cannot make the new state ready.
class PolicyPublicationAckTracker {
 public:
  PolicyPublicationAckTracker(size_t max_operations,
                              size_t max_ack_tokens_per_operation);
  PolicyPublicationAckTracker(const PolicyPublicationAckTracker&) = delete;
  PolicyPublicationAckTracker& operator=(const PolicyPublicationAckTracker&) =
      delete;
  ~PolicyPublicationAckTracker();

  PolicyPublicationAckResult Begin(
      PolicyPublicationAckRequirements requirements);
  PolicyPublicationAckResult Acknowledge(
      const PolicyPublicationIdentity& identity,
      const std::string& ack_token);
  PolicyPublicationAckResult MarkTerminationsComplete(
      const PolicyPublicationIdentity& identity);
  bool CanCommit(const PolicyPublicationIdentity& identity) const;
  PolicyPublicationAckResult MarkDurablyCommitted(
      const PolicyPublicationIdentity& identity);
  PolicyPublicationAckResult MarkFailed(
      const PolicyPublicationIdentity& identity);
  PolicyPublicationAckResult Abort(
      const PolicyPublicationIdentity& identity);
  PolicyPublicationAckResult Lookup(
      const PolicyPublicationIdentity& identity) const;
  PolicyPublicationAckResult Finalize(
      const PolicyPublicationIdentity& identity);

  size_t size() const { return entries_.size(); }

 private:
  struct Entry {
    PolicyPublicationIdentity identity;
    std::set<std::string> required_acks;
    std::set<std::string> received_acks;
    bool require_termination = true;
    bool termination_complete = false;
    bool durable_committed = false;
    bool failed = false;
  };

  Entry* FindBySelector(const RequestCancellationSelector& selector);
  const Entry* FindBySelector(
      const RequestCancellationSelector& selector) const;
  PolicyPublicationAckStatus ValidateIdentity(
      const PolicyPublicationIdentity& identity,
      const Entry& entry) const;
  PolicyPublicationAckStatus ValidateRequirements(
      const PolicyPublicationAckRequirements& requirements,
      std::set<std::string>* required_acks) const;
  PolicyPublicationAckResult UpdateEntry(
      Entry* entry,
      PolicyPublicationAckRequirements requirements,
      std::set<std::string> required_acks);
  std::pair<PolicyPublicationAckStatus, Entry*> FindAndValidate(
      const PolicyPublicationIdentity& identity);
  std::pair<PolicyPublicationAckStatus, const Entry*> FindAndValidate(
      const PolicyPublicationIdentity& identity) const;
  static PolicyPublicationAckStatus CurrentStatus(const Entry& entry);
  static bool IsReady(const Entry& entry);
  static PolicyPublicationAckSnapshot SnapshotFor(const Entry& entry);
  static PolicyPublicationAckResult ResultFor(
      PolicyPublicationAckStatus status,
      const Entry* entry);

  size_t max_operations_;
  size_t max_ack_tokens_per_operation_;
  std::vector<Entry> entries_;
};

}  // namespace aegis_access

#endif  // COMPONENTS_AEGIS_ACCESS_POLICY_PUBLICATION_ACK_TRACKER_H_
