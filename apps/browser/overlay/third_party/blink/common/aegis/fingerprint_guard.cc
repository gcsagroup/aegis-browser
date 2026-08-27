// Copyright 2026 GCSA
// Intended path: third_party/blink/common/aegis/fingerprint_guard.cc

#include "third_party/blink/public/common/aegis/fingerprint_guard.h"

#include <array>
#include <cstdint>
#include <string>
#include <vector>

#include "base/containers/span.h"
#include "base/no_destructor.h"
#include "base/rand_util.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "base/synchronization/lock.h"
#include "base/time/time.h"
#include "crypto/hmac.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"

namespace blink::aegis {
namespace {

constexpr uint64_t kSecondsPerWeek = 7 * 24 * 60 * 60;
constexpr std::string_view kHmacDomain = "aegis-farbling-v1";

struct FingerprintGuardState {
  base::Lock lock;
  bool enabled = false;
  std::vector<uint8_t> secret;
  std::string paused_sites;
};

FingerprintGuardState& State() {
  static base::NoDestructor<FingerprintGuardState> state;
  return *state;
}

std::string SiteKeyForHost(std::string_view host) {
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

bool IsPaused(std::string_view serialized,
              std::string_view host,
              int64_t now_unix_seconds) {
  const std::string target = SiteKeyForHost(host);
  if (target.empty()) {
    return false;
  }
  for (std::string_view line :
       base::SplitStringPiece(serialized, "\n", base::TRIM_WHITESPACE,
                              base::SPLIT_WANT_NONEMPTY)) {
    const std::vector<std::string_view> fields = base::SplitStringPiece(
        line, "|", base::TRIM_WHITESPACE, base::SPLIT_WANT_ALL);
    int64_t expiry = 0;
    if (fields.size() == 2 && base::StringToInt64(fields[1], &expiry) &&
        expiry > now_unix_seconds && SiteKeyForHost(fields[0]) == target) {
      return true;
    }
  }
  return false;
}

void AppendUint64BigEndian(uint64_t value, std::vector<uint8_t>* output) {
  for (int shift = 56; shift >= 0; shift -= 8) {
    output->push_back(static_cast<uint8_t>(value >> shift));
  }
}

void AppendUint32BigEndian(uint32_t value, std::vector<uint8_t>* output) {
  for (int shift = 24; shift >= 0; shift -= 8) {
    output->push_back(static_cast<uint8_t>(value >> shift));
  }
}

template <typename T, size_t N>
T BucketDown(T actual, const std::array<T, N>& buckets) {
  T result = actual;
  bool found = false;
  for (T bucket : buckets) {
    if (bucket <= actual) {
      result = bucket;
      found = true;
    }
  }
  return found ? result : actual;
}

std::vector<uint8_t> SnapshotSecret() {
  FingerprintGuardState& state = State();
  base::AutoLock lock(state.lock);
  return state.secret;
}

}  // namespace

void SetFingerprintGuardConfiguration(bool enabled,
                                      base::span<const uint8_t> profile_secret,
                                      std::string_view paused_sites) {
  FingerprintGuardState& state = State();
  base::AutoLock lock(state.lock);
  const bool valid_secret = profile_secret.size() == kFarblingSecretSize;
  state.enabled = enabled && valid_secret;
  state.secret.assign(profile_secret.begin(), profile_secret.end());
  state.paused_sites.assign(paused_sites);
}

void SetFingerprintGuardEnabled(bool enabled) {
  FingerprintGuardState& state = State();
  base::AutoLock lock(state.lock);
  if (enabled && state.secret.size() != kFarblingSecretSize) {
    state.secret = base::RandBytesAsVector(kFarblingSecretSize);
  }
  state.enabled = enabled;
}

bool IsFingerprintGuardEnabled() {
  FingerprintGuardState& state = State();
  base::AutoLock lock(state.lock);
  return state.enabled && state.secret.size() == kFarblingSecretSize;
}

bool FingerprintProtectionEnabledForSiteForTesting(
    bool enabled,
    std::string_view paused_sites,
    std::string_view top_level_host,
    int64_t now_unix_seconds) {
  return enabled && !IsPaused(paused_sites, top_level_host, now_unix_seconds);
}

bool IsFingerprintGuardEnabledForSite(std::string_view top_level_host) {
  FingerprintGuardState& state = State();
  bool enabled = false;
  std::string paused_sites;
  {
    base::AutoLock lock(state.lock);
    enabled = state.enabled && state.secret.size() == kFarblingSecretSize;
    paused_sites = state.paused_sites;
  }
  const int64_t now =
      static_cast<int64_t>(base::Time::Now().InSecondsFSinceUnixEpoch());
  return FingerprintProtectionEnabledForSiteForTesting(enabled, paused_sites,
                                                       top_level_host, now);
}

uint64_t ComputeFarblingTokenForTesting(
    base::span<const uint8_t> secret,
    std::string_view schemeful_top_level_site,
    FarblingSurface surface,
    uint64_t epoch) {
  if (secret.size() != kFarblingSecretSize ||
      schemeful_top_level_site.empty()) {
    return 0;
  }

  std::vector<uint8_t> message;
  message.reserve(kHmacDomain.size() + schemeful_top_level_site.size() + 16);
  message.insert(message.end(), kHmacDomain.begin(), kHmacDomain.end());
  message.push_back(0);
  message.push_back(static_cast<uint8_t>(surface));
  AppendUint64BigEndian(epoch, &message);
  AppendUint32BigEndian(static_cast<uint32_t>(schemeful_top_level_site.size()),
                        &message);
  message.insert(message.end(), schemeful_top_level_site.begin(),
                 schemeful_top_level_site.end());

  const auto digest = crypto::hmac::SignSha256(secret, message);
  uint64_t token = 0;
  for (size_t i = 0; i < sizeof(token); ++i) {
    token = (token << 8) | digest[i];
  }
  return token == 0 ? 1 : token;
}

uint64_t FarblingTokenForSite(std::string_view schemeful_top_level_site,
                              FarblingSurface surface) {
  const std::vector<uint8_t> secret = SnapshotSecret();
  const uint64_t epoch = static_cast<uint64_t>(
      base::Time::Now().InSecondsFSinceUnixEpoch() / kSecondsPerWeek);
  return ComputeFarblingTokenForTesting(secret, schemeful_top_level_site,
                                        surface, epoch);
}

uint64_t FarblingTokenForHost(std::string_view host) {
  const std::string site = SiteKeyForHost(host);
  return site.empty() ? 0
                      : FarblingTokenForSite("https://" + site,
                                             FarblingSurface::kCanvas);
}

uint64_t BucketWebGPUMaxBufferSize(uint64_t actual) {
  constexpr std::array<uint64_t, 5> kBuckets = {
      268435456ULL, 536870912ULL, 1073741824ULL, 2147483648ULL, 4294967296ULL};
  return BucketDown(actual, kBuckets);
}

uint32_t BucketWebGPUMaxWorkgroupStorage(uint32_t actual) {
  constexpr std::array<uint32_t, 3> kBuckets = {16384u, 32768u, 65536u};
  return BucketDown(actual, kBuckets);
}

uint32_t BucketWebGPUMaxTexture3D(uint32_t actual) {
  constexpr std::array<uint32_t, 3> kBuckets = {2048u, 4096u, 8192u};
  return BucketDown(actual, kBuckets);
}

}  // namespace blink::aegis
