// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_POLICY_PUBLICATION_ACK_TRACKER_CONTRACT_TEST_H_
#define COMPONENTS_AEGIS_ACCESS_POLICY_PUBLICATION_ACK_TRACKER_CONTRACT_TEST_H_

#include <string>

#include "components/aegis_access/policy_publication_ack_tracker.h"

namespace aegis_access::test {

class PolicyPublicationAckTrackerTestObserver {
 public:
  virtual ~PolicyPublicationAckTrackerTestObserver() = default;
  virtual void Expect(bool condition, const std::string& label) = 0;
};

inline RequestCancellationSelector PublicationSelector(
    const std::string& host = "target.example") {
  return {
      {ChannelNamespace::kDev, "profile-ack", "partition-ack"},
      "document-ack",
      "",
      "https://top.example",
      host,
      RequestScheme::kHttps,
      443,
  };
}

inline PolicyPublicationIdentity PublicationIdentity(
    uint64_t sequence,
    uint64_t generation,
    const std::string& operation_id = "operation-ack",
    const std::string& host = "target.example") {
  return {operation_id, sequence, generation, PublicationSelector(host)};
}

inline PolicyPublicationAckRequirements PublicationRequirements(
    uint64_t sequence = 1,
    uint64_t generation = 1,
    const std::string& operation_id = "operation-ack",
    const std::string& host = "target.example") {
  return {PublicationIdentity(sequence, generation, operation_id, host),
          {"browser-runtime", "network-context"},
          true};
}

inline void ExpectPublicationWaitsForEveryCompletion(
    PolicyPublicationAckTrackerTestObserver& observer) {
  PolicyPublicationAckTracker tracker(8, 4);
  const auto requirements = PublicationRequirements();
  observer.Expect(
      tracker.Begin(requirements).status == PolicyPublicationAckStatus::kPending,
      "publication begins pending");
  observer.Expect(
      tracker.Acknowledge(requirements.identity, "browser-runtime").status ==
          PolicyPublicationAckStatus::kPending,
      "browser ack alone stays pending");
  observer.Expect(
      tracker.Acknowledge(requirements.identity, "network-context").status ==
          PolicyPublicationAckStatus::kPending,
      "all acks still wait for termination and commit");
  observer.Expect(
      tracker.MarkTerminationsComplete(requirements.identity).status ==
          PolicyPublicationAckStatus::kPending,
      "termination still waits for durable commit");

  const auto committed = tracker.MarkDurablyCommitted(requirements.identity);
  observer.Expect(committed.status == PolicyPublicationAckStatus::kReady,
                  "durable commit makes publication ready");
  observer.Expect(committed.snapshot.has_value() &&
                      committed.snapshot->required_acks == 2 &&
                      committed.snapshot->received_acks == 2 &&
                      committed.snapshot->termination_complete &&
                      committed.snapshot->durable_committed &&
                      committed.snapshot->ready,
                  "ready snapshot records all dimensions");
  observer.Expect(
      tracker.Finalize(requirements.identity).status ==
          PolicyPublicationAckStatus::kFinalized,
      "ready publication finalizes");
  observer.Expect(tracker.size() == 0,
                  "finalized publication leaves no active state");
}

inline void ExpectUnknownAndDuplicateAcksCannotAdvance(
    PolicyPublicationAckTrackerTestObserver& observer) {
  PolicyPublicationAckTracker tracker(8, 4);
  const auto requirements = PublicationRequirements();
  tracker.Begin(requirements);
  observer.Expect(
      tracker.Acknowledge(requirements.identity, "other-context").status ==
          PolicyPublicationAckStatus::kUnexpectedAck,
      "unexpected ack is rejected");
  observer.Expect(
      tracker.Acknowledge(requirements.identity, "browser-runtime").status ==
          PolicyPublicationAckStatus::kPending,
      "expected ack is accepted");
  observer.Expect(
      tracker.Acknowledge(requirements.identity, "browser-runtime").status ==
          PolicyPublicationAckStatus::kDuplicateAck,
      "duplicate ack is rejected");
  const auto current = tracker.Lookup(requirements.identity);
  observer.Expect(current.snapshot.has_value() &&
                      current.snapshot->received_acks == 1,
                  "duplicate ack does not advance count");
}

inline void ExpectNewerOperationInvalidatesLateAck(
    PolicyPublicationAckTrackerTestObserver& observer) {
  PolicyPublicationAckTracker tracker(8, 4);
  const auto older = PublicationRequirements(10, 10, "operation-old");
  const auto newer = PublicationRequirements(11, 11, "operation-new");
  tracker.Begin(older);
  observer.Expect(tracker.Begin(newer).status ==
                      PolicyPublicationAckStatus::kPending,
                  "newer operation supersedes old operation");
  observer.Expect(
      tracker.Acknowledge(older.identity, "browser-runtime").status ==
          PolicyPublicationAckStatus::kStaleOperation,
      "late old ack is stale");
  observer.Expect(
      tracker.MarkDurablyCommitted(older.identity).status ==
          PolicyPublicationAckStatus::kStaleOperation,
      "late old commit is stale");
  const auto current = tracker.Lookup(newer.identity);
  observer.Expect(current.snapshot.has_value() &&
                      current.snapshot->received_acks == 0 &&
                      !current.snapshot->durable_committed,
                  "late old completion cannot mutate newer operation");
}

inline void ExpectExecutionPointFailureStaysFailClosed(
    PolicyPublicationAckTrackerTestObserver& observer) {
  PolicyPublicationAckTracker tracker(8, 4);
  const auto failed = PublicationRequirements(30, 30, "operation-failed");
  tracker.Begin(failed);
  observer.Expect(
      tracker.MarkFailed(failed.identity).status ==
          PolicyPublicationAckStatus::kFailed,
      "execution-point failure marks publication failed");
  observer.Expect(
      tracker.Acknowledge(failed.identity, "network-context").status ==
          PolicyPublicationAckStatus::kFailed,
      "late ack cannot revive failed publication");
  observer.Expect(
      tracker.Finalize(failed.identity).status ==
          PolicyPublicationAckStatus::kFailed,
      "failed publication cannot finalize");

  const auto retry = PublicationRequirements(31, 31, "operation-retry");
  observer.Expect(
      tracker.Begin(retry).status == PolicyPublicationAckStatus::kPending,
      "newer operation can supersede failed publication");
}

inline void ExpectGenerationCannotMoveBackward(
    PolicyPublicationAckTrackerTestObserver& observer) {
  PolicyPublicationAckTracker tracker(8, 4);
  tracker.Begin(PublicationRequirements(20, 20, "operation-a"));
  observer.Expect(
      tracker.Begin(PublicationRequirements(21, 20, "operation-b")).status ==
          PolicyPublicationAckStatus::kStaleGeneration,
      "newer operation cannot reuse old generation");
}

inline void ExpectIndependentSelectorsCanProgress(
    PolicyPublicationAckTrackerTestObserver& observer) {
  PolicyPublicationAckTracker tracker(8, 4);
  observer.Expect(
      tracker.Begin(PublicationRequirements(1, 1, "op-a", "a.example")).status ==
          PolicyPublicationAckStatus::kPending,
      "first selector begins");
  observer.Expect(
      tracker.Begin(PublicationRequirements(2, 2, "op-b", "b.example")).status ==
          PolicyPublicationAckStatus::kPending,
      "second selector begins");
  observer.Expect(tracker.size() == 2,
                  "independent selectors retain independent state");
}

inline void ExpectInvalidRequirementsFailClosed(
    PolicyPublicationAckTrackerTestObserver& observer) {
  PolicyPublicationAckTracker tracker(1, 2);
  auto duplicate = PublicationRequirements();
  duplicate.required_ack_tokens = {"browser-runtime", "browser-runtime"};
  observer.Expect(
      tracker.Begin(duplicate).status ==
          PolicyPublicationAckStatus::kInvalidOperation,
      "duplicate required ack is invalid");
  auto empty = PublicationRequirements();
  empty.required_ack_tokens.clear();
  observer.Expect(
      tracker.Begin(empty).status ==
          PolicyPublicationAckStatus::kInvalidOperation,
      "empty required ack set is invalid");
}

inline void RunPolicyPublicationAckTrackerUnitTests(
    PolicyPublicationAckTrackerTestObserver& observer) {
  ExpectPublicationWaitsForEveryCompletion(observer);
  ExpectUnknownAndDuplicateAcksCannotAdvance(observer);
  ExpectIndependentSelectorsCanProgress(observer);
  ExpectInvalidRequirementsFailClosed(observer);
}

inline void RunPolicyPublicationAckTrackerRegressionTests(
    PolicyPublicationAckTrackerTestObserver& observer) {
  ExpectNewerOperationInvalidatesLateAck(observer);
  ExpectExecutionPointFailureStaysFailClosed(observer);
  ExpectGenerationCannotMoveBackward(observer);
}

}  // namespace aegis_access::test

#endif  // COMPONENTS_AEGIS_ACCESS_POLICY_PUBLICATION_ACK_TRACKER_CONTRACT_TEST_H_
