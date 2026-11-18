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

base::DictValue ResolveAccountReply(AegisAccountReply resolve) {
  NSData* json = [NSJSONSerialization dataWithJSONObject:resolve()
                                                options:0
                                                  error:nil];
  auto parsed = json ? base::JSONReader::ReadDict(
      std::string_view(static_cast<const char*>(json.bytes), json.length),
      base::JSON_PARSE_RFC) : std::nullopt;
  return parsed ? std::move(*parsed) : base::DictValue().Set("state", "unavailable");
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

void AegisService::AccessAccountApplicationStateChanged() {
  auto* browsers = Browsers();
  auto* browser = browsers ? browsers->GetLastActiveBrowser() : nullptr;
  UpdateAccessAccountActivity(NSApp.active, browser && browser->GetProfile() == profile_);
}

void AegisService::RequestAccessAccountSnapshot() {
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

}  // namespace aegis
