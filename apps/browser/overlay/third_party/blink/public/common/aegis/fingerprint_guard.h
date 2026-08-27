// Copyright 2026 GCSA
// Intended path: third_party/blink/public/common/aegis/fingerprint_guard.h

#ifndef THIRD_PARTY_BLINK_PUBLIC_COMMON_AEGIS_FINGERPRINT_GUARD_H_
#define THIRD_PARTY_BLINK_PUBLIC_COMMON_AEGIS_FINGERPRINT_GUARD_H_

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>

#include "base/containers/span.h"
#include "third_party/blink/public/common/common_export.h"

namespace blink::aegis {

inline constexpr size_t kFarblingSecretSize = 32;

enum class FarblingSurface : uint8_t {
  kCanvas = 1,
  kAudio = 2,
  kWebGL = 3,
  kWebGPU = 4,
};

// Renderer 进程级配置。密钥由 Browser Profile 持有，不直接编码到 JS 可见值。
BLINK_COMMON_EXPORT void SetFingerprintGuardConfiguration(
    bool enabled,
    base::span<const uint8_t> profile_secret,
    std::string_view paused_sites);

// 兼容测试和早期初始化；生产代码应使用 SetFingerprintGuardConfiguration()。
BLINK_COMMON_EXPORT void SetFingerprintGuardEnabled(bool enabled);
BLINK_COMMON_EXPORT bool IsFingerprintGuardEnabled();
BLINK_COMMON_EXPORT bool IsFingerprintGuardEnabledForSite(
    std::string_view top_level_host);

// 对 Profile、schemeful 顶层站点、表面和 UTC 7 天周期保持稳定。
BLINK_COMMON_EXPORT uint64_t
FarblingTokenForSite(std::string_view schemeful_top_level_site,
                     FarblingSurface surface);

// 仅为原生回归测试保留；新 Renderer 代码应传入 schemeful 顶层站点。
BLINK_COMMON_EXPORT uint64_t FarblingTokenForHost(std::string_view host);

// 供原生测试锁定隐私契约的纯函数。
BLINK_COMMON_EXPORT uint64_t
ComputeFarblingTokenForTesting(base::span<const uint8_t> secret,
                               std::string_view schemeful_top_level_site,
                               FarblingSurface surface,
                               uint64_t epoch);
BLINK_COMMON_EXPORT bool FingerprintProtectionEnabledForSiteForTesting(
    bool enabled,
    std::string_view paused_sites,
    std::string_view top_level_host,
    int64_t now_unix_seconds);

BLINK_COMMON_EXPORT uint64_t BucketWebGPUMaxBufferSize(uint64_t actual);
BLINK_COMMON_EXPORT uint32_t BucketWebGPUMaxWorkgroupStorage(uint32_t actual);
BLINK_COMMON_EXPORT uint32_t BucketWebGPUMaxTexture3D(uint32_t actual);

}  // namespace blink::aegis

#endif  // THIRD_PARTY_BLINK_PUBLIC_COMMON_AEGIS_FINGERPRINT_GUARD_H_
