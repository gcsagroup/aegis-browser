// Copyright 2026 GCSA

#ifndef CHROME_COMMON_AEGIS_MINER_GUARD_REPORTER_H_
#define CHROME_COMMON_AEGIS_MINER_GUARD_REPORTER_H_

#include <string>

#include "base/functional/callback.h"
#include "base/memory/scoped_refptr.h"
#include "chrome/common/aegis/miner_guard_model.h"

namespace base {
class SequencedTaskRunner;
}

namespace aegis {

// Sequence-safe bridge from trusted browser instrumentation to AegisService.
// Reports contain only bounded booleans, CPU buckets and sanitized site keys;
// source text, query strings and WebSocket payloads never cross this bridge.
class MinerGuardReporter {
 public:
  using SignalsCallback =
      base::RepeatingCallback<void(std::string document_id,
                                   std::string site_key,
                                   std::string display_domain,
                                   MinerRuntimeSignals signals)>;

  static void SetCallback(scoped_refptr<base::SequencedTaskRunner> task_runner,
                          SignalsCallback callback);
  static void ClearCallback();

  static void ReportSignals(const std::string& document_id,
                            const std::string& site_key,
                            const std::string& display_domain,
                            const MinerRuntimeSignals& signals);
};

}  // namespace aegis

#endif  // CHROME_COMMON_AEGIS_MINER_GUARD_REPORTER_H_
