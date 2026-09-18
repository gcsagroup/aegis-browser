// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_REQUEST_GENERATION_TUPLE_BUILDER_H_
#define COMPONENTS_AEGIS_ACCESS_REQUEST_GENERATION_TUPLE_BUILDER_H_

#include <cstdint>
#include <optional>

#include "components/aegis_access/access_route_types.h"

namespace aegis_access {

enum class RequestGenerationTupleBuildStatus {
  kComplete,
  kInvalidOwner,
  kOwnershipMismatch,
  kMissingPolicyGeneration,
  kMissingIdentityGeneration,
  kMissingSelectionGeneration,
  kMissingNetworkEpoch,
  kMissingBaseProxyConfigGeneration,
};

struct RequestGenerationTupleInput {
  OwnershipKey request_owner;
  OwnershipKey snapshot_owner;
  uint64_t policy_generation = 0;
  uint64_t identity_generation = 0;
  uint64_t selection_generation = 0;
  uint64_t network_epoch = 0;
  uint64_t base_proxy_config_generation = 0;
};

struct RequestGenerationTupleBuildResult {
  RequestGenerationTupleBuildStatus status =
      RequestGenerationTupleBuildStatus::kInvalidOwner;
  std::optional<GenerationTuple> generations;
};

RequestGenerationTupleBuildResult BuildCompleteRequestGenerationTuple(
    const RequestGenerationTupleInput& input);

}  // namespace aegis_access

#endif  // COMPONENTS_AEGIS_ACCESS_REQUEST_GENERATION_TUPLE_BUILDER_H_
