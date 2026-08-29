#!/usr/bin/env node

import { performance } from "node:perf_hooks";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Worker } from "node:worker_threads";
import {
  assertBlind,
  digestCanonical,
  importVerifiedCandidateModule,
  readJsonFile,
  validatePredictionEnvelope,
  validatePredictionOutput,
  verifiedCandidateComponentBytes,
  verifyCandidateEnvironment,
  writeJsonExclusive,
} from "../src/script-risk/evaluation/blind-protocol.mjs";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const defaultRepoRoot = resolve(scriptDirectory, "../../..");

// 每个样本只进入一个资源受限 worker。样本源码始终只作为字符串传给 AST analyzer；
// vm 仅用于编译候选锁已经绑定并在 worker 内再次核验摘要的 analyzer 代码。
const SAMPLE_WORKER_SOURCE = String.raw`
  "use strict";
  const { createHash } = require("node:crypto");
  const { createRequire } = require("node:module");
  const { dirname, parse, resolve } = require("node:path");
  const vm = require("node:vm");
  const { parentPort, workerData } = require("node:worker_threads");
  try {
    const analyzerBytes = Buffer.from(workerData.analyzerBytes);
    const analyzerSha256 = workerData.analyzerSha256;
    const actualSha256 = createHash("sha256").update(analyzerBytes).digest("hex");
    if (!/^[a-f0-9]{64}$/.test(analyzerSha256) || actualSha256 !== analyzerSha256) {
      throw new Error("analyzer digest mismatch");
    }
    const analyzerSource = new TextDecoder("utf-8", { fatal: true }).decode(analyzerBytes);
    const virtualFilename = resolve(
      parse(process.execPath).root,
      "__gcsa_verified_components__",
      "analyzer-" + analyzerSha256 + ".cjs",
    );
    const moduleRecord = { exports: {} };
    const wrapperSource =
      "(function (exports, require, module, __filename, __dirname) {\n" +
      analyzerSource +
      "\n})";
    const compiledWrapper = new vm.Script(wrapperSource, {
      filename: virtualFilename,
      displayErrors: false,
    }).runInThisContext();
    compiledWrapper.call(
      moduleRecord.exports,
      moduleRecord.exports,
      createRequire(virtualFilename),
      moduleRecord,
      virtualFilename,
      dirname(virtualFilename),
    );
    const analyzer = moduleRecord.exports;
    if (!analyzer || typeof analyzer.analyzeScriptAst !== "function") {
      throw new Error("missing analyzer export");
    }
    const analyses = workerData.sources.map((sourceText) =>
      analyzer.analyzeScriptAst(sourceText, {
        maxSourceChars: workerData.maxSourceChars,
      }),
    );
    parentPort.postMessage({ ok: true, analyses });
  } catch {
    parentPort.postMessage({ ok: false });
  } finally {
    parentPort.close();
  }
`;

function usage() {
  return `Usage:
  node packages/core/scripts/predict-script-risk-blind.mjs \\
    --candidate <candidate-lock.json> --input <unlabelled-envelope.json> \\
    --output <predictions.json> [--repo-root <path>]

输入必须是 blind-v1 无标签 envelope。每个 case 的 files[] 在一个有时间和内存限制的
worker 中仅做 AST 解析，随后聚合信号并调用候选锁绑定的 corpus-eval.mjs 分类规则。
任一样本超时、资源失败、解析失败、截断或哈希不符都会使整次运行闭锁失败且不写输出。
输出不含源码或真实标签；它不是 independent-sealed 结果，也不授权阻断。`;
}

function parseArguments(argv) {
  const options = { repoRoot: defaultRepoRoot };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--") continue;
    if (argument === "--help" || argument === "-h") {
      options.help = true;
      continue;
    }
    if (argument === "--final") {
      throw new Error(
        "--final is unavailable: operator-blinded-local is not independent-sealed",
      );
    }
    const key = {
      "--candidate": "candidate",
      "--input": "input",
      "--output": "output",
      "--repo-root": "repoRoot",
    }[argument];
    if (!key) throw new Error(`unknown argument: ${argument}`);
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) throw new Error(`${argument} requires a value`);
    options[key] = value;
    index += 1;
  }
  return options;
}

function analyzeSampleInWorker(sample, analyzerComponent, limits) {
  const sources = sample.files.map((file) =>
    new TextDecoder("utf-8", { fatal: true }).decode(
      Buffer.from(file.sourceBase64, "base64"),
    ),
  );
  return new Promise((resolvePromise, rejectPromise) => {
    let settled = false;
    const worker = new Worker(SAMPLE_WORKER_SOURCE, {
      eval: true,
      // 不继承调用方的 loader、--input-type、inspect 等参数，固定为普通 CJS eval worker。
      execArgv: [],
      workerData: {
        analyzerBytes: analyzerComponent.bytes,
        analyzerSha256: analyzerComponent.sha256,
        sources,
        maxSourceChars: limits.maxSourceBytesPerFile,
      },
      resourceLimits: {
        maxOldGenerationSizeMb: limits.workerMaxOldGenerationSizeMb,
        maxYoungGenerationSizeMb: limits.workerMaxYoungGenerationSizeMb,
        stackSizeMb: limits.workerStackSizeMb,
      },
    });
    const finishWithFailure = (message) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      void worker.terminate();
      rejectPromise(new Error(`${sample.sampleId}: ${message}`));
    };
    const timer = setTimeout(
      () => finishWithFailure("sample worker timed out"),
      limits.sampleWorkerTimeoutMs,
    );
    worker.once("message", (message) => {
      if (settled) return;
      if (!message || message.ok !== true || !Array.isArray(message.analyses)) {
        finishWithFailure("sample worker failed closed");
        return;
      }
      settled = true;
      clearTimeout(timer);
      void worker.terminate();
      resolvePromise(message.analyses);
    });
    worker.once("error", (error) =>
      finishWithFailure(
        error?.code === "ERR_WORKER_OUT_OF_MEMORY"
          ? "sample worker exceeded its memory limit"
          : "sample worker failed closed",
      ),
    );
    worker.once("exit", (code) => {
      if (!settled && code !== 0) finishWithFailure("sample worker exited unexpectedly");
    });
  });
}

function aggregateAnalyses(sample, analyses) {
  assertBlind(analyses.length === sample.files.length, `${sample.sampleId}: analyzer result count mismatch`);
  const signalCounts = new Map();
  let sourceLength = 0;
  let analyzedLength = 0;
  let nodeCount = 0;
  let maxDepth = 0;
  let branchCount = 0;
  for (const [index, analysis] of analyses.entries()) {
    assertBlind(analysis && typeof analysis === "object", `${sample.sampleId}: invalid analyzer result`);
    assertBlind(
      analysis.parseStatus === "complete" && analysis.truncated === false,
      `${sample.sampleId}: file ${index} did not parse completely`,
    );
    assertBlind(Array.isArray(analysis.signals), `${sample.sampleId}: invalid analyzer signals`);
    for (const signal of analysis.signals) {
      assertBlind(
        signal &&
          typeof signal.code === "string" &&
          /^ast\.[a-z0-9-]{2,64}$/.test(signal.code) &&
          Number.isSafeInteger(signal.occurrences) &&
          signal.occurrences >= 1 &&
          signal.occurrences <= 255,
        `${sample.sampleId}: invalid analyzer signal`,
      );
      signalCounts.set(
        signal.code,
        Math.min(255, (signalCounts.get(signal.code) ?? 0) + signal.occurrences),
      );
    }
    for (const [field, value] of [
      ["sourceLength", analysis.sourceLength],
      ["analyzedLength", analysis.analyzedLength],
      ["nodeCount", analysis.nodeCount],
      ["maxDepth", analysis.maxDepth],
      ["branchCount", analysis.branchCount],
    ]) {
      assertBlind(Number.isSafeInteger(value) && value >= 0, `${sample.sampleId}: invalid ${field}`);
    }
    sourceLength += analysis.sourceLength;
    analyzedLength += analysis.analyzedLength;
    nodeCount += analysis.nodeCount;
    maxDepth = Math.max(maxDepth, analysis.maxDepth);
    branchCount += analysis.branchCount;
  }
  return {
    schemaVersion: 1,
    analyzer: "typescript-ast-bundle-aggregate",
    parseStatus: "complete",
    sourceLength,
    analyzedLength,
    truncated: false,
    nodeCount,
    maxDepth,
    branchCount,
    signals: [...signalCounts.entries()]
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([code, occurrences]) => ({ code, occurrences })),
  };
}

function normalizeClassification(sampleId, classification, protocol) {
  assertBlind(classification && typeof classification === "object", `${sampleId}: invalid classifier result`);
  const positive = classification.predicted === protocol.labels.classifierPositiveValue;
  const negative = classification.predicted === protocol.labels.classifierNegativeValue;
  assertBlind(positive !== negative, `${sampleId}: classifier returned an unknown label`);
  assertBlind(
    Number.isFinite(classification.score) &&
      classification.score >= 0 &&
      classification.score <= 100,
    `${sampleId}: classifier returned an invalid score`,
  );
  assertBlind(
    classification.finding === null || typeof classification.finding === "string",
    `${sampleId}: classifier returned an invalid finding`,
  );
  assertBlind(Array.isArray(classification.reasonCodes), `${sampleId}: classifier reasonCodes are invalid`);
  const reasonCodes = [...classification.reasonCodes];
  assertBlind(
    reasonCodes.every((value) => typeof value === "string") &&
      new Set(reasonCodes).size === reasonCodes.length,
    `${sampleId}: classifier reasonCodes are invalid`,
  );
  reasonCodes.sort();
  return {
    predictedLabel: positive
      ? protocol.labels.positiveLabel
      : protocol.labels.negativeLabel,
    score: classification.score,
    finding: classification.finding,
    reasonCodes,
  };
}

export async function predictEnvelope({
  candidate,
  envelope,
  repoRoot,
  environment: verifiedEnvironment,
}) {
  const environment =
    verifiedEnvironment ?? verifyCandidateEnvironment(repoRoot, candidate);
  const shouldReverifyEnvironment = verifiedEnvironment === undefined;
  const { protocol } = environment;
  validatePredictionEnvelope(envelope, protocol, {
    protocolSha256: candidate.protocol.sha256,
    candidateDigestSha256: candidate.candidateDigestSha256,
  });
  assertBlind(
    Date.parse(candidate.frozenAt) <= Date.parse(envelope.createdAt),
    "prediction input must not predate candidate freeze",
  );
  assertBlind(
    Date.parse(envelope.createdAt) <= Date.now(),
    "prediction input must not postdate prediction start",
  );
  const analyzerComponent = verifiedCandidateComponentBytes(
    environment.components.analyzer,
    "analyzer bundle",
  );
  const classifierModule = await importVerifiedCandidateModule(
    environment.components.classifier,
    "classification rules",
  );
  const classifier =
    classifierModule[candidate.detector.classificationRules.exportName];
  assertBlind(
    typeof classifier === "function",
    "classification rules export is unavailable",
  );

  const rows = [];
  for (const sample of envelope.samples) {
    const startedAt = performance.now();
    const analyses = await analyzeSampleInWorker(
      sample,
      analyzerComponent,
      protocol.limits,
    );
    const aggregated = aggregateAnalyses(sample, analyses);
    const classification = normalizeClassification(
      sample.sampleId,
      classifier(aggregated),
      protocol,
    );
    rows.push({
      sampleId: sample.sampleId,
      contentAddress: sample.contentAddress,
      ...classification,
      durationMs: Number((performance.now() - startedAt).toFixed(6)),
      filesAnalyzed: sample.files.length,
    });
  }
  const unsigned = {
    schema: protocol.schemas.predictionOutput,
    schemaVersion: 1,
    mode: "research-only",
    evaluationClass: "operator-blinded-local",
    independentSealVerified: false,
    releaseEligible: false,
    enforcementAuthorized: false,
    protocolId: protocol.protocolId,
    protocolSha256: candidate.protocol.sha256,
    candidateDigestSha256: candidate.candidateDigestSha256,
    inputEnvelopeId: envelope.envelopeId,
    inputEnvelopeDigestSha256: envelope.envelopeDigestSha256,
    predictedAt: new Date().toISOString(),
    ...(envelope.publicPilot
      ? { publicPilot: structuredClone(envelope.publicPilot) }
      : {}),
    rows,
  };
  const output = {
    ...unsigned,
    predictionDigestSha256: digestCanonical(unsigned),
  };
  validatePredictionOutput(output, protocol, candidate, envelope);
  if (shouldReverifyEnvironment) verifyCandidateEnvironment(repoRoot, candidate);
  return output;
}

export async function main(argv = process.argv.slice(2)) {
  const options = parseArguments(argv);
  if (options.help) {
    process.stdout.write(`${usage()}\n`);
    return null;
  }
  for (const key of ["candidate", "input", "output"]) {
    if (!options[key]) throw new Error(`--${key} is required`);
  }
  const repoRoot = resolve(options.repoRoot);
  const candidatePath = resolve(repoRoot, options.candidate);
  const inputPath = resolve(repoRoot, options.input);
  const outputPathRequested = resolve(repoRoot, options.output);
  const candidate = readJsonFile(candidatePath, 2 * 1024 * 1024, "candidate lock").value;
  const environment = verifyCandidateEnvironment(repoRoot, candidate);
  const envelope = readJsonFile(
    inputPath,
    environment.protocol.limits.maxJsonBytes,
    "prediction envelope",
  ).value;
  const output = await predictEnvelope({
    candidate,
    envelope,
    repoRoot,
    environment,
  });
  // 内存组件保证本次结果不混用路径内容；落盘前仍要求仓库恢复到冻结状态。
  verifyCandidateEnvironment(repoRoot, candidate);
  const outputPath = writeJsonExclusive(outputPathRequested, output);
  process.stdout.write(
    `${JSON.stringify({
      evaluationClass: output.evaluationClass,
      independentSealVerified: output.independentSealVerified,
      sampleCount: output.rows.length,
      predictionDigestSha256: output.predictionDigestSha256,
      outputPath,
    })}\n`,
  );
  return { output, outputPath };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    await main();
  } catch (error) {
    process.stderr.write(
      `script-risk blind prediction failed: ${
        error instanceof Error ? error.message : String(error)
      }\n`,
    );
    process.exitCode = 1;
  }
}
