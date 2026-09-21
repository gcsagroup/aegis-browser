// Copyright 2026 GCSA

#include "components/aegis_access/policy_publication_ack_tracker.h"

#include <algorithm>
#include <utility>

namespace aegis_access {
namespace {

bool IsValidAckToken(const std::string& token) {
  return !token.empty() && token.size() <= 128;
}

}  // namespace

PolicyPublicationAckTracker::PolicyPublicationAckTracker(
    size_t max_operations,
    size_t max_ack_tokens_per_operation)
    : max_operations_(max_operations),
      max_ack_tokens_per_operation_(max_ack_tokens_per_operation) {}

PolicyPublicationAckTracker::~PolicyPublicationAckTracker() = default;

bool PolicyPublicationAckTracker::IsReady(const Entry& entry) {
  return !entry.failed &&
         entry.received_acks.size() == entry.required_acks.size() &&
         (!entry.require_termination || entry.termination_complete) &&
         entry.durable_committed;
}

PolicyPublicationAckStatus PolicyPublicationAckTracker::CurrentStatus(
    const Entry& entry) {
  if (entry.failed) {
    return PolicyPublicationAckStatus::kFailed;
  }
  return IsReady(entry) ? PolicyPublicationAckStatus::kReady
                        : PolicyPublicationAckStatus::kPending;
}

PolicyPublicationAckSnapshot PolicyPublicationAckTracker::SnapshotFor(
    const Entry& entry) {
  return {
      entry.identity,
      entry.required_acks.size(),
      entry.received_acks.size(),
      entry.termination_complete,
      entry.durable_committed,
      entry.failed,
      IsReady(entry),
  };
}

PolicyPublicationAckResult PolicyPublicationAckTracker::ResultFor(
    PolicyPublicationAckStatus status,
    const Entry* entry) {
  if (!entry) {
    return {status, std::nullopt};
  }
  return {status, SnapshotFor(*entry)};
}

PolicyPublicationAckTracker::Entry*
PolicyPublicationAckTracker::FindBySelector(
    const RequestCancellationSelector& selector) {
  return const_cast<Entry*>(
      std::as_const(*this).FindBySelector(selector));
}

const PolicyPublicationAckTracker::Entry*
PolicyPublicationAckTracker::FindBySelector(
    const RequestCancellationSelector& selector) const {
  auto it = std::find_if(entries_.begin(), entries_.end(),
                         [&](const Entry& entry) {
                           return SameRequestCancellationSelector(
                               entry.identity.selector, selector);
                         });
  return it == entries_.end() ? nullptr : &*it;
}

PolicyPublicationAckStatus PolicyPublicationAckTracker::ValidateIdentity(
    const PolicyPublicationIdentity& identity,
    const Entry& entry) const {
  if (identity.operation_sequence < entry.identity.operation_sequence) {
    return PolicyPublicationAckStatus::kStaleOperation;
  }
  if (identity.operation_sequence != entry.identity.operation_sequence ||
      identity.operation_id != entry.identity.operation_id) {
    return PolicyPublicationAckStatus::kVersionMismatch;
  }
  if (identity.policy_generation < entry.identity.policy_generation) {
    return PolicyPublicationAckStatus::kStaleGeneration;
  }
  if (identity.policy_generation != entry.identity.policy_generation) {
    return PolicyPublicationAckStatus::kVersionMismatch;
  }
  if (identity.selection_generation < entry.identity.selection_generation ||
      identity.network_epoch < entry.identity.network_epoch) {
    return PolicyPublicationAckStatus::kStaleGeneration;
  }
  if (identity.selection_generation != entry.identity.selection_generation ||
      identity.network_epoch != entry.identity.network_epoch) {
    return PolicyPublicationAckStatus::kVersionMismatch;
  }
  return PolicyPublicationAckStatus::kPending;
}

PolicyPublicationAckStatus PolicyPublicationAckTracker::ValidateRequirements(
    const PolicyPublicationAckRequirements& requirements,
    std::set<std::string>* required_acks) const {
  if (!required_acks || requirements.identity.operation_id.empty() ||
      requirements.identity.operation_sequence == 0 ||
      requirements.identity.policy_generation == 0 ||
      requirements.identity.network_epoch == 0 ||
      !IsValidRequestCancellationSelector(requirements.identity.selector) ||
      requirements.required_ack_tokens.empty() ||
      requirements.required_ack_tokens.size() >
          max_ack_tokens_per_operation_) {
    return PolicyPublicationAckStatus::kInvalidOperation;
  }

  for (const std::string& token : requirements.required_ack_tokens) {
    if (!IsValidAckToken(token) || !required_acks->insert(token).second) {
      return PolicyPublicationAckStatus::kInvalidOperation;
    }
  }
  return PolicyPublicationAckStatus::kPending;
}

PolicyPublicationAckResult PolicyPublicationAckTracker::UpdateEntry(
    Entry* entry,
    PolicyPublicationAckRequirements requirements,
    std::set<std::string> required_acks) {
  if (requirements.identity.operation_sequence <
      entry->identity.operation_sequence) {
    return ResultFor(PolicyPublicationAckStatus::kStaleOperation, entry);
  }
  if (requirements.identity.operation_sequence ==
      entry->identity.operation_sequence) {
    if (requirements.identity != entry->identity ||
        required_acks != entry->required_acks ||
        requirements.require_termination != entry->require_termination) {
      return ResultFor(PolicyPublicationAckStatus::kVersionMismatch, entry);
    }
    return ResultFor(CurrentStatus(*entry), entry);
  }
  if (requirements.identity.policy_generation <=
      entry->identity.policy_generation) {
    return ResultFor(PolicyPublicationAckStatus::kStaleGeneration, entry);
  }

  entry->identity = std::move(requirements.identity);
  entry->required_acks = std::move(required_acks);
  entry->received_acks.clear();
  entry->require_termination = requirements.require_termination;
  entry->termination_complete = false;
  entry->durable_committed = false;
  entry->failed = false;
  return ResultFor(PolicyPublicationAckStatus::kPending, entry);
}

std::pair<PolicyPublicationAckStatus, PolicyPublicationAckTracker::Entry*>
PolicyPublicationAckTracker::FindAndValidate(
    const PolicyPublicationIdentity& identity) {
  const auto [status, entry] =
      std::as_const(*this).FindAndValidate(identity);
  return {status, const_cast<Entry*>(entry)};
}

std::pair<PolicyPublicationAckStatus,
          const PolicyPublicationAckTracker::Entry*>
PolicyPublicationAckTracker::FindAndValidate(
    const PolicyPublicationIdentity& identity) const {
  const Entry* entry = FindBySelector(identity.selector);
  if (!entry) {
    return {PolicyPublicationAckStatus::kNotFound, nullptr};
  }
  const PolicyPublicationAckStatus identity_status =
      ValidateIdentity(identity, *entry);
  if (identity_status != PolicyPublicationAckStatus::kPending) {
    return {identity_status, entry};
  }
  return {CurrentStatus(*entry), entry};
}

PolicyPublicationAckResult PolicyPublicationAckTracker::Begin(
    PolicyPublicationAckRequirements requirements) {
  std::set<std::string> required_acks;
  const PolicyPublicationAckStatus requirements_status =
      ValidateRequirements(requirements, &required_acks);
  if (requirements_status != PolicyPublicationAckStatus::kPending) {
    return {requirements_status, std::nullopt};
  }

  if (Entry* current = FindBySelector(requirements.identity.selector)) {
    return UpdateEntry(current, std::move(requirements),
                       std::move(required_acks));
  }
  if (entries_.size() >= max_operations_) {
    return {PolicyPublicationAckStatus::kCapacityExceeded, std::nullopt};
  }

  entries_.push_back({
      std::move(requirements.identity),
      std::move(required_acks),
      {},
      requirements.require_termination,
      false,
      false,
      false,
  });
  return ResultFor(PolicyPublicationAckStatus::kPending, &entries_.back());
}

PolicyPublicationAckResult PolicyPublicationAckTracker::Acknowledge(
    const PolicyPublicationIdentity& identity,
    const std::string& ack_token) {
  auto [status, entry] = FindAndValidate(identity);
  if (status != PolicyPublicationAckStatus::kPending) {
    return ResultFor(status, entry);
  }
  if (!entry->required_acks.contains(ack_token)) {
    return ResultFor(PolicyPublicationAckStatus::kUnexpectedAck, entry);
  }
  if (!entry->received_acks.insert(ack_token).second) {
    return ResultFor(PolicyPublicationAckStatus::kDuplicateAck, entry);
  }
  return ResultFor(CurrentStatus(*entry), entry);
}

PolicyPublicationAckResult
PolicyPublicationAckTracker::MarkTerminationsComplete(
    const PolicyPublicationIdentity& identity) {
  auto [status, entry] = FindAndValidate(identity);
  if (status != PolicyPublicationAckStatus::kPending) {
    return ResultFor(status, entry);
  }
  entry->termination_complete = true;
  return ResultFor(CurrentStatus(*entry), entry);
}

bool PolicyPublicationAckTracker::CanCommit(
    const PolicyPublicationIdentity& identity) const {
  const auto [status, entry] = FindAndValidate(identity);
  return status == PolicyPublicationAckStatus::kPending && entry &&
         !entry->durable_committed && !entry->failed &&
         entry->received_acks.size() == entry->required_acks.size() &&
         (!entry->require_termination || entry->termination_complete);
}

PolicyPublicationAckResult PolicyPublicationAckTracker::MarkDurablyCommitted(
    const PolicyPublicationIdentity& identity) {
  auto [status, entry] = FindAndValidate(identity);
  if (status != PolicyPublicationAckStatus::kPending) {
    return ResultFor(status, entry);
  }
  entry->durable_committed = true;
  return ResultFor(CurrentStatus(*entry), entry);
}

PolicyPublicationAckResult PolicyPublicationAckTracker::MarkFailed(
    const PolicyPublicationIdentity& identity) {
  auto [status, entry] = FindAndValidate(identity);
  if (status != PolicyPublicationAckStatus::kPending) {
    return ResultFor(status, entry);
  }
  entry->failed = true;
  return ResultFor(PolicyPublicationAckStatus::kFailed, entry);
}

PolicyPublicationAckResult PolicyPublicationAckTracker::Abort(
    const PolicyPublicationIdentity& identity) {
  auto it = std::find_if(entries_.begin(), entries_.end(),
                         [&](const Entry& entry) {
                           return entry.identity == identity;
                         });
  if (it == entries_.end()) {
    return {PolicyPublicationAckStatus::kNotFound, std::nullopt};
  }
  auto snapshot = SnapshotFor(*it);
  entries_.erase(it);
  snapshot.failed = true;
  snapshot.ready = false;
  return {PolicyPublicationAckStatus::kFailed, snapshot};
}

PolicyPublicationAckResult PolicyPublicationAckTracker::Lookup(
    const PolicyPublicationIdentity& identity) const {
  const auto [status, entry] = FindAndValidate(identity);
  return ResultFor(status, entry);
}

PolicyPublicationAckResult PolicyPublicationAckTracker::Finalize(
    const PolicyPublicationIdentity& identity) {
  auto [status, entry] = FindAndValidate(identity);
  if (status != PolicyPublicationAckStatus::kReady) {
    if (status == PolicyPublicationAckStatus::kPending) {
      status = PolicyPublicationAckStatus::kNotReady;
    }
    return ResultFor(status, entry);
  }

  const PolicyPublicationAckSnapshot snapshot = SnapshotFor(*entry);
  entries_.erase(std::remove_if(entries_.begin(), entries_.end(),
                                [&](const Entry& candidate) {
                                  return SameRequestCancellationSelector(
                                      candidate.identity.selector,
                                      identity.selector);
                                }),
                 entries_.end());
  return {PolicyPublicationAckStatus::kFinalized, snapshot};
}

}  // namespace aegis_access