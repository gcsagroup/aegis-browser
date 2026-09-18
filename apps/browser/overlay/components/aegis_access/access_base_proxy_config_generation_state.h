// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_ACCESS_BASE_PROXY_CONFIG_GENERATION_STATE_H_
#define COMPONENTS_AEGIS_ACCESS_ACCESS_BASE_PROXY_CONFIG_GENERATION_STATE_H_

#include <cstdint>

namespace aegis_access {

enum class BaseProxyConfigGenerationStatus {
  kPublished,
  kUnchanged,
  kAdvanced,
  kExhausted,
};

struct BaseProxyConfigGenerationResult {
  BaseProxyConfigGenerationStatus status =
      BaseProxyConfigGenerationStatus::kUnchanged;
  uint64_t generation = 0;
};

// Tracks the generation of Chromium's native proxy configuration.
//
// Zero means the base proxy configuration has not been published yet, or the
// generation space has been exhausted. The first observed VALID/UNSET config
// publishes generation one. Subsequent native proxy change notifications
// advance monotonically. Re-attaching another NetworkContext to the same
// current config is idempotent.
class BaseProxyConfigGenerationState {
 public:
  BaseProxyConfigGenerationState() = default;

  uint64_t generation() const { return generation_; }
  bool exhausted() const { return exhausted_; }

  BaseProxyConfigGenerationResult PublishCurrentConfig();
  BaseProxyConfigGenerationResult AdvanceOnConfigChange();

 private:
  friend class BaseProxyConfigGenerationStateTestPeer;

  bool exhausted_ = false;
  uint64_t generation_ = 0;
};

}  // namespace aegis_access

#endif  // COMPONENTS_AEGIS_ACCESS_ACCESS_BASE_PROXY_CONFIG_GENERATION_STATE_H_
