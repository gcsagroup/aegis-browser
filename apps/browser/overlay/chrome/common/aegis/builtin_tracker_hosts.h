// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/builtin_tracker_hosts.h
// Mirrored from packages/core/src/tracker/builtin-rules.ts (BUILTIN_TRACKER_HOSTS).

#ifndef CHROME_COMMON_AEGIS_BUILTIN_TRACKER_HOSTS_H_
#define CHROME_COMMON_AEGIS_BUILTIN_TRACKER_HOSTS_H_

class GURL;

namespace aegis {

// Returns true when |url| matches a built-in tracker rule.
// Rules are bare hosts ("doubleclick.net") or host/path ("facebook.com/tr").
bool MatchesBuiltinTrackerRule(const GURL& url);

}  // namespace aegis

#endif  // CHROME_COMMON_AEGIS_BUILTIN_TRACKER_HOSTS_H_
