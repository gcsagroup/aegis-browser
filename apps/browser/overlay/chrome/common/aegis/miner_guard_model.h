// Copyright 2026 GCSA

#ifndef CHROME_COMMON_AEGIS_MINER_GUARD_MODEL_H_
#define CHROME_COMMON_AEGIS_MINER_GUARD_MODEL_H_

#include <optional>
#include <string>
#include <vector>

#include "base/time/time.h"

class GURL;

namespace aegis {

// MinerGuard is deliberately multi-signal. Common high-load web features are
// not malicious on their own, so no single CPU, Worker, Wasm, WebGPU or socket
// signal can produce a mining verdict.
struct MinerRuntimeSignals {
  bool cpu_sampled = false;
  int cpu_percent = 0;
  int sustained_high_cpu_samples = 0;
  bool background = false;
  bool worker = false;
  bool wasm = false;
  bool webgpu = false;
  bool shared_memory = false;
  bool websocket = false;
  bool mining_endpoint = false;
};

enum class MinerVerdict {
  kBenign = 0,
  kObserve = 1,
  kSuspicious = 2,
  kLikelyMining = 3,
};

struct MinerAssessment {
  MinerVerdict verdict = MinerVerdict::kBenign;
  int score = 0;
  std::vector<std::string> reasons;
};

MinerAssessment AssessMinerSignals(const MinerRuntimeSignals& signals);

// Merges a full page-observer snapshot or a partial trusted hook report. CPU
// fields are replaced only by a sampled report; capability bits are sticky for
// the caller's bounded observation window.
void MergeMinerSignals(const MinerRuntimeSignals& incoming,
                       MinerRuntimeSignals* accumulated);

// Tracks each signal in a bounded rolling observation window. A new report
// refreshes only the fields it actually carries, so unrelated callbacks cannot
// keep old endpoint or CPU evidence alive.
struct MinerSignalWindow {
  MinerRuntimeSignals signals;
  base::TimeTicks cpu_at;
  base::TimeTicks background_at;
  base::TimeTicks worker_at;
  base::TimeTicks wasm_at;
  base::TimeTicks webgpu_at;
  base::TimeTicks shared_memory_at;
  base::TimeTicks websocket_at;
  base::TimeTicks mining_endpoint_at;
};

void AddMinerSignalsToWindow(const MinerRuntimeSignals& incoming,
                             base::TimeTicks now,
                             base::TimeDelta duration,
                             MinerSignalWindow* window);

// CPU attribution is only useful when page capabilities can satisfy the
// multi-signal mining rule. A lone WebSocket, Worker or compute API is not
// enough to start the sampler.
bool ShouldSampleMinerCpu(const MinerRuntimeSignals& signals);

// Returns a privacy-safe reason code for strong mining endpoint indicators.
// The query, fragment, credentials and full URL are never returned or stored.
std::optional<std::string> MiningEndpointIndicator(const GURL& url);

}  // namespace aegis

#endif  // CHROME_COMMON_AEGIS_MINER_GUARD_MODEL_H_
