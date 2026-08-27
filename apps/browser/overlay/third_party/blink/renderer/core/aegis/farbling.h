// Copyright 2026 GCSA
// Intended path: third_party/blink/renderer/core/aegis/farbling.h

#ifndef THIRD_PARTY_BLINK_RENDERER_CORE_AEGIS_FARBLING_H_
#define THIRD_PARTY_BLINK_RENDERER_CORE_AEGIS_FARBLING_H_

#include <cstdint>

#include "base/memory/scoped_refptr.h"
#include "third_party/blink/renderer/core/core_export.h"
#include "third_party/blink/renderer/platform/wtf/text/wtf_string.h"

namespace blink {

class ExecutionContext;
class ImageData;
class StaticBitmapImage;

namespace aegis {

// Applies canvas pixel farbling when FingerprintGuard is enabled.
CORE_EXPORT void MaybeFarbleImageData(ExecutionContext* context,
                                      ImageData* image_data);

// Farble a canvas snapshot used by toDataURL / toBlob serialization.
CORE_EXPORT scoped_refptr<StaticBitmapImage> MaybeFarbleStaticBitmapImage(
    ExecutionContext* context,
    scoped_refptr<StaticBitmapImage> image);

// Light Web Audio sample perturbation. 按 host 稳定；调用方应对每个
// AudioBuffer 只调用一次，避免重复叠加。
CORE_EXPORT void MaybeFarbleAudioChannel(ExecutionContext* context,
                                         float* data,
                                         size_t length);

// Stable farbled WebGL debug strings for UNMASKED_* parameters.
CORE_EXPORT String FarbledWebGLVendor(ExecutionContext* context);
CORE_EXPORT String FarbledWebGLRenderer(ExecutionContext* context);

// Stable farbled WebGPU adapter.info strings.
CORE_EXPORT void MaybeFarbleWebGPUAdapterStrings(ExecutionContext* context,
                                                 String& vendor,
                                                 String& architecture,
                                                 String& device,
                                                 String& description,
                                                 String& driver);

// 把若干高识别度 WebGPU 数值向规范下限收一档，按 host 稳定，且不超过硬件原值。
CORE_EXPORT void MaybeFarbleWebGPUNumericLimits(ExecutionContext* context,
                                                uint64_t& max_buffer_size,
                                                uint32_t& max_workgroup_storage,
                                                uint32_t& max_texture_3d,
                                                uint32_t& subgroup_min_size,
                                                uint32_t& subgroup_max_size);

}  // namespace aegis
}  // namespace blink

#endif  // THIRD_PARTY_BLINK_RENDERER_CORE_AEGIS_FARBLING_H_
