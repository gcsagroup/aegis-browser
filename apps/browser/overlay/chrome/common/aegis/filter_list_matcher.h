// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/filter_list_matcher.h

#ifndef CHROME_COMMON_AEGIS_FILTER_LIST_MATCHER_H_
#define CHROME_COMMON_AEGIS_FILTER_LIST_MATCHER_H_

#include <string>
#include <string_view>
#include <vector>

#include "base/containers/flat_set.h"
#include "base/memory/singleton.h"
#include "base/synchronization/lock.h"
#include "base/thread_annotations.h"
#include "chrome/common/aegis/filter_list.h"

class GURL;

namespace aegis {

enum class BlockReason {
  kNone = 0,
  kEasyList,
  kFirstPartyCollect,
};

const char* BlockReasonToString(BlockReason reason);

// Process-wide compiled EasyList matcher. Browser and renderer both consult
// this after the browser pushes a snapshot over mojo.
class FilterListMatcher {
 public:
  static FilterListMatcher* GetInstance();

  FilterListMatcher(const FilterListMatcher&) = delete;
  FilterListMatcher& operator=(const FilterListMatcher&) = delete;

  void ReplaceCompiledList(CompiledFilterList list);
  CompiledFilterList CurrentList() const;

  // True when |url| matches builtin tracker rules or compiled EasyList, and
  // is not covered by an EasyList exception. Builtin seed always wins over
  // exceptions so product defaults stay on.
  bool ShouldBlock(const GURL& url) const;
  BlockReason ClassifyBlock(const GURL& url) const;

  size_t compiled_host_count() const;

 private:
  friend struct base::DefaultSingletonTraits<FilterListMatcher>;
  FilterListMatcher();
  ~FilterListMatcher();

  bool MatchesCompiledHost(std::string_view host) const
      EXCLUSIVE_LOCKS_REQUIRED(lock_);
  bool MatchesException(std::string_view host) const
      EXCLUSIVE_LOCKS_REQUIRED(lock_);
  bool MatchesPathRule(const GURL& url) const EXCLUSIVE_LOCKS_REQUIRED(lock_);

  mutable base::Lock lock_;
  CompiledFilterList list_ GUARDED_BY(lock_);
  base::flat_set<std::string> hosts_ GUARDED_BY(lock_);
  base::flat_set<std::string> exceptions_ GUARDED_BY(lock_);
};

}  // namespace aegis

#endif  // CHROME_COMMON_AEGIS_FILTER_LIST_MATCHER_H_
