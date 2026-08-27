import { describe, expect, it } from "vitest";
import {
  SCRIPT_RISK_FEDERATED_FEATURES,
  predictFederatedScriptRisk,
  simulatePrivateFederatedScriptRiskTraining,
  vectorizeScriptRiskForFederatedTraining,
  type FederatedScriptRiskClient,
} from "./federated-simulation.js";
import type { ScriptRiskAssessment } from "./types.js";

function vector(value: number): number[] {
  return [value, 1 - value, value * 0.5];
}

function clients(): FederatedScriptRiskClient[] {
  return [0.05, 0.15, 0.75, 0.9].map((value, index) => ({
    clientId: `private-device-${index}`,
    examples: [
      { features: vector(value), label: value > 0.5 ? 1 : 0 },
      { features: vector(Math.min(1, value + 0.02)), label: value > 0.5 ? 1 : 0 },
    ],
  }));
}

describe("private federated script-risk simulation", () => {
  it("vectorizes only stable categorical assessment evidence", () => {
    const assessment: ScriptRiskAssessment = {
      schemaVersion: 1,
      mode: "observe-only",
      status: "active",
      site: "secret.example.test",
      decision: "high-confidence",
      wouldBlock: false,
      riskScore: 92,
      reasons: [{ code: "runtime.sustained-cpu", occurrences: 8 }],
      findings: [
        {
          kind: "suspected-mining",
          confidence: "high",
          score: 90,
          reasonCodes: ["runtime.sustained-cpu"],
        },
      ],
      graph: { nodes: [], edges: [] },
    };
    const result = vectorizeScriptRiskForFederatedTraining(assessment);
    expect(result).toHaveLength(SCRIPT_RISK_FEDERATED_FEATURES.length);
    expect(result.every((value) => value >= -1 && value <= 1)).toBe(true);
    expect(JSON.stringify(result)).not.toContain("secret.example.test");
  });

  it("is deterministic, finite, clipped, and never retains client IDs", () => {
    const options = {
      rounds: 4,
      localEpochs: 2,
      simulationSeed: 12345,
      privacy: { epsilon: 50, delta: 1e-5, clipNorm: 0.2 },
    } as const;
    const first = simulatePrivateFederatedScriptRiskTraining(clients(), options);
    const second = simulatePrivateFederatedScriptRiskTraining(clients(), options);
    expect(first).toEqual(second);
    expect(first.model.weights.every(Number.isFinite)).toBe(true);
    expect(Number.isFinite(first.model.bias)).toBe(true);
    expect(
      first.rounds.every(
        (round) =>
          Number.isFinite(round.meanClientLoss) &&
          Number.isFinite(round.gaussianNoiseStddev) &&
          Number.isFinite(round.maskCancellationResidual),
      ),
    ).toBe(true);
    expect(first.rounds.every((round) => round.maskCancellationResidual < 1e-12)).toBe(true);
    expect(first).toMatchObject({
      mode: "local-federated-simulation",
      secureAggregation: "pairwise-mask-simulation",
      rawClientUpdatesRetained: false,
      clientIdentifiersRetained: false,
      deploymentEligible: false,
    });
    expect(JSON.stringify(first)).not.toContain("private-device");
    const probability = predictFederatedScriptRisk(first.model, vector(0.8));
    expect(probability).toBeGreaterThanOrEqual(0);
    expect(probability).toBeLessThanOrEqual(1);
  });

  it("bounds a poisoning client with participant clipping", () => {
    const poisoned = clients();
    poisoned.push({
      clientId: "poison",
      examples: [{ features: [1e12, -1e12, 1e12], label: 0 }],
    });
    const report = simulatePrivateFederatedScriptRiskTraining(poisoned, {
      rounds: 2,
      learningRate: 10,
      privacy: { epsilon: 100, delta: 1e-5, clipNorm: 0.01 },
    });
    expect(report.rounds.some((round) => round.clippedUpdates > 0)).toBe(true);
    expect(report.model.weights.every(Number.isFinite)).toBe(true);
  });

  it("rejects dimensional mismatches and single-client simulations", () => {
    expect(() =>
      simulatePrivateFederatedScriptRiskTraining(
        [{ clientId: "only", examples: [{ features: [0], label: 0 }] }],
        { privacy: { epsilon: 1, delta: 1e-5, clipNorm: 1 } },
      ),
    ).toThrow(/between 2/);
    const invalid = clients();
    invalid[0] = {
      clientId: "broken",
      examples: [{ features: [0, 1], label: 0 }],
    };
    expect(() =>
      simulatePrivateFederatedScriptRiskTraining(invalid, {
        privacy: { epsilon: 1, delta: 1e-5, clipNorm: 1 },
      }),
    ).toThrow(/features/);
  });

  it("rejects privacy parameters that underflow per-round delta", () => {
    expect(() =>
      simulatePrivateFederatedScriptRiskTraining(clients(), {
        rounds: 100,
        privacy: {
          epsilon: 1,
          delta: Number.MIN_VALUE,
          clipNorm: 1,
        },
      }),
    ).toThrow(/per-round privacy parameters/);
  });

  it("rejects non-finite model state before prediction", () => {
    expect(() =>
      predictFederatedScriptRisk(
        {
          schemaVersion: 1,
          kind: "script-risk-logistic-regression",
          featureCount: 1,
          weights: [Number.POSITIVE_INFINITY],
          bias: 0,
        },
        [1],
      ),
    ).toThrow(/model weights/);
  });
});
