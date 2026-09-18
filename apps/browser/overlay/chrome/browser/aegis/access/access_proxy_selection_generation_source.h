// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_PROXY_SELECTION_GENERATION_SOURCE_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_PROXY_SELECTION_GENERATION_SOURCE_H_

#include <cstdint>
#include <map>
#include <string>

#include "base/supports_user_data.h"
#include "components/aegis_access/access_proxy_selection_generation_state.h"

class Profile;

namespace aegis::access {

// Profile-owned collection of committed proxy-group selection generations.
// Provisioning/probing remains outside this type. Callers commit only after a
// validated endpoint/lease/assignment binding has become authoritative.
class AccessProxySelectionGenerationSource
    : public base::SupportsUserData::Data {
 public:
  static AccessProxySelectionGenerationSource* Get(Profile* profile);
  static AccessProxySelectionGenerationSource* GetOrCreate(Profile* profile);

  AccessProxySelectionGenerationSource(
      const AccessProxySelectionGenerationSource&) = delete;
  AccessProxySelectionGenerationSource& operator=(
      const AccessProxySelectionGenerationSource&) = delete;
  ~AccessProxySelectionGenerationSource() override;

  uint64_t selection_generation(const std::string& proxy_group_id) const;
  const aegis_access::AccessProxySelectionBinding* binding_for_group(
      const std::string& proxy_group_id) const;

  aegis_access::ProxySelectionGenerationCommitResult CommitSelection(
      aegis_access::AccessProxySelectionBinding binding);

 private:
  AccessProxySelectionGenerationSource();

  std::map<std::string, aegis_access::ProxySelectionGenerationState> groups_;
};

}  // namespace aegis::access

#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_PROXY_SELECTION_GENERATION_SOURCE_H_
