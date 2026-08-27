#!/usr/bin/env node

import { createRequire } from "node:module";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { performance } from "node:perf_hooks";
import {
  authorizeEvaluationAccess,
  buildCorpusManifest,
  classifyStaticAnalysis,
  createEvaluationReport,
  createGroupedSplit,
  sha256Hex,
} from "../src/script-risk/evaluation/corpus-eval.mjs";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const coreDirectory = resolve(scriptDirectory, "..");
const defaults = {
  definition: resolve(
    coreDirectory,
    "src/script-risk/evaluation/fixtures/corpus.json",
  ),
  analyzer: resolve(coreDirectory, "dist/script-risk/ast-analyzer.cjs"),
  split: "validation",
};

function usage() {
  return `Usage:
  node packages/core/scripts/evaluate-script-risk-corpus.mjs \\
    --report-output <path> [--protocol-output <path>] \\
    [--definition <path>] [--fixtures-root <path>] [--analyzer <path>] \\
    [--split train|validation|test] [--final]

The repository test split is a deterministic public holdout: its seed, labels,
manifest, and assignments are inspectable, so it is not a sealed or blind test.
--final is accepted only to fail closed and can never authorize final evaluation.
The tool reads local synthetic fixtures as text for AST parsing; it has no
downloader and never executes fixture source.`;
}

function parseArguments(argv) {
  const options = {
    definition: defaults.definition,
    analyzer: defaults.analyzer,
    split: defaults.split,
    finalEvaluation: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    // pnpm 的嵌套脚本转发会保留标准参数分隔符；它不是评测参数。
    if (argument === "--") continue;
    if (argument === "--help" || argument === "-h") {
      options.help = true;
      continue;
    }
    if (argument === "--final") {
      options.finalEvaluation = true;
      continue;
    }
    const keyByArgument = {
      "--definition": "definition",
      "--fixtures-root": "fixturesRoot",
      "--analyzer": "analyzer",
      "--split": "split",
      "--protocol-output": "protocolOutput",
      "--report-output": "reportOutput",
    };
    const key = keyByArgument[argument];
    if (!key) throw new Error(`unknown argument: ${argument}`);
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) {
      throw new Error(`${argument} requires a value`);
    }
    options[key] = value;
    index += 1;
  }
  return options;
}

function writeJson(outputPath, value) {
  const absolute = resolve(outputPath);
  mkdirSync(dirname(absolute), { recursive: true });
  writeFileSync(absolute, `${JSON.stringify(value, null, 2)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
  return absolute;
}

function verifyFixture(entry, fixturesRoot) {
  if (entry.artifact.kind !== "synthetic-fixture") {
    throw new Error(
      `${entry.sampleId} is metadata-only; provide externally adjudicated predictions instead`,
    );
  }
  const bytes = readFileSync(resolve(fixturesRoot, entry.artifact.fixturePath));
  const digest = sha256Hex(bytes);
  if (digest !== entry.artifact.sha256) {
    throw new Error(`${entry.sampleId} content digest changed after manifest creation`);
  }
  return bytes.toString("utf8");
}

function loadAnalyzer(analyzerPath) {
  const absolute = resolve(analyzerPath);
  const bytes = readFileSync(absolute);
  const require = createRequire(import.meta.url);
  const loaded = require(absolute);
  if (typeof loaded.analyzeScriptAst !== "function") {
    throw new Error("analyzer bundle does not export analyzeScriptAst");
  }
  return {
    analyzeScriptAst: loaded.analyzeScriptAst,
    contentAddress: `sha256:${sha256Hex(bytes)}`,
  };
}

function main() {
  const options = parseArguments(process.argv.slice(2));
  if (options.help) {
    process.stdout.write(`${usage()}\n`);
    return;
  }
  if (!options.reportOutput) throw new Error("--report-output is required");

  const definitionPath = resolve(options.definition);
  const fixturesRoot = resolve(options.fixturesRoot ?? dirname(definitionPath));
  const definition = JSON.parse(readFileSync(definitionPath, "utf8"));
  const manifest = buildCorpusManifest(definition, fixturesRoot);
  const split = createGroupedSplit(manifest, {
    seed: definition.split?.seed,
    ratios: definition.split?.ratios,
  });
  const access = authorizeEvaluationAccess(manifest, split, {
    split: options.split,
    finalEvaluation: options.finalEvaluation,
  });
  const analyzer = loadAnalyzer(options.analyzer);
  const assignmentById = new Map(
    split.assignments.map((assignment) => [assignment.sampleId, assignment.split]),
  );

  const rows = manifest.entries
    .filter((entry) => assignmentById.get(entry.sampleId) === access.split)
    .map((entry) => {
      const sourceText = verifyFixture(entry, fixturesRoot);
      const startedAt = performance.now();
      const analysis = analyzer.analyzeScriptAst(sourceText);
      const durationMs = performance.now() - startedAt;
      const classification = classifyStaticAnalysis(analysis);
      return {
        sampleId: entry.sampleId,
        actual: entry.label.class,
        predicted: classification.predicted,
        score: classification.score,
        finding: classification.finding,
        reasonCodes: classification.reasonCodes,
        obfuscationTier: entry.obfuscation.tier,
        durationMs,
      };
    });

  const report = createEvaluationReport({
    manifest,
    split,
    access,
    rows,
    detector: {
      id: "gcsa-typescript-ast-multisignal-v1",
      contentAddress: analyzer.contentAddress,
      decisionRule:
        "malicious when mining has compute+WebSocket+protocol, or loader has dynamic-code+encoded-payload+remote-load",
    },
    evaluatedAt: new Date().toISOString(),
  });

  const reportPath = writeJson(options.reportOutput, report);
  const protocolPath = options.protocolOutput
    ? writeJson(options.protocolOutput, { manifest, split })
    : null;
  process.stdout.write(
    `${JSON.stringify(
      {
        mode: report.mode,
        releaseEligible: report.releaseEligible,
        evaluatedSplit: report.corpus.evaluatedSplit,
        sampleCount: report.corpus.sampleCount,
        precision: report.metrics.overall.precision,
        recall: report.metrics.overall.recall,
        falsePositiveRate: report.metrics.overall.falsePositiveRate,
        p95Ms: report.metrics.performance.p95Ms,
        holdoutClassification: report.publicHoldout.classification,
        publicHoldoutEvaluated: report.publicHoldout.evaluated,
        sealIsolationVerified: report.publicHoldout.sealIsolationVerified,
        finalEvaluationEligible: report.publicHoldout.finalEvaluationEligible,
        publicHoldoutIntegrityDigest:
          report.publicHoldout.integrityDigestSha256,
        reportPath,
        protocolPath,
      },
      null,
      2,
    )}\n`,
  );
}

try {
  main();
} catch (error) {
  process.stderr.write(
    `script-risk corpus evaluation failed: ${
      error instanceof Error ? error.message : String(error)
    }\n`,
  );
  process.exitCode = 1;
}
