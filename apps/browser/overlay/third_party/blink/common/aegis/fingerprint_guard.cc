// Copyright 2026 GCSA
// Intended path: third_party/blink/common/aegis/fingerprint_guard.cc

#include "third_party/blink/public/common/aegis/fingerprint_guard.h"

#include <atomic>

#include "base/hash/hash.h"
#include "base/rand_util.h"

namespace blink::aegis {
namespace {

std::atomic<bool> g_fingerprint_guard_enabled{false};
std::atomic<uint64_t> g_session_salt{0};

uint64_t SessionSalt() {
  uint64_t salt = g_session_salt.load(std::memory_order_relaxed);
  if (salt != 0) {
    return salt;
  }
  uint64_t generated = base::RandUint64();
  if (generated == 0) {
    generated = 1;
  }
  uint64_t expected = 0;
  if (g_session_salt.compare_exchange_strong(expected, generated,
                                             std::memory_order_relaxed)) {
    return generated;
  }
  return expected;
}

}  // namespace

void SetFingerprintGuardEnabled(bool enabled) {
  g_fingerprint_guard_enabled.store(enabled, std::memory_order_relaxed);
}

bool IsFingerprintGuardEnabled() {
  return g_fingerprint_guard_enabled.load(std::memory_order_relaxed);
}

uint64_t FarblingTokenForHost(std::string_view host) {
  const uint64_t host_hash = base::PersistentHash(host);
  return SessionSalt() ^ (host_hash << 1) ^ host_hash;
}

}  // namespace blink::aegis
