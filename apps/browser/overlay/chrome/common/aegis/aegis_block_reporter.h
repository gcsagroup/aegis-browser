// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/aegis_block_reporter.h

#ifndef CHROME_COMMON_AEGIS_AEGIS_BLOCK_REPORTER_H_
#define CHROME_COMMON_AEGIS_AEGIS_BLOCK_REPORTER_H_

#include <string>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/scoped_refptr.h"
#include "url/gurl.h"

namespace base {
class SequencedTaskRunner;
}

namespace aegis {

// 进程内回调：browser 侧接到 AegisService，renderer 侧经 mojo 转到 browser。
// AegisNetThrottle 在 chrome/common 编译，不能直接依赖 chrome/browser。
class BlockReporter {
 public:
  using BlockedCallback =
      base::RepeatingCallback<void(GURL url,
                                   std::string reason,
                                   std::string cname_alias,
                                   std::string source_site,
                                   std::string document_id)>;
  using ReferrerCallback =
      base::RepeatingCallback<void(std::string host,
                                   std::vector<std::string> keys,
                                   std::string source_site,
                                   std::string document_id)>;
  using ParamsCallback = ReferrerCallback;

  // Installs one callback set whose targets all run on |task_runner|. Reports
  // may arrive from any sequence after a URLLoaderThrottle is detached.
  static void SetCallbacks(scoped_refptr<base::SequencedTaskRunner> task_runner,
                           BlockedCallback blocked,
                           ReferrerCallback referrer,
                           ParamsCallback params);
  static void ClearCallbacks();

  static void ReportBlocked(const GURL& url,
                            const std::string& reason,
                            const std::string& cname_alias,
                            const std::string& source_site = std::string(),
                            const std::string& document_id = std::string());
  static void ReportStrippedReferrer(
      const std::string& host,
      const std::vector<std::string>& keys,
      const std::string& source_site = std::string(),
      const std::string& document_id = std::string());
  static void ReportStrippedParams(
      const std::string& host,
      const std::vector<std::string>& keys,
      const std::string& source_site = std::string(),
      const std::string& document_id = std::string());
};

}  // namespace aegis

#endif  // CHROME_COMMON_AEGIS_AEGIS_BLOCK_REPORTER_H_
