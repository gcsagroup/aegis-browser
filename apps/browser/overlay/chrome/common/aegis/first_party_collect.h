// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/first_party_collect.h
// Keep aligned with packages/core FIRST_PARTY_COLLECT_PATHS.

#ifndef CHROME_COMMON_AEGIS_FIRST_PARTY_COLLECT_H_
#define CHROME_COMMON_AEGIS_FIRST_PARTY_COLLECT_H_

class GURL;

namespace aegis {

// True for first-party copies of known measurement endpoints (GA4 /g/collect,
// gtm.js, gtag/js, Meta fbevents, etc.). Main-document navigations should not
// use this; it is for subresource blocking.
bool IsFirstPartyCollectUrl(const GURL& url);

}  // namespace aegis

#endif  // CHROME_COMMON_AEGIS_FIRST_PARTY_COLLECT_H_
