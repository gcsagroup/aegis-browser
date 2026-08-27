// Copyright 2026 GCSA

#include "chrome/common/aegis/site_control.h"

#include <map>
#include <string_view>

#include "base/strings/string_number_conversions.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"

namespace aegis {
namespace {

using PauseMap = std::map<std::string, int64_t>;

PauseMap ParseActive(const std::string& serialized, int64_t now) {
  PauseMap active;
  for (std::string_view line :
       base::SplitStringPiece(serialized, "\n", base::TRIM_WHITESPACE,
                              base::SPLIT_WANT_NONEMPTY)) {
    const std::vector<std::string_view> fields = base::SplitStringPiece(
        line, "|", base::TRIM_WHITESPACE, base::SPLIT_WANT_ALL);
    int64_t expiry = 0;
    if (fields.size() != 2 || !base::StringToInt64(fields[1], &expiry) ||
        expiry <= now) {
      continue;
    }
    const std::string site = SiteKeyForHost(std::string(fields[0]));
    if (!site.empty()) {
      active[site] = expiry;
    }
  }
  return active;
}

std::string Serialize(const PauseMap& active) {
  std::string serialized;
  for (const auto& [site, expiry] : active) {
    if (!serialized.empty()) {
      serialized.push_back('\n');
    }
    serialized += site + "|" + base::NumberToString(expiry);
  }
  return serialized;
}

}  // namespace

std::string SiteKeyForHost(const std::string& host) {
  std::string normalized = base::ToLowerASCII(host);
  while (!normalized.empty() && normalized.back() == '.') {
    normalized.pop_back();
  }
  if (normalized.empty() || normalized.find('/') != std::string::npos ||
      normalized.find('|') != std::string::npos ||
      normalized.find('\n') != std::string::npos) {
    return std::string();
  }
  const std::string registrable =
      net::registry_controlled_domains::GetDomainAndRegistry(
          normalized,
          net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);
  return registrable.empty() ? normalized : registrable;
}

bool IsSitePaused(const std::string& serialized,
                  const std::string& host,
                  int64_t now_unix_seconds) {
  const std::string site = SiteKeyForHost(host);
  if (site.empty()) {
    return false;
  }
  return ParseActive(serialized, now_unix_seconds).contains(site);
}

std::string SetSitePaused(const std::string& serialized,
                          const std::string& host,
                          int64_t expiry_unix_seconds,
                          int64_t now_unix_seconds) {
  PauseMap active = ParseActive(serialized, now_unix_seconds);
  const std::string site = SiteKeyForHost(host);
  if (!site.empty() && expiry_unix_seconds > now_unix_seconds) {
    active[site] = expiry_unix_seconds;
  }
  return Serialize(active);
}

std::string ResumeSite(const std::string& serialized,
                       const std::string& host,
                       int64_t now_unix_seconds) {
  PauseMap active = ParseActive(serialized, now_unix_seconds);
  active.erase(SiteKeyForHost(host));
  return Serialize(active);
}

}  // namespace aegis
