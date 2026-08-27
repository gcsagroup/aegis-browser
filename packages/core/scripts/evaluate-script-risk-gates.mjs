#!/usr/bin/env node

import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createHash } from "node:crypto";
import { dirname, extname, isAbsolute, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
export const DEFAULT_WORKSPACE_DIRECTORY = resolve(scriptDirectory, "../../..");
const MAX_EVIDENCE_BYTES = 1024 * 1024;

const booleanField = Object.freeze({ type: "boolean" });
const numberField = Object.freeze({ type: "number" });
const stringField = Object.freeze({ type: "string" });

const EVIDENCE_SCHEMA = Object.freeze({
  corpus: {
    type: "object",
    fields: {
      manifestSha256: stringField,
      provenanceRecordsComplete: booleanField,
      licenseReviewComplete: booleanField,
      independentLabelReview: booleanField,
      independentReviewerCount: numberField,
      splitLeakageChecked: booleanField,
      syntheticOnly: booleanField,
      realWorldBenignSamples: numberField,
      realWorldMaliciousSamples: numberField,
    },
  },
  sealedTest: {
    type: "object",
    fields: {
      sealVerified: booleanField,
      finalOpened: booleanField,
      candidateFrozenBeforeOpen: booleanField,
      usedForTuning: booleanField,
      sampleCount: numberField,
    },
  },
  metrics: {
    type: "object",
    fields: {
      sampleCount: numberField,
      obfuscatedSampleCount: numberField,
      precision: numberField,
      recall: numberField,
      falsePositiveRate: numberField,
      obfuscatedRecall: numberField,
    },
  },
  performance: {
    type: "object",
    fields: { sampleCount: numberField, p95OverheadPercent: numberField },
  },
  breakage: {
    type: "object",
    fields: { testedSites: numberField, majorBreakages: numberField },
  },
  v8Shadow: {
    type: "object",
    fields: {
      observedFunctions: numberField,
      distinctSites: numberField,
      crashes: numberField,
      wouldBlockCount: numberField,
    },
  },
  safety: {
    type: "object",
    fields: {
      failOpenVerified: booleanField,
      killSwitchVerified: booleanField,
      rollbackVerified: booleanField,
    },
  },
  privacy: {
    type: "object",
    fields: {
      auditComplete: booleanField,
      sourceFreeTelemetryVerified: booleanField,
      boundedRetentionVerified: booleanField,
    },
  },
  optionalComponents: {
    type: "object",
    fields: {
      localModel: {
        type: "object",
        fields: {
          status: {
            type: "enum",
            values: ["disabled", "advisory-only", "validated-advisory"],
          },
          receivesRawSource: booleanField,
          canChangeDecision: booleanField,
        },
      },
      federated: {
        type: "object",
        fields: {
          status: {
            type: "enum",
            values: ["disabled", "simulation-only", "research-validated"],
          },
          retainsRawClientUpdates: booleanField,
          retainsClientIdentifiers: booleanField,
          usedForEnforcement: booleanField,
        },
      },
    },
  },
});

export function usage() {
  return `Usage:
  node packages/core/scripts/evaluate-script-risk-gates.mjs \\
    --evidence <path> --expected-evidence-sha256 <lowercase-sha256> \\
    --output-root <path-under-workspace-.artifacts> \\
    --report-output <path-below-output-root>

The CLI accepts evidence only; gate thresholds are fixed in the core evaluator.
Exit codes: 0 claims-complete, 2 claims-incomplete, 1 invalid input or write failure.
Exit code 0 never grants release or enforcement eligibility.`;
}

export function parseArguments(argv) {
  const options = {};
  const keyByArgument = {
    "--evidence": "evidence",
    "--expected-evidence-sha256": "expectedEvidenceSha256",
    "--output-root": "outputRoot",
    "--report-output": "reportOutput",
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--") continue;
    if (argument === "--help" || argument === "-h") {
      options.help = true;
      continue;
    }
    const key = keyByArgument[argument];
    if (!key) throw new Error(`unknown argument: ${argument}`);
    if (Object.hasOwn(options, key)) {
      throw new Error(`${argument} may be specified only once`);
    }
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) {
      throw new Error(`${argument} requires a value`);
    }
    options[key] = value;
    index += 1;
  }
  return options;
}

function isPlainObject(value) {
  return (
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value) &&
    Object.getPrototypeOf(value) === Object.prototype
  );
}

function validateValue(value, descriptor, path) {
  if (descriptor.type === "boolean") {
    if (typeof value !== "boolean") throw new TypeError(`${path} must be boolean`);
    return;
  }
  if (descriptor.type === "number") {
    if (typeof value !== "number" || !Number.isFinite(value)) {
      throw new TypeError(`${path} must be a finite number`);
    }
    return;
  }
  if (descriptor.type === "string") {
    if (typeof value !== "string") throw new TypeError(`${path} must be string`);
    return;
  }
  if (descriptor.type === "enum") {
    if (typeof value !== "string" || !descriptor.values.includes(value)) {
      throw new TypeError(`${path} has an unsupported value`);
    }
    return;
  }
  if (!isPlainObject(value)) throw new TypeError(`${path} must be an object`);
  validateObject(value, descriptor.fields, path);
}

function validateObject(value, schema, path) {
  for (const key of Object.keys(value)) {
    if (!Object.hasOwn(schema, key)) throw new TypeError(`${path}.${key} is unknown`);
    validateValue(value[key], schema[key], `${path}.${key}`);
  }
}

/** 缺项交给 gate evaluator 判失败；已提供字段必须严格符合白名单 schema。 */
export function validateEvidence(value) {
  if (!isPlainObject(value)) throw new TypeError("evidence must be an object");
  validateObject(value, EVIDENCE_SCHEMA, "evidence");
  return value;
}

function isWithin(parent, candidate) {
  const pathFromParent = relative(parent, candidate);
  return (
    pathFromParent === "" ||
    (!pathFromParent.startsWith(`..${sep}`) &&
      pathFromParent !== ".." &&
      !isAbsolute(pathFromParent))
  );
}

function rejectExistingSymlinks(base, candidate) {
  const pathFromBase = relative(base, candidate);
  if (!isWithin(base, candidate)) throw new Error("path escapes its allowed root");
  let current = base;
  for (const segment of pathFromBase.split(sep).filter(Boolean)) {
    current = resolve(current, segment);
    if (!existsSync(current)) break;
    if (lstatSync(current).isSymbolicLink()) {
      throw new Error(`output path must not contain symlinks: ${current}`);
    }
  }
}

export function resolveReportPath({
  workspaceDirectory = DEFAULT_WORKSPACE_DIRECTORY,
  outputRoot,
  reportOutput,
}) {
  if (!outputRoot) throw new Error("--output-root is required");
  if (!reportOutput) throw new Error("--report-output is required");

  const requestedWorkspace = resolve(workspaceDirectory);
  const workspace = realpathSync(requestedWorkspace);
  const artifactsRoot = resolve(workspace, ".artifacts");
  const requestedOutputRoot = resolve(outputRoot);
  const absoluteOutputRoot = isWithin(requestedWorkspace, requestedOutputRoot)
    ? resolve(workspace, relative(requestedWorkspace, requestedOutputRoot))
    : requestedOutputRoot;
  const requestedReport = isAbsolute(reportOutput)
    ? resolve(reportOutput)
    : resolve(absoluteOutputRoot, reportOutput);
  const absoluteReport = isWithin(requestedWorkspace, requestedReport)
    ? resolve(workspace, relative(requestedWorkspace, requestedReport))
    : requestedReport;

  if (!isWithin(artifactsRoot, absoluteOutputRoot)) {
    throw new Error("--output-root must stay below workspace .artifacts");
  }
  if (!isWithin(absoluteOutputRoot, absoluteReport) || absoluteReport === absoluteOutputRoot) {
    throw new Error("--report-output must stay below --output-root");
  }
  if (extname(absoluteReport) !== ".json") {
    throw new Error("--report-output must use a .json extension");
  }

  rejectExistingSymlinks(workspace, artifactsRoot);
  rejectExistingSymlinks(workspace, absoluteOutputRoot);
  rejectExistingSymlinks(workspace, dirname(absoluteReport));
  if (existsSync(absoluteReport)) {
    throw new Error(`refusing to overwrite existing report: ${absoluteReport}`);
  }
  mkdirSync(dirname(absoluteReport), { recursive: true, mode: 0o700 });
  rejectExistingSymlinks(workspace, dirname(absoluteReport));
  const realArtifactsRoot = realpathSync(artifactsRoot);
  const realOutputRoot = realpathSync(absoluteOutputRoot);
  const realReportParent = realpathSync(dirname(absoluteReport));
  if (
    !isWithin(workspace, realArtifactsRoot) ||
    !isWithin(realArtifactsRoot, realOutputRoot) ||
    !isWithin(realOutputRoot, realReportParent)
  ) {
    throw new Error("resolved output path escapes its allowed root");
  }
  return { absoluteOutputRoot, absoluteReport };
}

export function readEvidence(evidencePath, expectedSha256) {
  if (!evidencePath) throw new Error("--evidence is required");
  if (!/^[a-f0-9]{64}$/.test(expectedSha256 ?? "")) {
    throw new Error("--expected-evidence-sha256 must be 64 lowercase hex characters");
  }
  const absolute = resolve(evidencePath);
  const metadata = statSync(absolute);
  if (!metadata.isFile()) throw new Error("--evidence must name a regular file");
  if (metadata.size > MAX_EVIDENCE_BYTES) {
    throw new Error(`evidence exceeds ${MAX_EVIDENCE_BYTES} bytes`);
  }
  const bytes = readFileSync(absolute);
  const sha256 = createHash("sha256").update(bytes).digest("hex");
  if (sha256 !== expectedSha256) {
    throw new Error("evidence SHA-256 does not match --expected-evidence-sha256");
  }
  return {
    evidence: validateEvidence(JSON.parse(bytes.toString("utf8"))),
    sha256,
  };
}

export function writeStableReport(path, report) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  writeFileSync(path, `${JSON.stringify(report, null, 2)}\n`, {
    encoding: "utf8",
    flag: "wx",
    mode: 0o600,
  });
}

export function evaluateAndWrite({ evidence, evidenceSha256, evaluator, reportPath }) {
  if (!/^[a-f0-9]{64}$/.test(evidenceSha256 ?? "")) {
    throw new Error("a verified evidence SHA-256 is required");
  }
  const claimsAssessment = evaluator(evidence);
  const report = {
    schemaVersion: 1,
    reportKind: "script-risk-research-claims-assessment",
    trustLevel: "unverified-claims",
    authorizationEligible: false,
    enforcementAuthorized: false,
    currentMode: "observe-only",
    wouldBlock: false,
    claimsComplete: claimsAssessment.claimsComplete === true,
    evidenceBinding: {
      algorithm: "sha256",
      evidenceFileSha256: evidenceSha256,
    },
    claimsAssessment,
  };
  writeStableReport(reportPath, report);
  return { report, exitCode: report.claimsComplete ? 0 : 2 };
}

export async function main(argv = process.argv.slice(2)) {
  const options = parseArguments(argv);
  if (options.help) {
    process.stdout.write(`${usage()}\n`);
    return 0;
  }
  const evidenceInput = readEvidence(
    options.evidence,
    options.expectedEvidenceSha256,
  );
  const { absoluteReport } = resolveReportPath({
    outputRoot: options.outputRoot,
    reportOutput: options.reportOutput,
  });
  const { evaluateScriptRiskResearchGate } = await import("../dist/index.js");
  if (typeof evaluateScriptRiskResearchGate !== "function") {
    throw new Error("built core does not export evaluateScriptRiskResearchGate");
  }
  const result = evaluateAndWrite({
    evidence: evidenceInput.evidence,
    evidenceSha256: evidenceInput.sha256,
    evaluator: evaluateScriptRiskResearchGate,
    reportPath: absoluteReport,
  });
  process.stdout.write(
    `${JSON.stringify({
      trustLevel: result.report.trustLevel,
      authorizationEligible: result.report.authorizationEligible,
      claimsComplete: result.report.claimsComplete,
      failedCheckCount: result.report.claimsAssessment.failedChecks.length,
      reportPath: absoluteReport,
    })}\n`,
  );
  return result.exitCode;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main()
    .then((exitCode) => {
      process.exitCode = exitCode;
    })
    .catch((error) => {
      process.stderr.write(
        `script-risk gate evaluation failed: ${
          error instanceof Error ? error.message : String(error)
        }\n`,
      );
      process.exitCode = 1;
    });
}
