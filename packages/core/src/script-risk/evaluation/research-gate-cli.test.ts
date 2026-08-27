// @ts-nocheck -- Node ESM CLI utility is tested directly without browser bundling.
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import { evaluateScriptRiskResearchGate } from "../research-gates.js";
import {
  evaluateAndWrite,
  parseArguments,
  readEvidence,
  resolveReportPath,
  validateEvidence,
} from "../../../scripts/evaluate-script-risk-gates.mjs";

function workspace() {
  const root = mkdtempSync(join(tmpdir(), "gcsa-gate-cli-"));
  mkdirSync(join(root, ".artifacts"));
  return root;
}

describe("script-risk research gate CLI", () => {
  it("accepts partial evidence so the evaluator can fail closed", () => {
    const evidence = validateEvidence({
      corpus: { syntheticOnly: true, realWorldBenignSamples: 0 },
    });
    const report = evaluateScriptRiskResearchGate(evidence);
    expect(report).toMatchObject({
      eligibility: "observe-only",
      limitedBlockingEligible: false,
      wouldBlock: false,
    });
  });

  it("rejects unknown fields, illegal types, enums, and non-finite numbers", () => {
    expect(() => validateEvidence({ thresholds: {} })).toThrow(/unknown/);
    expect(() =>
      validateEvidence({ corpus: { syntheticOnly: "false" } }),
    ).toThrow(/boolean/);
    expect(() =>
      validateEvidence({ optionalComponents: { localModel: { status: "remote" } } }),
    ).toThrow(/unsupported/);
    expect(() =>
      validateEvidence({ metrics: { precision: Number.POSITIVE_INFINITY } }),
    ).toThrow(/finite/);
  });

  it("rejects duplicate and threshold-like CLI arguments", () => {
    expect(() => parseArguments(["--evidence", "a", "--evidence", "b"])).toThrow(
      /only once/,
    );
    expect(() => parseArguments(["--min-precision", "0"])).toThrow(/unknown/);
  });

  it("parses only the exact evidence bytes bound by the expected SHA-256", () => {
    const root = workspace();
    const evidencePath = join(root, "evidence.json");
    const bytes = Buffer.from('{"corpus":{"syntheticOnly":true}}\n');
    writeFileSync(evidencePath, bytes);
    const sha256 = createHash("sha256").update(bytes).digest("hex");
    expect(readEvidence(evidencePath, sha256)).toEqual({
      evidence: { corpus: { syntheticOnly: true } },
      sha256,
    });
    expect(() => readEvidence(evidencePath, "0".repeat(64))).toThrow(/does not match/);
  });

  it("keeps reports inside the explicit .artifacts output root", () => {
    const root = workspace();
    const outputRoot = join(root, ".artifacts", "research");
    expect(
      resolveReportPath({
        workspaceDirectory: root,
        outputRoot,
        reportOutput: "gate.json",
      }).absoluteReport,
    ).toBe(join(realpathSync(root), ".artifacts", "research", "gate.json"));
    expect(() =>
      resolveReportPath({
        workspaceDirectory: root,
        outputRoot: join(root, "packages", "core"),
        reportOutput: "gate.json",
      }),
    ).toThrow(/workspace \.artifacts/);
    expect(() =>
      resolveReportPath({
        workspaceDirectory: root,
        outputRoot,
        reportOutput: "../gate.json",
      }),
    ).toThrow(/below --output-root/);
  });

  it("rejects symlink escapes and existing reports", () => {
    const root = workspace();
    const outside = mkdtempSync(join(tmpdir(), "gcsa-gate-outside-"));
    symlinkSync(outside, join(root, ".artifacts", "linked"));
    expect(() =>
      resolveReportPath({
        workspaceDirectory: root,
        outputRoot: join(root, ".artifacts", "linked"),
        reportOutput: "gate.json",
      }),
    ).toThrow(/symlinks/);

    const outputRoot = join(root, ".artifacts", "research");
    mkdirSync(outputRoot);
    writeFileSync(join(outputRoot, "gate.json"), "existing");
    expect(() =>
      resolveReportPath({
        workspaceDirectory: root,
        outputRoot,
        reportOutput: "gate.json",
      }),
    ).toThrow(/overwrite/);
  });

  it("writes a deterministic untrusted-claims report once and returns exit code 2", () => {
    const root = workspace();
    const reportPath = resolve(root, ".artifacts/research/gate.json");
    const first = evaluateAndWrite({
      evidence: {},
      evidenceSha256: "0".repeat(64),
      evaluator: evaluateScriptRiskResearchGate,
      reportPath,
    });
    expect(first.exitCode).toBe(2);
    expect(first.report).toMatchObject({
      trustLevel: "unverified-claims",
      authorizationEligible: false,
      enforcementAuthorized: false,
      currentMode: "observe-only",
      wouldBlock: false,
      claimsComplete: false,
    });
    expect(JSON.parse(readFileSync(reportPath, "utf8"))).toEqual(first.report);
    expect(() =>
      evaluateAndWrite({
        evidence: {},
        evidenceSha256: "0".repeat(64),
        evaluator: evaluateScriptRiskResearchGate,
        reportPath,
      }),
    ).toThrow();
  });

  it("never grants authorization even when self-reported claims pass", () => {
    const root = workspace();
    const reportPath = resolve(root, ".artifacts/research/passing-claims.json");
    const result = evaluateAndWrite({
      evidence: completeClaims(),
      evidenceSha256: "a".repeat(64),
      evaluator: evaluateScriptRiskResearchGate,
      reportPath,
    });
    expect(result.exitCode).toBe(0);
    expect(result.report).toMatchObject({
      claimsComplete: true,
      trustLevel: "unverified-claims",
      authorizationEligible: false,
      enforcementAuthorized: false,
      wouldBlock: false,
    });
  });
});

function completeClaims() {
  return {
    corpus: {
      manifestSha256: "a".repeat(64),
      provenanceRecordsComplete: true,
      licenseReviewComplete: true,
      independentLabelReview: true,
      independentReviewerCount: 2,
      splitLeakageChecked: true,
      syntheticOnly: false,
      realWorldBenignSamples: 10_000,
      realWorldMaliciousSamples: 1_000,
    },
    sealedTest: {
      sealVerified: true,
      finalOpened: true,
      candidateFrozenBeforeOpen: true,
      usedForTuning: false,
      sampleCount: 2_000,
    },
    metrics: {
      sampleCount: 2_000,
      obfuscatedSampleCount: 200,
      precision: 0.99,
      recall: 0.95,
      falsePositiveRate: 0.001,
      obfuscatedRecall: 0.9,
    },
    performance: { sampleCount: 10_000, p95OverheadPercent: 5 },
    breakage: { testedSites: 500, majorBreakages: 0 },
    v8Shadow: {
      observedFunctions: 100_000,
      distinctSites: 500,
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
