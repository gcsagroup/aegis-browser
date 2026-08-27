// Copyright 2026 GCSA

#include "chrome/common/aegis/threat_feed_index.h"

#include <algorithm>
#include <compare>
#include <limits>
#include <utility>

#include "base/containers/span.h"
#include "base/strings/string_util.h"
#include "crypto/hash.h"
#include "url/gurl.h"

namespace aegis {
namespace {

constexpr std::string_view kMagic = "AEGISTI1";
constexpr uint32_t kSchemaVersion = 1;
constexpr size_t kHeaderBytes = 36;
constexpr size_t kRecordBytes = 36;
constexpr uint32_t kMaxEntries = 1'000'000;
constexpr uint64_t kMaxFreshnessSeconds = 7 * 24 * 60 * 60;
constexpr uint8_t kKnownSourceMask =
    kThreatSourcePhishTank | kThreatSourceUrlhaus | kThreatSourceCertPl;

uint32_t ReadUint32(base::span<const uint8_t> bytes, size_t offset) {
  return static_cast<uint32_t>(bytes[offset]) |
         (static_cast<uint32_t>(bytes[offset + 1]) << 8) |
         (static_cast<uint32_t>(bytes[offset + 2]) << 16) |
         (static_cast<uint32_t>(bytes[offset + 3]) << 24);
}

uint64_t ReadUint64(base::span<const uint8_t> bytes, size_t offset) {
  uint64_t value = 0;
  for (size_t index = 0; index < 8; ++index) {
    value |= static_cast<uint64_t>(bytes[offset + index]) << (index * 8);
  }
  return value;
}

void AppendUint32(uint32_t value, std::string* output) {
  for (size_t index = 0; index < 4; ++index) {
    output->push_back(static_cast<char>((value >> (index * 8)) & 0xff));
  }
}

void AppendUint64(uint64_t value, std::string* output) {
  for (size_t index = 0; index < 8; ++index) {
    output->push_back(static_cast<char>((value >> (index * 8)) & 0xff));
  }
}

std::array<uint8_t, 32> Digest(std::string_view prefix,
                               std::string_view value) {
  return crypto::hash::Sha256(std::string(prefix) + std::string(value));
}

std::string CanonicalHost(std::string_view host) {
  std::string cleaned = base::ToLowerASCII(host);
  while (base::EndsWith(cleaned, ".")) {
    cleaned.pop_back();
  }
  if (cleaned.empty() || cleaned.find('.') == std::string::npos) {
    return std::string();
  }
  const GURL parsed("https://" + cleaned + "/");
  return parsed.is_valid() && parsed.has_host() ? std::string(parsed.host())
                                                : std::string();
}

ThreatEntry SearchKey(ThreatEntryKind kind,
                      const std::array<uint8_t, 32>& digest) {
  return {.kind = kind, .sources = 0, .digest = digest};
}

std::optional<ThreatEntry> FindEntry(const std::vector<ThreatEntry>& entries,
                                     ThreatEntryKind kind,
                                     const std::array<uint8_t, 32>& digest) {
  const ThreatEntry key = SearchKey(kind, digest);
  auto found = std::lower_bound(entries.begin(), entries.end(), key);
  if (found == entries.end() || found->kind != kind ||
      found->digest != digest) {
    return std::nullopt;
  }
  return *found;
}

}  // namespace

std::optional<ThreatEntry> MakeThreatHostEntry(std::string_view host,
                                               uint8_t sources) {
  const std::string canonical = CanonicalHost(host);
  if (canonical.empty() || sources == 0) {
    return std::nullopt;
  }
  return ThreatEntry{.kind = ThreatEntryKind::kHost,
                     .sources = sources,
                     .digest = Digest("h:", canonical)};
}

std::optional<ThreatEntry> MakeThreatUrlEntry(const GURL& url,
                                              uint8_t sources) {
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS() || !url.has_host() ||
      sources == 0) {
    return std::nullopt;
  }
  return ThreatEntry{.kind = ThreatEntryKind::kUrl,
                     .sources = sources,
                     .digest = Digest("u:", url.GetWithoutRef().spec())};
}

std::vector<ThreatEntry> MergeThreatEntries(std::vector<ThreatEntry> entries) {
  std::sort(entries.begin(), entries.end());
  std::vector<ThreatEntry> merged;
  merged.reserve(entries.size());
  for (ThreatEntry& entry : entries) {
    if (entry.sources == 0) {
      continue;
    }
    if (!merged.empty() && merged.back().kind == entry.kind &&
        merged.back().digest == entry.digest) {
      merged.back().sources |= entry.sources;
      continue;
    }
    merged.push_back(std::move(entry));
  }
  return merged;
}

std::optional<ThreatMatch> ThreatIndex::Match(const GURL& url,
                                              int64_t now) const {
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS() || !url.has_host()) {
    return std::nullopt;
  }
  if (const auto url_entry =
          FindEntry(entries, ThreatEntryKind::kUrl,
                    Digest("u:", url.GetWithoutRef().spec()))) {
    return ThreatMatch{.kind = url_entry->kind,
                       .sources = url_entry->sources,
                       .stale = now > expires_at};
  }

  std::string host = base::ToLowerASCII(url.host());
  while (host.find('.') != std::string::npos) {
    if (const auto host_entry =
            FindEntry(entries, ThreatEntryKind::kHost, Digest("h:", host))) {
      return ThreatMatch{.kind = host_entry->kind,
                         .sources = host_entry->sources,
                         .stale = now > expires_at};
    }
    const size_t dot = host.find('.');
    if (dot == std::string::npos) {
      break;
    }
    host.erase(0, dot + 1);
  }
  return std::nullopt;
}

std::optional<ThreatIndex> ParseThreatIndex(base::span<const uint8_t> bytes) {
  if (bytes.size() < kHeaderBytes ||
      std::string_view(reinterpret_cast<const char*>(bytes.data()),
                       kMagic.size()) != kMagic ||
      ReadUint32(bytes, 8) != kSchemaVersion) {
    return std::nullopt;
  }
  const uint64_t generated = ReadUint64(bytes, 12);
  const uint64_t expires = ReadUint64(bytes, 20);
  const uint32_t count = ReadUint32(bytes, 28);
  if (ReadUint32(bytes, 32) != 0 || generated == 0 || expires < generated ||
      expires - generated > kMaxFreshnessSeconds ||
      generated > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()) ||
      expires > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()) ||
      count > kMaxEntries ||
      bytes.size() !=
          kHeaderBytes + static_cast<size_t>(count) * kRecordBytes) {
    return std::nullopt;
  }

  ThreatIndex index{.generated_at = static_cast<int64_t>(generated),
                    .expires_at = static_cast<int64_t>(expires)};
  index.entries.reserve(count);
  for (uint32_t record = 0; record < count; ++record) {
    const size_t offset =
        kHeaderBytes + static_cast<size_t>(record) * kRecordBytes;
    const uint8_t kind_value = bytes[offset];
    const uint8_t sources = bytes[offset + 1];
    if ((kind_value != static_cast<uint8_t>(ThreatEntryKind::kHost) &&
         kind_value != static_cast<uint8_t>(ThreatEntryKind::kUrl)) ||
        sources == 0 || (sources & ~kKnownSourceMask) != 0 ||
        bytes[offset + 2] != 0 || bytes[offset + 3] != 0) {
      return std::nullopt;
    }
    ThreatEntry entry{.kind = static_cast<ThreatEntryKind>(kind_value),
                      .sources = sources};
    std::copy_n(bytes.begin() + offset + 4, entry.digest.size(),
                entry.digest.begin());
    if (!index.entries.empty() && !(index.entries.back() < entry)) {
      return std::nullopt;
    }
    index.entries.push_back(std::move(entry));
  }
  return index;
}

std::string SerializeThreatIndex(const ThreatIndex& index) {
  const std::vector<ThreatEntry> entries = MergeThreatEntries(index.entries);
  if (index.generated_at <= 0 || index.expires_at < index.generated_at ||
      entries.size() > kMaxEntries) {
    return std::string();
  }
  std::string output;
  output.reserve(kHeaderBytes + entries.size() * kRecordBytes);
  output.append(kMagic);
  AppendUint32(kSchemaVersion, &output);
  AppendUint64(static_cast<uint64_t>(index.generated_at), &output);
  AppendUint64(static_cast<uint64_t>(index.expires_at), &output);
  AppendUint32(static_cast<uint32_t>(entries.size()), &output);
  AppendUint32(0, &output);
  for (const ThreatEntry& entry : entries) {
    output.push_back(static_cast<char>(entry.kind));
    output.push_back(static_cast<char>(entry.sources));
    output.append(2, '\0');
    output.append(reinterpret_cast<const char*>(entry.digest.data()),
                  entry.digest.size());
  }
  return output;
}

std::vector<std::string> ThreatSourceNames(uint8_t sources) {
  std::vector<std::string> names;
  if (sources & kThreatSourcePhishTank) {
    names.push_back("PhishTank");
  }
  if (sources & kThreatSourceUrlhaus) {
    names.push_back("URLhaus");
  }
  if (sources & kThreatSourceCertPl) {
    names.push_back("CERT.PL");
  }
  return names;
}

}  // namespace aegis
