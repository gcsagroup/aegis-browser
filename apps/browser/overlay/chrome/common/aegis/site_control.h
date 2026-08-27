// Copyright 2026 GCSA

#ifndef CHROME_COMMON_AEGIS_SITE_CONTROL_H_
#define CHROME_COMMON_AEGIS_SITE_CONTROL_H_

#include <cstdint>
#include <string>

namespace aegis {

// Returns the registrable domain when available, otherwise a normalized host.
// Empty and non-host inputs are rejected.
std::string SiteKeyForHost(const std::string& host);

// Serialized form is one `site|expiry_unix_seconds` record per line. Expired
// or malformed records are ignored at read time.
bool IsSitePaused(const std::string& serialized,
                  const std::string& host,
                  int64_t now_unix_seconds);
std::string SetSitePaused(const std::string& serialized,
                          const std::string& host,
                          int64_t expiry_unix_seconds,
                          int64_t now_unix_seconds);
std::string ResumeSite(const std::string& serialized,
                       const std::string& host,
                       int64_t now_unix_seconds);

}  // namespace aegis

#endif  // CHROME_COMMON_AEGIS_SITE_CONTROL_H_
