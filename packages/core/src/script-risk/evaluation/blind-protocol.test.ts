// @ts-nocheck -- research-only Node ESM utilities intentionally stay outside browser bundles.
import { execFileSync, spawn, spawnSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import {
  buildBlindEnvelope,
  buildLabelEnvelope,
  computeOneSidedConfidenceBounds,
  createBlindScoreReport,
  digestCanonical,
  importVerifiedCandidateModule,
  loadBlindProtocol,
  sha256Hex,
  validateBlindProtocol,
  validateLabelEnvelope,
  validatePredictionEnvelope,
  validatePredictionOutput,
  verifiedCandidateComponentBytes,
  verifyCandidateEnvironment,
} from "./blind-protocol.mjs";
import * as confidenceFunctions from "./confidence-bounds.mjs";

const evaluationDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(evaluationDirectory, "../../../../..");
const freezeScript = resolve(
  repositoryRoot,
  "packages/core/scripts/freeze-script-risk-candidate.mjs",
);
const predictScript = resolve(
  repositoryRoot,
  "packages/core/scripts/predict-script-risk-blind.mjs",
);
const scoreScript = resolve(
  repositoryRoot,
  "packages/core/scripts/score-script-risk-blind.mjs",
);
const temporaryRoots: string[] = [];

function temporaryRoot() {
  const root = mkdtempSync(resolve(tmpdir(), "gcsa-blind-protocol-"));
  temporaryRoots.push(root);
  return root;
}

afterEach(() => {
  while (temporaryRoots.length > 0) {
    const root = temporaryRoots.pop();
    if (root) rmSync(root, { recursive: true, force: true });
  }
});

function writeJson(path: string, value: unknown) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

async function waitForFile(path: string, timeoutMs = 5_000) {
  const deadline = Date.now() + timeoutMs;
  while (!existsSync(path)) {
    if (Date.now() >= deadline) throw new Error(`timed out waiting for ${path}`);
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 10));
  }
}

function initializeFixtureRepository(root: string) {
  const repo = resolve(root, "repo");
  mkdirSync(resolve(repo, "packages/core/dist/script-risk"), { recursive: true });
  mkdirSync(resolve(repo, "packages/core/src/script-risk/evaluation/protocols"), {
    recursive: true,
  });
  mkdirSync(resolve(repo, "node_modules/typescript"), { recursive: true });
  writeJson(resolve(repo, "packages/core/package.json"), {
    name: "fixture-core",
    private: true,
  });
  writeJson(resolve(repo, "node_modules/typescript/package.json"), {
    name: "typescript",
    version: "5.9.3-fixture",
  });
  writeFileSync(resolve(repo, "pnpm-lock.yaml"), "lockfileVersion: '9.0'\n", "utf8");
  cpSync(
    resolve(evaluationDirectory, "protocols/blind-v1.json"),
    resolve(repo, "packages/core/src/script-risk/evaluation/protocols/blind-v1.json"),
  );
  const fixtureProtocolPath = resolve(
    repo,
    "packages/core/src/script-risk/evaluation/protocols/blind-v1.json",
  );
  const fixtureProtocol = JSON.parse(readFileSync(fixtureProtocolPath, "utf8"));
  fixtureProtocol.limits.sampleWorkerTimeoutMs = 500;
  writeJson(fixtureProtocolPath, fixtureProtocol);
  writeFileSync(
    resolve(repo, "packages/core/dist/script-risk/ast-analyzer.cjs"),
    `"use strict";
exports.analyzeScriptAst = function analyzeScriptAst(sourceText) {
  if (sourceText.includes("HANG_MARKER")) while (true) {}
  const signals = [];
  const add = (code, pattern) => { if (pattern.test(sourceText)) signals.push({ code, occurrences: 1 }); };
  add("ast.wasm-use", /WebAssembly/);
  add("ast.websocket", /WebSocket/);
  add("ast.mining-protocol", /mining\\.subscribe/);
  return {
    schemaVersion: 1,
    analyzer: "typescript-ast",
    parserVersion: "fixture",
    parseStatus: "complete",
    sourceLength: sourceText.length,
    analyzedLength: sourceText.length,
    truncated: false,
    nodeCount: 1,
    maxDepth: 1,
    branchCount: 0,
    signals,
  };
};
`,
    "utf8",
  );
  cpSync(
    resolve(evaluationDirectory, "confidence-bounds.mjs"),
    resolve(repo, "packages/core/src/script-risk/evaluation/confidence-bounds.mjs"),
  );
  writeFileSync(
    resolve(repo, "packages/core/src/script-risk/evaluation/corpus-eval.mjs"),
    `export function classifyStaticAnalysis(analysis) {
  const codes = new Set(analysis.signals.map((signal) => signal.code));
  const positive = codes.has("ast.wasm-use") && codes.has("ast.websocket") && codes.has("ast.mining-protocol");
  return {
    predicted: positive ? "malicious" : "benign",
    score: positive ? 70 : 0,
    finding: positive ? "suspected-mining" : null,
    reasonCodes: [...codes].sort(),
  };
}
`,
    "utf8",
  );
  execFileSync("git", ["init", "--quiet"], { cwd: repo });
  execFileSync("git", ["config", "user.name", "GCSA Test"], { cwd: repo });
  execFileSync("git", ["config", "user.email", "test@gcsa.invalid"], { cwd: repo });
  execFileSync("git", ["add", "."], { cwd: repo });
  execFileSync(
    "git",
    ["-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture"],
    { cwd: repo },
  );
  return repo;
}

describe("blind-v1 protocol validation", () => {
  it("keeps operator-blinded-local distinct from independent sealed evaluation", () => {
    const { protocol } = loadBlindProtocol(repositoryRoot);
    expect(validateBlindProtocol(protocol)).toBe(true);
    expect(protocol).toMatchObject({
      evaluationClass: "operator-blinded-local",
      independence: {
        operatorMayControlCandidateAndEvaluation: true,
        independentSealVerified: false,
        finalEvaluationEligible: false,
      },
      authorization: {
        releaseEligible: false,
        enforcementAuthorized: false,
        pagePathBlockingAuthorized: false,
      },
      labels: {
        positiveLabel: "mining-capable",
        negativeLabel: "benign-control",
      },
    });

    const elevated = structuredClone(protocol);
    elevated.independence.independentSealVerified = true;
    expect(() => validateBlindProtocol(elevated)).toThrow(
      "must not claim independent sealing",
    );
  });

  it("accepts sorted multi-file bundles but rejects labels, traversal, and digest tampering", () => {
    const { protocol, sha256 } = loadBlindProtocol(repositoryRoot);
    const candidateDigestSha256 = "1".repeat(64);
    const envelope = buildBlindEnvelope({
      protocol,
      protocolSha256: sha256,
      candidateDigestSha256,
      envelopeId: "blind-fixture-001",
      createdAt: "2026-08-28T00:00:00.000Z",
      samples: [
        {
          sampleId: "case-miner-001",
          files: [
            { path: "worker.js", source: "WebAssembly.instantiate(bytes);" },
            { path: "network/client.ts", source: "new WebSocket(url).send('mining.subscribe');" },
          ],
        },
      ],
    });
    expect(validatePredictionEnvelope(envelope, protocol, {
      protocolSha256: sha256,
      candidateDigestSha256,
    })).toBe(true);
    expect(envelope.samples[0].files.map((file) => file.path)).toEqual([
      "network/client.ts",
      "worker.js",
    ]);

    const labelled = structuredClone(envelope);
    labelled.samples[0].label = "mining-capable";
    const { envelopeDigestSha256: _oldDigest, ...unsigned } = labelled;
    labelled.envelopeDigestSha256 = digestCanonical(unsigned);
    expect(() => validatePredictionEnvelope(labelled, protocol, {
      protocolSha256: sha256,
      candidateDigestSha256,
    })).toThrow("label is not allowed");

    expect(() => buildBlindEnvelope({
      protocol,
      protocolSha256: sha256,
      candidateDigestSha256,
      envelopeId: "blind-fixture-002",
      samples: [{ sampleId: "case-miner-002", files: [{ path: "../escape.js", source: "x" }] }],
    })).toThrow("escapes the sample bundle");

    const tampered = structuredClone(envelope);
    tampered.samples[0].files[0].sourceBase64 = Buffer.from("changed").toString("base64");
    expect(() => validatePredictionEnvelope(tampered, protocol, {
      protocolSha256: sha256,
      candidateDigestSha256,
    })).toThrow("byteLength mismatch");
  });
});

describe("blind prediction and post-prediction scoring CLI", () => {
  it("freezes all identities, aggregates files in one case, joins labels later, and refuses overwrite", () => {
    const root = temporaryRoot();
    const repo = initializeFixtureRepository(root);
    const candidatePath = resolve(root, "candidate.json");
    const inputPath = resolve(root, "input.json");
    const predictionPath = resolve(root, "predictions.json");
    const labelPath = resolve(root, "labels.json");
    const reportPath = resolve(root, "report.json");

    execFileSync(
      process.execPath,
      [
        freezeScript,
        "--repo-root",
        repo,
        "--candidate-id",
        "fixture-candidate-v1",
        "--output",
        candidatePath,
      ],
      { encoding: "utf8" },
    );
    const candidate = JSON.parse(readFileSync(candidatePath, "utf8"));
    expect(candidate).toMatchObject({
      repository: { dirty: false, untrackedCount: 0 },
      runtime: {
        nodeVersion: process.versions.node,
        typescript: { version: "5.9.3-fixture" },
      },
      authorization: {
        releaseEligible: false,
        enforcementAuthorized: false,
        finalEvaluationEligible: false,
      },
    });
    const { protocol, sha256 } = loadBlindProtocol(repo);
    const input = buildBlindEnvelope({
      protocol,
      protocolSha256: sha256,
      candidateDigestSha256: candidate.candidateDigestSha256,
      envelopeId: "operator-blind-pilot-001",
      createdAt: candidate.frozenAt,
      samples: [
        {
          sampleId: "case-benign-001",
          files: [{ path: "ui.js", source: "export const value = 1;" }],
        },
        {
          sampleId: "case-miner-001",
          files: [
            { path: "compute/worker.js", source: "WebAssembly.instantiate(bytes);" },
            { path: "network.ts", source: "new WebSocket(url).send('mining.subscribe');" },
          ],
        },
      ],
    });
    writeJson(inputPath, input);

    execFileSync(
      process.execPath,
      [
        predictScript,
        "--repo-root",
        repo,
        "--candidate",
        candidatePath,
        "--input",
        inputPath,
        "--output",
        predictionPath,
      ],
      { encoding: "utf8" },
    );
    const predictionText = readFileSync(predictionPath, "utf8");
    const predictions = JSON.parse(predictionText);
    expect(predictions.rows).toMatchObject([
      { sampleId: "case-benign-001", predictedLabel: "benign-control", filesAnalyzed: 1 },
      { sampleId: "case-miner-001", predictedLabel: "mining-capable", filesAnalyzed: 2 },
    ]);
    expect(predictionText).not.toContain("actualLabel");
    expect(predictionText).not.toContain("WebAssembly");
    expect(predictionText).not.toContain("mining.subscribe");

    const preFreezeInputPath = resolve(root, "pre-freeze-input.json");
    const preFreezeOutputPath = resolve(root, "pre-freeze-predictions.json");
    const preFreezeInput = buildBlindEnvelope({
      protocol,
      protocolSha256: sha256,
      candidateDigestSha256: candidate.candidateDigestSha256,
      envelopeId: "operator-blind-pre-freeze-001",
      createdAt: new Date(Date.parse(candidate.frozenAt) - 1).toISOString(),
      samples: [
        {
          sampleId: "case-pre-freeze-001",
          files: [{ path: "input.js", source: "export const value = 1;" }],
        },
      ],
    });
    writeJson(preFreezeInputPath, preFreezeInput);
    const preFreezeRun = spawnSync(
      process.execPath,
      [
        predictScript,
        "--repo-root",
        repo,
        "--candidate",
        candidatePath,
        "--input",
        preFreezeInputPath,
        "--output",
        preFreezeOutputPath,
      ],
      { encoding: "utf8" },
    );
    expect(preFreezeRun.status).toBe(1);
    expect(preFreezeRun.stderr).toContain("must not predate candidate freeze");
    expect(existsSync(preFreezeOutputPath)).toBe(false);

    const earlyPrediction = structuredClone(predictions);
    earlyPrediction.predictedAt = new Date(
      Date.parse(input.createdAt) - 1,
    ).toISOString();
    const { predictionDigestSha256: _earlyDigest, ...earlyUnsigned } =
      earlyPrediction;
    earlyPrediction.predictionDigestSha256 = digestCanonical(earlyUnsigned);
    expect(() =>
      validatePredictionOutput(earlyPrediction, protocol, candidate, input),
    ).toThrow("prediction envelope.createdAt must not be after prediction output.predictedAt");

    const labelEnvelope = buildLabelEnvelope({
      protocol,
      protocolSha256: sha256,
      candidateDigestSha256: candidate.candidateDigestSha256,
      predictionDigestSha256: predictions.predictionDigestSha256,
      inputEnvelopeDigestSha256: input.envelopeDigestSha256,
      createdAt: predictions.predictedAt,
      labels: [
        { sampleId: "case-benign-001", actualLabel: "benign-control", obfuscationTier: "none" },
        { sampleId: "case-miner-001", actualLabel: "mining-capable", obfuscationTier: "none" },
      ],
    });
    const earlyLabels = structuredClone(labelEnvelope);
    earlyLabels.createdAt = new Date(
      Date.parse(predictions.predictedAt) - 1,
    ).toISOString();
    const { envelopeDigestSha256: _earlyLabelDigest, ...earlyLabelUnsigned } =
      earlyLabels;
    earlyLabels.envelopeDigestSha256 = digestCanonical(earlyLabelUnsigned);
    expect(() =>
      validateLabelEnvelope(earlyLabels, protocol, candidate, predictions),
    ).toThrow("prediction output.predictedAt must not be after label envelope.createdAt");
    writeJson(labelPath, labelEnvelope);
    execFileSync(
      process.execPath,
      [
        scoreScript,
        "--repo-root",
        repo,
        "--candidate",
        candidatePath,
        "--input",
        inputPath,
        "--predictions",
        predictionPath,
        "--labels",
        labelPath,
        "--output",
        reportPath,
      ],
      { encoding: "utf8" },
    );
    const report = JSON.parse(readFileSync(reportPath, "utf8"));
    expect(report).toMatchObject({
      evaluationClass: "operator-blinded-local",
      independentSealVerified: false,
      finalEvaluationEligible: false,
      releaseEligible: false,
      enforcementAuthorized: false,
      labelsJoinedAfterPrediction: true,
      labelDefinition: {
        positiveLabel: "mining-capable",
        negativeLabel: "benign-control",
      },
      metrics: {
        overall: {
          sampleCount: 2,
          precision: 1,
          recall: 1,
          falsePositiveRate: 0,
          accuracy: 1,
        },
        confidenceBounds: {
          method: "clopper-pearson-exact-one-sided",
          confidenceLevel: 0.95,
          recall: { successes: 1, trials: 1 },
          falsePositiveRate: { successes: 0, trials: 1, upperBound: 0.95 },
        },
      },
    });
    expect(report.metrics.confidenceBounds.recall.lowerBound).toBeCloseTo(0.05, 14);
    expect(() =>
      createBlindScoreReport({
        protocol,
        candidate,
        predictions,
        labels: labelEnvelope,
        scoredAt: new Date(Date.parse(labelEnvelope.createdAt) - 1).toISOString(),
        confidenceFunctions,
      }),
    ).toThrow("label envelope.createdAt must not be after scoredAt");

    const overwrite = spawnSync(
      process.execPath,
      [
        predictScript,
        "--repo-root",
        repo,
        "--candidate",
        candidatePath,
        "--input",
        inputPath,
        "--output",
        predictionPath,
      ],
      { encoding: "utf8" },
    );
    expect(overwrite.status).toBe(1);
    expect(overwrite.stderr).toContain("refusing to overwrite existing output");

    const timeoutInputPath = resolve(root, "timeout-input.json");
    const timeoutOutputPath = resolve(root, "timeout-predictions.json");
    const timeoutInput = buildBlindEnvelope({
      protocol,
      protocolSha256: sha256,
      candidateDigestSha256: candidate.candidateDigestSha256,
      envelopeId: "operator-blind-timeout-001",
      samples: [
        {
          sampleId: "case-timeout-001",
          files: [{ path: "timeout.js", source: "HANG_MARKER" }],
        },
      ],
    });
    writeJson(timeoutInputPath, timeoutInput);
    const timedOut = spawnSync(
      process.execPath,
      [
        predictScript,
        "--repo-root",
        repo,
        "--candidate",
        candidatePath,
        "--input",
        timeoutInputPath,
        "--output",
        timeoutOutputPath,
      ],
      { encoding: "utf8", timeout: 5_000 },
    );
    expect(timedOut.status).toBe(1);
    expect(timedOut.stderr).toContain("sample worker timed out");
    expect(existsSync(timeoutOutputPath)).toBe(false);

    const analyzerPath = resolve(
      repo,
      "packages/core/dist/script-risk/ast-analyzer.cjs",
    );
    writeFileSync(
      analyzerPath,
      `${readFileSync(analyzerPath, "utf8")}\n// post-freeze mutation\n`,
      "utf8",
    );
    const changedOutputPath = resolve(root, "changed-predictions.json");
    const changedCandidateRun = spawnSync(
      process.execPath,
      [
        predictScript,
        "--repo-root",
        repo,
        "--candidate",
        candidatePath,
        "--input",
        inputPath,
        "--output",
        changedOutputPath,
      ],
      { encoding: "utf8" },
    );
    expect(changedCandidateRun.status).toBe(1);
    expect(changedCandidateRun.stderr).toContain("analyzer bundle digest mismatch");
    expect(existsSync(changedOutputPath)).toBe(false);
  }, 30_000);

  it("keeps all component execution bytes digest-bound and exposes no loadable component path", async () => {
    const root = temporaryRoot();
    const repo = initializeFixtureRepository(root);
    const candidatePath = resolve(root, "memory-candidate.json");
    execFileSync(process.execPath, [
      freezeScript,
      "--repo-root", repo,
      "--candidate-id", "memory-components-candidate-v1",
      "--output", candidatePath,
    ]);
    const candidate = JSON.parse(readFileSync(candidatePath, "utf8"));
    const environment = verifyCandidateEnvironment(repo, candidate);
    expect(environment).not.toHaveProperty("analyzerPath");
    expect(environment).not.toHaveProperty("classifierPath");
    expect(environment).not.toHaveProperty("confidenceBoundsPath");
    for (const [name, component, digest] of [
      ["analyzer bundle", environment.components.analyzer, candidate.detector.analyzerBundle.sha256],
      ["classification rules", environment.components.classifier, candidate.detector.classificationRules.sha256],
      ["confidence bounds", environment.components.confidenceBounds, candidate.detector.confidenceBounds.sha256],
    ]) {
      expect(Buffer.isBuffer(component.bytes)).toBe(true);
      expect(sha256Hex(component.bytes)).toBe(digest);
      expect(verifiedCandidateComponentBytes(component, name).sha256).toBe(digest);
    }
    const classifier = await importVerifiedCandidateModule(
      environment.components.classifier,
      "classification rules",
    );
    const confidence = await importVerifiedCandidateModule(
      environment.components.confidenceBounds,
      "confidence bounds",
    );
    expect(typeof classifier.classifyStaticAnalysis).toBe("function");
    expect(typeof confidence.clopperPearsonLowerBound).toBe("function");

    const tamperedAnalyzer = {
      ...environment.components.analyzer,
      bytes: Buffer.concat([environment.components.analyzer.bytes, Buffer.from("\n")]),
    };
    expect(() =>
      verifiedCandidateComponentBytes(tamperedAnalyzer, "analyzer bundle"),
    ).toThrow("do not match the candidate digest");
  });

  it("uses one verified in-memory analyzer byte sequence when the repository bundle is replaced and restored between workers", async () => {
    const root = temporaryRoot();
    const repo = initializeFixtureRepository(root);
    const control = resolve(root, "control");
    mkdirSync(control, { recursive: true });
    const firstReady = resolve(control, "first-ready");
    const firstContinue = resolve(control, "first-continue");
    const secondReady = resolve(control, "second-ready");
    const secondContinue = resolve(control, "second-continue");
    const badLoaded = resolve(control, "bad-loaded");
    const virtualFilenameProbe = resolve(control, "virtual-filename");
    const analyzerPath = resolve(
      repo,
      "packages/core/dist/script-risk/ast-analyzer.cjs",
    );
    const coordinatedAnalyzer = Buffer.from(`"use strict";
const fs = require("node:fs");
fs.writeFileSync(${JSON.stringify(virtualFilenameProbe)}, __filename);
const waitFor = (path) => {
  const view = new Int32Array(new SharedArrayBuffer(4));
  const deadline = Date.now() + 5000;
  while (!fs.existsSync(path)) {
    if (Date.now() >= deadline) throw new Error("fixture coordination timeout");
    Atomics.wait(view, 0, 0, 10);
  }
};
exports.analyzeScriptAst = function analyzeScriptAst(sourceText) {
  if (sourceText.includes("FIRST_WORKER")) {
    fs.writeFileSync(${JSON.stringify(firstReady)}, "ready");
    waitFor(${JSON.stringify(firstContinue)});
  }
  if (sourceText.includes("SECOND_WORKER")) {
    fs.writeFileSync(${JSON.stringify(secondReady)}, "ready");
    waitFor(${JSON.stringify(secondContinue)});
  }
  return { schemaVersion: 1, analyzer: "typescript-ast", parserVersion: "fixture",
    parseStatus: "complete", sourceLength: sourceText.length, analyzedLength: sourceText.length,
    truncated: false, nodeCount: 1, maxDepth: 1, branchCount: 0, signals: [] };
};
`);
    writeFileSync(analyzerPath, coordinatedAnalyzer);
    execFileSync("git", ["add", "packages/core/dist/script-risk/ast-analyzer.cjs"], {
      cwd: repo,
    });
    execFileSync(
      "git",
      [
        "-c",
        "commit.gpgsign=false",
        "commit",
        "--quiet",
        "--amend",
        "--no-edit",
      ],
      { cwd: repo },
    );

    const candidatePath = resolve(root, "rotation-candidate.json");
    const inputPath = resolve(root, "rotation-input.json");
    const outputPath = resolve(root, "rotation-output.json");
    execFileSync(process.execPath, [
      freezeScript,
      "--repo-root", repo,
      "--candidate-id", "rotation-candidate-v1",
      "--output", candidatePath,
    ]);
    const candidate = JSON.parse(readFileSync(candidatePath, "utf8"));
    const { protocol, sha256 } = loadBlindProtocol(repo);
    writeJson(inputPath, buildBlindEnvelope({
      protocol,
      protocolSha256: sha256,
      candidateDigestSha256: candidate.candidateDigestSha256,
      envelopeId: "rotation-envelope-v1",
      createdAt: candidate.frozenAt,
      samples: [
        {
          sampleId: "case-first-worker",
          files: [{ path: "first.js", source: "FIRST_WORKER" }],
        },
        {
          sampleId: "case-second-worker",
          files: [{ path: "second.js", source: "SECOND_WORKER" }],
        },
      ],
    }));
    const badAnalyzer = `"use strict";
require("node:fs").writeFileSync(${JSON.stringify(badLoaded)}, "loaded");
exports.analyzeScriptAst = function () {
  return { parseStatus: "complete", truncated: false, sourceLength: 1, analyzedLength: 1,
    nodeCount: 1, maxDepth: 1, branchCount: 0,
    signals: [{ code: "ast.wasm-use", occurrences: 1 }, { code: "ast.websocket", occurrences: 1 },
      { code: "ast.mining-protocol", occurrences: 1 }] };
};
`;
    const temporarySnapshotsBefore = new Set(
      readdirSync(tmpdir()).filter((name) =>
        name.startsWith("gcsa-script-risk-candidate-"),
      ),
    );
    const child = spawn(process.execPath, [
      predictScript,
      "--repo-root", repo,
      "--candidate", candidatePath,
      "--input", inputPath,
      "--output", outputPath,
    ], { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout?.on("data", (chunk) => { stdout += chunk.toString(); });
    child.stderr?.on("data", (chunk) => { stderr += chunk.toString(); });
    const completion = new Promise<number | null>((resolvePromise, rejectPromise) => {
      child.once("error", rejectPromise);
      child.once("exit", resolvePromise);
    });
    try {
      await waitForFile(firstReady);
      await waitForFile(virtualFilenameProbe);
      const virtualFilename = readFileSync(virtualFilenameProbe, "utf8");
      expect(virtualFilename).toMatch(
        /^\/__gcsa_verified_components__\/analyzer-[a-f0-9]{64}\.cjs$/,
      );
      expect(existsSync(virtualFilename)).toBe(false);
      const temporarySnapshotsDuring = readdirSync(tmpdir()).filter((name) =>
        name.startsWith("gcsa-script-risk-candidate-"),
      );
      expect(
        temporarySnapshotsDuring.filter(
          (name) => !temporarySnapshotsBefore.has(name),
        ),
      ).toEqual([]);
      writeFileSync(analyzerPath, badAnalyzer, "utf8");
      writeFileSync(firstContinue, "continue", "utf8");
      await waitForFile(secondReady);
      writeFileSync(analyzerPath, coordinatedAnalyzer);
      writeFileSync(secondContinue, "continue", "utf8");
    } catch (error) {
      child.kill();
      throw error;
    } finally {
      writeFileSync(analyzerPath, coordinatedAnalyzer);
      writeFileSync(firstContinue, "continue", "utf8");
      writeFileSync(secondContinue, "continue", "utf8");
    }
    const exitCode = await completion;
    expect(exitCode, stderr || stdout).toBe(0);
    expect(existsSync(badLoaded)).toBe(false);
    expect(
      readdirSync(tmpdir()).filter(
        (name) =>
          name.startsWith("gcsa-script-risk-candidate-") &&
          !temporarySnapshotsBefore.has(name),
      ),
    ).toEqual([]);
    expect(JSON.parse(readFileSync(outputPath, "utf8")).rows).toMatchObject([
      { sampleId: "case-first-worker", predictedLabel: "benign-control" },
      { sampleId: "case-second-worker", predictedLabel: "benign-control" },
    ]);
  }, 30_000);

  it("keeps --final closed before accepting any evaluation inputs", () => {
    for (const script of [freezeScript, predictScript, scoreScript]) {
      const result = spawnSync(process.execPath, [script, "--final"], {
        encoding: "utf8",
      });
      expect(result.status).toBe(1);
      expect(result.stderr).toContain("--final is unavailable");
    }
  });
});

describe("blind score one-sided confidence bounds", () => {
  it("returns null only when recall or FPR has no corresponding denominator", () => {
    const noPositive = computeOneSidedConfidenceBounds(
      { truePositive: 0, falseNegative: 0, trueNegative: 10, falsePositive: 0 },
      confidenceFunctions,
    );
    expect(noPositive).toMatchObject({
      confidenceLevel: 0.95,
      recall: { successes: 0, trials: 0, lowerBound: null },
      falsePositiveRate: { successes: 0, trials: 10 },
    });
    expect(noPositive.falsePositiveRate.upperBound).toBeCloseTo(
      0.2588655508930523,
      14,
    );

    const noNegative = computeOneSidedConfidenceBounds(
      { truePositive: 10, falseNegative: 0, trueNegative: 0, falsePositive: 0 },
      confidenceFunctions,
    );
    expect(noNegative).toMatchObject({
      recall: { successes: 10, trials: 10 },
      falsePositiveRate: { successes: 0, trials: 0, upperBound: null },
    });
    expect(noNegative.recall.lowerBound).toBeCloseTo(
      0.7411344491069477,
      14,
    );
  });
});
