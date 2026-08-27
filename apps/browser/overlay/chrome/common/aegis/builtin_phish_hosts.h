// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/builtin_phish_hosts.h

#ifndef CHROME_COMMON_AEGIS_BUILTIN_PHISH_HOSTS_H_
#define CHROME_COMMON_AEGIS_BUILTIN_PHISH_HOSTS_H_

class GURL;

namespace aegis {

// Returns true when |url| matches a built-in phishing seed rule.
// Rules are bare hosts ("paypal-secure-login.com") or host/path
// ("testsafebrowsing.appspot.com/s/phishing").
bool MatchesBuiltinPhishRule(const GURL& url);

}  // namespace aegis

#endif  // CHROME_COMMON_AEGIS_BUILTIN_PHISH_HOSTS_H_
