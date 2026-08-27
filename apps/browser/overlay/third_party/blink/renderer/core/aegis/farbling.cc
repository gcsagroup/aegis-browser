// Copyright 2026 GCSA
// Intended path: third_party/blink/renderer/core/aegis/farbling.cc

#include "third_party/blink/renderer/core/aegis/farbling.h"

#include <cstdint>
#include <string>
#include <vector>

#include "base/containers/span.h"
#include "third_party/blink/public/common/aegis/fingerprint_guard.h"
#include "third_party/blink/public/common/fingerprinting_protection/noise_token.h"
#include "third_party/blink/renderer/core/canvas_interventions/noise_hash.h"
#include "third_party/blink/renderer/core/canvas_interventions/noise_helper.h"
#include "third_party/blink/renderer/core/execution_context/execution_context.h"
#include "third_party/blink/renderer/core/html/canvas/image_data.h"
#include "third_party/blink/renderer/platform/graphics/static_bitmap_image.h"
#include "third_party/blink/renderer/platform/graphics/unaccelerated_static_bitmap_image.h"
#include "third_party/blink/renderer/platform/weborigin/security_origin.h"
#include "third_party/blink/renderer/platform/wtf/text/string_builder.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "third_party/skia/include/core/SkImage.h"

namespace blink {
namespace aegis {
namespace {

std::string HostForContext(ExecutionContext* context) {
  if (!context) {
    return std::string();
  }
  const SecurityOrigin* origin = context->GetSecurityOrigin();
  if (!origin) {
    return std::string();
  }
  return origin->Host().Utf8();
}

uint64_t TokenForContext(ExecutionContext* context) {
  return FarblingTokenForHost(HostForContext(context));
}

}  // namespace

void MaybeFarbleImageData(ExecutionContext* context, ImageData* image_data) {
  if (!IsFingerprintGuardEnabled() || !image_data ||
      image_data->IsBufferBaseDetached()) {
    return;
  }

  if (image_data->GetSkColorType() != kRGBA_8888_SkColorType &&
      image_data->GetSkColorType() != kBGRA_8888_SkColorType) {
    return;
  }

  base::span<uint8_t> pixels = image_data->RawByteSpan();
  const int width = image_data->width();
  const int height = image_data->height();
  const size_t expected =
      static_cast<size_t>(width) * static_cast<size_t>(height) * 4u;
  if (width <= 0 || height <= 0 || pixels.size() != expected) {
    return;
  }

  NoiseHash hash(NoiseToken(TokenForContext(context)));
  NoisePixels(hash, pixels, width, height);
}

scoped_refptr<StaticBitmapImage> MaybeFarbleStaticBitmapImage(
    ExecutionContext* context,
    scoped_refptr<StaticBitmapImage> image) {
  if (!IsFingerprintGuardEnabled() || !image) {
    return image;
  }

  const gfx::Size size = image->Size();
  if (size.IsEmpty()) {
    return image;
  }

  SkImageInfo info =
      SkImageInfo::Make(size.width(), size.height(), kRGBA_8888_SkColorType,
                        kUnpremul_SkAlphaType);
  SkBitmap bitmap;
  if (!bitmap.tryAllocPixels(info)) {
    return image;
  }

  const bool read_ok = image->PaintImageForCurrentFrame().readPixels(
      bitmap.info(), bitmap.getPixels(), bitmap.rowBytes(), 0, 0);
  if (!read_ok) {
    return image;
  }

  const size_t row_bytes = static_cast<size_t>(size.width()) * 4u;
  if (bitmap.rowBytes() != row_bytes) {
    return image;
  }

  const size_t nbytes = row_bytes * static_cast<size_t>(size.height());
  auto bitmap_span =
      UNSAFE_TODO(base::span(static_cast<uint8_t*>(bitmap.getPixels()), nbytes));
  std::vector<uint8_t> packed(nbytes);
  base::span<uint8_t>(packed).copy_from(bitmap_span);
  NoiseHash hash(NoiseToken(TokenForContext(context)));
  NoisePixels(hash, packed, size.width(), size.height());
  bitmap_span.copy_from(packed);

  return UnacceleratedStaticBitmapImage::Create(
      SkImages::RasterFromBitmap(bitmap), image->Orientation());
}

void MaybeFarbleAudioChannel(ExecutionContext* context,
                             float* data,
                             size_t length) {
  if (!IsFingerprintGuardEnabled() || !data || length == 0) {
    return;
  }

  auto samples = UNSAFE_TODO(base::span(data, length));
  // 幅度约 0.05%，由当前页面 host 与采样下标决定，同一站点稳定。
  uint64_t token = TokenForContext(context);
  for (size_t i = 0; i < samples.size(); ++i) {
    token = token * 6364136223846793005ULL + 1ULL;
    const float delta =
        (static_cast<float>((token >> 33) & 0xFFFF) / 65535.f - 0.5f) *
        0.0005f;
    samples[i] += samples[i] * delta;
  }
}

String FarbledWebGLVendor(ExecutionContext* context) {
  const uint64_t token = TokenForContext(context);
  StringBuilder builder;
  builder.Append("Google Inc. (Aegis ");
  builder.AppendNumber(token & 0xFFFFu);
  builder.Append(")");
  return builder.ToString();
}

String FarbledWebGLRenderer(ExecutionContext* context) {
  const uint64_t token = TokenForContext(context);
  StringBuilder builder;
  builder.Append("ANGLE (Aegis, Aegis Renderer ");
  builder.AppendNumber((token >> 16) & 0xFFFFu);
  builder.Append(" Direct3D11)");
  return builder.ToString();
}

void MaybeFarbleWebGPUAdapterStrings(ExecutionContext* context,
                                     String& vendor,
                                     String& architecture,
                                     String& device,
                                     String& description,
                                     String& driver) {
  if (!IsFingerprintGuardEnabled()) {
    return;
  }
  const uint64_t token = TokenForContext(context);
  vendor = String("aegis");

  StringBuilder arch;
  arch.Append("aegis-");
  arch.AppendNumber(token & 0xFFFFu);
  architecture = arch.ToString();

  StringBuilder dev;
  dev.Append("0x");
  dev.AppendNumber((token >> 16) & 0xFFFFu);
  device = dev.ToString();

  StringBuilder desc;
  desc.Append("ANGLE (Aegis Renderer ");
  desc.AppendNumber((token >> 32) & 0xFFFFu);
  desc.Append(")");
  description = desc.ToString();

  StringBuilder drv;
  drv.Append("Aegis ");
  drv.AppendNumber((token >> 48) & 0xFFFFu);
  driver = drv.ToString();
}

namespace {

// WebGPU 规范要求的下限。只往下收，不抬高，避免报出硬件没有的能力。
constexpr uint64_t kMinMaxBufferSize = 268435456ULL;
constexpr uint32_t kMinMaxWorkgroupStorage = 16384u;
constexpr uint32_t kMinMaxTexture3d = 2048u;
constexpr uint32_t kMinSubgroupMin = 4u;

void AdvanceToken(uint64_t* token) {
  *token = *token * 6364136223846793005ULL + 1ULL;
}

template <typename T>
T FarbleTowardMin(T actual, T spec_min, uint64_t* token) {
  AdvanceToken(token);
  if (actual <= spec_min) {
    return actual;
  }
  const uint64_t headroom = static_cast<uint64_t>(actual - spec_min);
  const uint64_t drop = (headroom * ((*token >> 33) & 15u)) / 64u;
  const T out = actual - static_cast<T>(drop);
  return out < spec_min ? spec_min : out;
}

// subgroupMinSize / subgroupMaxSize 必须是 2 的幂，不能按任意整数收档。
uint32_t FarblePowerOfTwoTowardMin(uint32_t actual,
                                   uint32_t spec_min,
                                   uint64_t* token) {
  AdvanceToken(token);
  if (actual <= spec_min || (actual & (actual - 1u)) != 0u) {
    return actual;
  }
  uint32_t floor_min = spec_min;
  if (floor_min == 0u || (floor_min & (floor_min - 1u)) != 0u) {
    return actual;
  }
  uint32_t steps = 0u;
  for (uint32_t v = actual; v > floor_min; v >>= 1u) {
    ++steps;
  }
  const uint32_t drop_steps =
      static_cast<uint32_t>((steps * ((*token >> 33) & 15u)) / 64u);
  const uint32_t out = actual >> drop_steps;
  return out < floor_min ? floor_min : out;
}

}  // namespace

void MaybeFarbleWebGPUNumericLimits(ExecutionContext* context,
                                    uint64_t& max_buffer_size,
                                    uint32_t& max_workgroup_storage,
                                    uint32_t& max_texture_3d,
                                    uint32_t& subgroup_min_size,
                                    uint32_t& subgroup_max_size) {
  if (!IsFingerprintGuardEnabled()) {
    return;
  }
  uint64_t token = TokenForContext(context);
  max_buffer_size =
      FarbleTowardMin(max_buffer_size, kMinMaxBufferSize, &token);
  max_workgroup_storage =
      FarbleTowardMin(max_workgroup_storage, kMinMaxWorkgroupStorage, &token);
  max_texture_3d = FarbleTowardMin(max_texture_3d, kMinMaxTexture3d, &token);
  subgroup_min_size =
      FarblePowerOfTwoTowardMin(subgroup_min_size, kMinSubgroupMin, &token);
  if (subgroup_max_size > subgroup_min_size) {
    subgroup_max_size = FarblePowerOfTwoTowardMin(
        subgroup_max_size, subgroup_min_size, &token);
  }
}

}  // namespace aegis
}  // namespace blink
