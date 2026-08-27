// Copyright 2026 GCSA
// Intended path: third_party/blink/renderer/core/aegis/farbling.h

#ifndef THIRD_PARTY_BLINK_RENDERER_CORE_AEGIS_FARBLING_H_
#define THIRD_PARTY_BLINK_RENDERER_CORE_AEGIS_FARBLING_H_

#include <cstddef>
#include <cstdint>

#include "base/containers/span.h"
#include "base/memory/scoped_refptr.h"
#include "third_party/blink/renderer/core/core_export.h"
#include "third_party/blink/renderer/platform/wtf/text/wtf_string.h"

namespace blink {

class ExecutionContext;
class ImageData;
class StaticBitmapImage;

namespace aegis {

// 判断当前上下文的 schemeful 顶层站点是否启用指纹保护，并应用站点暂停策略。
CORE_EXPORT bool ShouldFarbleFingerprint(ExecutionContext* context);

// FingerprintGuard 启用时扰动 Canvas 像素。
CORE_EXPORT void MaybeFarbleImageData(ExecutionContext* context,
                                      ImageData* image_data);

// 对浮点 RGBA 像素施加确定性、有限值安全的扰动。RGB 向零移动少量可表示
// 步长，有限 alpha 保持不变；半精度输入使用 IEEE-754 binary16 位表示。
CORE_EXPORT void FarbleFloat16Pixels(uint64_t token,
                                     base::span<uint16_t> pixels);
CORE_EXPORT void FarbleFloat32Pixels(uint64_t token, base::span<float> pixels);

// 扰动供 toDataURL / toBlob 序列化使用的 Canvas 快照。
CORE_EXPORT scoped_refptr<StaticBitmapImage> MaybeFarbleStaticBitmapImage(
    ExecutionContext* context,
    scoped_refptr<StaticBitmapImage> image);

// 对 Web Audio 样本施加轻量扰动，并按顶层站点、表面和样本下标保持稳定。
CORE_EXPORT void MaybeFarbleAudioChannel(ExecutionContext* context,
                                         float* data,
                                         size_t length);

// 保护 WebGPU adapter.info 字符串。
CORE_EXPORT void MaybeFarbleWebGPUAdapterStrings(ExecutionContext* context,
                                                 String& vendor,
                                                 String& architecture,
                                                 String& device,
                                                 String& description,
                                                 String& driver);

// 把高熵 WebGPU 数值放入固定、有限且只向下收敛的人口桶。
CORE_EXPORT void MaybeFarbleWebGPUNumericLimits(ExecutionContext* context,
                                                uint64_t& max_buffer_size,
                                                uint32_t& max_workgroup_storage,
                                                uint32_t& max_texture_3d);

}  // namespace aegis
}  // namespace blink

#endif  // THIRD_PARTY_BLINK_RENDERER_CORE_AEGIS_FARBLING_H_
