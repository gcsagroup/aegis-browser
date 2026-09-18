// Copyright 2026 GCSA

#include "components/aegis_access/access_base_proxy_config_generation_state.h"

#include <limits>

namespace aegis_access {

BaseProxyConfigGenerationResult
BaseProxyConfigGenerationState::PublishCurrentConfig() {
  if (exhausted_) {
    return {BaseProxyConfigGenerationStatus::kExhausted, 0};
  }
  if (generation_ != 0) {
    return {BaseProxyConfigGenerationStatus::kUnchanged, generation_};
  }

  generation_ = 1;
  return {BaseProxyConfigGenerationStatus::kPublished, generation_};
}

BaseProxyConfigGenerationResult
BaseProxyConfigGenerationState::AdvanceOnConfigChange() {
  if (exhausted_) {
    return {BaseProxyConfigGenerationStatus::kExhausted, 0};
  }
  if (generation_ == std::numeric_limits<uint64_t>::max()) {
    exhausted_ = true;
    generation_ = 0;
    return {BaseProxyConfigGenerationStatus::kExhausted, 0};
  }

  ++generation_;
  return {generation_ == 1 ? BaseProxyConfigGenerationStatus::kPublished
                           : BaseProxyConfigGenerationStatus::kAdvanced,
          generation_};
}

}  // namespace aegis_access
