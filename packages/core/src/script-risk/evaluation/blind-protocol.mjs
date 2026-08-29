import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import {
  closeSync,
  constants,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  realpathSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { createRequire } from "node:module";
import { dirname, isAbsolute, posix, relative, resolve, sep } from "node:path";

export const BLIND_PROTOCOL_SCHEMA_VERSION = 1;
export const DEFAULT_PROTOCOL_PATH =
  "packages/core/src/script-risk/evaluation/protocols/blind-v1.json";
export const DEFAULT_ANALYZER_PATH =
  "packages/core/dist/script-risk/ast-analyzer.cjs";
export const DEFAULT_CLASSIFIER_PATH =
  "packages/core/src/script-risk/evaluation/corpus-eval.mjs";
export const DEFAULT_CONFIDENCE_BOUNDS_PATH =
  "packages/core/src/script-risk/evaluation/confidence-bounds.mjs";
export const DEFAULT_LOCKFILE_PATH = "pnpm-lock.yaml";

const SHA256_PATTERN = /^[a-f0-9]{64}$/;
const ID_PATTERN = /^[a-z0-9][a-z0-9._-]{2,127}$/;
const LABEL_PATTERN = /^[a-z0-9][a-z0-9._-]{1,63}$/;
const MAX_BOUND_FILE_BYTES = 64 * 1024 * 1024;
const EMPTY_SHA256 = createHash("sha256").update("").digest("hex");

function compareStrings(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

export function assertBlind(condition, message) {
  if (!condition) throw new Error(message);
}

function plainObject(value, field) {
  assertBlind(
    value !== null &&
      typeof value === "object" &&
      !Array.isArray(value) &&
      Object.getPrototypeOf(value) === Object.prototype,
    `${field} must be a plain object`,
  );
  return value;
}

function exactKeys(value, required, optional, field) {
  plainObject(value, field);
  const allowed = new Set([...required, ...optional]);
  for (const key of Object.keys(value)) {
    assertBlind(allowed.has(key), `${field}.${key} is not allowed`);
  }
  for (const key of required) {
    assertBlind(Object.hasOwn(value, key), `${field}.${key} is required`);
  }
  return value;
}

function requiredString(value, field, maxLength = 2_048) {
  assertBlind(typeof value === "string", `${field} must be a string`);
  assertBlind(value.length > 0, `${field} must not be empty`);
  assertBlind(value === value.trim(), `${field} must not contain outer whitespace`);
  assertBlind(value.length <= maxLength, `${field} is too long`);
  return value;
}

function boundedInteger(value, field, minimum, maximum) {
  assertBlind(Number.isSafeInteger(value), `${field} must be an integer`);
  assertBlind(value >= minimum && value <= maximum, `${field} is out of range`);
  return value;
}

function sha256(value, field) {
  const normalized = requiredString(value, field, 64);
  assertBlind(SHA256_PATTERN.test(normalized), `${field} must be lowercase sha256`);
  return normalized;
}

function identifier(value, field) {
  const normalized = requiredString(value, field, 128);
  assertBlind(ID_PATTERN.test(normalized), `${field} is invalid`);
  return normalized;
}

function label(value, field) {
  const normalized = requiredString(value, field, 64);
  assertBlind(LABEL_PATTERN.test(normalized), `${field} is invalid`);
  return normalized;
}

function isoTimestamp(value, field) {
  const normalized = requiredString(value, field, 64);
  const parsed = Date.parse(normalized);
  assertBlind(Number.isFinite(parsed), `${field} must be an ISO timestamp`);
  assertBlind(
    new Date(parsed).toISOString() === normalized,
    `${field} must be normalized UTC ISO-8601`,
  );
  return normalized;
}

function assertTimestampOrder(earlier, earlierField, later, laterField) {
  assertBlind(
    Date.parse(earlier) <= Date.parse(later),
    `${earlierField} must not be after ${laterField}`,
  );
}

function canonicalValue(value) {
  if (value === null || typeof value === "boolean" || typeof value === "string") {
    return value;
  }
  if (typeof value === "number") {
    assertBlind(Number.isFinite(value), "canonical JSON rejects non-finite numbers");
    return value;
  }
  if (Array.isArray(value)) return value.map(canonicalValue);
  plainObject(value, "canonical JSON value");
  const result = {};
  for (const key of Object.keys(value).sort()) {
    assertBlind(value[key] !== undefined, "canonical JSON rejects undefined values");
    result[key] = canonicalValue(value[key]);
  }
  return result;
}

export function canonicalJson(value) {
  return JSON.stringify(canonicalValue(value));
}

export function sha256Hex(value) {
  return createHash("sha256").update(value).digest("hex");
}

export function digestCanonical(value) {
  return sha256Hex(canonicalJson(value));
}

function regularFileBytes(filePath, maximumBytes = MAX_BOUND_FILE_BYTES) {
  const leaf = lstatSync(filePath);
  assertBlind(!leaf.isSymbolicLink(), `${filePath} must not be a symbolic link`);
  const canonical = realpathSync(filePath);
  const stats = statSync(canonical);
  assertBlind(stats.isFile(), `${filePath} must be a regular file`);
  assertBlind(stats.size <= maximumBytes, `${filePath} exceeds the byte limit`);
  return { canonical, bytes: readFileSync(canonical), size: stats.size };
}

function isWithin(parent, candidate) {
  const fromParent = relative(parent, candidate);
  return (
    fromParent === "" ||
    (fromParent !== ".." &&
      !fromParent.startsWith(`..${sep}`) &&
      !isAbsolute(fromParent))
  );
}

export function repositoryFile(repoRoot, requestedPath, field = "repository file") {
  const root = realpathSync(repoRoot);
  const requested = requiredString(requestedPath, field);
  const candidate = resolve(root, requested);
  assertBlind(isWithin(root, candidate), `${field} escapes repository root`);
  const file = regularFileBytes(candidate);
  assertBlind(isWithin(root, file.canonical), `${field} resolves outside repository root`);
  const repoPath = relative(root, file.canonical).split(sep).join("/");
  assertBlind(repoPath.length > 0, `${field} must not be repository root`);
  return { root, absolute: file.canonical, repoPath, bytes: file.bytes };
}

export function readJsonFile(filePath, maximumBytes, field = "JSON input") {
  const file = regularFileBytes(resolve(filePath), maximumBytes);
  try {
    return { path: file.canonical, value: JSON.parse(file.bytes.toString("utf8")) };
  } catch {
    throw new Error(`${field} must contain valid JSON`);
  }
}

export function writeJsonExclusive(outputPath, value) {
  const requested = resolve(requiredString(outputPath, "output path"));
  mkdirSync(dirname(requested), { recursive: true, mode: 0o700 });
  const parent = realpathSync(dirname(requested));
  const absolute = resolve(parent, requested.slice(dirname(requested).length + 1));
  assertBlind(isWithin(parent, absolute), "output path escapes its parent");
  let descriptor;
  try {
    descriptor = openSync(
      absolute,
      constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY,
      0o600,
    );
    writeFileSync(descriptor, `${JSON.stringify(value, null, 2)}\n`, "utf8");
    fsyncSync(descriptor);
    closeSync(descriptor);
    descriptor = undefined;
    return absolute;
  } catch (error) {
    if (descriptor !== undefined) {
      try {
        closeSync(descriptor);
      } catch {
        // Best-effort close before removing only the partial file created here.
      }
      try {
        unlinkSync(absolute);
      } catch {
        // Preserve the original write error.
      }
    }
    if (error && typeof error === "object" && error.code === "EEXIST") {
      throw new Error(`refusing to overwrite existing output: ${absolute}`);
    }
    throw error;
  }
}

function fixedStringArray(value, field, requiredValues) {
  assertBlind(Array.isArray(value), `${field} must be an array`);
  assertBlind(
    value.every((item) => typeof item === "string"),
    `${field} must contain strings`,
  );
  assertBlind(new Set(value).size === value.length, `${field} must be unique`);
  for (const required of requiredValues) {
    assertBlind(value.includes(required), `${field} must include ${required}`);
  }
  return value;
}

export function validateBlindProtocol(protocol) {
  exactKeys(
    protocol,
    [
      "schemaVersion",
      "protocolId",
      "mode",
      "evaluationClass",
      "independence",
      "authorization",
      "schemas",
      "labels",
      "obfuscationTiers",
      "limits",
      "privacy",
      "prohibitedClaims",
      "prohibitedActions",
    ],
    [],
    "protocol",
  );
  assertBlind(
    protocol.schemaVersion === BLIND_PROTOCOL_SCHEMA_VERSION,
    "unsupported blind protocol schemaVersion",
  );
  identifier(protocol.protocolId, "protocol.protocolId");
  assertBlind(protocol.mode === "research-only", "protocol must be research-only");
  assertBlind(
    protocol.evaluationClass === "operator-blinded-local",
    "protocol must remain operator-blinded-local",
  );

  exactKeys(
    protocol.independence,
    [
      "operatorMayControlCandidateAndEvaluation",
      "independentSampleHolderRequired",
      "independentSealVerified",
      "finalEvaluationEligible",
    ],
    [],
    "protocol.independence",
  );
  assertBlind(
    protocol.independence.operatorMayControlCandidateAndEvaluation === true &&
      protocol.independence.independentSampleHolderRequired === false &&
      protocol.independence.independentSealVerified === false &&
      protocol.independence.finalEvaluationEligible === false,
    "operator-blinded-local must not claim independent sealing",
  );

  exactKeys(
    protocol.authorization,
    [
      "releaseEligible",
      "enforcementAuthorized",
      "pagePathBlockingAuthorized",
    ],
    [],
    "protocol.authorization",
  );
  assertBlind(
    protocol.authorization.releaseEligible === false &&
      protocol.authorization.enforcementAuthorized === false &&
      protocol.authorization.pagePathBlockingAuthorized === false,
    "blind research protocol cannot authorize release or blocking",
  );

  exactKeys(
    protocol.schemas,
    [
      "candidateLock",
      "predictionEnvelope",
      "predictionOutput",
      "labelEnvelope",
      "scoreReport",
    ],
    [],
    "protocol.schemas",
  );
  for (const [name, value] of Object.entries(protocol.schemas)) {
    requiredString(value, `protocol.schemas.${name}`, 128);
  }
  assertBlind(
    canonicalJson(protocol.schemas) ===
      canonicalJson({
        candidateLock: "gcsa-script-risk-candidate-lock/v1",
        predictionEnvelope: "gcsa-script-risk-blind-envelope/v1",
        predictionOutput: "gcsa-script-risk-blind-predictions/v1",
        labelEnvelope: "gcsa-script-risk-blind-labels/v1",
        scoreReport: "gcsa-script-risk-blind-score/v1",
      }),
    "protocol artifact schemas do not match blind-v1",
  );

  exactKeys(
    protocol.labels,
    [
      "positiveLabel",
      "negativeLabel",
      "classifierPositiveValue",
      "classifierNegativeValue",
    ],
    [],
    "protocol.labels",
  );
  const positiveLabel = label(protocol.labels.positiveLabel, "protocol.labels.positiveLabel");
  const negativeLabel = label(protocol.labels.negativeLabel, "protocol.labels.negativeLabel");
  assertBlind(positiveLabel !== negativeLabel, "protocol labels must be distinct");
  const classifierPositive = label(
    protocol.labels.classifierPositiveValue,
    "protocol.labels.classifierPositiveValue",
  );
  const classifierNegative = label(
    protocol.labels.classifierNegativeValue,
    "protocol.labels.classifierNegativeValue",
  );
  assertBlind(
    classifierPositive !== classifierNegative,
    "classifier output values must be distinct",
  );

  fixedStringArray(protocol.obfuscationTiers, "protocol.obfuscationTiers", [
    "none",
    "minified",
    "identifier-renamed",
    "string-encoded",
    "control-flow",
  ]);
  for (const [index, tier] of protocol.obfuscationTiers.entries()) {
    label(tier, `protocol.obfuscationTiers[${index}]`);
  }

  exactKeys(
    protocol.limits,
    [
      "maxJsonBytes",
      "maxSamples",
      "maxFilesPerSample",
      "maxSourceBytesPerFile",
      "maxSourceBytesPerSample",
      "sampleWorkerTimeoutMs",
      "workerMaxOldGenerationSizeMb",
      "workerMaxYoungGenerationSizeMb",
      "workerStackSizeMb",
    ],
    [],
    "protocol.limits",
  );
  boundedInteger(protocol.limits.maxJsonBytes, "protocol.limits.maxJsonBytes", 1_024, 64 * 1024 * 1024);
  boundedInteger(protocol.limits.maxSamples, "protocol.limits.maxSamples", 1, 10_000);
  boundedInteger(protocol.limits.maxFilesPerSample, "protocol.limits.maxFilesPerSample", 1, 128);
  boundedInteger(
    protocol.limits.maxSourceBytesPerFile,
    "protocol.limits.maxSourceBytesPerFile",
    1,
    2_000_000,
  );
  boundedInteger(
    protocol.limits.maxSourceBytesPerSample,
    "protocol.limits.maxSourceBytesPerSample",
    protocol.limits.maxSourceBytesPerFile,
    32_000_000,
  );
  boundedInteger(protocol.limits.sampleWorkerTimeoutMs, "protocol.limits.sampleWorkerTimeoutMs", 100, 60_000);
  boundedInteger(
    protocol.limits.workerMaxOldGenerationSizeMb,
    "protocol.limits.workerMaxOldGenerationSizeMb",
    32,
    1_024,
  );
  boundedInteger(
    protocol.limits.workerMaxYoungGenerationSizeMb,
    "protocol.limits.workerMaxYoungGenerationSizeMb",
    4,
    256,
  );
  boundedInteger(protocol.limits.workerStackSizeMb, "protocol.limits.workerStackSizeMb", 1, 16);

  exactKeys(
    protocol.privacy,
    [
      "predictionInputGroundTruthAllowed",
      "predictionOutputSourceAllowed",
      "predictionOutputGroundTruthAllowed",
    ],
    [],
    "protocol.privacy",
  );
  assertBlind(
    protocol.privacy.predictionInputGroundTruthAllowed === false &&
      protocol.privacy.predictionOutputSourceAllowed === false &&
      protocol.privacy.predictionOutputGroundTruthAllowed === false,
    "blind prediction privacy fields must remain false",
  );
  fixedStringArray(protocol.prohibitedClaims, "protocol.prohibitedClaims", [
    "independent-sealed-test",
    "final-evaluation",
    "release-authorization",
    "page-path-blocking-authorization",
    "general-malicious-javascript-protection",
  ]);
  fixedStringArray(protocol.prohibitedActions, "protocol.prohibitedActions", [
    "execute-sample-source",
    "download-live-malware",
    "enable-page-path-blocking",
    "use-final-flag",
  ]);
  return true;
}

export function loadBlindProtocol(repoRoot, protocolPath = DEFAULT_PROTOCOL_PATH) {
  const file = repositoryFile(repoRoot, protocolPath, "protocol path");
  assertBlind(
    file.repoPath === DEFAULT_PROTOCOL_PATH,
    `protocol path must be ${DEFAULT_PROTOCOL_PATH}`,
  );
  const protocol = JSON.parse(file.bytes.toString("utf8"));
  validateBlindProtocol(protocol);
  return {
    protocol,
    path: file.repoPath,
    absolute: file.absolute,
    sha256: sha256Hex(file.bytes),
  };
}

function runGit(repoRoot, args) {
  try {
    return execFileSync("git", args, {
      cwd: repoRoot,
      encoding: null,
      maxBuffer: 128 * 1024 * 1024,
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch {
    throw new Error(`git ${args.join(" ")} failed`);
  }
}

function gitText(repoRoot, args, field) {
  const value = runGit(repoRoot, args).toString("utf8").trim();
  requiredString(value, field, 512);
  return value;
}

export function captureRepositoryState(repoRoot) {
  const root = realpathSync(repoRoot);
  const topLevel = realpathSync(gitText(root, ["rev-parse", "--show-toplevel"], "git root"));
  assertBlind(root === topLevel, "repo root must be the Git top level");
  const commitSha = gitText(root, ["rev-parse", "HEAD"], "git commit");
  const treeSha = gitText(root, ["rev-parse", "HEAD^{tree}"], "git tree");
  assertBlind(/^[a-f0-9]{40,64}$/.test(commitSha), "git commit is invalid");
  assertBlind(/^[a-f0-9]{40,64}$/.test(treeSha), "git tree is invalid");

  const status = runGit(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]);
  const trackedDiff = runGit(root, ["diff", "--binary", "HEAD", "--"]);
  const stagedDiff = runGit(root, ["diff", "--cached", "--binary", "--"]);
  const untrackedOutput = runGit(root, ["ls-files", "--others", "--exclude-standard", "-z"]);
  const untrackedPaths = untrackedOutput
    .toString("utf8")
    .split("\0")
    .filter(Boolean)
    .sort();
  const untracked = untrackedPaths.map((repoPath) => {
    const file = repositoryFile(root, repoPath, "untracked path");
    assertBlind(file.repoPath === repoPath, "untracked path must be canonical");
    return {
      path: repoPath,
      byteLength: file.bytes.length,
      sha256: sha256Hex(file.bytes),
    };
  });
  return {
    commitSha,
    treeSha,
    dirty: status.length > 0,
    statusSha256: status.length === 0 ? EMPTY_SHA256 : sha256Hex(status),
    trackedDiffSha256:
      trackedDiff.length === 0 ? EMPTY_SHA256 : sha256Hex(trackedDiff),
    stagedDiffSha256:
      stagedDiff.length === 0 ? EMPTY_SHA256 : sha256Hex(stagedDiff),
    untrackedCount: untracked.length,
    untrackedDigestSha256: digestCanonical(untracked),
  };
}

function typescriptIdentity(repoRoot) {
  const require = createRequire(resolve(repoRoot, "packages/core/package.json"));
  let manifestPath;
  try {
    manifestPath = require.resolve("typescript/package.json");
  } catch {
    throw new Error("cannot resolve TypeScript package from packages/core");
  }
  const file = repositoryFile(repoRoot, manifestPath, "TypeScript package manifest");
  const manifest = JSON.parse(file.bytes.toString("utf8"));
  const version = requiredString(manifest.version, "TypeScript version", 64);
  return {
    version,
    packageManifestPath: file.repoPath,
    packageManifestSha256: sha256Hex(file.bytes),
  };
}

export function createCandidateLock({
  repoRoot,
  candidateId,
  analyzerPath = DEFAULT_ANALYZER_PATH,
  classifierPath = DEFAULT_CLASSIFIER_PATH,
  protocolPath = DEFAULT_PROTOCOL_PATH,
  lockfilePath = DEFAULT_LOCKFILE_PATH,
  frozenAt = new Date().toISOString(),
}) {
  const root = realpathSync(repoRoot);
  const protocol = loadBlindProtocol(root, protocolPath);
  const analyzer = repositoryFile(root, analyzerPath, "analyzer bundle path");
  const classifier = repositoryFile(root, classifierPath, "classification rules path");
  const confidenceBounds = repositoryFile(
    root,
    DEFAULT_CONFIDENCE_BOUNDS_PATH,
    "confidence bounds path",
  );
  const lockfile = repositoryFile(root, lockfilePath, "pnpm lockfile path");
  assertBlind(
    analyzer.repoPath === DEFAULT_ANALYZER_PATH,
    `analyzer bundle path must be ${DEFAULT_ANALYZER_PATH}`,
  );
  assertBlind(
    classifier.repoPath === DEFAULT_CLASSIFIER_PATH,
    `classification rules path must be ${DEFAULT_CLASSIFIER_PATH}`,
  );
  assertBlind(
    lockfile.repoPath === DEFAULT_LOCKFILE_PATH,
    `lockfile path must be ${DEFAULT_LOCKFILE_PATH}`,
  );
  const typescript = typescriptIdentity(root);
  const unsigned = {
    schema: protocol.protocol.schemas.candidateLock,
    schemaVersion: BLIND_PROTOCOL_SCHEMA_VERSION,
    mode: "research-only",
    evaluationClass: "operator-blinded-local",
    candidateId: identifier(candidateId, "candidateId"),
    frozenAt: isoTimestamp(frozenAt, "frozenAt"),
    protocol: {
      id: protocol.protocol.protocolId,
      path: protocol.path,
      sha256: protocol.sha256,
    },
    detector: {
      analyzerBundle: {
        path: analyzer.repoPath,
        sha256: sha256Hex(analyzer.bytes),
      },
      classificationRules: {
        path: classifier.repoPath,
        sha256: sha256Hex(classifier.bytes),
        exportName: "classifyStaticAnalysis",
      },
      confidenceBounds: {
        path: confidenceBounds.repoPath,
        sha256: sha256Hex(confidenceBounds.bytes),
        method: "clopper-pearson-exact-one-sided",
        confidenceLevel: 0.95,
      },
    },
    dependencyLock: {
      path: lockfile.repoPath,
      sha256: sha256Hex(lockfile.bytes),
    },
    runtime: {
      nodeVersion: process.versions.node,
      nodeAbi: process.versions.modules,
      v8Version: process.versions.v8,
      platform: process.platform,
      architecture: process.arch,
      typescript,
    },
    repository: captureRepositoryState(root),
    authorization: {
      releaseEligible: false,
      enforcementAuthorized: false,
      pagePathBlockingAuthorized: false,
      finalEvaluationEligible: false,
      independentSealVerified: false,
    },
  };
  const candidate = {
    ...unsigned,
    candidateDigestSha256: digestCanonical(unsigned),
  };
  validateCandidateLock(candidate, protocol.protocol);
  return candidate;
}

function validateRepositoryState(value, field) {
  exactKeys(
    value,
    [
      "commitSha",
      "treeSha",
      "dirty",
      "statusSha256",
      "trackedDiffSha256",
      "stagedDiffSha256",
      "untrackedCount",
      "untrackedDigestSha256",
    ],
    [],
    field,
  );
  assertBlind(/^[a-f0-9]{40,64}$/.test(value.commitSha), `${field}.commitSha is invalid`);
  assertBlind(/^[a-f0-9]{40,64}$/.test(value.treeSha), `${field}.treeSha is invalid`);
  assertBlind(typeof value.dirty === "boolean", `${field}.dirty must be boolean`);
  sha256(value.statusSha256, `${field}.statusSha256`);
  sha256(value.trackedDiffSha256, `${field}.trackedDiffSha256`);
  sha256(value.stagedDiffSha256, `${field}.stagedDiffSha256`);
  boundedInteger(value.untrackedCount, `${field}.untrackedCount`, 0, 1_000_000);
  sha256(value.untrackedDigestSha256, `${field}.untrackedDigestSha256`);
}

export function validateCandidateLock(candidate, protocol) {
  validateBlindProtocol(protocol);
  exactKeys(
    candidate,
    [
      "schema",
      "schemaVersion",
      "mode",
      "evaluationClass",
      "candidateId",
      "frozenAt",
      "protocol",
      "detector",
      "dependencyLock",
      "runtime",
      "repository",
      "authorization",
      "candidateDigestSha256",
    ],
    [],
    "candidate",
  );
  assertBlind(candidate.schema === protocol.schemas.candidateLock, "candidate schema mismatch");
  assertBlind(candidate.schemaVersion === 1, "candidate schemaVersion mismatch");
  assertBlind(candidate.mode === "research-only", "candidate must be research-only");
  assertBlind(
    candidate.evaluationClass === "operator-blinded-local",
    "candidate evaluationClass mismatch",
  );
  identifier(candidate.candidateId, "candidate.candidateId");
  isoTimestamp(candidate.frozenAt, "candidate.frozenAt");

  exactKeys(candidate.protocol, ["id", "path", "sha256"], [], "candidate.protocol");
  assertBlind(candidate.protocol.id === protocol.protocolId, "candidate protocol id mismatch");
  assertBlind(candidate.protocol.path === DEFAULT_PROTOCOL_PATH, "candidate protocol path mismatch");
  sha256(candidate.protocol.sha256, "candidate.protocol.sha256");

  exactKeys(
    candidate.detector,
    ["analyzerBundle", "classificationRules", "confidenceBounds"],
    [],
    "candidate.detector",
  );
  exactKeys(
    candidate.detector.analyzerBundle,
    ["path", "sha256"],
    [],
    "candidate.detector.analyzerBundle",
  );
  assertBlind(
    candidate.detector.analyzerBundle.path === DEFAULT_ANALYZER_PATH,
    "candidate analyzer bundle path mismatch",
  );
  sha256(candidate.detector.analyzerBundle.sha256, "candidate analyzer sha256");
  exactKeys(
    candidate.detector.classificationRules,
    ["path", "sha256", "exportName"],
    [],
    "candidate.detector.classificationRules",
  );
  assertBlind(
    candidate.detector.classificationRules.path === DEFAULT_CLASSIFIER_PATH &&
      candidate.detector.classificationRules.exportName === "classifyStaticAnalysis",
    "candidate classification rule binding mismatch",
  );
  sha256(candidate.detector.classificationRules.sha256, "candidate classification sha256");
  exactKeys(
    candidate.detector.confidenceBounds,
    ["path", "sha256", "method", "confidenceLevel"],
    [],
    "candidate.detector.confidenceBounds",
  );
  assertBlind(
    candidate.detector.confidenceBounds.path === DEFAULT_CONFIDENCE_BOUNDS_PATH &&
      candidate.detector.confidenceBounds.method ===
        "clopper-pearson-exact-one-sided" &&
      candidate.detector.confidenceBounds.confidenceLevel === 0.95,
    "candidate confidence bounds binding mismatch",
  );
  sha256(
    candidate.detector.confidenceBounds.sha256,
    "candidate confidence bounds sha256",
  );

  exactKeys(candidate.dependencyLock, ["path", "sha256"], [], "candidate.dependencyLock");
  assertBlind(candidate.dependencyLock.path === DEFAULT_LOCKFILE_PATH, "candidate lockfile path mismatch");
  sha256(candidate.dependencyLock.sha256, "candidate.dependencyLock.sha256");

  exactKeys(
    candidate.runtime,
    [
      "nodeVersion",
      "nodeAbi",
      "v8Version",
      "platform",
      "architecture",
      "typescript",
    ],
    [],
    "candidate.runtime",
  );
  for (const key of ["nodeVersion", "nodeAbi", "v8Version", "platform", "architecture"]) {
    requiredString(candidate.runtime[key], `candidate.runtime.${key}`, 128);
  }
  exactKeys(
    candidate.runtime.typescript,
    ["version", "packageManifestPath", "packageManifestSha256"],
    [],
    "candidate.runtime.typescript",
  );
  requiredString(candidate.runtime.typescript.version, "candidate.runtime.typescript.version", 64);
  requiredString(
    candidate.runtime.typescript.packageManifestPath,
    "candidate.runtime.typescript.packageManifestPath",
  );
  sha256(
    candidate.runtime.typescript.packageManifestSha256,
    "candidate.runtime.typescript.packageManifestSha256",
  );
  validateRepositoryState(candidate.repository, "candidate.repository");

  exactKeys(
    candidate.authorization,
    [
      "releaseEligible",
      "enforcementAuthorized",
      "pagePathBlockingAuthorized",
      "finalEvaluationEligible",
      "independentSealVerified",
    ],
    [],
    "candidate.authorization",
  );
  assertBlind(
    Object.values(candidate.authorization).every((value) => value === false),
    "candidate cannot authorize release, blocking, or final evaluation",
  );
  const { candidateDigestSha256, ...unsigned } = candidate;
  sha256(candidateDigestSha256, "candidate.candidateDigestSha256");
  assertBlind(
    digestCanonical(unsigned) === candidateDigestSha256,
    "candidate digest mismatch",
  );
  return true;
}

function verifyBoundFile(repoRoot, binding, field) {
  const file = repositoryFile(repoRoot, binding.path, `${field}.path`);
  assertBlind(file.repoPath === binding.path, `${field}.path is not canonical`);
  assertBlind(sha256Hex(file.bytes) === binding.sha256, `${field} digest mismatch`);
  return file;
}

export function verifyCandidateEnvironment(repoRoot, candidate) {
  const protocolFile = loadBlindProtocol(repoRoot, candidate?.protocol?.path);
  validateCandidateLock(candidate, protocolFile.protocol);
  assertBlind(
    protocolFile.sha256 === candidate.protocol.sha256,
    "candidate protocol file digest mismatch",
  );
  const analyzer = verifyBoundFile(
    repoRoot,
    candidate.detector.analyzerBundle,
    "analyzer bundle",
  );
  const classifier = verifyBoundFile(
    repoRoot,
    candidate.detector.classificationRules,
    "classification rules",
  );
  const confidenceBounds = verifyBoundFile(
    repoRoot,
    candidate.detector.confidenceBounds,
    "confidence bounds",
  );
  verifyBoundFile(repoRoot, candidate.dependencyLock, "pnpm lockfile");
  const typescript = typescriptIdentity(realpathSync(repoRoot));
  assertBlind(
    canonicalJson(typescript) === canonicalJson(candidate.runtime.typescript),
    "TypeScript identity mismatch",
  );
  const currentRuntime = {
    nodeVersion: process.versions.node,
    nodeAbi: process.versions.modules,
    v8Version: process.versions.v8,
    platform: process.platform,
    architecture: process.arch,
  };
  for (const [key, value] of Object.entries(currentRuntime)) {
    assertBlind(value === candidate.runtime[key], `runtime ${key} mismatch`);
  }
  const repository = captureRepositoryState(repoRoot);
  assertBlind(
    canonicalJson(repository) === canonicalJson(candidate.repository),
    "repository state changed after candidate freeze",
  );
  return {
    protocol: protocolFile.protocol,
    protocolSha256: protocolFile.sha256,
    // 后续执行只能使用这些固定字节，不能再按仓库路径或临时快照路径加载组件。
    components: {
      analyzer: {
        bytes: Buffer.from(analyzer.bytes),
        sha256: candidate.detector.analyzerBundle.sha256,
      },
      classifier: {
        bytes: Buffer.from(classifier.bytes),
        sha256: candidate.detector.classificationRules.sha256,
      },
      confidenceBounds: {
        bytes: Buffer.from(confidenceBounds.bytes),
        sha256: candidate.detector.confidenceBounds.sha256,
      },
    },
  };
}

export function verifiedCandidateComponentBytes(component, name) {
  assertBlind(Buffer.isBuffer(component?.bytes), `${name} bytes are unavailable`);
  const bytes = Buffer.from(component.bytes);
  const digest = sha256(component.sha256, `${name} sha256`);
  assertBlind(
    sha256Hex(bytes) === digest,
    `${name} fixed bytes do not match the candidate digest`,
  );
  return { bytes, sha256: digest };
}

/**
 * 从已经验证的固定字节导入 ESM。data URL 的模块内容直接来自内存，既不创建临时文件，
 * 也不会在摘要校验后再次读取候选组件路径。
 */
export async function importVerifiedCandidateModule(component, name) {
  const verified = verifiedCandidateComponentBytes(component, name);
  const moduleUrl =
    `data:text/javascript;base64,${verified.bytes.toString("base64")}` +
    `#sha256=${verified.sha256}`;
  return import(moduleUrl);
}

function logicalFilePath(value, field) {
  const normalized = requiredString(value, field, 512);
  assertBlind(!normalized.includes("\\"), `${field} must use POSIX separators`);
  assertBlind(!/[\u0000-\u001f\u007f]/.test(normalized), `${field} contains control characters`);
  assertBlind(!normalized.startsWith("/"), `${field} must be relative`);
  assertBlind(posix.normalize(normalized) === normalized, `${field} is not canonical`);
  assertBlind(
    normalized !== "." &&
      normalized !== ".." &&
      !normalized.startsWith("../") &&
      !normalized.includes("/../"),
    `${field} escapes the sample bundle`,
  );
  return normalized;
}

function decodeCanonicalBase64(value, field) {
  assertBlind(typeof value === "string", `${field} must be a string`);
  assertBlind(
    /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value),
    `${field} is not canonical base64`,
  );
  const bytes = Buffer.from(value, "base64");
  assertBlind(bytes.toString("base64") === value, `${field} is not canonical base64`);
  return bytes;
}

function bundleContentAddress(files) {
  return `sha256:${digestCanonical(
    files.map(({ path, sha256: digest, byteLength }) => ({
      path,
      sha256: digest,
      byteLength,
    })),
  )}`;
}

function validatePublicPilotProvenance(value, field) {
  exactKeys(
    value,
    [
      "datasetId",
      "definitionSha256",
      "planSha256",
      "receiptSha256",
      "publiclyInspectable",
      "independentLabelReview",
      "sealed",
    ],
    [],
    field,
  );
  identifier(value.datasetId, `${field}.datasetId`);
  sha256(value.definitionSha256, `${field}.definitionSha256`);
  sha256(value.planSha256, `${field}.planSha256`);
  sha256(value.receiptSha256, `${field}.receiptSha256`);
  assertBlind(
    value.publiclyInspectable === true &&
      value.independentLabelReview === false &&
      value.sealed === false,
    `${field} must remain public, unsealed, and not independently labelled`,
  );
  return value;
}

export function buildBlindEnvelope({
  protocol,
  protocolSha256,
  candidateDigestSha256,
  envelopeId,
  createdAt = new Date().toISOString(),
  samples,
  publicPilot,
}) {
  validateBlindProtocol(protocol);
  assertBlind(Array.isArray(samples), "samples must be an array");
  const encodedSamples = samples.map((sample) => {
    assertBlind(Array.isArray(sample.files), `${sample.sampleId}.files must be an array`);
    const files = sample.files
      .map((file) => {
        assertBlind(
          Buffer.isBuffer(file.source) || typeof file.source === "string",
          `${sample.sampleId}.${file.path}.source must be a Buffer or string`,
        );
        const bytes = Buffer.from(file.source);
        return {
          path: logicalFilePath(file.path, `${sample.sampleId}.file.path`),
          sha256: sha256Hex(bytes),
          byteLength: bytes.length,
          sourceBase64: bytes.toString("base64"),
        };
      })
      .sort((left, right) => compareStrings(left.path, right.path));
    return {
      sampleId: identifier(sample.sampleId, "sample.sampleId"),
      contentAddress: bundleContentAddress(files),
      files,
    };
  }).sort((left, right) => compareStrings(left.sampleId, right.sampleId));
  const unsigned = {
    schema: protocol.schemas.predictionEnvelope,
    schemaVersion: 1,
    protocolId: protocol.protocolId,
    protocolSha256: sha256(protocolSha256, "protocolSha256"),
    candidateDigestSha256: sha256(candidateDigestSha256, "candidateDigestSha256"),
    envelopeId: identifier(envelopeId, "envelopeId"),
    createdAt: isoTimestamp(createdAt, "createdAt"),
    labelAccess: "unavailable-to-predictor",
    labelsIncluded: false,
    ...(publicPilot
      ? {
          publicPilot: validatePublicPilotProvenance(
            structuredClone(publicPilot),
            "publicPilot",
          ),
        }
      : {}),
    samples: encodedSamples,
  };
  const result = { ...unsigned, envelopeDigestSha256: digestCanonical(unsigned) };
  validatePredictionEnvelope(result, protocol, {
    protocolSha256,
    candidateDigestSha256,
  });
  return result;
}

export function validatePredictionEnvelope(
  envelope,
  protocol,
  { protocolSha256, candidateDigestSha256 },
) {
  validateBlindProtocol(protocol);
  exactKeys(
    envelope,
    [
      "schema",
      "schemaVersion",
      "protocolId",
      "protocolSha256",
      "candidateDigestSha256",
      "envelopeId",
      "createdAt",
      "labelAccess",
      "labelsIncluded",
      "samples",
      "envelopeDigestSha256",
    ],
    ["publicPilot"],
    "prediction envelope",
  );
  assertBlind(envelope.schema === protocol.schemas.predictionEnvelope, "prediction envelope schema mismatch");
  assertBlind(envelope.schemaVersion === 1, "prediction envelope schemaVersion mismatch");
  assertBlind(envelope.protocolId === protocol.protocolId, "prediction envelope protocol mismatch");
  assertBlind(envelope.protocolSha256 === protocolSha256, "prediction envelope protocol digest mismatch");
  assertBlind(
    envelope.candidateDigestSha256 === candidateDigestSha256,
    "prediction envelope candidate mismatch",
  );
  identifier(envelope.envelopeId, "prediction envelope.envelopeId");
  isoTimestamp(envelope.createdAt, "prediction envelope.createdAt");
  assertBlind(
    envelope.labelAccess === "unavailable-to-predictor" &&
      envelope.labelsIncluded === false,
    "prediction envelope must not expose labels",
  );
  if (envelope.publicPilot !== undefined) {
    validatePublicPilotProvenance(
      envelope.publicPilot,
      "prediction envelope.publicPilot",
    );
  }
  assertBlind(Array.isArray(envelope.samples), "prediction envelope.samples must be an array");
  boundedInteger(
    envelope.samples.length,
    "prediction envelope sample count",
    1,
    protocol.limits.maxSamples,
  );
  const seenSamples = new Set();
  let previousSampleId = "";
  for (const [sampleIndex, sample] of envelope.samples.entries()) {
    const field = `prediction envelope.samples[${sampleIndex}]`;
    exactKeys(sample, ["sampleId", "contentAddress", "files"], [], field);
    const sampleId = identifier(sample.sampleId, `${field}.sampleId`);
    assertBlind(!seenSamples.has(sampleId), `duplicate sampleId: ${sampleId}`);
    assertBlind(previousSampleId < sampleId, "prediction envelope samples must be sorted");
    previousSampleId = sampleId;
    seenSamples.add(sampleId);
    assertBlind(Array.isArray(sample.files), `${field}.files must be an array`);
    boundedInteger(sample.files.length, `${field}.files length`, 1, protocol.limits.maxFilesPerSample);
    const seenPaths = new Set();
    let previousPath = "";
    let totalBytes = 0;
    for (const [fileIndex, file] of sample.files.entries()) {
      const fileField = `${field}.files[${fileIndex}]`;
      exactKeys(file, ["path", "sha256", "byteLength", "sourceBase64"], [], fileField);
      const filePath = logicalFilePath(file.path, `${fileField}.path`);
      assertBlind(!seenPaths.has(filePath), `${sampleId} has duplicate file path`);
      assertBlind(previousPath < filePath, `${sampleId} files must be sorted`);
      previousPath = filePath;
      seenPaths.add(filePath);
      const bytes = decodeCanonicalBase64(file.sourceBase64, `${fileField}.sourceBase64`);
      boundedInteger(
        file.byteLength,
        `${fileField}.byteLength`,
        0,
        protocol.limits.maxSourceBytesPerFile,
      );
      assertBlind(bytes.length === file.byteLength, `${fileField} byteLength mismatch`);
      assertBlind(sha256Hex(bytes) === sha256(file.sha256, `${fileField}.sha256`), `${fileField} digest mismatch`);
      // Fatal UTF-8 decoding prevents platform-dependent replacement characters.
      new TextDecoder("utf-8", { fatal: true }).decode(bytes);
      totalBytes += bytes.length;
    }
    assertBlind(totalBytes <= protocol.limits.maxSourceBytesPerSample, `${sampleId} exceeds sample byte limit`);
    assertBlind(sample.contentAddress === bundleContentAddress(sample.files), `${sampleId} bundle digest mismatch`);
  }
  const { envelopeDigestSha256, ...unsigned } = envelope;
  sha256(envelopeDigestSha256, "prediction envelope.envelopeDigestSha256");
  assertBlind(digestCanonical(unsigned) === envelopeDigestSha256, "prediction envelope digest mismatch");
  return true;
}

function validatePredictionRow(row, field, protocol) {
  exactKeys(
    row,
    [
      "sampleId",
      "contentAddress",
      "predictedLabel",
      "score",
      "finding",
      "reasonCodes",
      "durationMs",
      "filesAnalyzed",
    ],
    [],
    field,
  );
  identifier(row.sampleId, `${field}.sampleId`);
  assertBlind(/^sha256:[a-f0-9]{64}$/.test(row.contentAddress), `${field}.contentAddress is invalid`);
  assertBlind(
    [protocol.labels.positiveLabel, protocol.labels.negativeLabel].includes(row.predictedLabel),
    `${field}.predictedLabel is invalid`,
  );
  assertBlind(Number.isFinite(row.score) && row.score >= 0 && row.score <= 100, `${field}.score is invalid`);
  assertBlind(row.finding === null || typeof row.finding === "string", `${field}.finding is invalid`);
  assertBlind(Array.isArray(row.reasonCodes), `${field}.reasonCodes must be an array`);
  assertBlind(
    row.reasonCodes.every((value) => typeof value === "string") &&
      new Set(row.reasonCodes).size === row.reasonCodes.length &&
      canonicalJson([...row.reasonCodes].sort()) === canonicalJson(row.reasonCodes),
    `${field}.reasonCodes must be unique sorted strings`,
  );
  assertBlind(Number.isFinite(row.durationMs) && row.durationMs >= 0, `${field}.durationMs is invalid`);
  boundedInteger(row.filesAnalyzed, `${field}.filesAnalyzed`, 1, protocol.limits.maxFilesPerSample);
}

export function validatePredictionOutput(output, protocol, candidate, envelope) {
  validateCandidateLock(candidate, protocol);
  validatePredictionEnvelope(envelope, protocol, {
    protocolSha256: candidate.protocol.sha256,
    candidateDigestSha256: candidate.candidateDigestSha256,
  });
  exactKeys(
    output,
    [
      "schema",
      "schemaVersion",
      "mode",
      "evaluationClass",
      "independentSealVerified",
      "releaseEligible",
      "enforcementAuthorized",
      "protocolId",
      "protocolSha256",
      "candidateDigestSha256",
      "inputEnvelopeId",
      "inputEnvelopeDigestSha256",
      "predictedAt",
      "rows",
      "predictionDigestSha256",
    ],
    ["publicPilot"],
    "prediction output",
  );
  assertBlind(output.schema === protocol.schemas.predictionOutput, "prediction output schema mismatch");
  assertBlind(output.schemaVersion === 1, "prediction output schemaVersion mismatch");
  assertBlind(
    output.mode === "research-only" && output.evaluationClass === "operator-blinded-local",
    "prediction output classification mismatch",
  );
  assertBlind(
    output.independentSealVerified === false &&
      output.releaseEligible === false &&
      output.enforcementAuthorized === false,
    "prediction output cannot authorize release or enforcement",
  );
  assertBlind(output.protocolId === protocol.protocolId, "prediction output protocol id mismatch");
  assertBlind(output.protocolSha256 === candidate.protocol.sha256, "prediction output protocol digest mismatch");
  assertBlind(output.candidateDigestSha256 === candidate.candidateDigestSha256, "prediction output candidate mismatch");
  assertBlind(output.inputEnvelopeId === envelope.envelopeId, "prediction output envelope id mismatch");
  assertBlind(
    output.inputEnvelopeDigestSha256 === envelope.envelopeDigestSha256,
    "prediction output envelope digest mismatch",
  );
  isoTimestamp(output.predictedAt, "prediction output.predictedAt");
  assertTimestampOrder(
    candidate.frozenAt,
    "candidate.frozenAt",
    envelope.createdAt,
    "prediction envelope.createdAt",
  );
  assertTimestampOrder(
    envelope.createdAt,
    "prediction envelope.createdAt",
    output.predictedAt,
    "prediction output.predictedAt",
  );
  if (envelope.publicPilot === undefined) {
    assertBlind(output.publicPilot === undefined, "unexpected prediction public pilot provenance");
  } else {
    validatePublicPilotProvenance(
      output.publicPilot,
      "prediction output.publicPilot",
    );
    assertBlind(
      canonicalJson(output.publicPilot) === canonicalJson(envelope.publicPilot),
      "prediction public pilot provenance mismatch",
    );
  }
  assertBlind(Array.isArray(output.rows), "prediction output.rows must be an array");
  assertBlind(output.rows.length === envelope.samples.length, "prediction output row count mismatch");
  for (let index = 0; index < output.rows.length; index += 1) {
    const row = output.rows[index];
    const sample = envelope.samples[index];
    validatePredictionRow(row, `prediction output.rows[${index}]`, protocol);
    assertBlind(row.sampleId === sample.sampleId, "prediction output sample order mismatch");
    assertBlind(row.contentAddress === sample.contentAddress, `${row.sampleId} content address mismatch`);
    assertBlind(row.filesAnalyzed === sample.files.length, `${row.sampleId} filesAnalyzed mismatch`);
  }
  const { predictionDigestSha256, ...unsigned } = output;
  sha256(predictionDigestSha256, "prediction output.predictionDigestSha256");
  assertBlind(digestCanonical(unsigned) === predictionDigestSha256, "prediction output digest mismatch");
  return true;
}

export function buildLabelEnvelope({
  protocol,
  protocolSha256,
  candidateDigestSha256,
  predictionDigestSha256,
  inputEnvelopeDigestSha256,
  createdAt = new Date().toISOString(),
  labels,
  publicPilot,
}) {
  validateBlindProtocol(protocol);
  const sortedLabels = [...labels]
    .map((item) => ({
      sampleId: identifier(item.sampleId, "label.sampleId"),
      actualLabel: label(item.actualLabel, "label.actualLabel"),
      obfuscationTier: label(item.obfuscationTier, "label.obfuscationTier"),
    }))
    .sort((left, right) => compareStrings(left.sampleId, right.sampleId));
  const unsigned = {
    schema: protocol.schemas.labelEnvelope,
    schemaVersion: 1,
    protocolId: protocol.protocolId,
    protocolSha256: sha256(protocolSha256, "protocolSha256"),
    candidateDigestSha256: sha256(candidateDigestSha256, "candidateDigestSha256"),
    predictionDigestSha256: sha256(predictionDigestSha256, "predictionDigestSha256"),
    inputEnvelopeDigestSha256: sha256(
      inputEnvelopeDigestSha256,
      "inputEnvelopeDigestSha256",
    ),
    labelDisclosure: "post-prediction",
    createdAt: isoTimestamp(createdAt, "createdAt"),
    ...(publicPilot
      ? {
          publicPilot: validatePublicPilotProvenance(
            structuredClone(publicPilot),
            "publicPilot",
          ),
        }
      : {}),
    labels: sortedLabels,
  };
  return { ...unsigned, envelopeDigestSha256: digestCanonical(unsigned) };
}

export function validateLabelEnvelope(labels, protocol, candidate, predictions) {
  validateCandidateLock(candidate, protocol);
  exactKeys(
    labels,
    [
      "schema",
      "schemaVersion",
      "protocolId",
      "protocolSha256",
      "candidateDigestSha256",
      "predictionDigestSha256",
      "inputEnvelopeDigestSha256",
      "labelDisclosure",
      "createdAt",
      "labels",
      "envelopeDigestSha256",
    ],
    ["publicPilot"],
    "label envelope",
  );
  assertBlind(labels.schema === protocol.schemas.labelEnvelope, "label envelope schema mismatch");
  assertBlind(labels.schemaVersion === 1, "label envelope schemaVersion mismatch");
  assertBlind(labels.protocolId === protocol.protocolId, "label envelope protocol mismatch");
  assertBlind(labels.protocolSha256 === candidate.protocol.sha256, "label envelope protocol digest mismatch");
  assertBlind(labels.candidateDigestSha256 === candidate.candidateDigestSha256, "label envelope candidate mismatch");
  assertBlind(labels.predictionDigestSha256 === predictions.predictionDigestSha256, "labels must bind frozen predictions");
  assertBlind(
    labels.inputEnvelopeDigestSha256 === predictions.inputEnvelopeDigestSha256,
    "label envelope input digest mismatch",
  );
  assertBlind(labels.labelDisclosure === "post-prediction", "label disclosure must be post-prediction");
  isoTimestamp(labels.createdAt, "label envelope.createdAt");
  assertTimestampOrder(
    candidate.frozenAt,
    "candidate.frozenAt",
    predictions.predictedAt,
    "prediction output.predictedAt",
  );
  assertTimestampOrder(
    predictions.predictedAt,
    "prediction output.predictedAt",
    labels.createdAt,
    "label envelope.createdAt",
  );
  if (predictions.publicPilot === undefined) {
    assertBlind(labels.publicPilot === undefined, "unexpected label public pilot provenance");
  } else {
    validatePublicPilotProvenance(labels.publicPilot, "label envelope.publicPilot");
    assertBlind(
      canonicalJson(labels.publicPilot) === canonicalJson(predictions.publicPilot),
      "label public pilot provenance mismatch",
    );
  }
  assertBlind(Array.isArray(labels.labels), "label envelope.labels must be an array");
  assertBlind(labels.labels.length === predictions.rows.length, "label count mismatch");
  const acceptedLabels = new Set([
    protocol.labels.positiveLabel,
    protocol.labels.negativeLabel,
  ]);
  const acceptedTiers = new Set(protocol.obfuscationTiers);
  for (let index = 0; index < labels.labels.length; index += 1) {
    const item = labels.labels[index];
    const prediction = predictions.rows[index];
    const field = `label envelope.labels[${index}]`;
    exactKeys(item, ["sampleId", "actualLabel", "obfuscationTier"], [], field);
    identifier(item.sampleId, `${field}.sampleId`);
    assertBlind(item.sampleId === prediction.sampleId, "label sample order mismatch");
    assertBlind(acceptedLabels.has(item.actualLabel), `${field}.actualLabel is invalid`);
    assertBlind(acceptedTiers.has(item.obfuscationTier), `${field}.obfuscationTier is invalid`);
  }
  const { envelopeDigestSha256, ...unsigned } = labels;
  sha256(envelopeDigestSha256, "label envelope.envelopeDigestSha256");
  assertBlind(digestCanonical(unsigned) === envelopeDigestSha256, "label envelope digest mismatch");
  return true;
}

function rate(numerator, denominator) {
  return denominator === 0 ? null : Number((numerator / denominator).toFixed(6));
}

function percentile(sorted, quantile) {
  if (sorted.length === 0) return null;
  return Number(sorted[Math.max(0, Math.ceil(sorted.length * quantile) - 1)].toFixed(6));
}

function confusion(rows, positiveLabel, negativeLabel) {
  let truePositive = 0;
  let trueNegative = 0;
  let falsePositive = 0;
  let falseNegative = 0;
  for (const row of rows) {
    if (row.actualLabel === positiveLabel && row.predictedLabel === positiveLabel) truePositive += 1;
    else if (row.actualLabel === negativeLabel && row.predictedLabel === negativeLabel) trueNegative += 1;
    else if (row.actualLabel === negativeLabel && row.predictedLabel === positiveLabel) falsePositive += 1;
    else if (row.actualLabel === positiveLabel && row.predictedLabel === negativeLabel) falseNegative += 1;
    else throw new Error(`invalid scoring labels for ${row.sampleId}`);
  }
  return {
    sampleCount: rows.length,
    confusion: { truePositive, trueNegative, falsePositive, falseNegative },
    precision: rate(truePositive, truePositive + falsePositive),
    recall: rate(truePositive, truePositive + falseNegative),
    falsePositiveRate: rate(falsePositive, falsePositive + trueNegative),
    specificity: rate(trueNegative, trueNegative + falsePositive),
    accuracy: rate(truePositive + trueNegative, rows.length),
  };
}

export function computeOneSidedConfidenceBounds(
  confusionValue,
  confidenceFunctions,
  confidenceLevel = 0.95,
) {
  exactKeys(
    confusionValue,
    ["truePositive", "trueNegative", "falsePositive", "falseNegative"],
    [],
    "confusion",
  );
  for (const [name, value] of Object.entries(confusionValue)) {
    boundedInteger(value, `confusion.${name}`, 0, Number.MAX_SAFE_INTEGER);
  }
  assertBlind(
    confidenceFunctions &&
      typeof confidenceFunctions.clopperPearsonLowerBound === "function" &&
      typeof confidenceFunctions.clopperPearsonUpperBound === "function",
    "Clopper-Pearson confidence functions are required",
  );
  assertBlind(
    Number.isFinite(confidenceLevel) &&
      confidenceLevel > 0 &&
      confidenceLevel < 1,
    "confidenceLevel is invalid",
  );
  const positiveTrials =
    confusionValue.truePositive + confusionValue.falseNegative;
  const negativeTrials =
    confusionValue.trueNegative + confusionValue.falsePositive;
  const recallLowerBound =
    positiveTrials === 0
      ? null
      : confidenceFunctions.clopperPearsonLowerBound(
          confusionValue.truePositive,
          positiveTrials,
          confidenceLevel,
        );
  const falsePositiveRateUpperBound =
    negativeTrials === 0
      ? null
      : confidenceFunctions.clopperPearsonUpperBound(
          confusionValue.falsePositive,
          negativeTrials,
          confidenceLevel,
        );
  for (const [field, value] of [
    ["recall lower bound", recallLowerBound],
    ["false-positive-rate upper bound", falsePositiveRateUpperBound],
  ]) {
    assertBlind(
      value === null || (Number.isFinite(value) && value >= 0 && value <= 1),
      `${field} is invalid`,
    );
  }
  return {
    method: "clopper-pearson-exact-one-sided",
    confidenceLevel,
    recall: {
      successes: confusionValue.truePositive,
      trials: positiveTrials,
      lowerBound: recallLowerBound,
    },
    falsePositiveRate: {
      successes: confusionValue.falsePositive,
      trials: negativeTrials,
      upperBound: falsePositiveRateUpperBound,
    },
  };
}

export function createBlindScoreReport({
  protocol,
  candidate,
  predictions,
  labels,
  scoredAt,
  confidenceFunctions,
}) {
  validateLabelEnvelope(labels, protocol, candidate, predictions);
  const normalizedScoredAt = isoTimestamp(scoredAt, "scoredAt");
  assertTimestampOrder(
    labels.createdAt,
    "label envelope.createdAt",
    normalizedScoredAt,
    "scoredAt",
  );
  const rows = predictions.rows.map((prediction, index) => ({
    sampleId: prediction.sampleId,
    contentAddress: prediction.contentAddress,
    actualLabel: labels.labels[index].actualLabel,
    predictedLabel: prediction.predictedLabel,
    obfuscationTier: labels.labels[index].obfuscationTier,
    score: prediction.score,
    durationMs: prediction.durationMs,
  }));
  const positiveLabel = protocol.labels.positiveLabel;
  const negativeLabel = protocol.labels.negativeLabel;
  const durations = rows.map((row) => row.durationMs).sort((left, right) => left - right);
  const totalMs = durations.reduce((total, value) => total + value, 0);
  const overall = confusion(rows, positiveLabel, negativeLabel);
  const confidenceBounds = computeOneSidedConfidenceBounds(
    overall.confusion,
    confidenceFunctions,
    candidate.detector.confidenceBounds.confidenceLevel,
  );
  const unsigned = {
    schema: protocol.schemas.scoreReport,
    schemaVersion: 1,
    mode: "research-only",
    evaluationClass: "operator-blinded-local",
    independentSealVerified: false,
    finalEvaluationEligible: false,
    releaseEligible: false,
    enforcementAuthorized: false,
    labelsJoinedAfterPrediction: true,
    protocolId: protocol.protocolId,
    protocolSha256: candidate.protocol.sha256,
    candidateDigestSha256: candidate.candidateDigestSha256,
    predictionDigestSha256: predictions.predictionDigestSha256,
    labelEnvelopeDigestSha256: labels.envelopeDigestSha256,
    scoredAt: normalizedScoredAt,
    labelDefinition: { positiveLabel, negativeLabel },
    ...(labels.publicPilot ? { publicPilot: structuredClone(labels.publicPilot) } : {}),
    metrics: {
      overall,
      confidenceBounds,
      obfuscation: protocol.obfuscationTiers.map((tier) => {
        const retained = rows.filter((row) => row.obfuscationTier === tier);
        return { tier, present: retained.length > 0, ...confusion(retained, positiveLabel, negativeLabel) };
      }),
      performance: {
        sampleCount: durations.length,
        totalMs: Number(totalMs.toFixed(6)),
        meanMs: durations.length === 0 ? null : Number((totalMs / durations.length).toFixed(6)),
        p50Ms: percentile(durations, 0.5),
        p95Ms: percentile(durations, 0.95),
        p99Ms: percentile(durations, 0.99),
        maxMs: durations.length === 0 ? null : Number(durations.at(-1).toFixed(6)),
      },
    },
    rows,
    prohibitedClaims: [...protocol.prohibitedClaims],
  };
  return { ...unsigned, reportDigestSha256: digestCanonical(unsigned) };
}
