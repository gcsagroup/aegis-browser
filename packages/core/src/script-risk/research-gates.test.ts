import { describe, expect, it } from "vitest";
import {
  evaluateScriptRiskResearchGate,
  type ScriptRiskResearchGateEvidence,
} from "./research-gates.js";

function completeEvidence(): ScriptRiskResearchGateEvidence {
  return {
    corpus: {
      manifestSha256: "a".repeat(64),
      provenanceRecordsComplete: true,
      licenseReviewComplete: true,
      independentLabelReview: true,
      independentReviewerCount: 3,
      splitLeakageChecked: true,
      syntheticOnly: false,
      realWorldBenignSamples: 20_000,
      realWorldMaliciousSamples: 2_000,
    },
    sealedTest: {
      sealVerified: true,
      finalOpened: true,
      candidateFrozenBeforeOpen: true,
      usedForTuning: false,
      sampleCount: 4_000,
    },
    metrics: {
      sampleCount: 4_000,
      obfuscatedSampleCount: 500,
      precision: 0.995,
      recall: 0.97,
      falsePositiveRate: 0.0005,
      obfuscatedRecall: 0.93,
    },
    performance: {
      sampleCount: 20_000,
      p95OverheadPercent: 3.2,
    },
    breakage: {
      testedSites: 1_000,
      majorBreakages: 2,
    },
    v8Shadow: {
      observedFunctions: 200_000,
      distinctSites: 1_000,
      crashes: 0,
      wouldBlockCount: 0,
    },
    safety: {
      failOpenVerified: true,
      killSwitchVerified: true,
      rollbackVerified: true,
    },
    privacy: {
      auditComplete: true,
      sourceFreeTelemetryVerified: true,
      boundedRetentionVerified: true,
    },
    optionalComponents: {
      localModel: {
        status: "advisory-only",
        receivesRawSource: false,
        canChangeDecision: false,
      },
      federated: {
        status: "simulation-only",
        retainsRawClientUpdates: false,
        retainsClientIdentifiers: false,
        usedForEnforcement: false,
      },
    },
  };
}

describe("script-risk research gate", () => {
  it("keeps incomplete evidence observe-only", () => {
    const report = evaluateScriptRiskResearchGate({
      optionalComponents: {} as ScriptRiskResearchGateEvidence["optionalComponents"],
    });
    expect(report).toMatchObject({
      currentMode: "observe-only",
      eligibility: "observe-only",
      wouldBlock: false,
      claimsComplete: false,
      authorizationEligible: false,
      limitedBlockingEligible: false,
    });
    expect(report.failedChecks).toContain("sealed.final-opened");
    expect(report.failedChecks).toContain("privacy.audit-complete");
    expect(report.checks.every((check) => check.observed !== undefined)).toBe(true);
  });

  it("rejects a synthetic-only corpus even when all other fields pass", () => {
    const evidence = completeEvidence();
    evidence.corpus = {
      ...evidence.corpus!,
      syntheticOnly: true,
      realWorldBenignSamples: 0,
      realWorldMaliciousSamples: 0,
    };
    const report = evaluateScriptRiskResearchGate(evidence);
    expect(report.eligibility).toBe("observe-only");
    expect(report.failedChecks).toEqual(
      expect.arrayContaining([
        "corpus.not-synthetic-only",
        "corpus.real-world-benign-samples",
        "corpus.real-world-malicious-samples",
      ]),
    );
  });

  it("reports complete claims without granting eligibility", () => {
    const report = evaluateScriptRiskResearchGate(completeEvidence());
    expect(report).toMatchObject({
      trustLevel: "unverified-claims",
      currentMode: "observe-only",
      eligibility: "observe-only",
      wouldBlock: false,
      claimsComplete: true,
      authorizationEligible: false,
      limitedBlockingEligible: false,
      failedChecks: [],
    });
    expect(report.checks.every((check) => check.status === "pass")).toBe(true);
    expect(report.thresholds.minPrecision).toBe(0.99);
  });

  it("fails closed to observe-only for non-finite evidence", () => {
    const evidence = completeEvidence();
    evidence.metrics!.precision = Number.NaN;
    evidence.performance!.p95OverheadPercent = Number.POSITIVE_INFINITY;
    const report = evaluateScriptRiskResearchGate(evidence);
    expect(report.eligibility).toBe("observe-only");
    expect(report.failedChecks).toEqual(
      expect.arrayContaining([
        "metrics.precision",
        "performance.p95-overhead-percent",
      ]),
    );
    expect(report.checks.find((check) => check.id === "metrics.precision")?.observed).toBeNull();
  });

  it("rejects non-finite or weakened threshold overrides", () => {
    expect(() =>
      evaluateScriptRiskResearchGate(completeEvidence(), {
        minPrecision: Number.NaN,
      }),
    ).toThrow(/minPrecision/);
    expect(() =>
      evaluateScriptRiskResearchGate(completeEvidence(), {
        maxFalsePositiveRate: 0.01,
      }),
    ).toThrow(/maxFalsePositiveRate/);
  });

  it("rejects any V8 shadow blocking observation", () => {
    const evidence = completeEvidence();
    evidence.v8Shadow!.wouldBlockCount = 1;
    const report = evaluateScriptRiskResearchGate(evidence);
    expect(report).toMatchObject({
      eligibility: "observe-only",
      wouldBlock: false,
      limitedBlockingEligible: false,
    });
    expect(report.failedChecks).toContain("v8.would-block-zero");
  });
});
