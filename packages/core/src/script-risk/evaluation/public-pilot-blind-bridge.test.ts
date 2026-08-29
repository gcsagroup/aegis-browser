// @ts-nocheck -- research-only Node ESM CLI integration test.
import { execFileSync, spawnSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import { buildPublicPilotPlan, sha256Hex } from "./public-pilot-acquisition.mjs";

const evaluationDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(evaluationDirectory, "../../../../..");
const scripts = {
  freeze: resolve(repositoryRoot, "packages/core/scripts/freeze-script-risk-candidate.mjs"),
  bridge: resolve(repositoryRoot, "packages/core/scripts/bridge-script-risk-public-pilot.mjs"),
  predict: resolve(repositoryRoot, "packages/core/scripts/predict-script-risk-blind.mjs"),
  score: resolve(repositoryRoot, "packages/core/scripts/score-script-risk-blind.mjs"),
};
const temporaryRoots: string[] = [];

afterEach(() => {
  for (const root of temporaryRoots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

function writeJson(path: string, value: unknown) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function fixtureDefinition(files: Record<string, Buffer>) {
  const revision = "1".repeat(40);
  const descriptor = (remotePath: string) => ({
    remotePath,
    byteLength: files[remotePath].length,
    sha256: sha256Hex(files[remotePath]),
  });
  return {
    schemaVersion: 1,
    mode: "research-only",
    datasetId: "gcsa-public-bridge-fixture-v1",
    createdAt: "2026-08-28T00:00:00.000Z",
    task: {
      target: "browser-mining-capability",
      positiveLabel: "mining-capable",
      negativeLabel: "benign-control",
      publiclyInspectable: true,
      independentLabelReview: false,
      sealed: false,
      contextualMaliciousnessInferred: false,
    },
    acquisition: {
      transport: "https-pinned-github-raw",
      allowedHost: "raw.githubusercontent.com",
      sourceExecution: false,
      maxFileBytes: 2_000_000,
      maxTotalBytes: 8_000_000,
      localOnly: true,
      redistributeWithProduct: false,
    },
    sources: {
      fixture: {
        name: "Fixture",
        repository: "owner/repository",
        revision,
        retrievedAt: "2026-08-28T00:00:00.000Z",
        purposeEvidenceUrl: `https://github.com/owner/repository/tree/${revision}`,
        license: {
          spdx: "MIT",
          url: `https://github.com/owner/repository/blob/${revision}/LICENSE`,
        },
      },
    },
    samples: [
      {
        sampleId: "benign-one",
        sourceRef: "fixture",
        familyGroup: "benign-one",
        label: "benign-control",
        category: "plain-control",
        obfuscationTier: "none",
        files: [descriptor("one.js")],
      },
      {
        sampleId: "benign-two",
        sourceRef: "fixture",
        familyGroup: "benign-two",
        label: "benign-control",
        category: "websocket-control",
        obfuscationTier: "none",
        files: [descriptor("two.js")],
      },
      {
        sampleId: "miner-one",
        sourceRef: "fixture",
        familyGroup: "miner-one",
        label: "mining-capable",
        category: "multi-file-mining-capability",
        obfuscationTier: "none",
        files: [descriptor("compute.js"), descriptor("network.js")],
      },
    ],
  };
}

function createFixture() {
  const root = mkdtempSync(resolve(tmpdir(), "gcsa-public-blind-bridge-"));
  temporaryRoots.push(root);
  const repo = resolve(root, "repo");
  const sourceRoot = resolve(root, "sources");
  const files = {
    "one.js": Buffer.from("export const value = 1;\n"),
    "two.js": Buffer.from('new WebSocket("wss://control.invalid");\n'),
    "compute.js": Buffer.from("WebAssembly.instantiate(bytes);\n"),
    "network.js": Buffer.from(
      'const socket = new WebSocket("wss://capable.invalid"); socket.send("mining.subscribe");\n',
    ),
  };
  const definition = fixtureDefinition(files);
  const definitionPath = resolve(
    repo,
    "packages/core/src/script-risk/evaluation/protocols/miner-capability-public-v1.json",
  );
  mkdirSync(resolve(repo, "packages/core/dist/script-risk"), { recursive: true });
  mkdirSync(dirname(definitionPath), { recursive: true });
  mkdirSync(resolve(repo, "node_modules/typescript"), { recursive: true });
  writeJson(resolve(repo, "packages/core/package.json"), { name: "bridge-fixture", private: true });
  writeJson(resolve(repo, "node_modules/typescript/package.json"), {
    name: "typescript",
    version: "5.9.3-fixture",
  });
  writeFileSync(resolve(repo, "pnpm-lock.yaml"), "lockfileVersion: '9.0'\n", "utf8");
  cpSync(
    resolve(evaluationDirectory, "protocols/blind-v1.json"),
    resolve(repo, "packages/core/src/script-risk/evaluation/protocols/blind-v1.json"),
  );
  cpSync(
    resolve(evaluationDirectory, "confidence-bounds.mjs"),
    resolve(repo, "packages/core/src/script-risk/evaluation/confidence-bounds.mjs"),
  );
  writeJson(definitionPath, definition);
  writeFileSync(
    resolve(repo, "packages/core/dist/script-risk/ast-analyzer.cjs"),
    `"use strict";
exports.analyzeScriptAst = function analyzeScriptAst(sourceText) {
  const signals = [];
  const add = (code, pattern) => { if (pattern.test(sourceText)) signals.push({ code, occurrences: 1 }); };
  add("ast.wasm-use", /WebAssembly/);
  add("ast.websocket", /WebSocket/);
  add("ast.mining-protocol", /mining\\.subscribe/);
  return { schemaVersion: 1, analyzer: "typescript-ast", parserVersion: "fixture",
    parseStatus: "complete", sourceLength: sourceText.length, analyzedLength: sourceText.length,
    truncated: false, nodeCount: 1, maxDepth: 1, branchCount: 0, signals };
};
`,
    "utf8",
  );
  writeFileSync(
    resolve(repo, "packages/core/src/script-risk/evaluation/corpus-eval.mjs"),
    `export function classifyStaticAnalysis(analysis) {
  const codes = new Set(analysis.signals.map((signal) => signal.code));
  const positive = codes.has("ast.wasm-use") && codes.has("ast.websocket") && codes.has("ast.mining-protocol");
  return { predicted: positive ? "malicious" : "benign", score: positive ? 70 : 0,
    finding: positive ? "suspected-mining" : null, reasonCodes: [...codes].sort() };
}
`,
    "utf8",
  );
  for (const [remotePath, bytes] of Object.entries(files)) {
    const localPath = resolve(sourceRoot, "fixture", remotePath);
    mkdirSync(dirname(localPath), { recursive: true });
    writeFileSync(localPath, bytes, { mode: 0o600 });
  }
  const plan = buildPublicPilotPlan(definition);
  const receipt = {
    schemaVersion: 1,
    mode: "research-only",
    releaseEligible: false,
    finalEvaluationEligible: false,
    enforcementAuthorized: false,
    datasetId: plan.datasetId,
    acquisitionMode: "offline-verify",
    acquiredAt: "2026-08-28T00:01:00.000Z",
    definitionSha256: plan.definitionSha256,
    planSha256: plan.planSha256,
    sampleCount: plan.sampleCount,
    sourceCount: plan.sourceCount,
    fileCount: plan.fileCount,
    totalBytes: plan.totalBytes,
    labels: plan.labels,
    dataHandling: {
      sourceExecution: false,
      localOnly: true,
      redistributedWithProduct: false,
      publiclyInspectable: true,
      independentLabelReview: false,
      contextualMaliciousnessInferred: false,
    },
    files: plan.files.map(({ localPath, byteLength, sha256 }) => ({
      localPath,
      byteLength,
      sha256,
    })),
  };
  const receiptPath = resolve(root, "receipt.json");
  writeJson(receiptPath, receipt);
  execFileSync("git", ["init", "--quiet"], { cwd: repo });
  execFileSync("git", ["config", "user.name", "GCSA Test"], { cwd: repo });
  execFileSync("git", ["config", "user.email", "test@gcsa.invalid"], { cwd: repo });
  execFileSync("git", ["add", "."], { cwd: repo });
  execFileSync(
    "git",
    ["-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture"],
    { cwd: repo },
  );
  return { root, repo, sourceRoot, receiptPath, receipt };
}

describe("public pilot to blind-v1 bridge", () => {
  it("prepares an unlabelled pseudonymous envelope and reveals labels only after prediction", () => {
    const fixture = createFixture();
    const candidatePath = resolve(fixture.root, "candidate.json");
    const inputPath = resolve(fixture.root, "unlabelled.json");
    const predictionsPath = resolve(fixture.root, "predictions.json");
    const labelsPath = resolve(fixture.root, "labels.json");
    const reportPath = resolve(fixture.root, "score.json");
    execFileSync(process.execPath, [
      scripts.freeze,
      "--repo-root", fixture.repo,
      "--candidate-id", "public-bridge-candidate-v1",
      "--output", candidatePath,
    ]);
    const candidate = JSON.parse(readFileSync(candidatePath, "utf8"));
    execFileSync(process.execPath, [
      scripts.bridge, "prepare",
      "--repo-root", fixture.repo,
      "--candidate", candidatePath,
      "--receipt", fixture.receiptPath,
      "--source-root", fixture.sourceRoot,
      "--envelope-id", "public-bridge-envelope-v1",
      "--output", inputPath,
    ]);
    const inputText = readFileSync(inputPath, "utf8");
    const input = JSON.parse(inputText);
    expect(input).toMatchObject({
      labelAccess: "unavailable-to-predictor",
      labelsIncluded: false,
      publicPilot: {
        datasetId: "gcsa-public-bridge-fixture-v1",
        publiclyInspectable: true,
        independentLabelReview: false,
        sealed: false,
      },
    });
    expect(input.samples).toHaveLength(3);
    expect(input.samples.every((sample) => /^public-[a-f0-9]{32}$/.test(sample.sampleId))).toBe(true);
    expect(
      input.samples.every((sample) =>
        sample.files.every((file) => /^file-\d{4}\.(?:js|mjs|cjs|ts)$/.test(file.path)),
      ),
    ).toBe(true);
    expect(inputText).not.toContain("benign-control");
    expect(inputText).not.toContain("mining-capable");
    expect(inputText).not.toContain("benign-one");
    expect(inputText).not.toContain("miner-one");
    expect(inputText).not.toContain("fixture/");
    for (const sourcePath of ["one.js", "two.js", "compute.js", "network.js"]) {
      expect(inputText).not.toContain(`\"path\": \"${sourcePath}\"`);
    }

    execFileSync(process.execPath, [
      scripts.predict,
      "--repo-root", fixture.repo,
      "--candidate", candidatePath,
      "--input", inputPath,
      "--output", predictionsPath,
    ]);
    const predictions = JSON.parse(readFileSync(predictionsPath, "utf8"));
    expect(predictions.publicPilot).toEqual(input.publicPilot);
    expect(predictions.rows.filter((row) => row.predictedLabel === "mining-capable")).toHaveLength(1);
    expect(predictions.rows.filter((row) => row.predictedLabel === "benign-control")).toHaveLength(2);

    execFileSync(process.execPath, [
      scripts.bridge, "reveal",
      "--repo-root", fixture.repo,
      "--candidate", candidatePath,
      "--receipt", fixture.receiptPath,
      "--source-root", fixture.sourceRoot,
      "--input", inputPath,
      "--predictions", predictionsPath,
      "--output", labelsPath,
    ]);
    const labels = JSON.parse(readFileSync(labelsPath, "utf8"));
    expect(labels.predictionDigestSha256).toBe(predictions.predictionDigestSha256);
    expect(labels.publicPilot).toEqual(input.publicPilot);
    expect(labels.labels.filter((item) => item.actualLabel === "mining-capable")).toHaveLength(1);
    expect(labels.labels.filter((item) => item.actualLabel === "benign-control")).toHaveLength(2);

    execFileSync(process.execPath, [
      scripts.score,
      "--repo-root", fixture.repo,
      "--candidate", candidatePath,
      "--input", inputPath,
      "--predictions", predictionsPath,
      "--labels", labelsPath,
      "--output", reportPath,
    ]);
    const report = JSON.parse(readFileSync(reportPath, "utf8"));
    expect(Date.parse(candidate.frozenAt)).toBeLessThanOrEqual(Date.parse(input.createdAt));
    expect(Date.parse(input.createdAt)).toBeLessThanOrEqual(Date.parse(predictions.predictedAt));
    expect(Date.parse(predictions.predictedAt)).toBeLessThanOrEqual(Date.parse(labels.createdAt));
    expect(Date.parse(labels.createdAt)).toBeLessThanOrEqual(Date.parse(report.scoredAt));
    expect(report).toMatchObject({
      evaluationClass: "operator-blinded-local",
      independentSealVerified: false,
      finalEvaluationEligible: false,
      releaseEligible: false,
      publicPilot: input.publicPilot,
      metrics: {
        overall: { sampleCount: 3, precision: 1, recall: 1, falsePositiveRate: 0 },
        confidenceBounds: {
          confidenceLevel: 0.95,
          recall: { successes: 1, trials: 1 },
          falsePositiveRate: { successes: 0, trials: 2 },
        },
      },
    });
    expect(report.metrics.confidenceBounds.recall.lowerBound).toBeCloseTo(0.05, 14);
    expect(report.metrics.confidenceBounds.falsePositiveRate.upperBound).toBeCloseTo(
      0.776393202250021,
      14,
    );

    const tamperedReceiptPath = resolve(fixture.root, "tampered-receipt.json");
    const tamperedReceipt = structuredClone(fixture.receipt);
    tamperedReceipt.planSha256 = "0".repeat(64);
    writeJson(tamperedReceiptPath, tamperedReceipt);
    const tamperedOutputPath = resolve(fixture.root, "tampered-input.json");
    const rejectedReceipt = spawnSync(process.execPath, [
      scripts.bridge, "prepare",
      "--repo-root", fixture.repo,
      "--candidate", candidatePath,
      "--receipt", tamperedReceiptPath,
      "--source-root", fixture.sourceRoot,
      "--envelope-id", "tampered-envelope-v1",
      "--output", tamperedOutputPath,
    ], { encoding: "utf8" });
    expect(rejectedReceipt.status).toBe(1);
    expect(rejectedReceipt.stderr).toContain("receipt.planSha256");
    expect(existsSync(tamperedOutputPath)).toBe(false);

    writeFileSync(resolve(fixture.sourceRoot, "fixture/one.js"), "changed\n", "utf8");
    const changedLabelsPath = resolve(fixture.root, "changed-labels.json");
    const rejectedBytes = spawnSync(process.execPath, [
      scripts.bridge, "reveal",
      "--repo-root", fixture.repo,
      "--candidate", candidatePath,
      "--receipt", fixture.receiptPath,
      "--source-root", fixture.sourceRoot,
      "--input", inputPath,
      "--predictions", predictionsPath,
      "--output", changedLabelsPath,
    ], { encoding: "utf8" });
    expect(rejectedBytes.status).toBe(1);
    expect(rejectedBytes.stderr).toContain("byte length mismatch");
    expect(existsSync(changedLabelsPath)).toBe(false);
  }, 30_000);

  it("keeps --final closed in both bridge modes", () => {
    for (const mode of ["prepare", "reveal"]) {
      const result = spawnSync(process.execPath, [scripts.bridge, "--", mode, "--final"], {
        encoding: "utf8",
      });
      expect(result.status).toBe(1);
      expect(result.stderr).toContain("--final 不可用");
    }
  });
});
