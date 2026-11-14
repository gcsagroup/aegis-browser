// Copyright 2026 GCSA
#include "chrome/browser/aegis/aegis_service.h"

#import <AppKit/AppKit.h>

#include <memory>
#include <string_view>
#include <utility>

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/bind_post_task.h"
#include "chrome/browser/aegis/access/access_account_mac.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/global_features.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_collection_observer.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"

namespace aegis {
namespace {

base::DictValue AccountState(std::string_view state) {
  return base::DictValue().Set("state", state);
}

base::DictValue ResolveAccountReply(AegisAccountReply resolve) {
  NSData* json = [NSJSONSerialization dataWithJSONObject:resolve()
                                                options:0
                                                  error:nil];
  auto parsed = json ? base::JSONReader::ReadDict(
      std::string_view(static_cast<const char*>(json.bytes), json.length),
      base::JSON_PARSE_RFC) : std::nullopt;
  return parsed ? std::move(*parsed) : AccountState("unavailable");
}

GlobalBrowserCollection* Browsers() {
  auto* features = g_browser_process ? g_browser_process->GetFeatures() : nullptr;
  return features ? features->global_browser_collection() : nullptr;
}

class AccountBrowserObserver : public BrowserCollectionObserver {
 public:
  AccountBrowserObserver(GlobalBrowserCollection* browsers,
                         base::RepeatingClosure changed)
      : changed_(std::move(changed)) {
    if (browsers) observation_.Observe(browsers);
  }

  void OnBrowserActivated(BrowserWindowInterface* browser) override {
    changed_.Run();
  }

  void OnBrowserClosed(BrowserWindowInterface* browser) override {
    changed_.Run();
  }

 private:
  base::RepeatingClosure changed_;
  base::ScopedObservation<GlobalBrowserCollection, BrowserCollectionObserver>
      observation_{this};
};

}  // namespace

void AegisService::InitializeAccessAccountRefresh() {
  if (!profile_->IsRegularProfile() || profile_->IsOffTheRecord()) {
    return;
  }
  auto changed = base::BindRepeating(
      &AegisService::AccessAccountApplicationStateChanged,
      weak_ptr_factory_.GetWeakPtr());
  auto browsers = std::make_unique<AccountBrowserObserver>(Browsers(), changed);
  auto on_activation = ^(NSNotification*) { changed.Run(); };
  NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
  id active = [center addObserverForName:NSApplicationDidBecomeActiveNotification
      object:nil queue:NSOperationQueue.mainQueue usingBlock:on_activation];
  id inactive = [center addObserverForName:NSApplicationDidResignActiveNotification
      object:nil queue:NSOperationQueue.mainQueue usingBlock:on_activation];
  access_account_activation_observer_ = base::ScopedClosureRunner(base::BindOnce(
      [](NSNotificationCenter* center, id active, id inactive,
         std::unique_ptr<AccountBrowserObserver> browsers) {
        [center removeObserver:active];
        [center removeObserver:inactive];
      }, center, active, inactive, std::move(browsers)));
  AccessAccountApplicationStateChanged();
}

void AegisService::StopAccessAccountRefresh() {
  access_account_activation_observer_.RunAndReset();
  access_account_timer_.Stop();
  access_account_refresh_.SetActivity(false, false, base::TimeTicks::Now());
  access_account_reply_.Reset();
  access_account_reply_state_.clear();
  access_account_query_unavailable_ = false;
  access_account_waiters_.clear();
}

void AegisService::AccessAccountApplicationStateChanged() {
  auto* browsers = Browsers();
  auto* browser = browsers ? browsers->GetLastActiveBrowser() : nullptr;
  access_account_refresh_.SetActivity(NSApp.active,
      browser && browser->GetProfile() == profile_, base::TimeTicks::Now());
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
  __block auto reply = base::BindPostTaskToCurrentDefault(base::BindOnce(
      [](base::WeakPtr<AegisService> service, AegisAccountReply resolve) {
        if (service && service->IsInitializedForProfile(service->profile())) {
          service->OnAccessAccountReady(
              base::BindRepeating(&ResolveAccountReply, resolve));
        }
      }, weak_ptr_factory_.GetWeakPtr()));
  AegisQueryAccessAccount(base::SysUTF8ToNSString(profile_->GetPath().value()),
      ^(AegisAccountReply resolve) { std::move(reply).Run(resolve); });
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
