// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_ACCESS_BASE_PROXY_CONFIG_GENERATION_STATE_CONTRACT_TEST_H_
#define COMPONENTS_AEGIS_ACCESS_ACCESS_BASE_PROXY_CONFIG_GENERATION_STATE_CONTRACT_TEST_H_

#include <cstdint>
#include <limits>
#include <string>

#include "components/aegis_access/access_base_proxy_config_generation_state.h"

namespace aegis_access {

class BaseProxyConfigGenerationStateTestPeer {
 public:
  static void SetGeneration(BaseProxyConfigGenerationState* state,
                            uint64_t generation) {
    state->generation_ = generation;
  }
};

namespace test {

class BaseProxyConfigGenerationStateTestObserver {
 public:
  virtual ~BaseProxyConfigGenerationStateTestObserver() = default;
  virtual void Expect(bool condition, const std::string& label) = 0;
};

inline void ExpectBaseProxyConfigStartsUnpublished(
    BaseProxyConfigGenerationStateTestObserver& observer) {
  BaseProxyConfigGenerationState state;
  observer.Expect(state.generation() == 0,
                  "base proxy generation starts at zero");
  observer.Expect(!state.exhausted(),
                  "base proxy generation starts available");
}

inline void ExpectFirstAvailableConfigPublishesOne(
    BaseProxyConfigGenerationStateTestObserver& observer) {
  BaseProxyConfigGenerationState state;
  const auto result = state.PublishCurrentConfig();
  observer.Expect(result.status == BaseProxyConfigGenerationStatus::kPublished,
                  "base proxy first available config publishes");
  observer.Expect(result.generation == 1,
                  "base proxy first available config publishes generation one");
  observer.Expect(state.generation() == 1,
                  "base proxy state stores generation one");
}

inline void ExpectRepeatedAttachIsIdempotent(
    BaseProxyConfigGenerationStateTestObserver& observer) {
  BaseProxyConfigGenerationState state;
  state.PublishCurrentConfig();
  const auto result = state.PublishCurrentConfig();
  observer.Expect(result.status == BaseProxyConfigGenerationStatus::kUnchanged,
                  "base proxy repeated attach is unchanged");
  observer.Expect(result.generation == 1,
                  "base proxy repeated attach keeps generation");
}

inline void ExpectNativeConfigChangeAdvances(
    BaseProxyConfigGenerationStateTestObserver& observer) {
  BaseProxyConfigGenerationState state;
  state.PublishCurrentConfig();
  const auto result = state.AdvanceOnConfigChange();
  observer.Expect(result.status == BaseProxyConfigGenerationStatus::kAdvanced,
                  "base proxy native config change advances");
  observer.Expect(result.generation == 2,
                  "base proxy native config change reaches generation two");
}

inline void ExpectChangeCanPublishFirstGeneration(
    BaseProxyConfigGenerationStateTestObserver& observer) {
  BaseProxyConfigGenerationState state;
  const auto result = state.AdvanceOnConfigChange();
  observer.Expect(result.status == BaseProxyConfigGenerationStatus::kPublished,
                  "base proxy change publishes when initial config was pending");
  observer.Expect(result.generation == 1,
                  "base proxy pending-to-available change publishes generation one");
}

inline void ExpectBaseProxyConfigGenerationOverflowFailsClosed(
    BaseProxyConfigGenerationStateTestObserver& observer) {
  BaseProxyConfigGenerationState state;
  state.PublishCurrentConfig();
  BaseProxyConfigGenerationStateTestPeer::SetGeneration(
      &state, std::numeric_limits<uint64_t>::max());

  const auto exhausted = state.AdvanceOnConfigChange();
  observer.Expect(exhausted.status ==
                      BaseProxyConfigGenerationStatus::kExhausted,
                  "base proxy generation overflow reports exhausted");
  observer.Expect(exhausted.generation == 0,
                  "base proxy generation overflow returns zero");
  observer.Expect(state.generation() == 0,
                  "base proxy generation overflow stores zero");
  observer.Expect(state.exhausted(),
                  "base proxy generation overflow is permanent");

  const auto retry = state.PublishCurrentConfig();
  observer.Expect(retry.status == BaseProxyConfigGenerationStatus::kExhausted,
                  "base proxy exhausted state rejects republish");
  observer.Expect(retry.generation == 0,
                  "base proxy exhausted state remains zero");
}

inline void RunBaseProxyConfigGenerationStateUnitTests(
    BaseProxyConfigGenerationStateTestObserver& observer) {
  ExpectBaseProxyConfigStartsUnpublished(observer);
  ExpectFirstAvailableConfigPublishesOne(observer);
  ExpectRepeatedAttachIsIdempotent(observer);
  ExpectNativeConfigChangeAdvances(observer);
  ExpectChangeCanPublishFirstGeneration(observer);
}

inline void RunBaseProxyConfigGenerationStateRegressionTests(
    BaseProxyConfigGenerationStateTestObserver& observer) {
  ExpectBaseProxyConfigGenerationOverflowFailsClosed(observer);
}

}  // namespace test
}  // namespace aegis_access

#endif  // COMPONENTS_AEGIS_ACCESS_ACCESS_BASE_PROXY_CONFIG_GENERATION_STATE_CONTRACT_TEST_H_
