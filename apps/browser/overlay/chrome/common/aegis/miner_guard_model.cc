// Copyright 2026 GCSA

#include "chrome/common/aegis/miner_guard_model.h"

#include <algorithm>
#include <string_view>

#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "url/gurl.h"

namespace aegis {
namespace {

constexpr int kHighCpuPercent = 35;
constexpr int kSustainedSampleCount = 3;

bool IsExpired(base::TimeTicks observed_at,
               base::TimeTicks now,
               base::TimeDelta duration) {
  return !observed_at.is_null() &&
         (now < observed_at || now - observed_at >= duration);
}

void ExpireSignal(bool* signal,
                  base::TimeTicks* observed_at,
                  base::TimeTicks now,
                  base::TimeDelta duration) {
  if (!IsExpired(*observed_at, now, duration)) {
    return;
  }
  *signal = false;
  *observed_at = base::TimeTicks();
}

void ObserveSignal(bool incoming,
                   bool* signal,
                   base::TimeTicks* observed_at,
                   base::TimeTicks now) {
  if (!incoming) {
    return;
  }
  *signal = true;
  *observed_at = now;
}

void AddReason(bool present,
               int weight,
               std::string_view code,
               int* score,
               std::vector<std::string>* reasons) {
  if (!present) {
    return;
  }
  *score += weight;
  reasons->emplace_back(code);
}

std::vector<std::string_view> EndpointTokens(const GURL& url,
                                             std::string* storage) {
  *storage = base::ToLowerASCII(url.host());
  storage->push_back('/');
  storage->append(base::ToLowerASCII(url.path()));
  return base::SplitStringPiece(*storage, ".-_/", base::TRIM_WHITESPACE,
                                base::SPLIT_WANT_NONEMPTY);
}

bool HasToken(const std::vector<std::string_view>& tokens,
              std::string_view expected) {
  return std::ranges::find(tokens, expected) != tokens.end();
}

}  // namespace

MinerAssessment AssessMinerSignals(const MinerRuntimeSignals& signals) {
  MinerAssessment result;
  const bool high_cpu =
      signals.cpu_sampled && signals.cpu_percent >= kHighCpuPercent;
  const bool sustained =
      signals.cpu_sampled &&
      signals.sustained_high_cpu_samples >= kSustainedSampleCount;
  const bool compute = signals.wasm || signals.webgpu;
  const bool execution_fanout = signals.worker || signals.websocket;
  const bool strong_indicator = signals.mining_endpoint;

  AddReason(high_cpu, 20, "high_cpu", &result.score, &result.reasons);
  AddReason(sustained, 20, "sustained_cpu", &result.score, &result.reasons);
  AddReason(signals.background, 5, "background", &result.score,
            &result.reasons);
  AddReason(signals.worker, 10, "worker", &result.score, &result.reasons);
  AddReason(signals.wasm, 10, "wasm", &result.score, &result.reasons);
  AddReason(signals.webgpu, 10, "webgpu", &result.score, &result.reasons);
  AddReason(signals.shared_memory, 5, "shared_memory", &result.score,
            &result.reasons);
  AddReason(signals.websocket, 10, "websocket", &result.score, &result.reasons);
  AddReason(signals.mining_endpoint, 35, "mining_endpoint", &result.score,
            &result.reasons);
  result.score = std::min(100, result.score);

  // A likely-mining verdict requires sustained resource use plus a strong
  // endpoint indicator and an execution or communication fan-out. This keeps
  // games, codecs, local AI and scientific Wasm/WebGPU workloads out of the
  // high-confidence bucket.
  if (strong_indicator && high_cpu && sustained && execution_fanout &&
      (compute || signals.worker) && result.score >= 80) {
    result.verdict = MinerVerdict::kLikelyMining;
  } else if (high_cpu && sustained && compute && execution_fanout &&
             result.score >= 60) {
    result.verdict = MinerVerdict::kSuspicious;
  } else if (result.score >= 20) {
    result.verdict = MinerVerdict::kObserve;
  }
  return result;
}

void MergeMinerSignals(const MinerRuntimeSignals& incoming,
                       MinerRuntimeSignals* accumulated) {
  if (!accumulated) {
    return;
  }
  if (incoming.cpu_sampled) {
    accumulated->cpu_sampled = true;
    accumulated->cpu_percent = incoming.cpu_percent;
    accumulated->sustained_high_cpu_samples =
        incoming.sustained_high_cpu_samples;
  }
  accumulated->background = accumulated->background || incoming.background;
  accumulated->worker = accumulated->worker || incoming.worker;
  accumulated->wasm = accumulated->wasm || incoming.wasm;
  accumulated->webgpu = accumulated->webgpu || incoming.webgpu;
  accumulated->shared_memory =
      accumulated->shared_memory || incoming.shared_memory;
  accumulated->websocket = accumulated->websocket || incoming.websocket;
  accumulated->mining_endpoint =
      accumulated->mining_endpoint || incoming.mining_endpoint;
}

void AddMinerSignalsToWindow(const MinerRuntimeSignals& incoming,
                             base::TimeTicks now,
                             base::TimeDelta duration,
                             MinerSignalWindow* window) {
  if (!window) {
    return;
  }
  if (IsExpired(window->cpu_at, now, duration)) {
    window->signals.cpu_sampled = false;
    window->signals.cpu_percent = 0;
    window->signals.sustained_high_cpu_samples = 0;
    window->cpu_at = base::TimeTicks();
  }
  ExpireSignal(&window->signals.background, &window->background_at, now,
               duration);
  ExpireSignal(&window->signals.worker, &window->worker_at, now, duration);
  ExpireSignal(&window->signals.wasm, &window->wasm_at, now, duration);
  ExpireSignal(&window->signals.webgpu, &window->webgpu_at, now, duration);
  ExpireSignal(&window->signals.shared_memory, &window->shared_memory_at, now,
               duration);
  ExpireSignal(&window->signals.websocket, &window->websocket_at, now,
               duration);
  ExpireSignal(&window->signals.mining_endpoint, &window->mining_endpoint_at,
               now, duration);

  if (incoming.cpu_sampled) {
    window->signals.cpu_sampled = true;
    window->signals.cpu_percent = incoming.cpu_percent;
    window->signals.sustained_high_cpu_samples =
        incoming.sustained_high_cpu_samples;
    window->cpu_at = now;
  }
  ObserveSignal(incoming.background, &window->signals.background,
                &window->background_at, now);
  ObserveSignal(incoming.worker, &window->signals.worker, &window->worker_at,
                now);
  ObserveSignal(incoming.wasm, &window->signals.wasm, &window->wasm_at, now);
  ObserveSignal(incoming.webgpu, &window->signals.webgpu, &window->webgpu_at,
                now);
  ObserveSignal(incoming.shared_memory, &window->signals.shared_memory,
                &window->shared_memory_at, now);
  ObserveSignal(incoming.websocket, &window->signals.websocket,
                &window->websocket_at, now);
  ObserveSignal(incoming.mining_endpoint, &window->signals.mining_endpoint,
                &window->mining_endpoint_at, now);
}

bool ShouldSampleMinerCpu(const MinerRuntimeSignals& signals) {
  const bool compute = signals.wasm || signals.webgpu;
  return (signals.worker && compute) ||
         (signals.websocket && (signals.worker || compute));
}

std::optional<std::string> MiningEndpointIndicator(const GURL& url) {
  if (!url.is_valid() || (!url.SchemeIs("ws") && !url.SchemeIs("wss") &&
                          !url.SchemeIsHTTPOrHTTPS())) {
    return std::nullopt;
  }
  std::string storage;
  const std::vector<std::string_view> tokens = EndpointTokens(url, &storage);
  if (HasToken(tokens, "stratum")) {
    return "stratum_endpoint";
  }
  if (HasToken(tokens, "cryptonight")) {
    return "cryptonight_endpoint";
  }
  if (HasToken(tokens, "coinhive")) {
    return "coinhive_endpoint";
  }
  if (HasToken(tokens, "xmrig")) {
    return "xmrig_endpoint";
  }
  if (HasToken(tokens, "webmine") || HasToken(tokens, "webminer")) {
    return "web_mining_endpoint";
  }
  return std::nullopt;
}

}  // namespace aegis
