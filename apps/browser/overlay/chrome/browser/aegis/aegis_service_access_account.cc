// Copyright 2026 GCSA
#include "chrome/browser/aegis/aegis_service.h"

#include <string_view>
#include <utility>

#include "base/functional/bind.h"
#include "chrome/browser/profiles/profile.h"

namespace aegis {
namespace {
base::DictValue AccountState(std::string_view state) {
  return base::DictValue().Set("state", state);
}
}  // namespace

void AegisService::StopAccessAccountRefresh() {
  access_account_activation_observer_.RunAndReset();
#if BUILDFLAG(IS_WIN)
  access_account_activity_timer_.Stop();
  access_account_activity_.reset();
#endif
  access_account_timer_.Stop();
  access_account_refresh_.SetActivity(false, false, base::TimeTicks::Now());
  access_account_reply_.Reset();
  access_account_reply_state_.clear();
  access_account_query_unavailable_ = false;
  access_account_waiters_.clear();
}

void AegisService::UpdateAccessAccountActivity(bool foreground, bool active_profile) {
  const auto now = base::TimeTicks::Now();
  access_account_refresh_.SetActivity(foreground, active_profile, now);
  ScheduleAccessAccountRefresh();
}

base::ScopedClosureRunner AegisService::ObserveAccessAccountUsage() {
  const auto owner = base::UnguessableToken::Create();
  SetAccessAccountUsageVisible(owner, true);
  return base::ScopedClosureRunner(base::BindOnce(
      &AegisService::SetAccessAccountUsageVisible,
      weak_ptr_factory_.GetWeakPtr(), owner, false));
}

void AegisService::SetAccessAccountUsageVisible(base::UnguessableToken owner,
                                               bool visible) {
  if (!profile_ || !initialized_ || !profile_->IsRegularProfile() ||
      profile_->IsOffTheRecord()) {
    return;
  }
  access_account_refresh_.SetVisible(owner, visible, base::TimeTicks::Now());
  ScheduleAccessAccountRefresh();
}

void AegisService::ScheduleAccessAccountRefresh() {
  access_account_timer_.Stop();
  if (!initialized_) {
    return;
  }
  auto delay = access_account_refresh_.DueIn(base::TimeTicks::Now());
  if (delay) {
    access_account_timer_.Start(
        FROM_HERE, *delay, base::BindOnce(&AegisService::StartAccessAccountRefresh,
                                         weak_ptr_factory_.GetWeakPtr(), false));
  }
}

base::DictValue AegisService::CurrentAccessAccountSnapshot() {
  return ResolveAccessAccountSnapshot(true);
}

base::DictValue AegisService::ResolveAccessAccountSnapshot(bool reschedule) {
  if (!profile_ || !initialized_ || !profile_->IsRegularProfile() ||
      profile_->IsOffTheRecord()) {
    return AccountState("signed_out");
  }
  if (access_account_reply_.is_null()) {
    return AccountState(access_account_refresh_.in_flight() ? "loading"
                                                             : "unavailable");
  }
  auto result = access_account_reply_.Run();
  const auto* state = result.FindString("state");
  if (state && *state != access_account_reply_state_) {
    access_account_reply_.Reset();
    access_account_reply_state_.clear();
    access_account_query_unavailable_ = false;
    access_account_refresh_.IdentityChanged(base::TimeTicks::Now());
    if (reschedule) ScheduleAccessAccountRefresh();
  } else if (state && *state == "available" && result.FindDict("entitlement") &&
             (access_account_query_unavailable_ ||
              access_account_refresh_.in_flight())) {
    result.Set("state", access_account_query_unavailable_ ? "unavailable"
                                                         : "loading");
    result.Set("stale", true);
  }
  return result;
}

void AegisService::QueryCurrentAccessAccount(
    base::OnceCallback<void(base::DictValue)> callback) {
  if (!profile_ || !initialized_ || !profile_->IsRegularProfile() ||
      profile_->IsOffTheRecord()) {
    std::move(callback).Run(AccountState("signed_out"));
    return;
  }
  access_account_waiters_.push_back(std::move(callback));
  StartAccessAccountRefresh(true);
}

void AegisService::StartAccessAccountRefresh(bool manual) {
  if (!profile_ || !initialized_) {
    return;
  }
  // A newly switched identity does not inherit the previous account's
  // debounce or retry delay.
  if (access_account_reply_) ResolveAccessAccountSnapshot(false);
  if (!access_account_refresh_.Begin(base::TimeTicks::Now(), manual)) {
    if (!access_account_refresh_.in_flight()) {
      auto weak = weak_ptr_factory_.GetWeakPtr();
      auto callbacks = std::exchange(access_account_waiters_, {});
      for (auto& callback : callbacks) {
        if (!weak) break;
        std::move(callback).Run(weak->CurrentAccessAccountSnapshot());
      }
    }
    return;
  }
  access_account_timer_.Stop();
  RequestAccessAccountSnapshot();
}

void AegisService::OnAccessAccountReady(
    base::RepeatingCallback<base::DictValue()> resolve) {
  auto result = resolve.Run();
  const auto* state = result.FindString("state");
  const std::string_view reply_state =
      state ? std::string_view(*state) : "unavailable";
  access_account_query_unavailable_ = reply_state == "unavailable";
  // A failed refresh can keep the prior observation only while its original
  // Profile binding still validates on every read. Sign-out and identity
  // replacement discard it regardless of the previous balance.
  if (access_account_query_unavailable_ &&
      access_account_reply_state_ == "available") {
    ResolveAccessAccountSnapshot(false);
  } else {
    access_account_reply_ = std::move(resolve);
    access_account_reply_state_ = reply_state;
  }
  const auto now = base::TimeTicks::Now();
  access_account_refresh_.Complete(reply_state == "available" ||
                                       reply_state == "signed_out",
                                   now);
  if (reply_state == "superseded") {
    access_account_refresh_.IdentityChanged(now);
  }
  ScheduleAccessAccountRefresh();
  auto weak = weak_ptr_factory_.GetWeakPtr();
  auto callbacks = std::exchange(access_account_waiters_, {});
  for (auto& callback : callbacks) {
    if (!weak) break;
    std::move(callback).Run(weak->CurrentAccessAccountSnapshot());
  }
}

}  // namespace aegis
