// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/cname_uncloak.h

#ifndef CHROME_COMMON_AEGIS_CNAME_UNCLOAK_H_
#define CHROME_COMMON_AEGIS_CNAME_UNCLOAK_H_

#include <string>
#include <string_view>
#include <vector>

#include "base/containers/flat_map.h"
#include "base/memory/singleton.h"
#include "base/synchronization/lock.h"
#include "base/thread_annotations.h"
#include "chrome/common/aegis/cname_cache_partition.h"

class GURL;

namespace aegis {

// Process-wide, BrowserContext-partitioned cache of first-party hosts whose DNS
// CNAME chain pointed at a known tracker. Subsequent subresource requests in
// the same context are blocked at WillStartRequest without waiting for DNS.
class CnameUncloakCache {
 public:
  static CnameUncloakCache* GetInstance();

  CnameUncloakCache(const CnameUncloakCache&) = delete;
  CnameUncloakCache& operator=(const CnameUncloakCache&) = delete;

  void RememberCloakedHost(CnameCachePartitionId partition_id,
                           std::string_view host,
                           std::string_view alias);
  bool IsCloakedHost(CnameCachePartitionId partition_id,
                     std::string_view host) const;
  std::string CloakedAlias(CnameCachePartitionId partition_id,
                           std::string_view host) const;
  void ClearPartition(CnameCachePartitionId partition_id);

 private:
  friend struct base::DefaultSingletonTraits<CnameUncloakCache>;
  CnameUncloakCache();
  ~CnameUncloakCache();

  using Entries = base::flat_map<std::string, std::string>;

  mutable base::Lock lock_;
  base::flat_map<CnameCachePartitionId, Entries> entries_by_partition_
      GUARDED_BY(lock_);
};

// True when |dns_aliases| contains a tracker host on a different registrable
// domain than |request_url|. Same-site CNAMEs (www → apex, first-party CDN)
// are ignored to limit false positives. |matched_alias| 若非空则写入命中的
// tracker 别名。
bool AliasesRevealTracker(const GURL& request_url,
                          const std::vector<std::string>& dns_aliases,
                          std::string* matched_alias = nullptr);

}  // namespace aegis

#endif  // CHROME_COMMON_AEGIS_CNAME_UNCLOAK_H_
