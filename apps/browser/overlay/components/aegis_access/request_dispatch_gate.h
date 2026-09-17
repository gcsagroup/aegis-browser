// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_REQUEST_DISPATCH_GATE_H_
#define COMPONENTS_AEGIS_ACCESS_REQUEST_DISPATCH_GATE_H_

#include <optional>

#include "components/aegis_access/request_ownership_registry.h"

namespace aegis_access {

enum class RequestDispatchGateStatus {
  kAllowRegistered,
  kBlockedByBarrier,
  kInvalidRequest,
  kRegistrationFailed,
  kInvalidDependencies,
};

struct RequestDispatchGateResult {
  RequestDispatchGateStatus status =
      RequestDispatchGateStatus::kInvalidDependencies;
  RequestDispatchDecision decision = RequestDispatchDecision::kBlock;
  RequestDispatchBarrierStatus barrier_status =
      RequestDispatchBarrierStatus::kInvalidRequest;
  RequestOwnershipStatus ownership_status =
      RequestOwnershipStatus::kInvalidRecord;
  std::optional<RequestDispatchBarrier> barrier;
};

RequestDispatchGateResult EvaluateAndRegisterRequestForDispatch(
    RequestOwnershipRecord record,
    const RequestDispatchBarrierRegistry* barriers,
    RequestOwnershipRegistry* ownership_registry);

}  // namespace aegis_access

#endif  // COMPONENTS_AEGIS_ACCESS_REQUEST_DISPATCH_GATE_H_
