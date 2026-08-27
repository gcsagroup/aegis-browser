// @ts-nocheck -- research-only Node ESM utility intentionally stays out of browser bundles.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { analyzeScriptAst } from "../ast-analyzer.js";
import {
  authorizeEvaluationAccess,
  buildCorpusManifest,
  buildCorpusManifestFromFile,
  classifyStaticAnalysis,
  computeEvaluationMetrics,
  createEvaluationReport,
  createGroupedSplit,
  sha256Hex,
  verifyCorpusManifest,
  verifyGroupedSplit,
} from "./corpus-eval.mjs";

const definitionPath = fileURLToPath(new URL("./fixtures/corpus.json", import.meta.url));
const fixturesRoot = fileURLToPath(new URL("./fixtures", import.meta.url));
const definition = JSON.parse(readFileSync(definitionPath, "utf8"));

function corpus() {
  const manifest = buildCorpusManifestFromFile(definitionPath, fixturesRoot);
  const split = createGroupedSplit(manifest, {
    seed: definition.split.seed,
    ratios: definition.split.ratios,
  });
  return { manifest, split };
}

describe("script-risk research corpus manifest", () => {
  it("content-addresses every synthetic fixture and retains source, license, and label evidence", () => {
    const { manifest } = corpus();

    expect(manifest).toMatchObject({
      schemaVersion: 1,
      mode: "research-only",
      releaseEligible: false,
      contentAddressAlgorithm: "sha256",
      stats: {
        samples: 16,
        byLabel: { benign: 8, malicious: 8 },
        syntheticFixtures: 16,
        metadataOnly: 0,
      },
    });
    expect(verifyCorpusManifest(manifest)).toBe(true);
    for (const entry of manifest.entries) {
      const bytes = readFileSync(
        fileURLToPath(new URL(`./fixtures/${entry.artifact.fixturePath}`, import.meta.url)),
      );
      expect(entry.artifact.contentAddress).toBe(`sha256:${sha256Hex(bytes)}`);
      expect(entry.source.license).toMatchObject({
        spdx: "Apache-2.0",
        redistribution: "allowed",
      });
      expect(entry.label.evidence.kind).toBe("synthetic-spec");
      expect(JSON.stringify(entry)).not.toContain(bytes.toString("utf8"));
    }
  });

  it("rejects missing provenance and paths that escape the fixture root", () => {
    const missingLicense = structuredClone(definition);
    delete missingLicense.sourceCatalog["project-synthetic"].license;
    expect(() => buildCorpusManifest(missingLicense, fixturesRoot)).toThrow("license");

    const traversal = structuredClone(definition);
    traversal.samples[0].artifact.path = "../corpus-eval.mjs";
    expect(() => buildCorpusManifest(traversal, fixturesRoot)).toThrow(
      "must stay below fixtures root",
    );
  });

  it("detects manifest tampering", () => {
    const { manifest } = corpus();
    const tampered = structuredClone(manifest);
    tampered.entries[0].label.class = "malicious";
    expect(verifyCorpusManifest(tampered)).toBe(false);
  });
});

describe("grouped split and deterministic public holdout protocol", () => {
  it("keeps content, site, family, and time groups in one deterministic split", () => {
    const { manifest, split } = corpus();
    const again = createGroupedSplit(manifest, {
      seed: definition.split.seed,
      ratios: definition.split.ratios,
    });
    expect(again).toEqual(split);
    expect(verifyGroupedSplit(manifest, split)).toBe(true);
    expect(split.counts).toEqual({ train: 8, validation: 4, test: 4 });
    expect(split.publicHoldout).toMatchObject({
      classification: "deterministic-public-holdout",
      sampleCount: 4,
      publiclyInspectable: true,
      sealIsolationVerified: false,
      finalEvaluationEligible: false,
    });

    const assignmentById = new Map(
      split.assignments.map((assignment) => [assignment.sampleId, assignment.split]),
    );
    for (const dimension of ["artifact", "siteGroup", "familyGroup", "timeGroup"]) {
      const splitsByGroup = new Map<string, Set<string>>();
      for (const entry of manifest.entries) {
        const key = dimension === "artifact" ? entry.artifact.sha256 : entry[dimension];
        const retained = splitsByGroup.get(key) ?? new Set();
        retained.add(assignmentById.get(entry.sampleId));
        splitsByGroup.set(key, retained);
      }
      expect([...splitsByGroup.values()].every((splits) => splits.size === 1)).toBe(true);
    }
  });

  it("rejects a changed assignment even if the old integrity digest is retained", () => {
    const { manifest, split } = corpus();
    const tampered = structuredClone(split);
    tampered.assignments[0].split =
      tampered.assignments[0].split === "train" ? "validation" : "train";
    expect(verifyGroupedSplit(manifest, tampered)).toBe(false);
  });

  it("never upgrades the public holdout to a sealed final evaluation", () => {
    const { manifest, split } = corpus();
    expect(
      authorizeEvaluationAccess(manifest, split, { split: "validation" }),
    ).toMatchObject({
      evaluationClass: "development-split",
      publicHoldoutEvaluated: false,
      sealIsolationVerified: false,
      finalEvaluationEligible: false,
    });
    expect(authorizeEvaluationAccess(manifest, split, { split: "test" })).toMatchObject({
      evaluationClass: "deterministic-public-holdout",
      publicHoldoutEvaluated: true,
      sealIsolationVerified: false,
      finalEvaluationEligible: false,
    });
    expect(() =>
      authorizeEvaluationAccess(manifest, split, {
        split: "test",
        finalEvaluation: true,
      }),
    ).toThrow("--final is unavailable");
    expect(() =>
      authorizeEvaluationAccess(manifest, split, {
        split: "test",
        expectedSeal: split.publicHoldout.integrityDigestSha256,
      }),
    ).toThrow("does not accept a seal");
  });
});

describe("metrics and static research baseline", () => {
  it("reports precision, recall, FPR, obfuscation strata, and latency percentiles", () => {
    const metrics = computeEvaluationMetrics([
      {
        sampleId: "tp",
        actual: "malicious",
        predicted: "malicious",
        obfuscationTier: "none",
        durationMs: 1,
      },
      {
        sampleId: "tn",
        actual: "benign",
        predicted: "benign",
        obfuscationTier: "minified",
        durationMs: 2,
      },
      {
        sampleId: "fp",
        actual: "benign",
        predicted: "malicious",
        obfuscationTier: "identifier-renamed",
        durationMs: 3,
      },
      {
        sampleId: "fn",
        actual: "malicious",
        predicted: "benign",
        obfuscationTier: "string-encoded",
        durationMs: 100,
      },
    ]);

    expect(metrics.overall).toMatchObject({
      confusion: {
        truePositive: 1,
        trueNegative: 1,
        falsePositive: 1,
        falseNegative: 1,
      },
      precision: 0.5,
      recall: 0.5,
      falsePositiveRate: 0.5,
      accuracy: 0.5,
    });
    expect(metrics.performance).toMatchObject({ p50Ms: 2, p95Ms: 100, maxMs: 100 });
    expect(metrics.obfuscation.missingTiers).toEqual(["control-flow"]);
  });

  it("records known string-splitting evasions instead of hiding them", () => {
    const clearMining = readFileSync(
      new URL("./fixtures/source/malicious-miner-alpha-clear.js", import.meta.url),
      "utf8",
    );
    const encodedMining = readFileSync(
      new URL("./fixtures/source/malicious-miner-beta-encoded.js", import.meta.url),
      "utf8",
    );
    expect(classifyStaticAnalysis(analyzeScriptAst(clearMining)).predicted).toBe(
      "malicious",
    );
    expect(classifyStaticAnalysis(analyzeScriptAst(encodedMining))).toMatchObject({
      predicted: "benign",
      score: 0,
    });
  });

  it("emits an explicitly non-release validation report and requires full split coverage", () => {
    const { manifest, split } = corpus();
    const access = authorizeEvaluationAccess(manifest, split, { split: "validation" });
    const assignmentById = new Map(
      split.assignments.map((assignment) => [assignment.sampleId, assignment.split]),
    );
    const rows = manifest.entries
      .filter((entry) => assignmentById.get(entry.sampleId) === "validation")
      .map((entry) => ({
        sampleId: entry.sampleId,
        actual: entry.label.class,
        predicted: entry.label.class,
        score: entry.label.class === "malicious" ? 70 : 0,
        finding: null,
        reasonCodes: [],
        obfuscationTier: entry.obfuscation.tier,
        durationMs: 1,
      }));
    const input = {
      manifest,
      split,
      access,
      rows,
      detector: {
        id: "test-detector",
        contentAddress: `sha256:${"0".repeat(64)}`,
        decisionRule: "fixed test rule",
      },
      evaluatedAt: "2026-08-27T00:00:00.000Z",
    };
    const report = createEvaluationReport(input);
    expect(report).toMatchObject({
      mode: "research-only",
      releaseEligible: false,
      enforcementAuthorized: false,
      publicHoldout: {
        classification: "deterministic-public-holdout",
        evaluated: false,
        publiclyInspectable: true,
        sealIsolationVerified: false,
        finalEvaluationEligible: false,
      },
      dataHandling: {
        sourceExecution: false,
        networkAcquisition: false,
        liveMalwareDownloaded: false,
      },
    });
    expect(() => createEvaluationReport({ ...input, rows: rows.slice(1) })).toThrow(
      "do not match split",
    );
    const serialized = JSON.stringify(report);
    expect(serialized).not.toContain('"sealedTest"');
    expect(serialized).not.toContain('"sealSha256"');
    expect(serialized).not.toContain('"sealVerified":true');
    expect(serialized).not.toContain('"finalEvaluationEligible":true');
  });
});
