// Copyright 2026 GCSA

#ifndef CHROME_COMMON_AEGIS_THREAT_FEED_INDEX_H_
#define CHROME_COMMON_AEGIS_THREAT_FEED_INDEX_H_

#include <array>
#include <compare>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "base/containers/span.h"

class GURL;

namespace aegis {

inline constexpr uint8_t kThreatSourcePhishTank = 1 << 0;
inline constexpr uint8_t kThreatSourceUrlhaus = 1 << 1;
inline constexpr uint8_t kThreatSourceCertPl = 1 << 2;

enum class ThreatEntryKind : uint8_t {
  kHost = 1,
  kUrl = 2,
};

struct ThreatEntry {
  ThreatEntryKind kind = ThreatEntryKind::kHost;
  uint8_t sources = 0;
  std::array<uint8_t, 32> digest{};

  auto operator<=>(const ThreatEntry& other) const {
    if (kind != other.kind) {
      return static_cast<uint8_t>(kind) <=> static_cast<uint8_t>(other.kind);
    }
    return digest <=> other.digest;
  }
  bool operator==(const ThreatEntry& other) const = default;
};

struct ThreatMatch {
  ThreatEntryKind kind = ThreatEntryKind::kHost;
  uint8_t sources = 0;
  bool stale = false;
};

struct ThreatIndex {
  int64_t generated_at = 0;
  int64_t expires_at = 0;
  std::vector<ThreatEntry> entries;

  std::optional<ThreatMatch> Match(const GURL& url, int64_t now) const;
};

std::optional<ThreatEntry> MakeThreatHostEntry(std::string_view host,
                                               uint8_t sources);
std::optional<ThreatEntry> MakeThreatUrlEntry(const GURL& url, uint8_t sources);
std::vector<ThreatEntry> MergeThreatEntries(std::vector<ThreatEntry> entries);

std::optional<ThreatIndex> ParseThreatIndex(base::span<const uint8_t> bytes);
std::string SerializeThreatIndex(const ThreatIndex& index);

std::vector<std::string> ThreatSourceNames(uint8_t sources);

}  // namespace aegis

#endif  // CHROME_COMMON_AEGIS_THREAT_FEED_INDEX_H_
