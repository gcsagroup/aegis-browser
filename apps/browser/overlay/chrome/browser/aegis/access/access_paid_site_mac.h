// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_PAID_SITE_MAC_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_PAID_SITE_MAC_H_

#include <string>

#include "base/functional/callback.h"

class Profile;
namespace aegis::access {
// Called only from trusted browser chrome for the active committed HTTPS site.
enum class AccountNodeStatus { kOff, kAcquiring, kAssigned, kUnavailable };
bool UsesAccountNode(Profile* profile, bool local_node_available = false);
AccountNodeStatus AccountNodeForSite(Profile* profile, const std::string& site);
void DisableAccountNodeSite(Profile* profile, const std::string& site);
void ToggleAccountNodeSite(Profile* profile, const std::string& site,
                           base::OnceClosure on_assigned = {});
}  // namespace aegis::access
#endif
