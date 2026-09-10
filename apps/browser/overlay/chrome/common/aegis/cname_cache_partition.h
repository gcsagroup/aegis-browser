// Copyright 2026 GCSA
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CHROME_COMMON_AEGIS_CNAME_CACHE_PARTITION_H_
#define CHROME_COMMON_AEGIS_CNAME_CACHE_PARTITION_H_

#include <cstdint>

#include "base/types/strong_alias.h"

namespace aegis {

// Identifies one exact BrowserContext for CNAME cache isolation. Values are
// created in the browser process and sent to that context's renderers.
using CnameCachePartitionId =
    base::StrongAlias<class CnameCachePartitionIdTag, uint64_t>;

inline constexpr CnameCachePartitionId kInvalidCnameCachePartitionId{0};

}  // namespace aegis

#endif  // CHROME_COMMON_AEGIS_CNAME_CACHE_PARTITION_H_
