// Copyright 2026 GCSA

#include "third_party/blink/public/common/aegis/fingerprint_guard.h"

#include <array>
#include <cstdint>
#include <string_view>

#include "base/hash/hash.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis {
namespace {

uint64_t PublicHostMask(std::string_view host) {
  const uint64_t hash = base::PersistentHash(host);
  return (hash << 1) ^ hash;
}

TEST(FingerprintGuardTest, RegistrableSiteIsStableAcrossSubdomains) {
  blink::aegis::SetFingerprintGuardEnabled(true);

  EXPECT_EQ(blink::aegis::FarblingTokenForHost("login.example.com"),
            blink::aegis::FarblingTokenForHost("cdn.example.com"));
}

TEST(FingerprintGuardTest, PublicHostHashCannotRecoverACommonSalt) {
  blink::aegis::SetFingerprintGuardEnabled(true);

  constexpr std::string_view kFirstHost = "one.example.com";
  constexpr std::string_view kSecondHost = "two.example.net";
  const uint64_t recovered_first =
      blink::aegis::FarblingTokenForHost(kFirstHost) ^
      PublicHostMask(kFirstHost);
  const uint64_t recovered_second =
      blink::aegis::FarblingTokenForHost(kSecondHost) ^
      PublicHostMask(kSecondHost);

  EXPECT_NE(recovered_first, recovered_second);
}

TEST(FingerprintGuardTest, HmacDerivationHasStableDomainSeparatedVector) {
  std::array<uint8_t, blink::aegis::kFarblingSecretSize> secret;
  for (size_t i = 0; i < secret.size(); ++i) {
    secret[i] = static_cast<uint8_t>(i);
  }

  constexpr std::string_view kSite = "https://example.com";
  constexpr uint64_t kEpoch = 12345;
  const uint64_t canvas = blink::aegis::ComputeFarblingTokenForTesting(
      secret, kSite, blink::aegis::FarblingSurface::kCanvas, kEpoch);
  EXPECT_EQ(14324488412929654517ULL, canvas);
  EXPECT_EQ(canvas,
            blink::aegis::ComputeFarblingTokenForTesting(
                secret, kSite, blink::aegis::FarblingSurface::kCanvas, kEpoch));
  EXPECT_NE(canvas,
            blink::aegis::ComputeFarblingTokenForTesting(
                secret, kSite, blink::aegis::FarblingSurface::kAudio, kEpoch));
  EXPECT_NE(canvas, blink::aegis::ComputeFarblingTokenForTesting(
                        secret, "https://example.net",
                        blink::aegis::FarblingSurface::kCanvas, kEpoch));
  EXPECT_NE(canvas, blink::aegis::ComputeFarblingTokenForTesting(
                        secret, kSite, blink::aegis::FarblingSurface::kCanvas,
                        kEpoch + 1));
}

TEST(FingerprintGuardTest, InvalidSecretAndPausedSiteDisableProtection) {
  std::array<uint8_t, blink::aegis::kFarblingSecretSize> secret{};
  blink::aegis::SetFingerprintGuardConfiguration(
      true, secret, "example.com|200\nexpired.test|100");

  EXPECT_FALSE(blink::aegis::FingerprintProtectionEnabledForSiteForTesting(
      true, "example.com|200", "cdn.example.com", 150));
  EXPECT_TRUE(blink::aegis::FingerprintProtectionEnabledForSiteForTesting(
      true, "example.com|200", "other.test", 150));
  EXPECT_TRUE(blink::aegis::FingerprintProtectionEnabledForSiteForTesting(
      true, "example.com|200", "example.com", 200));
  EXPECT_FALSE(blink::aegis::FingerprintProtectionEnabledForSiteForTesting(
      false, std::string_view(), "example.com", 150));

  blink::aegis::SetFingerprintGuardConfiguration(
      true, base::span(secret).first(secret.size() - 1), std::string_view());
  EXPECT_FALSE(blink::aegis::IsFingerprintGuardEnabled());
}

TEST(FingerprintGuardTest, WebGPULimitsUseFiniteDownwardBuckets) {
  EXPECT_EQ(268435456ULL,
            blink::aegis::BucketWebGPUMaxBufferSize(300000000ULL));
  EXPECT_EQ(1073741824ULL,
            blink::aegis::BucketWebGPUMaxBufferSize(1500000000ULL));
  EXPECT_EQ(32768u, blink::aegis::BucketWebGPUMaxWorkgroupStorage(50000u));
  EXPECT_EQ(4096u, blink::aegis::BucketWebGPUMaxTexture3D(6000u));
  EXPECT_EQ(1024u, blink::aegis::BucketWebGPUMaxTexture3D(1024u));
}

}  // namespace
}  // namespace aegis
