// Copyright 2026 GCSA

#include "components/aegis_access/request_dispatch_gate.h"

#include <utility>

namespace aegis_access {

RequestDispatchGateResult EvaluateAndRegisterRequestForDispatch(
    RequestOwnershipRecord record,
    const RequestDispatchBarrierRegistry* barriers,
    RequestOwnershipRegistry* ownership_registry) {
  if (!barriers || !ownership_registry) {
    return {RequestDispatchGateStatus::kInvalidDependencies,
            RequestDispatchDecision::kBlock,
            RequestDispatchBarrierStatus::kInvalidRequest,
            RequestOwnershipStatus::kInvalidRecord, std::nullopt};
  }

  const RequestDispatchEvaluationResult barrier_result =
      barriers->EvaluateRequest(record);
  if (barrier_result.decision != RequestDispatchDecision::kAllow ||
      barrier_result.status != RequestDispatchBarrierStatus::kOk) {
    const RequestDispatchGateStatus status =
        barrier_result.status == RequestDispatchBarrierStatus::kInvalidRequest
            ? RequestDispatchGateStatus::kInvalidRequest
            : RequestDispatchGateStatus::kBlockedByBarrier;
    return {status, RequestDispatchDecision::kBlock, barrier_result.status,
            RequestOwnershipStatus::kInvalidRecord, barrier_result.barrier};
  }

  const RequestOwnershipStatus ownership_status =
      ownership_registry->Register(std::move(record));
  if (ownership_status != RequestOwnershipStatus::kOk) {
    return {RequestDispatchGateStatus::kRegistrationFailed,
            RequestDispatchDecision::kBlock, barrier_result.status,
            ownership_status, std::nullopt};
  }

  return {RequestDispatchGateStatus::kAllowRegistered,
          RequestDispatchDecision::kAllow, barrier_result.status,
          RequestOwnershipStatus::kOk, std::nullopt};
}

}  // namespace aegis_access
