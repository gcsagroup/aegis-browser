// Copyright 2026 GCSA

#include "components/aegis_access/access_proxy_selection_generation_state.h"

#include <limits>
#include <utility>

namespace aegis_access {
namespace {

bool IsValidSelectionBinding(const AccessProxySelectionBinding& binding) {
  return !binding.proxy_group_id.empty() && !binding.endpoint_id.empty() &&
         !binding.lease_id.empty() && !binding.assignment_id.empty() &&
         binding.binding_revision != 0;
}

}  // namespace

ProxySelectionGenerationCommitResult ProxySelectionGenerationState::Commit(
    AccessProxySelectionBinding binding) {
  if (exhausted_) {
    return {ProxySelectionGenerationCommitStatus::kExhausted, 0};
  }
  if (!IsValidSelectionBinding(binding)) {
    return {ProxySelectionGenerationCommitStatus::kInvalidSelection,
            generation_};
  }
  if (binding_.has_value() && *binding_ == binding) {
    return {ProxySelectionGenerationCommitStatus::kUnchanged, generation_};
  }
  if (binding_.has_value() &&
      binding.proxy_group_id != binding_->proxy_group_id) {
    return {ProxySelectionGenerationCommitStatus::kWrongProxyGroup,
            generation_};
  }
  if (binding_.has_value() &&
      binding.binding_revision <= binding_->binding_revision) {
    return {ProxySelectionGenerationCommitStatus::kStaleBindingRevision,
            generation_};
  }
  if (generation_ == std::numeric_limits<uint64_t>::max()) {
    exhausted_ = true;
    generation_ = 0;
    binding_.reset();
    return {ProxySelectionGenerationCommitStatus::kExhausted, 0};
  }

  ++generation_;
  binding_ = std::move(binding);
  return {ProxySelectionGenerationCommitStatus::kCommitted, generation_};
}

}  // namespace aegis_access
