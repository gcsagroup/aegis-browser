// Copyright 2026 GCSA
#import <AppKit/AppKit.h>
#import "chrome/browser/aegis/access/access_account_mac.h"
#include "chrome/browser/aegis/access/access_paid_site_mac.h"

#include <sys/stat.h>
#include <algorithm>
#include <set>
#include <vector>

#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/sys_string_conversions.h"
#include "base/supports_user_data.h"
#include "base/task/bind_post_task.h"
#include "base/timer/timer.h"
#include "chrome/browser/aegis/access/access_network_context_transport.h"
#include "chrome/browser/aegis/aegis_profile_support.h"
#include "chrome/browser/profiles/profile.h"
#include "content/public/browser/storage_partition.h"
#include "services/network/public/mojom/network_context.mojom.h"

namespace aegis::access {
namespace {
const char kLeaseKey[] = "aegis-account-node";

// Private authorization is independent, temporary, and entered only into
// native browser chrome. No regular profile binding is opened for OTR.
NSDictionary* AuthorizePrivate() {
  NSAlert* alert = [NSAlert new];
  alert.messageText = @"Authorize private Access session";
  alert.informativeText = @"Use the account service and session issued for this private window.";
  [alert addButtonWithTitle:@"Authorize"];
  [alert addButtonWithTitle:@"Cancel"];
  NSTextField* origin = [NSTextField textFieldWithString:@""];
  NSTextField* account = [NSTextField textFieldWithString:@""];
  NSSecureTextField* token = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
  origin.placeholderString = @"Account service origin";
  account.placeholderString = @"Account ID";
  token.placeholderString = @"Private account session";
  NSStackView* fields = [NSStackView stackViewWithViews:@[origin, account, token]];
  fields.orientation = NSUserInterfaceLayoutOrientationVertical;
  fields.alignment = NSLayoutAttributeLeading;
  fields.frame = NSMakeRect(0, 0, 320, 90);
  for (NSView* view in fields.arrangedSubviews)
    [view.widthAnchor constraintEqualToConstant:320].active = YES;
  alert.accessoryView = fields;
  if ([alert runModal] != NSAlertFirstButtonReturn) return nil;
  return @{@"origin":origin.stringValue, @"accountId":account.stringValue,
           @"token":token.stringValue};
}
class SiteLease final : public base::SupportsUserData::Data {
 public:
  explicit SiteLease(Profile* profile) : profile_(profile) {}
  ~SiteLease() override { if (revoke_) revoke_(); }
  AccountNodeStatus Status(const std::string& site) const {
    if (!sites_.contains(site)) return AccountNodeStatus::kOff;
    if (!auth_.empty()) {
      auto* transport = AccessNetworkContextTransport::Get(profile_);
      return transport && !transport->AccountDispatchBlocked(GURL("https://" + site + "/"))
          ? AccountNodeStatus::kAssigned : AccountNodeStatus::kAcquiring;
    }
    return in_flight_ ? AccountNodeStatus::kAcquiring : AccountNodeStatus::kUnavailable;
  }
  bool HasSites() const { return !sites_.empty(); }
  void Toggle(const std::string& site) {
    if (sites_.erase(site)) {
      Publish();
      if (sites_.empty()) Reset();
      return;
    }
    // A remaining selection does not imply a live grant after an issue or
    // renewal failure. Revalidate the current grant before publishing it.
    if (!auth_.empty() && (NSDate.date.timeIntervalSince1970 * 1000 >= expires_ ||
                           (change_ && change_()))) Reset();
    sites_.insert(site);
    if (!Publish()) { sites_.erase(site); return; }
    if (!auth_.empty() || in_flight_) return;
    // An abandoned in-flight POST may arrive after a later off/on cycle. Give
    // the new authorization its own context so the old POST cannot rotate it.
    context_ = NSUUID.UUID.UUIDString.lowercaseString;
    const bool otr = profile_->IsOffTheRecord();
    auto weak = weak_.GetWeakPtr();
    if (otr) {
      NSDictionary* binding = AuthorizePrivate();
      if (!weak) return;
      private_binding_ = binding;
      if (!binding) { sites_.erase(site); Publish(); Reset(); return; }
    }
    Issue();
  }
 private:
  bool Publish() {
    auto* route = AccessNetworkContextTransport::Get(profile_);
    return route && route->SetAccountNodeSites(
        std::vector<std::string>(sites_.begin(), sites_.end()), host_, port_, auth_);
  }
  void Issue() {
    in_flight_ = true;
    const bool otr = profile_->IsOffTheRecord();
    __block auto reply = base::BindPostTaskToCurrentDefault(base::BindOnce(
        [](base::WeakPtr<SiteLease> self, NSDictionary* lease,
           AegisAccountBindingChange change, AegisNodeRevoke revoke, AegisNodeRenew renew) {
          if (!self) { if (revoke) revoke(); return; }
          self->Accept(lease, change, revoke, renew);
        }, weak_.GetWeakPtr()));
    AegisIssueNode(otr ? nil : base::SysUTF8ToNSString(profile_->GetPath().value()),
                   context_, otr, private_binding_,
                   ^(NSDictionary* lease, AegisAccountBindingChange change, AegisNodeRevoke revoke, AegisNodeRenew renew) {
                     std::move(reply).Run(lease, change, revoke, renew);
                   });
  }
  void Accept(NSDictionary* lease, AegisAccountBindingChange change, AegisNodeRevoke revoke, AegisNodeRenew renew) {
    in_flight_ = false;
    if (!lease || (change_ && change_()) || (change && change())) {
      if (revoke) revoke();
      Reset(); Publish(); return;
    }
    if (revoke_) revoke_();
    revoke_ = revoke;
    extend_ = renew;
    change_ = change;
    expires_ = [lease[@"expiresAt"] doubleValue];
    double now = NSDate.date.timeIntervalSince1970 * 1000;
    if (now >= expires_) { Reset(); Publish(); return; }
    renew_ = RenewalTime(now, expires_);
    NSString* pair = [NSString stringWithFormat:@"%@:%@", lease[@"username"], lease[@"password"]];
    NSString* auth = [@"Basic " stringByAppendingString:
        [[pair dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]];
    host_ = base::SysNSStringToUTF8(lease[@"host"]);
    port_ = [lease[@"port"] unsignedShortValue];
    auth_ = base::SysNSStringToUTF8(auth);
    if (!Publish()) { Reset(); Publish(); return; }
    guard_.Start(FROM_HERE, base::Milliseconds(200), base::BindRepeating(
        &SiteLease::Check, weak_.GetWeakPtr()));
  }
  static double RenewalTime(double now, double expires) {
    return expires - std::min(5000.0, (expires - now) / 2);
  }
  void Check() {
    double now = NSDate.date.timeIntervalSince1970 * 1000;
    if (now >= expires_ || (change_ && change_())) { Reset(); Publish(); return; }
    if (now < renew_ || in_flight_) return;
    in_flight_ = true;
    __block auto reply = base::BindPostTaskToCurrentDefault(base::BindOnce(
        &SiteLease::Renewed, weak_.GetWeakPtr()));
    extend_(^(int64_t expiry) { std::move(reply).Run(expiry); });
  }
  void Renewed(int64_t expiry) {
    in_flight_ = false;
    double now = NSDate.date.timeIntervalSince1970 * 1000;
    if (now >= expires_ || now >= expiry || (change_ && change_())) {
      Reset(); Publish(); return;
    }
    // At the session/period boundary the service may return the same final
    // deadline. Wait for it instead of repeatedly renewing a capped grant.
    renew_ = expiry > expires_ ? RenewalTime(now, expiry) : expiry;
    expires_ = expiry;
  }
  void Reset() {
    weak_.InvalidateWeakPtrs();
    guard_.Stop();
    if (revoke_) revoke_();
    revoke_ = nil;
    extend_ = nil;
    change_ = nil;
    private_binding_ = nil;
    auth_.clear(); host_.clear(); port_ = 0;
    in_flight_ = false;
  }
  raw_ptr<Profile> profile_;
  std::set<std::string> sites_;
  std::string host_, auth_;
  uint16_t port_ = 0;
  bool in_flight_ = false;
  double renew_ = 0;
  NSDictionary* private_binding_ = nil;
  NSString* context_ = nil;
  AegisAccountBindingChange change_ = nil;
  AegisNodeRevoke revoke_ = nil;
  AegisNodeRenew extend_ = nil;
  double expires_ = 0;
  base::RepeatingTimer guard_;
  base::WeakPtrFactory<SiteLease> weak_{this};
};
}  // namespace
bool UsesAccountNode(Profile* profile, bool local_node_available) {
  if (!aegis::IsAegisProfileSupported(profile)) return false;
  auto* lease = static_cast<SiteLease*>(profile->GetUserData(kLeaseKey));
  if (lease && lease->HasSites()) return true;
  // A configured local test node remains available in an unbound private
  // window. Only check for the regular binding's existence to select the UI.
  // Private authorization always prompts and never reads that binding.
  if (profile->IsOffTheRecord() && !local_node_available) return true;
  struct stat binding;
  return lstat(profile->GetOriginalProfile()->GetPath().AppendASCII("AegisAccessAccount.json").value().c_str(),
               &binding) == 0 || errno != ENOENT;
}
AccountNodeStatus AccountNodeForSite(Profile* profile, const std::string& site) {
  auto* lease = static_cast<SiteLease*>(profile->GetUserData(kLeaseKey));
  return lease ? lease->Status(site) : AccountNodeStatus::kOff;
}
void DisableAccountNodeSite(Profile* profile, const std::string& site) {
  auto* lease = static_cast<SiteLease*>(profile->GetUserData(kLeaseKey));
  if (lease && lease->Status(site) != AccountNodeStatus::kOff) lease->Toggle(site);
}
void ToggleAccountNodeSite(Profile* profile, const std::string& site) {
  if (!aegis::IsAegisProfileSupported(profile) || site.empty()) return;
  if (!profile->GetUserData(kLeaseKey))
    profile->SetUserData(kLeaseKey, std::make_unique<SiteLease>(profile));
  static_cast<SiteLease*>(profile->GetUserData(kLeaseKey))->Toggle(site);
}
}  // namespace aegis::access
