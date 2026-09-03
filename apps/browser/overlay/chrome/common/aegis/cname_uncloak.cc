// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/cname_uncloak.cc

#include "chrome/common/aegis/cname_uncloak.h"

#include "base/memory/singleton.h"
#include "base/strings/strcat.h"
#include "base/strings/string_util.h"
#include "chrome/common/aegis/filter_list_matcher.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "url/gurl.h"

namespace aegis {
namespace {

constexpr size_t kMaxCachedHosts = 4096;

std::string NormalizeDnsAlias(std::string_view alias) {
  std::string host = base::ToLowerASCII(alias);
  while (base::EndsWith(host, ".")) {
    host.pop_back();
  }
  return host;
}

std::string RegistrableDomain(std::string_view host) {
  return net::registry_controlled_domains::GetDomainAndRegistry(
      host, net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);
}

}  // namespace

// static
CnameUncloakCache* CnameUncloakCache::GetInstance() {
  return base::Singleton<CnameUncloakCache>::get();
}

CnameUncloakCache::CnameUncloakCache() = default;
CnameUncloakCache::~CnameUncloakCache() = default;

void CnameUncloakCache::RememberCloakedHost(CnameCachePartitionId partition_id,
                                            std::string_view host,
                                            std::string_view alias) {
  if (partition_id == kInvalidCnameCachePartitionId) {
    return;
  }
  const std::string normalized = NormalizeDnsAlias(host);
  if (normalized.empty()) {
    return;
  }
  const std::string alias_n = NormalizeDnsAlias(alias);
  base::AutoLock lock(lock_);
  auto& entries = entries_by_partition_[partition_id];
  if (entries.size() >= kMaxCachedHosts) {
    entries.clear();
  }
  entries[normalized] = alias_n;
}

bool CnameUncloakCache::IsCloakedHost(CnameCachePartitionId partition_id,
                                      std::string_view host) const {
  if (partition_id == kInvalidCnameCachePartitionId) {
    return false;
  }
  const std::string normalized = NormalizeDnsAlias(host);
  if (normalized.empty()) {
    return false;
  }
  base::AutoLock lock(lock_);
  auto partition = entries_by_partition_.find(partition_id);
  return partition != entries_by_partition_.end() &&
         partition->second.contains(normalized);
}

std::string CnameUncloakCache::CloakedAlias(CnameCachePartitionId partition_id,
                                            std::string_view host) const {
  if (partition_id == kInvalidCnameCachePartitionId) {
    return std::string();
  }
  const std::string normalized = NormalizeDnsAlias(host);
  if (normalized.empty()) {
    return std::string();
  }
  base::AutoLock lock(lock_);
  auto partition = entries_by_partition_.find(partition_id);
  if (partition == entries_by_partition_.end()) {
    return std::string();
  }
  auto it = partition->second.find(normalized);
  if (it == partition->second.end()) {
    return std::string();
  }
  return it->second;
}

void CnameUncloakCache::ClearPartition(CnameCachePartitionId partition_id) {
  if (partition_id == kInvalidCnameCachePartitionId) {
    return;
  }
  base::AutoLock lock(lock_);
  entries_by_partition_.erase(partition_id);
}

bool AliasesRevealTracker(const GURL& request_url,
                          const std::vector<std::string>& dns_aliases,
                          std::string* matched_alias) {
  if (!request_url.is_valid() || !request_url.has_host() ||
      dns_aliases.empty()) {
    return false;
  }

  const std::string request_host = NormalizeDnsAlias(request_url.host());
  const std::string request_reg = RegistrableDomain(request_host);
  if (request_reg.empty()) {
    return false;
  }

  for (const std::string& alias : dns_aliases) {
    const std::string host = NormalizeDnsAlias(alias);
    if (host.empty() || host == request_host) {
      continue;
    }
    const std::string alias_reg = RegistrableDomain(host);
    if (alias_reg.empty() ||
        base::EqualsCaseInsensitiveASCII(alias_reg, request_reg)) {
      continue;
    }
    const GURL alias_url(base::StrCat({"https://", host, "/"}));
    if (FilterListMatcher::GetInstance()->ShouldBlock(alias_url)) {
      if (matched_alias) {
        *matched_alias = host;
      }
      return true;
    }
  }
  return false;
}

}  // namespace aegis
