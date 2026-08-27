// Copyright 2026 GCSA
// Intended path: third_party/blink/renderer/core/aegis/farbling.cc

#include "third_party/blink/renderer/core/aegis/farbling.h"

#include <algorithm>
#include <bit>
#include <cstdint>
#include <string>

#include "base/containers/span.h"
#include "base/unguessable_token.h"
#include "third_party/blink/public/common/aegis/fingerprint_guard.h"
#include "third_party/blink/public/common/fingerprinting_protection/noise_token.h"
#include "third_party/blink/renderer/bindings/core/v8/v8_union_float16array_float32array_uint8clampedarray.h"
#include "third_party/blink/renderer/core/canvas_interventions/noise_hash.h"
#include "third_party/blink/renderer/core/canvas_interventions/noise_helper.h"
#include "third_party/blink/renderer/core/dom/document.h"
#include "third_party/blink/renderer/core/execution_context/execution_context.h"
#include "third_party/blink/renderer/core/frame/local_dom_window.h"
#include "third_party/blink/renderer/core/html/canvas/image_data.h"
#include "third_party/blink/renderer/core/workers/worker_global_scope.h"
#include "third_party/blink/renderer/platform/graphics/static_bitmap_image.h"
#include "third_party/blink/renderer/platform/graphics/unaccelerated_static_bitmap_image.h"
#include "third_party/blink/renderer/platform/weborigin/security_origin.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "third_party/skia/include/core/SkImage.h"

namespace blink {
namespace aegis {
namespace {

scoped_refptr<const SecurityOrigin> TopLevelOriginForContext(
    ExecutionContext* context) {
  if (!context) {
    return nullptr;
  }

  if (auto* window = DynamicTo<LocalDOMWindow>(context)) {
    if (Document* document = window->document()) {
      if (scoped_refptr<const SecurityOrigin> top_frame_origin =
              document->TopFrameOrigin()) {
        return top_frame_origin;
      }
    }
  }
  if (auto* worker = DynamicTo<WorkerGlobalScope>(context)) {
    if (const SecurityOrigin* top_level =
            worker->top_level_frame_security_origin()) {
      return base::WrapRefCounted(top_level);
    }
  }
  return base::WrapRefCounted(context->GetSecurityOrigin());
}

std::string TopLevelSiteForContext(ExecutionContext* context) {
  scoped_refptr<const SecurityOrigin> origin =
      TopLevelOriginForContext(context);
  if (!origin) {
    return std::string();
  }
  if (origin->IsOpaque()) {
    return "opaque:" + context->GetAgentClusterID().ToString();
  }
  return origin->GetSchemefulSite().Serialize();
}

std::string TopLevelHostForContext(ExecutionContext* context) {
  scoped_refptr<const SecurityOrigin> origin =
      TopLevelOriginForContext(context);
  return origin && !origin->IsOpaque() ? origin->Host().Utf8() : std::string();
}

uint64_t TokenForContext(ExecutionContext* context, FarblingSurface surface) {
  return FarblingTokenForSite(TopLevelSiteForContext(context), surface);
}

uint64_t AudioNoiseForSample(uint64_t token, size_t sample_index) {
  // 采用 SplitMix64 风格混合，使每个样本下标都能独立、确定地生成扰动。
  uint64_t value = token + 0x9e3779b97f4a7c15ULL *
                               (static_cast<uint64_t>(sample_index) + 1ULL);
  value = (value ^ (value >> 30)) * 0xbf58476d1ce4e5b9ULL;
  value = (value ^ (value >> 27)) * 0x94d049bb133111ebULL;
  return value ^ (value >> 31);
}

uint64_t PixelNoiseForIndex(uint64_t token, size_t index) {
  uint64_t value =
      token + 0x9e3779b97f4a7c15ULL * (static_cast<uint64_t>(index) + 1);
  value = (value ^ (value >> 30)) * 0xbf58476d1ce4e5b9ULL;
  value = (value ^ (value >> 27)) * 0x94d049bb133111ebULL;
  return value ^ (value >> 31);
}

template <typename Bits>
Bits FarbleFloatingPointBits(uint64_t token,
                             size_t index,
                             Bits bits,
                             Bits sign_mask,
                             Bits exponent_mask,
                             Bits one_bits) {
  const Bits magnitude = bits & ~sign_mask;
  if ((magnitude & exponent_mask) == exponent_mask) {
    return index % 4 == 3 ? one_bits : 0;
  }
  if (index % 4 == 3 || magnitude == 0) {
    return bits;
  }

  const Bits steps =
      static_cast<Bits>((PixelNoiseForIndex(token, index) & 3u) + 1u);
  return (bits & sign_mask) | (magnitude > steps ? magnitude - steps : 0);
}

void PreserveByteAlphaInvariant(base::span<uint8_t> pixels,
                                SkAlphaType alpha_type) {
  if (alpha_type != kOpaque_SkAlphaType && alpha_type != kPremul_SkAlphaType) {
    return;
  }
  for (size_t i = 0; i < pixels.size(); i += 4) {
    uint8_t& alpha = pixels[i + 3];
    if (alpha_type == kOpaque_SkAlphaType) {
      alpha = 255;
    } else {
      pixels[i] = std::min(pixels[i], alpha);
      pixels[i + 1] = std::min(pixels[i + 1], alpha);
      pixels[i + 2] = std::min(pixels[i + 2], alpha);
    }
  }
}

template <typename T>
void PreserveOpaqueFloatAlpha(base::span<T> pixels, T one) {
  for (size_t i = 3; i < pixels.size(); i += 4) {
    pixels[i] = one;
  }
}

}  // namespace

bool ShouldFarbleFingerprint(ExecutionContext* context) {
  if (!context || TopLevelSiteForContext(context).empty()) {
    return false;
  }
  return IsFingerprintGuardEnabledForSite(TopLevelHostForContext(context));
}

void FarbleFloat16Pixels(uint64_t token, base::span<uint16_t> pixels) {
  for (size_t i = 0; i < pixels.size(); ++i) {
    pixels[i] = FarbleFloatingPointBits<uint16_t>(token, i, pixels[i], 0x8000u,
                                                  0x7c00u, 0x3c00u);
  }
}

void FarbleFloat32Pixels(uint64_t token, base::span<float> pixels) {
  for (size_t i = 0; i < pixels.size(); ++i) {
    uint32_t bits = std::bit_cast<uint32_t>(pixels[i]);
    bits = FarbleFloatingPointBits<uint32_t>(token, i, bits, 0x80000000u,
                                             0x7f800000u, 0x3f800000u);
    pixels[i] = std::bit_cast<float>(bits);
  }
}

void MaybeFarbleImageData(ExecutionContext* context, ImageData* image_data) {
  if (!ShouldFarbleFingerprint(context) || !image_data ||
      image_data->IsBufferBaseDetached()) {
    return;
  }

  const int width = image_data->width();
  const int height = image_data->height();
  const size_t expected =
      static_cast<size_t>(width) * static_cast<size_t>(height) * 4u;
  if (width <= 0 || height <= 0) {
    return;
  }

  const uint64_t token = TokenForContext(context, FarblingSurface::kCanvas);
  switch (image_data->GetSkColorType()) {
    case kRGBA_8888_SkColorType:
    case kBGRA_8888_SkColorType: {
      base::span<uint8_t> pixels = image_data->RawByteSpan();
      if (pixels.size() != expected) {
        return;
      }
      NoisePixels(NoiseHash(NoiseToken(token)), pixels, width, height);
      return;
    }
    case kRGBA_F16_SkColorType: {
      base::span<uint16_t> pixels =
          image_data->data()->GetAsFloat16Array()->AsSpan();
      if (pixels.size() != expected) {
        return;
      }
      FarbleFloat16Pixels(token, pixels);
      return;
    }
    case kRGBA_F32_SkColorType: {
      base::span<float> pixels =
          image_data->data()->GetAsFloat32Array()->AsSpan();
      if (pixels.size() != expected) {
        return;
      }
      FarbleFloat32Pixels(token, pixels);
      return;
    }
    default:
      NOTREACHED();
  }
}

scoped_refptr<StaticBitmapImage> MaybeFarbleStaticBitmapImage(
    ExecutionContext* context,
    scoped_refptr<StaticBitmapImage> image) {
  if (!ShouldFarbleFingerprint(context) || !image) {
    return image;
  }

  const gfx::Size size = image->Size();
  if (size.IsEmpty()) {
    return nullptr;
  }

  const PaintImage paint_image = image->PaintImageForCurrentFrame();
  const SkImageInfo source_info = paint_image.GetSkImageInfo();
  SkColorType target_color_type = source_info.colorType();
  switch (target_color_type) {
    case kRGBA_8888_SkColorType:
    case kBGRA_8888_SkColorType:
    case kSRGBA_8888_SkColorType:
    case kRGBA_F16Norm_SkColorType:
    case kRGBA_F16_SkColorType:
    case kRGBA_F32_SkColorType:
      break;
    default:
      target_color_type = kRGBA_8888_SkColorType;
  }
  const SkAlphaType target_alpha_type = source_info.alphaType();
  const SkImageInfo info =
      SkImageInfo::Make(size.width(), size.height(), target_color_type,
                        target_alpha_type, source_info.refColorSpace());
  SkBitmap bitmap;
  if (!bitmap.tryAllocPixels(info)) {
    return nullptr;
  }

  const bool read_ok = paint_image.readPixels(bitmap.info(), bitmap.getPixels(),
                                              bitmap.rowBytes(), 0, 0);
  if (!read_ok) {
    return nullptr;
  }

  const size_t row_bytes = info.minRowBytes();
  if (bitmap.rowBytes() != row_bytes) {
    return nullptr;
  }

  const size_t nbytes = row_bytes * static_cast<size_t>(size.height());
  auto bitmap_span = UNSAFE_TODO(
      base::span(static_cast<uint8_t*>(bitmap.getPixels()), nbytes));
  const uint64_t token = TokenForContext(context, FarblingSurface::kCanvas);
  switch (target_color_type) {
    case kRGBA_8888_SkColorType:
    case kBGRA_8888_SkColorType:
    case kSRGBA_8888_SkColorType:
      NoisePixels(NoiseHash(NoiseToken(token)), bitmap_span, size.width(),
                  size.height());
      PreserveByteAlphaInvariant(bitmap_span, target_alpha_type);
      break;
    case kRGBA_F16Norm_SkColorType:
    case kRGBA_F16_SkColorType: {
      auto pixels =
          UNSAFE_TODO(base::span(static_cast<uint16_t*>(bitmap.getPixels()),
                                 nbytes / sizeof(uint16_t)));
      FarbleFloat16Pixels(token, pixels);
      if (target_alpha_type == kOpaque_SkAlphaType) {
        PreserveOpaqueFloatAlpha<uint16_t>(pixels, 0x3c00u);
      }
      break;
    }
    case kRGBA_F32_SkColorType: {
      auto pixels = UNSAFE_TODO(base::span(
          static_cast<float*>(bitmap.getPixels()), nbytes / sizeof(float)));
      FarbleFloat32Pixels(token, pixels);
      if (target_alpha_type == kOpaque_SkAlphaType) {
        PreserveOpaqueFloatAlpha<float>(pixels, 1.0f);
      }
      break;
    }
    default:
      NOTREACHED();
  }

  sk_sp<SkImage> sk_image = SkImages::RasterFromBitmap(bitmap);
  if (!sk_image) {
    return nullptr;
  }
  scoped_refptr<StaticBitmapImage> farbled =
      UnacceleratedStaticBitmapImage::Create(
          std::move(sk_image), image->Orientation(), image->GetHdrMetadata());
  if (!farbled) {
    return nullptr;
  }
  farbled->SetOriginClean(image->OriginClean());
  return farbled;
}

void MaybeFarbleAudioChannel(ExecutionContext* context,
                             float* data,
                             size_t length) {
  if (!ShouldFarbleFingerprint(context) || !data || length == 0) {
    return;
  }

  auto samples = UNSAFE_TODO(base::span(data, length));
  // 扰动幅度约 0.05%，对同一顶层站点和音频表面保持稳定。
  const uint64_t token = TokenForContext(context, FarblingSurface::kAudio);
  for (size_t i = 0; i < samples.size(); ++i) {
    const uint64_t sample_noise = AudioNoiseForSample(token, i);
    const float delta =
        (static_cast<float>((sample_noise >> 33) & 0xFFFF) / 65535.f - 0.5f) *
        0.0005f;
    samples[i] += samples[i] * delta;
  }
}

void MaybeFarbleWebGPUAdapterStrings(ExecutionContext* context,
                                     String& vendor,
                                     String& architecture,
                                     String& device,
                                     String& description,
                                     String& driver) {
  if (!ShouldFarbleFingerprint(context)) {
    return;
  }
  vendor = String();
  architecture = String();
  device = String();
  description = String();
  driver = String();
}

void MaybeFarbleWebGPUNumericLimits(ExecutionContext* context,
                                    uint64_t& max_buffer_size,
                                    uint32_t& max_workgroup_storage,
                                    uint32_t& max_texture_3d) {
  if (!ShouldFarbleFingerprint(context)) {
    return;
  }
  max_buffer_size = BucketWebGPUMaxBufferSize(max_buffer_size);
  max_workgroup_storage =
      BucketWebGPUMaxWorkgroupStorage(max_workgroup_storage);
  max_texture_3d = BucketWebGPUMaxTexture3D(max_texture_3d);
}

}  // namespace aegis
}  // namespace blink
