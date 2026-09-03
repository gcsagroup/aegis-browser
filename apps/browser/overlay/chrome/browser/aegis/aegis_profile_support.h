// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_AEGIS_PROFILE_SUPPORT_H_
#define CHROME_BROWSER_AEGIS_AEGIS_PROFILE_SUPPORT_H_

class Profile;

namespace aegis {

// Returns true only for a user regular Profile or its primary Incognito
// Profile. Guest, System, ChromeOS signin/lockscreen, and auxiliary
// off-the-record Profiles stay excluded.
bool IsAegisProfileSupported(const Profile* profile);

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_AEGIS_PROFILE_SUPPORT_H_
