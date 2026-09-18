// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_ACCESS_PROXY_SELECTION_GENERATION_STATE_CONTRACT_TEST_H_
#define COMPONENTS_AEGIS_ACCESS_ACCESS_PROXY_SELECTION_GENERATION_STATE_CONTRACT_TEST_H_

#include <cstdint>
#include <limits>
#include <string>

#include "components/aegis_access/access_proxy_selection_generation_state.h"

namespace aegis_access {

class ProxySelectionGenerationStateTestPeer {
 public:
  static void SetGeneration(ProxySelectionGenerationState* state,
                            uint64_t generation) {
    state->generation_ = generation;
  }
};

namespace test {

class ProxySelectionGenerationStateTestObserver {
 public:
  virtual ~ProxySelectionGenerationStateTestObserver() = default;
  virtual void Expect(bool condition, const std::string& label) = 0;
};

inline AccessProxySelectionBinding InitialSelection() {
  return {"group-a", "endpoint-a", "lease-a", "assignment-a", 1};
}

inline AccessProxySelectionBinding SwitchedSelection() {
  return {"group-a", "endpoint-b", "lease-b", "assignment-b", 2};
}

inline void ExpectSelectionStartsUnpublished(
    ProxySelectionGenerationStateTestObserver& observer,
    const ProxySelectionGenerationState& state) {
  observer.Expect(state.generation() == 0,
                  "selection generation unit starts at zero");
  observer.Expect(!state.binding().has_value(),
                  "selection generation unit starts without binding");
  observer.Expect(!state.exhausted(),
                  "selection generation unit starts available");
}

inline void ExpectInitialSelectionCommit(
    ProxySelectionGenerationStateTestObserver& observer,
    ProxySelectionGenerationState& state) {
  const ProxySelectionGenerationCommitResult result =
      state.Commit(InitialSelection());
  observer.Expect(
      result.status == ProxySelectionGenerationCommitStatus::kCommitted,
      "selection generation unit initial binding commits");
  observer.Expect(result.generation == 1,
                  "selection generation unit first commit publishes one");
  observer.Expect(state.binding().has_value(),
                  "selection generation unit stores first binding");
  observer.Expect(state.binding()->endpoint_id == "endpoint-a",
                  "selection generation unit stores first endpoint");
}

inline void ExpectDuplicateSelectionIsIdempotent(
    ProxySelectionGenerationStateTestObserver& observer,
    ProxySelectionGenerationState& state) {
  const ProxySelectionGenerationCommitResult result =
      state.Commit(InitialSelection());
  observer.Expect(
      result.status == ProxySelectionGenerationCommitStatus::kUnchanged,
      "selection generation unit duplicate binding is unchanged");
  observer.Expect(result.generation == 1,
                  "selection generation unit duplicate keeps generation");
}

inline void ExpectEndpointSwitchAdvances(
    ProxySelectionGenerationStateTestObserver& observer,
    ProxySelectionGenerationState& state) {
  const ProxySelectionGenerationCommitResult result =
      state.Commit(SwitchedSelection());
  observer.Expect(
      result.status == ProxySelectionGenerationCommitStatus::kCommitted,
      "selection generation unit endpoint switch commits");
  observer.Expect(result.generation == 2,
                  "selection generation unit endpoint switch advances");
  observer.Expect(state.binding()->endpoint_id == "endpoint-b",
                  "selection generation unit stores switched endpoint");
}

inline void ExpectLeaseRefreshAdvances(
    ProxySelectionGenerationStateTestObserver& observer,
    ProxySelectionGenerationState& state) {
  AccessProxySelectionBinding refresh = SwitchedSelection();
  refresh.lease_id = "lease-b2";
  refresh.assignment_id = "assignment-b2";
  refresh.binding_revision = 3;
  const ProxySelectionGenerationCommitResult result =
      state.Commit(refresh);
  observer.Expect(
      result.status == ProxySelectionGenerationCommitStatus::kCommitted,
      "selection generation unit lease refresh commits");
  observer.Expect(result.generation == 3,
                  "selection generation unit lease refresh advances");
}

inline void ExpectInvalidSelectionNeverPublishes(
    ProxySelectionGenerationStateTestObserver& observer) {
  ProxySelectionGenerationState state;
  AccessProxySelectionBinding invalid = InitialSelection();
  invalid.lease_id.clear();
  const ProxySelectionGenerationCommitResult result = state.Commit(invalid);
  observer.Expect(
      result.status == ProxySelectionGenerationCommitStatus::kInvalidSelection,
      "selection generation regression invalid binding is rejected");
  observer.Expect(state.generation() == 0,
                  "selection generation regression invalid binding keeps zero");
  observer.Expect(!state.binding().has_value(),
                  "selection generation regression invalid binding stays unpublished");
}

inline void ExpectStaleRevisionCannotOverwrite(
    ProxySelectionGenerationStateTestObserver& observer) {
  ProxySelectionGenerationState state;
  state.Commit(InitialSelection());
  state.Commit(SwitchedSelection());

  AccessProxySelectionBinding stale = InitialSelection();
  stale.endpoint_id = "endpoint-stale";
  const ProxySelectionGenerationCommitResult result = state.Commit(stale);
  observer.Expect(
      result.status ==
          ProxySelectionGenerationCommitStatus::kStaleBindingRevision,
      "selection generation regression stale revision is rejected");
  observer.Expect(state.generation() == 2,
                  "selection generation regression stale revision keeps generation");
  observer.Expect(state.binding()->endpoint_id == "endpoint-b",
                  "selection generation regression stale revision keeps endpoint");
}

inline void ExpectProxyGroupCannotChangeOwner(
    ProxySelectionGenerationStateTestObserver& observer) {
  ProxySelectionGenerationState state;
  state.Commit(InitialSelection());

  AccessProxySelectionBinding other_group = SwitchedSelection();
  other_group.proxy_group_id = "group-b";
  other_group.binding_revision = 4;
  const ProxySelectionGenerationCommitResult result =
      state.Commit(other_group);
  observer.Expect(
      result.status == ProxySelectionGenerationCommitStatus::kWrongProxyGroup,
      "selection generation regression group ownership is immutable");
  observer.Expect(state.generation() == 1,
                  "selection generation regression wrong group keeps generation");
}

inline void ExpectSelectionStatesAreIsolated(
    ProxySelectionGenerationStateTestObserver& observer) {
  ProxySelectionGenerationState first;
  ProxySelectionGenerationState second;
  first.Commit(InitialSelection());
  observer.Expect(first.generation() == 1,
                  "selection generation regression first owner advances");
  observer.Expect(second.generation() == 0,
                  "selection generation regression second owner stays zero");
}

inline void ExpectSelectionGenerationOverflowFailsClosed(
    ProxySelectionGenerationStateTestObserver& observer) {
  ProxySelectionGenerationState state;
  state.Commit(InitialSelection());
  ProxySelectionGenerationStateTestPeer::SetGeneration(
      &state, std::numeric_limits<uint64_t>::max());

  const ProxySelectionGenerationCommitResult exhausted =
      state.Commit(SwitchedSelection());
  observer.Expect(
      exhausted.status == ProxySelectionGenerationCommitStatus::kExhausted,
      "selection generation regression overflow reports exhausted");
  observer.Expect(exhausted.generation == 0,
                  "selection generation regression overflow returns zero");
  observer.Expect(state.generation() == 0,
                  "selection generation regression overflow stores zero");
  observer.Expect(state.exhausted(),
                  "selection generation regression overflow is permanent");
  observer.Expect(!state.binding().has_value(),
                  "selection generation regression overflow clears binding");

  const ProxySelectionGenerationCommitResult retry =
      state.Commit(InitialSelection());
  observer.Expect(
      retry.status == ProxySelectionGenerationCommitStatus::kExhausted,
      "selection generation regression exhausted retry is rejected");
  observer.Expect(retry.generation == 0,
                  "selection generation regression exhausted retry stays zero");
}

inline void RunProxySelectionGenerationStateUnitTests(
    ProxySelectionGenerationStateTestObserver& observer) {
  ProxySelectionGenerationState state;
  ExpectSelectionStartsUnpublished(observer, state);
  ExpectInitialSelectionCommit(observer, state);
  ExpectDuplicateSelectionIsIdempotent(observer, state);
  ExpectEndpointSwitchAdvances(observer, state);
  ExpectLeaseRefreshAdvances(observer, state);
}

inline void RunProxySelectionGenerationStateRegressionTests(
    ProxySelectionGenerationStateTestObserver& observer) {
  ExpectInvalidSelectionNeverPublishes(observer);
  ExpectStaleRevisionCannotOverwrite(observer);
  ExpectProxyGroupCannotChangeOwner(observer);
  ExpectSelectionStatesAreIsolated(observer);
  ExpectSelectionGenerationOverflowFailsClosed(observer);
}

}  // namespace test
}  // namespace aegis_access

#endif  // COMPONENTS_AEGIS_ACCESS_ACCESS_PROXY_SELECTION_GENERATION_STATE_CONTRACT_TEST_H_
