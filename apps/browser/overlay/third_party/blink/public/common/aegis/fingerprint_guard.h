// Copyright 2026 GCSA
// Intended path: third_party/blink/public/common/aegis/fingerprint_guard.h

#ifndef THIRD_PARTY_BLINK_PUBLIC_COMMON_AEGIS_FINGERPRINT_GUARD_H_
#define THIRD_PARTY_BLINK_PUBLIC_COMMON_AEGIS_FINGERPRINT_GUARD_H_

#include <cstdint>
#include <string_view>

#include "third_party/blink/public/common/common_export.h"

namespace blink::aegis {

// Process-wide FingerprintGuard switch, synced from profile prefs via
// chrome.mojom.DynamicParams.
BLINK_COMMON_EXPORT void SetFingerprintGuardEnabled(bool enabled);
BLINK_COMMON_EXPORT bool IsFingerprintGuardEnabled();

// Stable-per-session, varies-by-host farbling seed (eTLD+1 / host scoped).
BLINK_COMMON_EXPORT uint64_t FarblingTokenForHost(std::string_view host);

}  // namespace blink::aegis

#endif  // THIRD_PARTY_BLINK_PUBLIC_COMMON_AEGIS_FINGERPRINT_GUARD_H_
