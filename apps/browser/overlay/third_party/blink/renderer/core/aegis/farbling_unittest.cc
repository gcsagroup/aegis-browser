// Copyright 2026 GCSA

#include "third_party/blink/renderer/core/aegis/farbling.h"

#include <cmath>
#include <cstdint>
#include <iterator>
#include <limits>

#include "base/containers/span.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace blink::aegis {
namespace {

TEST(AegisFarblingTest, Float16IsDeterministicFiniteAndFormatPreserving) {
  constexpr uint64_t kToken = 0x123456789abcdef0ULL;
  uint16_t first[] = {0x3c00u, 0x3800u, 0xbc00u, 0x3c00u,
                      0x7c00u, 0x7e00u, 0xfc00u, 0x7c00u};
  uint16_t second[] = {0x3c00u, 0x3800u, 0xbc00u, 0x3c00u,
                       0x7c00u, 0x7e00u, 0xfc00u, 0x7c00u};

  FarbleFloat16Pixels(kToken, first);
  FarbleFloat16Pixels(kToken, second);

  EXPECT_EQ(base::span(first), base::span(second));
  EXPECT_NE(first[0], 0x3c00u);
  EXPECT_EQ(first[3], 0x3c00u);
  for (uint16_t value : first) {
    EXPECT_NE(value & 0x7c00u, 0x7c00u);
  }
}

TEST(AegisFarblingTest, Float32IsDeterministicFiniteAndPreservesAlpha) {
  constexpr uint64_t kToken = 0x0fedcba987654321ULL;
  float first[] = {1.0f,
                   -0.5f,
                   0.25f,
                   0.75f,
                   std::numeric_limits<float>::infinity(),
                   std::numeric_limits<float>::quiet_NaN(),
                   -std::numeric_limits<float>::infinity(),
                   1.0f};
  float second[std::size(first)];
  base::span(second).copy_from(first);

  FarbleFloat32Pixels(kToken, first);
  FarbleFloat32Pixels(kToken, second);

  EXPECT_EQ(base::span(first), base::span(second));
  for (float value : first) {
    EXPECT_TRUE(std::isfinite(value));
  }
  EXPECT_NE(first[0], 1.0f);
  EXPECT_FLOAT_EQ(first[3], 0.75f);
  EXPECT_FLOAT_EQ(first[7], 1.0f);
}

TEST(AegisFarblingTest, FloatNoiseIsSiteTokenSeparated) {
  float first[16] = {1.0f, 0.5f, 0.25f, 1.0f, 1.0f, 0.5f, 0.25f, 1.0f,
                     1.0f, 0.5f, 0.25f, 1.0f, 1.0f, 0.5f, 0.25f, 1.0f};
  float second[std::size(first)];
  base::span(second).copy_from(first);

  FarbleFloat32Pixels(1u, first);
  FarbleFloat32Pixels(2u, second);

  EXPECT_NE(base::span(first), base::span(second));
}

}  // namespace
}  // namespace blink::aegis
