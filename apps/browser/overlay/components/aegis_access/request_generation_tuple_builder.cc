// Copyright 2026 GCSA

#include "components/aegis_access/request_generation_tuple_builder.h"

namespace aegis_access {
namespace {

RequestGenerationTupleBuildResult Missing(
    RequestGenerationTupleBuildStatus status) {
  return {status, std::nullopt};
}

}  // namespace

RequestGenerationTupleBuildResult BuildCompleteRequestGenerationTuple(
    const RequestGenerationTupleInput& input) {
  if (!IsCompleteOwner(input.request_owner) ||
      !IsCompleteOwner(input.snapshot_owner)) {
    return Missing(RequestGenerationTupleBuildStatus::kInvalidOwner);
  }
  if (input.request_owner != input.snapshot_owner) {
    return Missing(RequestGenerationTupleBuildStatus::kOwnershipMismatch);
  }
  if (input.policy_generation == 0) {
    return Missing(
        RequestGenerationTupleBuildStatus::kMissingPolicyGeneration);
  }
  if (input.identity_generation == 0) {
    return Missing(
        RequestGenerationTupleBuildStatus::kMissingIdentityGeneration);
  }
  if (input.selection_generation == 0) {
    return Missing(
        RequestGenerationTupleBuildStatus::kMissingSelectionGeneration);
  }
  if (input.network_epoch == 0) {
    return Missing(RequestGenerationTupleBuildStatus::kMissingNetworkEpoch);
  }
  if (input.base_proxy_config_generation == 0) {
    return Missing(
        RequestGenerationTupleBuildStatus::kMissingBaseProxyConfigGeneration);
  }

  return {
      RequestGenerationTupleBuildStatus::kComplete,
      GenerationTuple{
          input.policy_generation,
          input.identity_generation,
          input.selection_generation,
          input.network_epoch,
          input.base_proxy_config_generation,
      }};
}

}  // namespace aegis_access
