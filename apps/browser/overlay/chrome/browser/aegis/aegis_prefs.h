// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/aegis_prefs.h

#ifndef CHROME_BROWSER_AEGIS_AEGIS_PREFS_H_
#define CHROME_BROWSER_AEGIS_AEGIS_PREFS_H_

class PrefRegistrySimple;

namespace user_prefs {
class PrefRegistrySyncable;
}

namespace aegis {

void RegisterProfilePrefs(user_prefs::PrefRegistrySyncable* registry);

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_AEGIS_PREFS_H_
