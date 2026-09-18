// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_REQUEST_GENERATION_TUPLE_BUILDER_CONTRACT_TEST_H_
#define COMPONENTS_AEGIS_ACCESS_REQUEST_GENERATION_TUPLE_BUILDER_CONTRACT_TEST_H_

#include <string>

#include "components/aegis_access/request_generation_tuple_builder.h"

namespace aegis_access::test {

class RequestGenerationTupleBuilderTestObserver {
 public:
  virtual ~RequestGenerationTupleBuilderTestObserver() = default;
  virtual void Expect(bool condition, const std::string& label) = 0;
};

inline RequestGenerationTupleInput CompleteGenerationTupleInput() {
  RequestGenerationTupleInput input;
  input.request_owner = {ChannelNamespace::kDev, "profile-a", "<default>"};
  input.snapshot_owner = input.request_owner;
  input.policy_generation = 11;
  input.identity_generation = 12;
  input.selection_generation = 13;
  input.network_epoch = 14;
  input.base_proxy_config_generation = 15;
  return input;
}

inline void ExpectCompleteGenerationTuple(
    RequestGenerationTupleBuilderTestObserver& observer) {
  const auto result =
      BuildCompleteRequestGenerationTuple(CompleteGenerationTupleInput());
  observer.Expect(result.status == RequestGenerationTupleBuildStatus::kComplete,
                  "complete production generations are accepted");
  observer.Expect(result.generations.has_value(),
                  "complete production generations publish a tuple");
  observer.Expect(
      result.generations ==
          GenerationTuple{11, 12, 13, 14, 15},
      "tuple preserves all five source generations");
}

inline void ExpectGenerationTupleOwnerMismatchFailsClosed(
    RequestGenerationTupleBuilderTestObserver& observer) {
  auto input = CompleteGenerationTupleInput();
  input.snapshot_owner.storage_partition_token = "partition:other";
  const auto result = BuildCompleteRequestGenerationTuple(input);
  observer.Expect(
      result.status == RequestGenerationTupleBuildStatus::kOwnershipMismatch,
      "cross-partition snapshot is rejected");
  observer.Expect(!result.generations.has_value(),
                  "owner mismatch never publishes a tuple");
}

inline void ExpectInvalidGenerationTupleOwnerFailsClosed(
    RequestGenerationTupleBuilderTestObserver& observer) {
  auto input = CompleteGenerationTupleInput();
  input.request_owner.channel = ChannelNamespace::kInvalid;
  const auto result = BuildCompleteRequestGenerationTuple(input);
  observer.Expect(result.status ==
                      RequestGenerationTupleBuildStatus::kInvalidOwner,
                  "invalid channel is rejected");
  observer.Expect(!result.generations.has_value(),
                  "invalid owner never publishes a tuple");
}

inline void ExpectEachMissingGenerationFailsClosed(
    RequestGenerationTupleBuilderTestObserver& observer) {
  struct MissingCase {
    RequestGenerationTupleBuildStatus status;
    void (*clear)(RequestGenerationTupleInput&);
  };
  const MissingCase cases[] = {
      {RequestGenerationTupleBuildStatus::kMissingPolicyGeneration,
       [](RequestGenerationTupleInput& input) { input.policy_generation = 0; }},
      {RequestGenerationTupleBuildStatus::kMissingIdentityGeneration,
       [](RequestGenerationTupleInput& input) {
         input.identity_generation = 0;
       }},
      {RequestGenerationTupleBuildStatus::kMissingSelectionGeneration,
       [](RequestGenerationTupleInput& input) {
         input.selection_generation = 0;
       }},
      {RequestGenerationTupleBuildStatus::kMissingNetworkEpoch,
       [](RequestGenerationTupleInput& input) { input.network_epoch = 0; }},
      {RequestGenerationTupleBuildStatus::kMissingBaseProxyConfigGeneration,
       [](RequestGenerationTupleInput& input) {
         input.base_proxy_config_generation = 0;
       }},
  };

  for (const auto& missing : cases) {
    auto input = CompleteGenerationTupleInput();
    missing.clear(input);
    const auto result = BuildCompleteRequestGenerationTuple(input);
    observer.Expect(result.status == missing.status,
                    "missing generation reports its exact source");
    observer.Expect(!result.generations.has_value(),
                    "missing generation never publishes a tuple");
  }
}

inline void RunRequestGenerationTupleBuilderUnitTests(
    RequestGenerationTupleBuilderTestObserver& observer) {
  ExpectCompleteGenerationTuple(observer);
  ExpectGenerationTupleOwnerMismatchFailsClosed(observer);
  ExpectInvalidGenerationTupleOwnerFailsClosed(observer);
}

inline void RunRequestGenerationTupleBuilderRegressionTests(
    RequestGenerationTupleBuilderTestObserver& observer) {
  ExpectEachMissingGenerationFailsClosed(observer);
}

}  // namespace aegis_access::test

#endif  // COMPONENTS_AEGIS_ACCESS_REQUEST_GENERATION_TUPLE_BUILDER_CONTRACT_TEST_H_
