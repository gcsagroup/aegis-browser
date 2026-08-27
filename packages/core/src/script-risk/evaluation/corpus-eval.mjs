import { createHash } from "node:crypto";
import { readFileSync, realpathSync } from "node:fs";
import { dirname, relative, resolve, sep } from "node:path";

export const EVALUATION_MODE = "research-only";
export const CORPUS_SCHEMA_VERSION = 1;
export const OBFUSCATION_TIERS = Object.freeze([
  "none",
  "minified",
  "identifier-renamed",
  "string-encoded",
  "control-flow",
]);

const LABEL_CLASSES = new Set(["benign", "malicious"]);
const ARTIFACT_KINDS = new Set(["synthetic-fixture", "metadata-only"]);
const REDISTRIBUTION_STATES = new Set([
  "allowed",
  "restricted",
  "unknown",
]);
const SPLIT_NAMES = Object.freeze(["train", "validation", "test"]);
const MAX_FIXTURE_BYTES = 2_000_000;
const SHA256_PATTERN = /^[a-f0-9]{64}$/;
const SAMPLE_ID_PATTERN = /^[a-z0-9][a-z0-9._-]{2,127}$/;

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function requiredString(value, field, maxLength = 2_048) {
  assert(typeof value === "string", `${field} must be a string`);
  const normalized = value.trim();
  assert(normalized.length > 0, `${field} must not be empty`);
  assert(normalized.length <= maxLength, `${field} is too long`);
  return normalized;
}

function isoTimestamp(value, field) {
  const normalized = requiredString(value, field, 64);
  const time = Date.parse(normalized);
  assert(Number.isFinite(time), `${field} must be an ISO timestamp`);
  assert(
    new Date(time).toISOString() === normalized,
    `${field} must be normalized UTC ISO-8601`,
  );
  return normalized;
}

function canonicalValue(value) {
  if (value === null || typeof value === "boolean" || typeof value === "string") {
    return value;
  }
  if (typeof value === "number") {
    assert(Number.isFinite(value), "canonical JSON rejects non-finite numbers");
    return value;
  }
  if (Array.isArray(value)) return value.map(canonicalValue);
  assert(
    typeof value === "object" && value !== null,
    "canonical JSON rejects unsupported values",
  );
  const result = {};
  for (const key of Object.keys(value).sort()) {
    assert(value[key] !== undefined, "canonical JSON rejects undefined values");
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

function validateLicense(license, field) {
  assert(license && typeof license === "object", `${field} is required`);
  const name = requiredString(license.name, `${field}.name`, 256);
  const url = requiredString(license.url, `${field}.url`);
  const redistribution = requiredString(
    license.redistribution,
    `${field}.redistribution`,
    32,
  );
  assert(
    REDISTRIBUTION_STATES.has(redistribution),
    `${field}.redistribution is invalid`,
  );
  return {
    name,
    ...(license.spdx
      ? { spdx: requiredString(license.spdx, `${field}.spdx`, 128) }
      : {}),
    url,
    redistribution,
  };
}

function validateSource(source, field) {
  assert(source && typeof source === "object", `${field} is required`);
  return {
    name: requiredString(source.name, `${field}.name`, 256),
    locator: requiredString(source.locator, `${field}.locator`),
    retrievedAt: isoTimestamp(source.retrievedAt, `${field}.retrievedAt`),
    license: validateLicense(source.license, `${field}.license`),
  };
}

function validateEvidence(evidence, field) {
  assert(evidence && typeof evidence === "object", `${field} is required`);
  const kind = requiredString(evidence.kind, `${field}.kind`, 64);
  assert(
    ["synthetic-spec", "public-metadata", "manual-review", "multi-review"].includes(
      kind,
    ),
    `${field}.kind is invalid`,
  );
  return {
    kind,
    reference: requiredString(evidence.reference, `${field}.reference`),
    adjudicator: requiredString(
      evidence.adjudicator,
      `${field}.adjudicator`,
      256,
    ),
    adjudicatedAt: isoTimestamp(
      evidence.adjudicatedAt,
      `${field}.adjudicatedAt`,
    ),
  };
}

function validateObfuscation(obfuscation, field) {
  assert(
    obfuscation && typeof obfuscation === "object",
    `${field} is required`,
  );
  const tier = requiredString(obfuscation.tier, `${field}.tier`, 64);
  assert(OBFUSCATION_TIERS.includes(tier), `${field}.tier is invalid`);
  assert(
    Array.isArray(obfuscation.transformations),
    `${field}.transformations must be an array`,
  );
  const transformations = obfuscation.transformations.map((item, index) =>
    requiredString(item, `${field}.transformations[${index}]`, 256),
  );
  return { tier, transformations };
}

function safeFixturePath(fixturesRoot, fixturePath) {
  const normalizedPath = requiredString(fixturePath, "artifact.path");
  assert(!normalizedPath.includes("\0"), "artifact.path contains NUL");
  const root = realpathSync(fixturesRoot);
  const candidate = realpathSync(resolve(root, normalizedPath));
  const fromRoot = relative(root, candidate);
  assert(
    fromRoot !== "" &&
      fromRoot !== ".." &&
      !fromRoot.startsWith(`..${sep}`) &&
      !fromRoot.startsWith(sep),
    "artifact.path must stay below fixtures root",
  );
  return { absolute: candidate, relative: fromRoot.split(sep).join("/") };
}

function materializeArtifact(artifact, fixturesRoot, sampleId) {
  assert(artifact && typeof artifact === "object", `${sampleId}.artifact is required`);
  const kind = requiredString(artifact.kind, `${sampleId}.artifact.kind`, 64);
  assert(ARTIFACT_KINDS.has(kind), `${sampleId}.artifact.kind is invalid`);

  if (kind === "metadata-only") {
    const digest = requiredString(
      artifact.sha256,
      `${sampleId}.artifact.sha256`,
      64,
    ).toLowerCase();
    assert(SHA256_PATTERN.test(digest), `${sampleId}.artifact.sha256 is invalid`);
    const byteLength = artifact.byteLength;
    assert(
      byteLength === null ||
        (Number.isSafeInteger(byteLength) && byteLength >= 0),
      `${sampleId}.artifact.byteLength is invalid`,
    );
    return {
      kind,
      contentAddress: `sha256:${digest}`,
      sha256: digest,
      byteLength: byteLength ?? null,
      handling: "metadata-only-no-artifact",
    };
  }

  const fixture = safeFixturePath(fixturesRoot, artifact.path);
  const bytes = readFileSync(fixture.absolute);
  assert(bytes.length <= MAX_FIXTURE_BYTES, `${sampleId} fixture exceeds size limit`);
  const digest = sha256Hex(bytes);
  return {
    kind,
    fixturePath: fixture.relative,
    contentAddress: `sha256:${digest}`,
    sha256: digest,
    byteLength: bytes.length,
    handling: "synthetic-source-only-never-execute",
  };
}

function corpusStats(entries) {
  const byLabel = { benign: 0, malicious: 0 };
  const byObfuscation = Object.fromEntries(
    OBFUSCATION_TIERS.map((tier) => [tier, 0]),
  );
  let metadataOnly = 0;
  for (const entry of entries) {
    byLabel[entry.label.class] += 1;
    byObfuscation[entry.obfuscation.tier] += 1;
    if (entry.artifact.kind === "metadata-only") metadataOnly += 1;
  }
  return {
    samples: entries.length,
    byLabel,
    byObfuscation,
    syntheticFixtures: entries.length - metadataOnly,
    metadataOnly,
  };
}

export function buildCorpusManifest(definition, fixturesRoot) {
  assert(definition && typeof definition === "object", "definition is required");
  assert(
    definition.schemaVersion === CORPUS_SCHEMA_VERSION,
    "unsupported corpus definition schemaVersion",
  );
  assert(definition.mode === EVALUATION_MODE, "corpus must be research-only");
  const datasetId = requiredString(definition.datasetId, "datasetId", 128);
  const createdAt = isoTimestamp(definition.createdAt, "createdAt");
  assert(
    definition.sourceCatalog && typeof definition.sourceCatalog === "object",
    "sourceCatalog is required",
  );
  assert(
    definition.evidenceCatalog && typeof definition.evidenceCatalog === "object",
    "evidenceCatalog is required",
  );
  assert(Array.isArray(definition.samples), "samples must be an array");
  assert(definition.samples.length >= 3, "corpus needs at least three samples");

  const seenIds = new Set();
  const labelByDigest = new Map();
  const entries = definition.samples.map((sample, index) => {
    const field = `samples[${index}]`;
    assert(sample && typeof sample === "object", `${field} is invalid`);
    const sampleId = requiredString(sample.sampleId, `${field}.sampleId`, 128);
    assert(SAMPLE_ID_PATTERN.test(sampleId), `${field}.sampleId is invalid`);
    assert(!seenIds.has(sampleId), `duplicate sampleId: ${sampleId}`);
    seenIds.add(sampleId);

    const sourceRef = requiredString(sample.sourceRef, `${field}.sourceRef`, 128);
    const source = validateSource(
      definition.sourceCatalog[sourceRef],
      `sourceCatalog.${sourceRef}`,
    );
    assert(sample.label && typeof sample.label === "object", `${field}.label is required`);
    const labelClass = requiredString(
      sample.label.class,
      `${field}.label.class`,
      32,
    );
    assert(LABEL_CLASSES.has(labelClass), `${field}.label.class is invalid`);
    const evidenceRef = requiredString(
      sample.label.evidenceRef,
      `${field}.label.evidenceRef`,
      128,
    );
    const evidence = validateEvidence(
      definition.evidenceCatalog[evidenceRef],
      `evidenceCatalog.${evidenceRef}`,
    );
    const artifact = materializeArtifact(sample.artifact, fixturesRoot, sampleId);
    const previousLabel = labelByDigest.get(artifact.sha256);
    assert(
      !previousLabel || previousLabel === labelClass,
      `content digest has conflicting labels: ${artifact.sha256}`,
    );
    labelByDigest.set(artifact.sha256, labelClass);

    return {
      sampleId,
      artifact,
      siteGroup: requiredString(sample.siteGroup, `${field}.siteGroup`, 256),
      familyGroup: requiredString(sample.familyGroup, `${field}.familyGroup`, 256),
      timeGroup: requiredString(sample.timeGroup, `${field}.timeGroup`, 256),
      observedAt: isoTimestamp(sample.observedAt, `${field}.observedAt`),
      label: {
        class: labelClass,
        category: requiredString(
          sample.label.category,
          `${field}.label.category`,
          128,
        ),
        evidence,
      },
      source,
      obfuscation: validateObfuscation(
        sample.obfuscation,
        `${field}.obfuscation`,
      ),
    };
  });

  entries.sort((left, right) => left.sampleId.localeCompare(right.sampleId));
  const unsigned = {
    schemaVersion: CORPUS_SCHEMA_VERSION,
    mode: EVALUATION_MODE,
    releaseEligible: false,
    datasetId,
    createdAt,
    contentAddressAlgorithm: "sha256",
    acceptedArtifactKinds: ["synthetic-fixture", "metadata-only"],
    prohibitedActions: [
      "download-live-malware",
      "execute-sample-source",
      "enable-page-path-blocking",
    ],
    entries,
    stats: corpusStats(entries),
  };
  return { ...unsigned, manifestDigest: digestCanonical(unsigned) };
}

export function buildCorpusManifestFromFile(definitionPath, fixturesRoot) {
  const parsed = JSON.parse(readFileSync(definitionPath, "utf8"));
  return buildCorpusManifest(parsed, fixturesRoot ?? dirname(definitionPath));
}

export function verifyCorpusManifest(manifest) {
  assert(manifest && typeof manifest === "object", "manifest is required");
  const { manifestDigest, ...unsigned } = manifest;
  return SHA256_PATTERN.test(manifestDigest ?? "") &&
    digestCanonical(unsigned) === manifestDigest;
}

class UnionFind {
  constructor(size) {
    this.parent = Array.from({ length: size }, (_, index) => index);
    this.rank = Array(size).fill(0);
  }

  find(index) {
    if (this.parent[index] !== index) this.parent[index] = this.find(this.parent[index]);
    return this.parent[index];
  }

  union(left, right) {
    let leftRoot = this.find(left);
    let rightRoot = this.find(right);
    if (leftRoot === rightRoot) return;
    if (this.rank[leftRoot] < this.rank[rightRoot]) {
      [leftRoot, rightRoot] = [rightRoot, leftRoot];
    }
    this.parent[rightRoot] = leftRoot;
    if (this.rank[leftRoot] === this.rank[rightRoot]) this.rank[leftRoot] += 1;
  }
}

function validateRatios(ratios) {
  assert(ratios && typeof ratios === "object", "split ratios are required");
  const normalized = {};
  for (const split of SPLIT_NAMES) {
    const value = ratios[split];
    assert(Number.isFinite(value) && value > 0 && value < 1, `${split} ratio is invalid`);
    normalized[split] = value;
  }
  const sum = SPLIT_NAMES.reduce((total, split) => total + normalized[split], 0);
  assert(Math.abs(sum - 1) < 1e-9, "split ratios must sum to one");
  return normalized;
}

function allocateCounts(count, ratios) {
  const result = Object.fromEntries(SPLIT_NAMES.map((split) => [split, 0]));
  let allocated = 0;
  if (count >= SPLIT_NAMES.length) {
    for (const split of SPLIT_NAMES) {
      result[split] = 1;
      allocated += 1;
    }
  }
  while (allocated < count) {
    const split = [...SPLIT_NAMES].sort((left, right) => {
      const rightDeficit = count * ratios[right] - result[right];
      const leftDeficit = count * ratios[left] - result[left];
      return rightDeficit - leftDeficit || SPLIT_NAMES.indexOf(left) - SPLIT_NAMES.indexOf(right);
    })[0];
    result[split] += 1;
    allocated += 1;
  }
  return result;
}

function groupedComponents(entries) {
  const unionFind = new UnionFind(entries.length);
  const firstByKey = new Map();
  entries.forEach((entry, index) => {
    const keys = [
      `content:${entry.artifact.sha256}`,
      `site:${entry.siteGroup}`,
      `family:${entry.familyGroup}`,
      `time:${entry.timeGroup}`,
    ];
    for (const key of keys) {
      const first = firstByKey.get(key);
      if (first === undefined) firstByKey.set(key, index);
      else unionFind.union(first, index);
    }
  });

  const components = new Map();
  entries.forEach((entry, index) => {
    const root = unionFind.find(index);
    const retained = components.get(root) ?? [];
    retained.push(entry);
    components.set(root, retained);
  });
  return [...components.values()].map((component) =>
    component.sort((left, right) => left.sampleId.localeCompare(right.sampleId)),
  );
}

function publicHoldoutMaterial(manifest, split) {
  const entryById = new Map(manifest.entries.map((entry) => [entry.sampleId, entry]));
  const holdoutEntries = split.assignments
    .filter((assignment) => assignment.split === "test")
    .map((assignment) => {
      const entry = entryById.get(assignment.sampleId);
      assert(entry, `split references unknown sample: ${assignment.sampleId}`);
      return {
        sampleId: entry.sampleId,
        contentAddress: entry.artifact.contentAddress,
      };
    })
    .sort((left, right) => left.sampleId.localeCompare(right.sampleId));
  return {
    corpusManifestDigest: manifest.manifestDigest,
    algorithm: split.algorithm,
    seedDigest: split.seedDigest,
    ratios: split.ratios,
    holdoutEntries,
  };
}

export function createGroupedSplit(manifest, options) {
  assert(verifyCorpusManifest(manifest), "corpus manifest digest mismatch");
  const seed = requiredString(options?.seed, "split seed", 512);
  const ratios = validateRatios(options?.ratios);
  const components = groupedComponents(manifest.entries);
  const strata = new Map();
  for (const component of components) {
    const labelProfile = [...new Set(component.map((entry) => entry.label.class))]
      .sort()
      .join("+");
    const retained = strata.get(labelProfile) ?? [];
    retained.push(component);
    strata.set(labelProfile, retained);
  }

  const assignmentById = new Map();
  for (const [stratum, retained] of [...strata.entries()].sort()) {
    const ordered = retained.sort((left, right) => {
      const leftKey = sha256Hex(`${seed}\0${stratum}\0${left.map((item) => item.sampleId).join("\0")}`);
      const rightKey = sha256Hex(`${seed}\0${stratum}\0${right.map((item) => item.sampleId).join("\0")}`);
      return leftKey.localeCompare(rightKey);
    });
    const counts = allocateCounts(ordered.length, ratios);
    let cursor = 0;
    for (const splitName of SPLIT_NAMES) {
      const end = cursor + counts[splitName];
      for (const component of ordered.slice(cursor, end)) {
        for (const entry of component) assignmentById.set(entry.sampleId, splitName);
      }
      cursor = end;
    }
  }

  const assignments = manifest.entries.map((entry) => ({
    sampleId: entry.sampleId,
    split: assignmentById.get(entry.sampleId),
  }));
  assert(assignments.every((item) => SPLIT_NAMES.includes(item.split)), "split assignment failed");
  const counts = Object.fromEntries(SPLIT_NAMES.map((split) => [split, 0]));
  for (const assignment of assignments) counts[assignment.split] += 1;
  const unsigned = {
    schemaVersion: CORPUS_SCHEMA_VERSION,
    mode: EVALUATION_MODE,
    releaseEligible: false,
    corpusManifestDigest: manifest.manifestDigest,
    algorithm: "grouped-content-site-family-time-sha256-v1",
    groupDimensions: ["content-sha256", "siteGroup", "familyGroup", "timeGroup"],
    seedDigest: sha256Hex(seed),
    ratios,
    assignments,
    counts,
  };
  const splitDigest = digestCanonical(unsigned);
  const provisional = { ...unsigned, splitDigest };
  const integrityDigestSha256 = digestCanonical(
    publicHoldoutMaterial(manifest, provisional),
  );
  return {
    ...provisional,
    publicHoldout: {
      classification: "deterministic-public-holdout",
      integrityDigestSha256,
      sampleCount: counts.test,
      publiclyInspectable: true,
      sealIsolationVerified: false,
      finalEvaluationEligible: false,
      prohibitedClaims: [
        "sealed-test",
        "blind-holdout",
        "final-evaluation",
        "release-authorization",
      ],
    },
  };
}

export function verifyGroupedSplit(manifest, split) {
  try {
    assert(verifyCorpusManifest(manifest), "corpus manifest digest mismatch");
    assert(split.corpusManifestDigest === manifest.manifestDigest, "split corpus mismatch");
    const { publicHoldout, splitDigest, ...unsigned } = split;
    assert(digestCanonical(unsigned) === splitDigest, "split digest mismatch");
    const ids = new Set(manifest.entries.map((entry) => entry.sampleId));
    assert(split.assignments.length === ids.size, "split assignment count mismatch");
    const assigned = new Set();
    for (const assignment of split.assignments) {
      assert(ids.has(assignment.sampleId), "split references unknown sample");
      assert(!assigned.has(assignment.sampleId), "duplicate split assignment");
      assert(SPLIT_NAMES.includes(assignment.split), "invalid split name");
      assigned.add(assignment.sampleId);
    }
    const expectedDigest = digestCanonical(publicHoldoutMaterial(manifest, split));
    assert(
      publicHoldout?.classification === "deterministic-public-holdout",
      "public holdout classification mismatch",
    );
    assert(
      publicHoldout?.integrityDigestSha256 === expectedDigest,
      "public holdout integrity digest mismatch",
    );
    assert(publicHoldout?.publiclyInspectable === true, "public holdout must be public");
    assert(
      publicHoldout?.sealIsolationVerified === false,
      "public holdout cannot claim seal isolation",
    );
    assert(
      publicHoldout?.finalEvaluationEligible === false,
      "public holdout cannot authorize final evaluation",
    );
    assert(
      publicHoldout?.sampleCount ===
        split.assignments.filter((assignment) => assignment.split === "test").length,
      "public holdout sample count mismatch",
    );

    const assignmentById = new Map(
      split.assignments.map((assignment) => [assignment.sampleId, assignment.split]),
    );
    for (const component of groupedComponents(manifest.entries)) {
      const splits = new Set(component.map((entry) => assignmentById.get(entry.sampleId)));
      assert(splits.size === 1, "group leakage detected");
    }
    return true;
  } catch {
    return false;
  }
}

export function authorizeEvaluationAccess(manifest, split, options) {
  assert(verifyGroupedSplit(manifest, split), "split or public holdout verification failed");
  const splitName = requiredString(options?.split, "evaluation split", 32);
  assert(SPLIT_NAMES.includes(splitName), "evaluation split is invalid");
  assert(
    options?.finalEvaluation !== true,
    "--final is unavailable: the repository corpus is a deterministic public holdout",
  );
  assert(
    options?.expectedSeal === undefined,
    "the repository corpus does not accept a seal as final-evaluation authorization",
  );
  return {
    split: splitName,
    evaluationClass:
      splitName === "test" ? "deterministic-public-holdout" : "development-split",
    publicHoldoutEvaluated: splitName === "test",
    sealIsolationVerified: false,
    finalEvaluationEligible: false,
  };
}

function rate(numerator, denominator) {
  if (denominator === 0) return null;
  return Number((numerator / denominator).toFixed(6));
}

function percentile(sorted, quantile) {
  if (sorted.length === 0) return null;
  const index = Math.max(0, Math.ceil(sorted.length * quantile) - 1);
  return Number(sorted[index].toFixed(6));
}

function metricsForRows(rows) {
  let truePositive = 0;
  let trueNegative = 0;
  let falsePositive = 0;
  let falseNegative = 0;
  for (const row of rows) {
    if (row.actual === "malicious" && row.predicted === "malicious") truePositive += 1;
    else if (row.actual === "benign" && row.predicted === "benign") trueNegative += 1;
    else if (row.actual === "benign" && row.predicted === "malicious") falsePositive += 1;
    else if (row.actual === "malicious" && row.predicted === "benign") falseNegative += 1;
    else throw new Error(`invalid evaluation labels for ${row.sampleId}`);
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

export function computeEvaluationMetrics(rows) {
  assert(Array.isArray(rows), "evaluation rows must be an array");
  const seen = new Set();
  for (const row of rows) {
    const sampleId = requiredString(row.sampleId, "row.sampleId", 128);
    assert(!seen.has(sampleId), `duplicate evaluation row: ${sampleId}`);
    seen.add(sampleId);
    assert(LABEL_CLASSES.has(row.actual), `${sampleId} actual label is invalid`);
    assert(LABEL_CLASSES.has(row.predicted), `${sampleId} predicted label is invalid`);
    assert(OBFUSCATION_TIERS.includes(row.obfuscationTier), `${sampleId} tier is invalid`);
    assert(
      Number.isFinite(row.durationMs) && row.durationMs >= 0,
      `${sampleId} durationMs is invalid`,
    );
  }

  const durations = rows.map((row) => row.durationMs).sort((left, right) => left - right);
  const totalMs = durations.reduce((total, value) => total + value, 0);
  const strata = OBFUSCATION_TIERS.map((tier) => {
    const retained = rows.filter((row) => row.obfuscationTier === tier);
    return {
      tier,
      present: retained.length > 0,
      ...metricsForRows(retained),
    };
  });
  return {
    positiveClass: "malicious",
    overall: metricsForRows(rows),
    obfuscation: {
      expectedTiers: [...OBFUSCATION_TIERS],
      coveredTiers: strata.filter((item) => item.present).map((item) => item.tier),
      missingTiers: strata.filter((item) => !item.present).map((item) => item.tier),
      strata,
    },
    performance: {
      sampleCount: durations.length,
      totalMs: Number(totalMs.toFixed(6)),
      meanMs: durations.length === 0 ? null : Number((totalMs / durations.length).toFixed(6)),
      p50Ms: percentile(durations, 0.5),
      p95Ms: percentile(durations, 0.95),
      p99Ms: percentile(durations, 0.99),
      maxMs: durations.length === 0 ? null : Number(durations.at(-1).toFixed(6)),
    },
  };
}

export function classifyStaticAnalysis(analysis) {
  const signals = new Set(
    Array.isArray(analysis?.signals) ? analysis.signals.map((signal) => signal.code) : [],
  );
  const mining =
    ["ast.wasm-use", "ast.webgpu-compute", "ast.hash-loop"].some((code) => signals.has(code)) &&
    signals.has("ast.websocket") &&
    signals.has("ast.mining-protocol");
  const loader = ["ast.dynamic-code", "ast.encoded-payload", "ast.remote-load"].every(
    (code) => signals.has(code),
  );
  const malicious = analysis?.parseStatus === "complete" && (mining || loader);
  return {
    predicted: malicious ? "malicious" : "benign",
    score: mining ? 70 : loader ? 65 : 0,
    finding: mining ? "suspected-mining" : loader ? "obfuscated-remote-loader" : null,
    reasonCodes: [...signals].sort(),
  };
}

export function createEvaluationReport({
  manifest,
  split,
  access,
  rows,
  detector,
  evaluatedAt,
}) {
  assert(verifyGroupedSplit(manifest, split), "split verification failed");
  assert(access?.split && SPLIT_NAMES.includes(access.split), "evaluation access is required");
  assert(
    access.sealIsolationVerified === false &&
      access.finalEvaluationEligible === false,
    "public corpus access cannot authorize final evaluation",
  );
  const assignmentById = new Map(
    split.assignments.map((assignment) => [assignment.sampleId, assignment.split]),
  );
  const entryById = new Map(manifest.entries.map((entry) => [entry.sampleId, entry]));
  const expectedIds = manifest.entries
    .filter((entry) => assignmentById.get(entry.sampleId) === access.split)
    .map((entry) => entry.sampleId)
    .sort();
  const actualIds = rows.map((row) => row.sampleId).sort();
  assert(canonicalJson(actualIds) === canonicalJson(expectedIds), "evaluation rows do not match split");
  for (const row of rows) {
    const entry = entryById.get(row.sampleId);
    assert(entry, `unknown evaluation row: ${row.sampleId}`);
    assert(row.actual === entry.label.class, `${row.sampleId} actual label mismatch`);
    assert(
      row.obfuscationTier === entry.obfuscation.tier,
      `${row.sampleId} obfuscation tier mismatch`,
    );
  }
  const timestamp = isoTimestamp(evaluatedAt, "evaluatedAt");
  const metrics = computeEvaluationMetrics(rows);
  return {
    schemaVersion: CORPUS_SCHEMA_VERSION,
    mode: EVALUATION_MODE,
    releaseEligible: false,
    enforcementAuthorized: false,
    evaluatedAt: timestamp,
    corpus: {
      datasetId: manifest.datasetId,
      manifestDigest: manifest.manifestDigest,
      splitDigest: split.splitDigest,
      evaluatedSplit: access.split,
      sampleCount: rows.length,
    },
    publicHoldout: {
      classification: split.publicHoldout.classification,
      integrityDigestSha256: split.publicHoldout.integrityDigestSha256,
      evaluated: access.publicHoldoutEvaluated === true,
      publiclyInspectable: true,
      sealIsolationVerified: false,
      finalEvaluationEligible: false,
    },
    detector: {
      id: requiredString(detector?.id, "detector.id", 256),
      contentAddress: requiredString(
        detector?.contentAddress,
        "detector.contentAddress",
        80,
      ),
      decisionRule: requiredString(
        detector?.decisionRule,
        "detector.decisionRule",
        512,
      ),
    },
    dataHandling: {
      acceptedArtifactKinds: [...manifest.acceptedArtifactKinds],
      sourceExecution: false,
      networkAcquisition: false,
      liveMalwareDownloaded: false,
    },
    metrics,
    predictions: rows.map((row) => ({
      sampleId: row.sampleId,
      contentAddress: entryById.get(row.sampleId).artifact.contentAddress,
      actual: row.actual,
      predicted: row.predicted,
      score: row.score,
      finding: row.finding,
      reasonCodes: [...row.reasonCodes],
      obfuscationTier: row.obfuscationTier,
      durationMs: Number(row.durationMs.toFixed(6)),
    })),
    limitations: [
      "synthetic fixtures do not establish production prevalence or false-positive rate",
      "the repository holdout is public and deterministic, not sealed or blind",
      "static parsing does not observe runtime-only or dynamically decoded behavior",
      "validation success does not authorize page execution-path blocking",
    ],
  };
}
