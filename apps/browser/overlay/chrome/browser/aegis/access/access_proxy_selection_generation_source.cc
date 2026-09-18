// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_proxy_selection_generation_source.h"

#include <memory>
#include <utility>

#include "chrome/browser/aegis/aegis_profile_support.h"
#include "chrome/browser/profiles/profile.h"

namespace aegis::access {
namespace {

const void* const kProxySelectionGenerationSourceUserDataKey =
    &kProxySelectionGenerationSourceUserDataKey;

}  // namespace

// static
AccessProxySelectionGenerationSource* AccessProxySelectionGenerationSource::Get(
    Profile* profile) {
  if (!profile) {
    return nullptr;
  }
  return static_cast<AccessProxySelectionGenerationSource*>(
      profile->GetUserData(kProxySelectionGenerationSourceUserDataKey));
}

// static
AccessProxySelectionGenerationSource*
AccessProxySelectionGenerationSource::GetOrCreate(Profile* profile) {
  if (!profile || !aegis::IsAegisProfileSupported(profile)) {
    return nullptr;
  }
  if (auto* existing = Get(profile)) {
    return existing;
  }
  auto source = std::unique_ptr<AccessProxySelectionGenerationSource>(
      new AccessProxySelectionGenerationSource());
  auto* result = source.get();
  profile->SetUserData(kProxySelectionGenerationSourceUserDataKey,
                       std::move(source));
  return result;
}

AccessProxySelectionGenerationSource::AccessProxySelectionGenerationSource() =
    default;

AccessProxySelectionGenerationSource::~AccessProxySelectionGenerationSource() =
    default;

uint64_t AccessProxySelectionGenerationSource::selection_generation(
    const std::string& proxy_group_id) const {
  const auto it = groups_.find(proxy_group_id);
  return it == groups_.end() ? 0 : it->second.generation();
}

const aegis_access::AccessProxySelectionBinding*
AccessProxySelectionGenerationSource::binding_for_group(
    const std::string& proxy_group_id) const {
  const auto it = groups_.find(proxy_group_id);
  if (it == groups_.end() || !it->second.binding().has_value()) {
    return nullptr;
  }
  return &*it->second.binding();
}

aegis_access::ProxySelectionGenerationCommitResult
AccessProxySelectionGenerationSource::CommitSelection(
    aegis_access::AccessProxySelectionBinding binding) {
  if (binding.proxy_group_id.empty()) {
    return {aegis_access::ProxySelectionGenerationCommitStatus::kInvalidSelection,
            0};
  }
  auto it = groups_.try_emplace(binding.proxy_group_id).first;
  return it->second.Commit(std::move(binding));
}

}  // namespace aegis::access
