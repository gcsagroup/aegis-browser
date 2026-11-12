// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/aegis_prefs.h

#ifndef CHROME_BROWSER_AEGIS_AEGIS_PREFS_H_
#define CHROME_BROWSER_AEGIS_AEGIS_PREFS_H_

class PrefRegistrySimple;

namespace user_prefs {
class PrefRegistrySyncable;
}

namespace aegis {

inline constexpr char kAccessCoreLogLevel[] = "aegis.access_core_log_level";

inline constexpr char kAccessPrivateCoreLogLevel[] = "aegis.access_private_core_log_level";

void RegisterProfilePrefs(user_prefs::PrefRegistrySyncable* registry);

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_AEGIS_PREFS_H_
