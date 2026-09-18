// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_ACCESS_PROXY_SELECTION_GENERATION_STATE_H_
#define COMPONENTS_AEGIS_ACCESS_ACCESS_PROXY_SELECTION_GENERATION_STATE_H_

#include <cstdint>
#include <optional>
#include <string>

namespace aegis_access {

struct AccessProxySelectionBinding {
  std::string proxy_group_id;
  std::string endpoint_id;
  std::string lease_id;
  std::string assignment_id;
  uint64_t binding_revision = 0;

  friend bool operator==(const AccessProxySelectionBinding&,
                         const AccessProxySelectionBinding&) = default;
};

enum class ProxySelectionGenerationCommitStatus {
  kCommitted,
  kUnchanged,
  kInvalidSelection,
  kWrongProxyGroup,
  kStaleBindingRevision,
  kExhausted,
};

struct ProxySelectionGenerationCommitResult {
  ProxySelectionGenerationCommitStatus status =
      ProxySelectionGenerationCommitStatus::kInvalidSelection;
  uint64_t generation = 0;
};

// Monotonic generation for one logical proxy group's committed endpoint
// binding. Candidate probes and uncommitted switch attempts stay outside this
// state. A binding may advance only with a strictly newer binding_revision.
class ProxySelectionGenerationState {
 public:
  ProxySelectionGenerationState() = default;

  ProxySelectionGenerationState(const ProxySelectionGenerationState&) = delete;
  ProxySelectionGenerationState& operator=(
      const ProxySelectionGenerationState&) = delete;

  uint64_t generation() const { return generation_; }
  bool exhausted() const { return exhausted_; }
  const std::optional<AccessProxySelectionBinding>& binding() const {
    return binding_;
  }

  ProxySelectionGenerationCommitResult Commit(
      AccessProxySelectionBinding binding);

 private:
  friend class ProxySelectionGenerationStateTestPeer;

  bool exhausted_ = false;
  uint64_t generation_ = 0;
  std::optional<AccessProxySelectionBinding> binding_;
};

}  // namespace aegis_access

#endif  // COMPONENTS_AEGIS_ACCESS_ACCESS_PROXY_SELECTION_GENERATION_STATE_H_
