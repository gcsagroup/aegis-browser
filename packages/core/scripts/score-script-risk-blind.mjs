#!/usr/bin/env node

import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createBlindScoreReport,
  importVerifiedCandidateModule,
  readJsonFile,
  validateLabelEnvelope,
  validatePredictionEnvelope,
  validatePredictionOutput,
  verifyCandidateEnvironment,
  writeJsonExclusive,
} from "../src/script-risk/evaluation/blind-protocol.mjs";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const defaultRepoRoot = resolve(scriptDirectory, "../../..");

function usage() {
  return `Usage:
  node packages/core/scripts/score-script-risk-blind.mjs \\
    --candidate <candidate-lock.json> --input <unlabelled-envelope.json> \\
    --predictions <predictions.json> --labels <post-prediction-labels.json> \\
    --output <score-report.json> [--repo-root <path>]

评分阶段重新校验候选、无标签输入和冻结预测，然后才连接绑定 prediction digest 的
标签 envelope。正负类名称来自协议，不硬编码 malicious/benign。输出始终标记为
operator-blinded-local、independentSealVerified=false、releaseEligible=false；
--final 始终闭锁。`;
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
      "--predictions": "predictions",
      "--labels": "labels",
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

export async function main(argv = process.argv.slice(2)) {
  const options = parseArguments(argv);
  if (options.help) {
    process.stdout.write(`${usage()}\n`);
    return null;
  }
  for (const key of ["candidate", "input", "predictions", "labels", "output"]) {
    if (!options[key]) throw new Error(`--${key} is required`);
  }
  const repoRoot = resolve(options.repoRoot);
  const candidate = readJsonFile(
    resolve(repoRoot, options.candidate),
    2 * 1024 * 1024,
    "candidate lock",
  ).value;
  const environment = verifyCandidateEnvironment(repoRoot, candidate);
  const { protocol } = environment;
  const input = readJsonFile(
    resolve(repoRoot, options.input),
    protocol.limits.maxJsonBytes,
    "prediction envelope",
  ).value;
  validatePredictionEnvelope(input, protocol, {
    protocolSha256: candidate.protocol.sha256,
    candidateDigestSha256: candidate.candidateDigestSha256,
  });
  const predictions = readJsonFile(
    resolve(repoRoot, options.predictions),
    protocol.limits.maxJsonBytes,
    "prediction output",
  ).value;
  validatePredictionOutput(predictions, protocol, candidate, input);
  const labels = readJsonFile(
    resolve(repoRoot, options.labels),
    protocol.limits.maxJsonBytes,
    "label envelope",
  ).value;
  validateLabelEnvelope(labels, protocol, candidate, predictions);
  const confidenceFunctions = await importVerifiedCandidateModule(
    environment.components.confidenceBounds,
    "confidence bounds",
  );
  const report = createBlindScoreReport({
    protocol,
    candidate,
    predictions,
    labels,
    scoredAt: new Date().toISOString(),
    confidenceFunctions,
  });
  verifyCandidateEnvironment(repoRoot, candidate);
  const outputPath = writeJsonExclusive(resolve(repoRoot, options.output), report);
  process.stdout.write(
    `${JSON.stringify({
      evaluationClass: report.evaluationClass,
      independentSealVerified: report.independentSealVerified,
      finalEvaluationEligible: report.finalEvaluationEligible,
      sampleCount: report.metrics.overall.sampleCount,
      precision: report.metrics.overall.precision,
      recall: report.metrics.overall.recall,
      falsePositiveRate: report.metrics.overall.falsePositiveRate,
      reportDigestSha256: report.reportDigestSha256,
      outputPath,
    })}\n`,
  );
  return { report, outputPath };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    await main();
  } catch (error) {
    process.stderr.write(
      `script-risk blind scoring failed: ${
        error instanceof Error ? error.message : String(error)
      }\n`,
    );
    process.exitCode = 1;
  }
}
