// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/tracking_query_params.h

#ifndef CHROME_COMMON_AEGIS_TRACKING_QUERY_PARAMS_H_
#define CHROME_COMMON_AEGIS_TRACKING_QUERY_PARAMS_H_

#include <string>
#include <string_view>
#include <vector>

class GURL;

namespace aegis {

// Returns true when |name| is a known tracking query parameter
// (from packages/core TRACKING_QUERY_PARAMS).
bool IsTrackingQueryParam(std::string_view name);

// Strips known tracking query params and hash decorations. |removed|
// (optional) receives the stripped keys.
GURL SanitizeTrackingDecorations(const GURL& url,
                                 std::vector<std::string>* removed = nullptr);

}  // namespace aegis

#endif  // CHROME_COMMON_AEGIS_TRACKING_QUERY_PARAMS_H_
