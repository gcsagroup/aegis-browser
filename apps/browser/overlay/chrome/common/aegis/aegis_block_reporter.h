// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/aegis_block_reporter.h

#ifndef CHROME_COMMON_AEGIS_AEGIS_BLOCK_REPORTER_H_
#define CHROME_COMMON_AEGIS_AEGIS_BLOCK_REPORTER_H_

#include <string>
#include <vector>

#include "base/functional/callback.h"

class GURL;

namespace aegis {

// 进程内回调：browser 侧接到 AegisService，renderer 侧经 mojo 转到 browser。
// AegisNetThrottle 在 chrome/common 编译，不能直接依赖 chrome/browser。
class BlockReporter {
 public:
  using BlockedCallback = base::RepeatingCallback<
      void(const GURL& url,
           const std::string& reason,
           const std::string& cname_alias)>;
  using ReferrerCallback = base::RepeatingCallback<
      void(const std::string& host, const std::vector<std::string>& keys)>;
  using ParamsCallback = ReferrerCallback;

  static void SetBlockedCallback(BlockedCallback callback);
  static void SetReferrerCallback(ReferrerCallback callback);
  static void SetParamsCallback(ParamsCallback callback);

  static void ReportBlocked(const GURL& url,
                            const std::string& reason,
                            const std::string& cname_alias);
  static void ReportStrippedReferrer(const std::string& host,
                                     const std::vector<std::string>& keys);
  static void ReportStrippedParams(const std::string& host,
                                   const std::vector<std::string>& keys);
};

}  // namespace aegis

#endif  // CHROME_COMMON_AEGIS_AEGIS_BLOCK_REPORTER_H_
