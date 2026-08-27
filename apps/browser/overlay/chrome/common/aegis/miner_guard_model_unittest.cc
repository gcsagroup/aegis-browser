// Copyright 2026 GCSA

#include "chrome/common/aegis/miner_guard_model.h"

#include <algorithm>

#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace aegis {
namespace {

TEST(MinerGuardModelTest, SingleSignalsNeverProduceMiningVerdict) {
  MinerRuntimeSignals cpu;
  cpu.cpu_sampled = true;
  cpu.cpu_percent = 95;
  cpu.sustained_high_cpu_samples = 8;
  EXPECT_NE(AssessMinerSignals(cpu).verdict, MinerVerdict::kLikelyMining);

  MinerRuntimeSignals wasm;
  wasm.wasm = true;
  EXPECT_NE(AssessMinerSignals(wasm).verdict, MinerVerdict::kLikelyMining);

  MinerRuntimeSignals worker;
  worker.worker = true;
  EXPECT_NE(AssessMinerSignals(worker).verdict, MinerVerdict::kLikelyMining);

  MinerRuntimeSignals socket;
  socket.websocket = true;
  EXPECT_NE(AssessMinerSignals(socket).verdict, MinerVerdict::kLikelyMining);
}

TEST(MinerGuardModelTest, BenignHighLoadCombinationsAreNotLikelyMining) {
  MinerRuntimeSignals codec;
  codec.cpu_sampled = true;
  codec.cpu_percent = 90;
  codec.sustained_high_cpu_samples = 6;
  codec.worker = true;
  codec.wasm = true;
  EXPECT_EQ(AssessMinerSignals(codec).verdict, MinerVerdict::kSuspicious);

  MinerRuntimeSignals game = codec;
  game.websocket = true;
  game.shared_memory = true;
  EXPECT_EQ(AssessMinerSignals(game).verdict, MinerVerdict::kSuspicious);

  MinerRuntimeSignals local_ai;
  local_ai.cpu_sampled = true;
  local_ai.cpu_percent = 90;
  local_ai.sustained_high_cpu_samples = 6;
  local_ai.worker = true;
  local_ai.webgpu = true;
  EXPECT_EQ(AssessMinerSignals(local_ai).verdict, MinerVerdict::kSuspicious);
}

TEST(MinerGuardModelTest, StrongEndpointAndSustainedBehaviorAreRequired) {
  MinerRuntimeSignals signals;
  signals.worker = true;
  signals.wasm = true;
  signals.websocket = true;
  signals.mining_endpoint = true;
  EXPECT_NE(AssessMinerSignals(signals).verdict, MinerVerdict::kLikelyMining);

  signals.cpu_sampled = true;
  signals.cpu_percent = 75;
  signals.sustained_high_cpu_samples = 3;
  const MinerAssessment result = AssessMinerSignals(signals);
  EXPECT_EQ(result.verdict, MinerVerdict::kLikelyMining);
  EXPECT_GE(result.score, 80);
  EXPECT_NE(std::ranges::find(result.reasons, "mining_endpoint"),
            result.reasons.end());
}

TEST(MinerGuardModelTest, JavaScriptWorkerWithStrongEndpointCanBeDetected) {
  MinerRuntimeSignals signals;
  signals.cpu_sampled = true;
  signals.cpu_percent = 80;
  signals.sustained_high_cpu_samples = 4;
  signals.worker = true;
  signals.websocket = true;
  signals.mining_endpoint = true;
  EXPECT_EQ(AssessMinerSignals(signals).verdict, MinerVerdict::kLikelyMining);
}

TEST(MinerGuardModelTest, EndpointMatchingIsBoundedAndPrivacySafe) {
  EXPECT_EQ(MiningEndpointIndicator(
                GURL("wss://compute.example.test/v1/stratum?wallet=secret")),
            "stratum_endpoint");
  EXPECT_EQ(MiningEndpointIndicator(
                GURL("https://cdn.example.test/assets/xmrig/module.wasm")),
            "xmrig_endpoint");
  EXPECT_FALSE(MiningEndpointIndicator(
      GURL("wss://chat.example.test/socket?room=miners")));
  EXPECT_FALSE(MiningEndpointIndicator(GURL("file:///tmp/stratum")));
}

TEST(MinerGuardModelTest, MergesPartialReportsWithoutResettingEvidence) {
  MinerRuntimeSignals accumulated;
  accumulated.worker = true;
  accumulated.wasm = true;

  MinerRuntimeSignals endpoint;
  endpoint.websocket = true;
  endpoint.mining_endpoint = true;
  MergeMinerSignals(endpoint, &accumulated);

  MinerRuntimeSignals cpu;
  cpu.cpu_sampled = true;
  cpu.cpu_percent = 82;
  cpu.sustained_high_cpu_samples = 3;
  MergeMinerSignals(cpu, &accumulated);

  EXPECT_TRUE(accumulated.worker);
  EXPECT_TRUE(accumulated.wasm);
  EXPECT_TRUE(accumulated.websocket);
  EXPECT_TRUE(accumulated.mining_endpoint);
  EXPECT_EQ(accumulated.cpu_percent, 82);
  EXPECT_EQ(AssessMinerSignals(accumulated).verdict,
            MinerVerdict::kLikelyMining);
}

TEST(MinerGuardModelTest, RollingWindowExpiresEachSignalIndependently) {
  const base::TimeTicks start = base::TimeTicks::Now();
  MinerSignalWindow window;

  MinerRuntimeSignals endpoint;
  endpoint.worker = true;
  endpoint.websocket = true;
  endpoint.mining_endpoint = true;
  AddMinerSignalsToWindow(endpoint, start, base::Seconds(30), &window);

  MinerRuntimeSignals keepalive;
  keepalive.wasm = true;
  AddMinerSignalsToWindow(keepalive, start + base::Seconds(29),
                          base::Seconds(30), &window);
  EXPECT_TRUE(window.signals.mining_endpoint);

  MinerRuntimeSignals cpu;
  cpu.cpu_sampled = true;
  cpu.cpu_percent = 90;
  cpu.sustained_high_cpu_samples = 4;
  AddMinerSignalsToWindow(cpu, start + base::Seconds(30), base::Seconds(30),
                          &window);
  EXPECT_FALSE(window.signals.mining_endpoint);
  EXPECT_FALSE(window.signals.worker);
  EXPECT_EQ(AssessMinerSignals(window.signals).verdict, MinerVerdict::kObserve);
}

TEST(MinerGuardModelTest, LateEndpointRemainsFreshForLaterCpuSamples) {
  const base::TimeTicks start = base::TimeTicks::Now();
  MinerSignalWindow window;
  MinerRuntimeSignals capability;
  capability.worker = true;
  AddMinerSignalsToWindow(capability, start, base::Seconds(30), &window);

  MinerRuntimeSignals endpoint;
  endpoint.websocket = true;
  endpoint.mining_endpoint = true;
  AddMinerSignalsToWindow(endpoint, start + base::Seconds(29),
                          base::Seconds(30), &window);

  MinerRuntimeSignals cpu;
  cpu.cpu_sampled = true;
  cpu.cpu_percent = 80;
  cpu.sustained_high_cpu_samples = 3;
  cpu.worker = true;
  AddMinerSignalsToWindow(cpu, start + base::Seconds(35), base::Seconds(30),
                          &window);
  EXPECT_EQ(AssessMinerSignals(window.signals).verdict,
            MinerVerdict::kLikelyMining);
}

TEST(MinerGuardModelTest, UnsampledCpuValuesCannotProduceMiningVerdict) {
  MinerRuntimeSignals signals;
  signals.cpu_percent = 99;
  signals.sustained_high_cpu_samples = 10;
  signals.worker = true;
  signals.websocket = true;
  signals.mining_endpoint = true;
  EXPECT_NE(AssessMinerSignals(signals).verdict, MinerVerdict::kLikelyMining);
}

TEST(MinerGuardModelTest, CpuSamplingRequiresAUsefulCapabilityCombination) {
  MinerRuntimeSignals signals;
  signals.websocket = true;
  EXPECT_FALSE(ShouldSampleMinerCpu(signals));
  signals.worker = true;
  EXPECT_TRUE(ShouldSampleMinerCpu(signals));

  signals = MinerRuntimeSignals();
  signals.worker = true;
  EXPECT_FALSE(ShouldSampleMinerCpu(signals));
  signals.wasm = true;
  EXPECT_TRUE(ShouldSampleMinerCpu(signals));
}

}  // namespace
}  // namespace aegis
