// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_ACCESS_IDENTITY_GENERATION_STATE_CONTRACT_TEST_H_
#define COMPONENTS_AEGIS_ACCESS_ACCESS_IDENTITY_GENERATION_STATE_CONTRACT_TEST_H_

#include <cstdint>
#include <limits>
#include <string>

#include "components/aegis_access/access_identity_generation_state.h"

namespace aegis_access {

class IdentityGenerationStateTestPeer {
 public:
  static void SetGeneration(IdentityGenerationState* state,
                            uint64_t generation) {
    state->generation_ = generation;
  }
};

namespace test {

class IdentityGenerationStateTestObserver {
 public:
  virtual ~IdentityGenerationStateTestObserver() = default;
  virtual void Expect(bool condition, const std::string& label) = 0;
};

inline AccessIdentityBinding InstallationGuestIdentity() {
  return {AccessIdentityKind::kInstallationGuest, "visitor-principal",
          "visitor-entitlement", "prod", "access"};
}

inline AccessIdentityBinding AuthenticatedIdentity() {
  return {AccessIdentityKind::kAuthenticated, "account-principal",
          "account-entitlement", "prod", "access"};
}

inline AccessIdentityBinding SignedOutIdentity() {
  return {AccessIdentityKind::kSignedOut, "", "", "prod", "access"};
}

inline void ExpectInitialIdentityUnpublished(
    IdentityGenerationStateTestObserver& observer,
    const IdentityGenerationState& state) {
  observer.Expect(state.generation() == 0,
                  "identity generation unit starts at zero");
  observer.Expect(!state.binding().has_value(),
                  "identity generation unit starts without binding");
  observer.Expect(!state.exhausted(),
                  "identity generation unit starts available");
}

inline void ExpectFirstGuestCommit(
    IdentityGenerationStateTestObserver& observer,
    IdentityGenerationState& state) {
  const IdentityGenerationCommitResult result =
      state.Commit(InstallationGuestIdentity());
  observer.Expect(result.status == IdentityGenerationCommitStatus::kCommitted,
                  "identity generation unit commits installation guest");
  observer.Expect(result.generation == 1,
                  "identity generation unit first commit publishes one");
  observer.Expect(state.generation() == 1,
                  "identity generation unit stores first generation");
  observer.Expect(state.binding().has_value(),
                  "identity generation unit stores guest binding");
  observer.Expect(
      state.binding()->kind == AccessIdentityKind::kInstallationGuest,
      "identity generation unit binding is installation guest");
}

inline void ExpectDuplicateGuestIsIdempotent(
    IdentityGenerationStateTestObserver& observer,
    IdentityGenerationState& state) {
  const IdentityGenerationCommitResult result =
      state.Commit(InstallationGuestIdentity());
  observer.Expect(result.status == IdentityGenerationCommitStatus::kUnchanged,
                  "identity generation unit duplicate commit is unchanged");
  observer.Expect(result.generation == 1,
                  "identity generation unit duplicate keeps generation");
  observer.Expect(state.generation() == 1,
                  "identity generation unit duplicate keeps stored generation");
}

inline void ExpectAuthenticatedTransition(
    IdentityGenerationStateTestObserver& observer,
    IdentityGenerationState& state) {
  const IdentityGenerationCommitResult result =
      state.Commit(AuthenticatedIdentity());
  observer.Expect(result.status == IdentityGenerationCommitStatus::kCommitted,
                  "identity generation unit account transition commits");
  observer.Expect(result.generation == 2,
                  "identity generation unit account transition advances");
  observer.Expect(
      state.binding()->kind == AccessIdentityKind::kAuthenticated,
      "identity generation unit binding is authenticated");
}

inline void ExpectSignedOutTransition(
    IdentityGenerationStateTestObserver& observer,
    IdentityGenerationState& state) {
  const IdentityGenerationCommitResult result =
      state.Commit(SignedOutIdentity());
  observer.Expect(result.status == IdentityGenerationCommitStatus::kCommitted,
                  "identity generation unit sign out commits");
  observer.Expect(result.generation == 3,
                  "identity generation unit sign out advances");
  observer.Expect(state.binding()->kind == AccessIdentityKind::kSignedOut,
                  "identity generation unit binding is signed out");
}

inline void ExpectExplicitGuestReturn(
    IdentityGenerationStateTestObserver& observer,
    IdentityGenerationState& state) {
  const IdentityGenerationCommitResult result =
      state.Commit(InstallationGuestIdentity());
  observer.Expect(result.status == IdentityGenerationCommitStatus::kCommitted,
                  "identity generation unit guest return commits");
  observer.Expect(result.generation == 4,
                  "identity generation unit guest return advances");
  observer.Expect(state.generation() == 4,
                  "identity generation unit stores guest return generation");
}

inline void ExpectInvalidGuestNeverPublishes(
    IdentityGenerationStateTestObserver& observer) {
  IdentityGenerationState state;
  AccessIdentityBinding binding = InstallationGuestIdentity();
  binding.principal_id.clear();
  const IdentityGenerationCommitResult result = state.Commit(binding);
  observer.Expect(
      result.status == IdentityGenerationCommitStatus::kInvalidIdentity,
      "identity generation regression invalid guest is rejected");
  observer.Expect(result.generation == 0,
                  "identity generation regression invalid guest returns zero");
  observer.Expect(state.generation() == 0,
                  "identity generation regression invalid guest keeps zero");
  observer.Expect(!state.binding().has_value(),
                  "identity generation regression invalid guest stays unpublished");
}

inline void ExpectSignedOutCannotRetainPrincipal(
    IdentityGenerationStateTestObserver& observer) {
  IdentityGenerationState state;
  AccessIdentityBinding binding = SignedOutIdentity();
  binding.principal_id = "stale-principal";
  const IdentityGenerationCommitResult result = state.Commit(binding);
  observer.Expect(
      result.status == IdentityGenerationCommitStatus::kInvalidIdentity,
      "identity generation regression stale signed-out principal is rejected");
  observer.Expect(state.generation() == 0,
                  "identity generation regression invalid sign out keeps zero");
}

inline void ExpectIdentityOwnersAreIsolated(
    IdentityGenerationStateTestObserver& observer) {
  IdentityGenerationState first;
  IdentityGenerationState second;
  first.Commit(InstallationGuestIdentity());
  observer.Expect(first.generation() == 1,
                  "identity generation regression first owner advances");
  observer.Expect(second.generation() == 0,
                  "identity generation regression second owner stays zero");
  observer.Expect(!second.binding().has_value(),
                  "identity generation regression second owner stays unpublished");
}

inline void ExpectIdentityGenerationOverflowFailsClosed(
    IdentityGenerationStateTestObserver& observer) {
  IdentityGenerationState state;
  state.Commit(InstallationGuestIdentity());
  IdentityGenerationStateTestPeer::SetGeneration(
      &state, std::numeric_limits<uint64_t>::max());

  const IdentityGenerationCommitResult exhausted =
      state.Commit(AuthenticatedIdentity());
  observer.Expect(
      exhausted.status == IdentityGenerationCommitStatus::kExhausted,
      "identity generation regression overflow reports exhausted");
  observer.Expect(exhausted.generation == 0,
                  "identity generation regression overflow returns zero");
  observer.Expect(state.generation() == 0,
                  "identity generation regression overflow stores zero");
  observer.Expect(state.exhausted(),
                  "identity generation regression overflow is permanent");
  observer.Expect(!state.binding().has_value(),
                  "identity generation regression overflow clears binding");

  const IdentityGenerationCommitResult retry =
      state.Commit(InstallationGuestIdentity());
  observer.Expect(retry.status == IdentityGenerationCommitStatus::kExhausted,
                  "identity generation regression exhausted retry is rejected");
  observer.Expect(retry.generation == 0,
                  "identity generation regression exhausted retry stays zero");
  observer.Expect(!state.binding().has_value(),
                  "identity generation regression exhausted retry stays unpublished");
}

inline void RunIdentityGenerationStateUnitTests(
    IdentityGenerationStateTestObserver& observer) {
  IdentityGenerationState state;
  ExpectInitialIdentityUnpublished(observer, state);
  ExpectFirstGuestCommit(observer, state);
  ExpectDuplicateGuestIsIdempotent(observer, state);
  ExpectAuthenticatedTransition(observer, state);
  ExpectSignedOutTransition(observer, state);
  ExpectExplicitGuestReturn(observer, state);
}

inline void RunIdentityGenerationStateRegressionTests(
    IdentityGenerationStateTestObserver& observer) {
  ExpectInvalidGuestNeverPublishes(observer);
  ExpectSignedOutCannotRetainPrincipal(observer);
  ExpectIdentityOwnersAreIsolated(observer);
  ExpectIdentityGenerationOverflowFailsClosed(observer);
}

}  // namespace test
}  // namespace aegis_access

#endif  // COMPONENTS_AEGIS_ACCESS_ACCESS_IDENTITY_GENERATION_STATE_CONTRACT_TEST_H_
