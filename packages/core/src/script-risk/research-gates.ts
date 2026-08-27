export interface ScriptRiskCorpusGateEvidence {
  manifestSha256: string;
  provenanceRecordsComplete: boolean;
  licenseReviewComplete: boolean;
  independentLabelReview: boolean;
  independentReviewerCount: number;
  splitLeakageChecked: boolean;
  syntheticOnly: boolean;
  realWorldBenignSamples: number;
  realWorldMaliciousSamples: number;
}

export interface ScriptRiskSealedTestGateEvidence {
  sealVerified: boolean;
  finalOpened: boolean;
  candidateFrozenBeforeOpen: boolean;
  usedForTuning: boolean;
  sampleCount: number;
}

export interface ScriptRiskMetricGateEvidence {
  sampleCount: number;
  obfuscatedSampleCount: number;
  precision: number;
  recall: number;
  falsePositiveRate: number;
  obfuscatedRecall: number;
}

export interface ScriptRiskPerformanceGateEvidence {
  sampleCount: number;
  p95OverheadPercent: number;
}

export interface ScriptRiskBreakageGateEvidence {
  testedSites: number;
  majorBreakages: number;
}

export interface ScriptRiskV8ShadowGateEvidence {
  observedFunctions: number;
  distinctSites: number;
  crashes: number;
  wouldBlockCount: number;
}

export interface ScriptRiskSafetyGateEvidence {
  failOpenVerified: boolean;
  killSwitchVerified: boolean;
  rollbackVerified: boolean;
}

export interface ScriptRiskPrivacyGateEvidence {
  auditComplete: boolean;
  sourceFreeTelemetryVerified: boolean;
  boundedRetentionVerified: boolean;
}

export type ScriptRiskLocalModelGateStatus =
  | "disabled"
  | "advisory-only"
  | "validated-advisory";

export type ScriptRiskFederatedGateStatus =
  | "disabled"
  | "simulation-only"
  | "research-validated";

export interface ScriptRiskOptionalComponentGateEvidence {
  localModel: {
    status: ScriptRiskLocalModelGateStatus;
    receivesRawSource: boolean;
    canChangeDecision: boolean;
  };
  federated: {
    status: ScriptRiskFederatedGateStatus;
    retainsRawClientUpdates: boolean;
    retainsClientIdentifiers: boolean;
    usedForEnforcement: boolean;
  };
}

/**
 * 所有证据域均为可选，目的是让运行时缺项安全地落到 observe-only，
 * 而不是依赖 TypeScript 调用方保证完整性。
 */
export interface ScriptRiskResearchGateEvidence {
  corpus?: ScriptRiskCorpusGateEvidence;
  sealedTest?: ScriptRiskSealedTestGateEvidence;
  metrics?: ScriptRiskMetricGateEvidence;
  performance?: ScriptRiskPerformanceGateEvidence;
  breakage?: ScriptRiskBreakageGateEvidence;
  v8Shadow?: ScriptRiskV8ShadowGateEvidence;
  safety?: ScriptRiskSafetyGateEvidence;
  privacy?: ScriptRiskPrivacyGateEvidence;
  optionalComponents?: ScriptRiskOptionalComponentGateEvidence;
}

export interface ScriptRiskResearchGateThresholds {
  minIndependentReviewers: number;
  minRealWorldBenignSamples: number;
  minRealWorldMaliciousSamples: number;
  minSealedTestSamples: number;
  minObfuscatedSamples: number;
  minPrecision: number;
  minRecall: number;
  maxFalsePositiveRate: number;
  minObfuscatedRecall: number;
  minPerformanceSamples: number;
  maxP95OverheadPercent: number;
  minBreakageSites: number;
  maxMajorBreakageRate: number;
  minV8ObservedFunctions: number;
  minV8DistinctSites: number;
  maxV8CrashRate: number;
}

export const DEFAULT_SCRIPT_RISK_RESEARCH_GATE_THRESHOLDS = Object.freeze({
  minIndependentReviewers: 2,
  minRealWorldBenignSamples: 10_000,
  minRealWorldMaliciousSamples: 1_000,
  minSealedTestSamples: 2_000,
  minObfuscatedSamples: 200,
  minPrecision: 0.99,
  minRecall: 0.95,
  maxFalsePositiveRate: 0.001,
  minObfuscatedRecall: 0.9,
  minPerformanceSamples: 10_000,
  maxP95OverheadPercent: 5,
  minBreakageSites: 500,
  maxMajorBreakageRate: 0.005,
  minV8ObservedFunctions: 100_000,
  minV8DistinctSites: 500,
  maxV8CrashRate: 0.00001,
}) satisfies Readonly<ScriptRiskResearchGateThresholds>;

export type ScriptRiskResearchGateCheckId =
  | "corpus.manifest-sha256"
  | "corpus.provenance-complete"
  | "corpus.license-review-complete"
  | "corpus.independent-label-review"
  | "corpus.independent-reviewers"
  | "corpus.split-leakage-checked"
  | "corpus.not-synthetic-only"
  | "corpus.real-world-benign-samples"
  | "corpus.real-world-malicious-samples"
  | "sealed.seal-verified"
  | "sealed.final-opened"
  | "sealed.candidate-frozen-before-open"
  | "sealed.not-used-for-tuning"
  | "sealed.sample-count"
  | "metrics.same-sealed-sample-count"
  | "metrics.obfuscated-sample-count"
  | "metrics.precision"
  | "metrics.recall"
  | "metrics.false-positive-rate"
  | "metrics.obfuscated-recall"
  | "performance.sample-count"
  | "performance.p95-overhead-percent"
  | "breakage.site-count"
  | "breakage.count-consistent"
  | "breakage.major-rate"
  | "v8.observed-functions"
  | "v8.distinct-sites"
  | "v8.crash-count-consistent"
  | "v8.crash-rate"
  | "v8.would-block-zero"
  | "safety.fail-open-verified"
  | "safety.kill-switch-verified"
  | "safety.rollback-verified"
  | "privacy.audit-complete"
  | "privacy.source-free-telemetry"
  | "privacy.bounded-retention"
  | "components.local-model-status"
  | "components.local-model-no-raw-source"
  | "components.local-model-advisory-only"
  | "components.federated-status"
  | "components.federated-no-raw-updates"
  | "components.federated-no-client-identifiers"
  | "components.federated-not-enforcement";

export interface ScriptRiskResearchGateCheck {
  id: ScriptRiskResearchGateCheckId;
  status: "pass" | "fail";
  observed: boolean | number | string | null;
  requirement: string;
}

export interface ScriptRiskResearchGateReport {
  schemaVersion: 1;
  trustLevel: "unverified-claims";
  currentMode: "observe-only";
  eligibility: "observe-only";
  /** 本模块只检查 claims，不产生任何浏览器执行副作用。 */
  wouldBlock: false;
  /** 所有自报字段是否满足阈值；不代表证据可信或可授权阻断。 */
  claimsComplete: boolean;
  authorizationEligible: false;
  limitedBlockingEligible: false;
  thresholds: ScriptRiskResearchGateThresholds;
  checks: ScriptRiskResearchGateCheck[];
  failedChecks: ScriptRiskResearchGateCheckId[];
}

const SHA256_PATTERN = /^[a-f0-9]{64}$/;
const LOCAL_MODEL_STATUSES = new Set<ScriptRiskLocalModelGateStatus>([
  "disabled",
  "advisory-only",
  "validated-advisory",
]);
const FEDERATED_STATUSES = new Set<ScriptRiskFederatedGateStatus>([
  "disabled",
  "simulation-only",
  "research-validated",
]);

function finiteNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function nonNegativeInteger(value: unknown): number | null {
  const number = finiteNumber(value);
  return number !== null && Number.isSafeInteger(number) && number >= 0
    ? number
    : null;
}

function ratio(value: unknown): number | null {
  const number = finiteNumber(value);
  return number !== null && number >= 0 && number <= 1 ? number : null;
}

function strictMinimumThreshold(
  value: number,
  name: keyof ScriptRiskResearchGateThresholds,
  floor: number,
  integer: boolean,
  maximum = Number.POSITIVE_INFINITY,
): number {
  if (
    !Number.isFinite(value) ||
    value < floor ||
    value > maximum ||
    (integer && !Number.isSafeInteger(value))
  ) {
    throw new RangeError(`${name} must be finite and no weaker than ${floor}`);
  }
  return value;
}

function strictMaximumThreshold(
  value: number,
  name: keyof ScriptRiskResearchGateThresholds,
  ceiling: number,
): number {
  if (!Number.isFinite(value) || value < 0 || value > ceiling) {
    throw new RangeError(`${name} must be finite and no weaker than ${ceiling}`);
  }
  return value;
}

/** 自定义阈值只能收紧默认政策，不能静默降低门槛。 */
function resolveThresholds(
  overrides: Partial<ScriptRiskResearchGateThresholds>,
): ScriptRiskResearchGateThresholds {
  const values = {
    ...DEFAULT_SCRIPT_RISK_RESEARCH_GATE_THRESHOLDS,
    ...overrides,
  };
  return {
    minIndependentReviewers: strictMinimumThreshold(
      values.minIndependentReviewers,
      "minIndependentReviewers",
      DEFAULT_SCRIPT_RISK_RESEARCH_GATE_THRESHOLDS.minIndependentReviewers,
      true,
    ),
    minRealWorldBenignSamples: strictMinimumThreshold(
      values.minRealWorldBenignSamples,
      "minRealWorldBenignSamples",
      DEFAULT_SCRIPT_RISK_RESEARCH_GATE_THRESHOLDS.minRealWorldBenignSamples,
      true,
    ),
    minRealWorldMaliciousSamples: strictMinimumThreshold(
      values.minRealWorldMaliciousSamples,
      "minRealWorldMaliciousSamples",
      DEFAULT_SCRIPT_RISK_RESEARCH_GATE_THRESHOLDS.minRealWorldMaliciousSamples,
      true,
    ),
    minSealedTestSamples: strictMinimumThreshold(
      values.minSealedTestSamples,
      "minSealedTestSamples",
      DEFAULT_SCRIPT_RISK_RESEARCH_GATE_THRESHOLDS.minSealedTestSamples,
      true,
    ),
    minObfuscatedSamples: strictMinimumThreshold(
      values.minObfuscatedSamples,
      "minObfuscatedSamples",
      DEFAULT_SCRIPT_RISK_RESEARCH_GATE_THRESHOLDS.minObfuscatedSamples,
      true,
    ),
    minPrecision: strictMinimumThreshold(
      values.minPrecision,
      "minPrecision",
      DEFAULT_SCRIPT_RISK_RESEARCH_GATE_THRESHOLDS.minPrecision,
      false,
      1,
    ),
    minRecall: strictMinimumThreshold(
      values.minRecall,
      "minRecall",
      DEFAULT_SCRIPT_RISK_RESEARCH_GATE_THRESHOLDS.minRecall,
      false,
      1,
    ),
    maxFalsePositiveRate: strictMaximumThreshold(
      values.maxFalsePositiveRate,
      "maxFalsePositiveRate",
      DEFAULT_SCRIPT_RISK_RESEARCH_GATE_THRESHOLDS.maxFalsePositiveRate,
    ),
    minObfuscatedRecall: strictMinimumThreshold(
      values.minObfuscatedRecall,
      "minObfuscatedRecall",
      DEFAULT_SCRIPT_RISK_RESEARCH_GATE_THRESHOLDS.minObfuscatedRecall,
      false,
      1,
    ),
    minPerformanceSamples: strictMinimumThreshold(
      values.minPerformanceSamples,
      "minPerformanceSamples",
      DEFAULT_SCRIPT_RISK_RESEARCH_GATE_THRESHOLDS.minPerformanceSamples,
      true,
    ),
    maxP95OverheadPercent: strictMaximumThreshold(
      values.maxP95OverheadPercent,
      "maxP95OverheadPercent",
      DEFAULT_SCRIPT_RISK_RESEARCH_GATE_THRESHOLDS.maxP95OverheadPercent,
    ),
    minBreakageSites: strictMinimumThreshold(
      values.minBreakageSites,
      "minBreakageSites",
      DEFAULT_SCRIPT_RISK_RESEARCH_GATE_THRESHOLDS.minBreakageSites,
      true,
    ),
    maxMajorBreakageRate: strictMaximumThreshold(
      values.maxMajorBreakageRate,
      "maxMajorBreakageRate",
      DEFAULT_SCRIPT_RISK_RESEARCH_GATE_THRESHOLDS.maxMajorBreakageRate,
    ),
    minV8ObservedFunctions: strictMinimumThreshold(
      values.minV8ObservedFunctions,
      "minV8ObservedFunctions",
      DEFAULT_SCRIPT_RISK_RESEARCH_GATE_THRESHOLDS.minV8ObservedFunctions,
      true,
    ),
    minV8DistinctSites: strictMinimumThreshold(
      values.minV8DistinctSites,
      "minV8DistinctSites",
      DEFAULT_SCRIPT_RISK_RESEARCH_GATE_THRESHOLDS.minV8DistinctSites,
      true,
    ),
    maxV8CrashRate: strictMaximumThreshold(
      values.maxV8CrashRate,
      "maxV8CrashRate",
      DEFAULT_SCRIPT_RISK_RESEARCH_GATE_THRESHOLDS.maxV8CrashRate,
    ),
  };
}

/**
 * 严格的研究 claims 完整性检查：缺项、非法数值或任一不达标均失败。
 * 输入仍是调用方自报字段，因而即使全部通过也保持 observe-only，且绝不授权阻断。
 */
export function evaluateScriptRiskResearchGate(
  evidence: ScriptRiskResearchGateEvidence = {},
  thresholdOverrides: Partial<ScriptRiskResearchGateThresholds> = {},
): ScriptRiskResearchGateReport {
  const thresholds = resolveThresholds(thresholdOverrides);
  const checks: ScriptRiskResearchGateCheck[] = [];
  const add = (
    id: ScriptRiskResearchGateCheckId,
    passed: boolean,
    observed: ScriptRiskResearchGateCheck["observed"],
    requirement: string,
  ): void => {
    checks.push({ id, status: passed ? "pass" : "fail", observed, requirement });
  };

  const corpus = evidence.corpus;
  const manifestSha256 =
    typeof corpus?.manifestSha256 === "string" ? corpus.manifestSha256 : null;
  add(
    "corpus.manifest-sha256",
    manifestSha256 !== null && SHA256_PATTERN.test(manifestSha256),
    manifestSha256,
    "64-char lowercase SHA-256 corpus manifest",
  );
  add(
    "corpus.provenance-complete",
    corpus?.provenanceRecordsComplete === true,
    corpus?.provenanceRecordsComplete ?? null,
    "true",
  );
  add(
    "corpus.license-review-complete",
    corpus?.licenseReviewComplete === true,
    corpus?.licenseReviewComplete ?? null,
    "true",
  );
  add(
    "corpus.independent-label-review",
    corpus?.independentLabelReview === true,
    corpus?.independentLabelReview ?? null,
    "true",
  );
  const reviewerCount = nonNegativeInteger(corpus?.independentReviewerCount);
  add(
    "corpus.independent-reviewers",
    reviewerCount !== null && reviewerCount >= thresholds.minIndependentReviewers,
    reviewerCount,
    `>= ${thresholds.minIndependentReviewers}`,
  );
  add(
    "corpus.split-leakage-checked",
    corpus?.splitLeakageChecked === true,
    corpus?.splitLeakageChecked ?? null,
    "true",
  );
  add(
    "corpus.not-synthetic-only",
    corpus?.syntheticOnly === false,
    corpus?.syntheticOnly ?? null,
    "false",
  );
  const benignSamples = nonNegativeInteger(corpus?.realWorldBenignSamples);
  add(
    "corpus.real-world-benign-samples",
    benignSamples !== null &&
      benignSamples >= thresholds.minRealWorldBenignSamples,
    benignSamples,
    `>= ${thresholds.minRealWorldBenignSamples}`,
  );
  const maliciousSamples = nonNegativeInteger(corpus?.realWorldMaliciousSamples);
  add(
    "corpus.real-world-malicious-samples",
    maliciousSamples !== null &&
      maliciousSamples >= thresholds.minRealWorldMaliciousSamples,
    maliciousSamples,
    `>= ${thresholds.minRealWorldMaliciousSamples}`,
  );

  const sealed = evidence.sealedTest;
  add(
    "sealed.seal-verified",
    sealed?.sealVerified === true,
    sealed?.sealVerified ?? null,
    "true",
  );
  add(
    "sealed.final-opened",
    sealed?.finalOpened === true,
    sealed?.finalOpened ?? null,
    "true after candidate freeze",
  );
  add(
    "sealed.candidate-frozen-before-open",
    sealed?.candidateFrozenBeforeOpen === true,
    sealed?.candidateFrozenBeforeOpen ?? null,
    "true",
  );
  add(
    "sealed.not-used-for-tuning",
    sealed?.usedForTuning === false,
    sealed?.usedForTuning ?? null,
    "false",
  );
  const sealedSamples = nonNegativeInteger(sealed?.sampleCount);
  add(
    "sealed.sample-count",
    sealedSamples !== null && sealedSamples >= thresholds.minSealedTestSamples,
    sealedSamples,
    `>= ${thresholds.minSealedTestSamples}`,
  );

  const metrics = evidence.metrics;
  const metricSamples = nonNegativeInteger(metrics?.sampleCount);
  add(
    "metrics.same-sealed-sample-count",
    metricSamples !== null &&
      sealedSamples !== null &&
      metricSamples === sealedSamples,
    metricSamples,
    "equals sealed test sample count",
  );
  const obfuscatedSamples = nonNegativeInteger(metrics?.obfuscatedSampleCount);
  add(
    "metrics.obfuscated-sample-count",
    obfuscatedSamples !== null &&
      obfuscatedSamples >= thresholds.minObfuscatedSamples,
    obfuscatedSamples,
    `>= ${thresholds.minObfuscatedSamples}`,
  );
  const precision = ratio(metrics?.precision);
  add(
    "metrics.precision",
    precision !== null && precision >= thresholds.minPrecision,
    precision,
    `finite ratio >= ${thresholds.minPrecision}`,
  );
  const recall = ratio(metrics?.recall);
  add(
    "metrics.recall",
    recall !== null && recall >= thresholds.minRecall,
    recall,
    `finite ratio >= ${thresholds.minRecall}`,
  );
  const falsePositiveRate = ratio(metrics?.falsePositiveRate);
  add(
    "metrics.false-positive-rate",
    falsePositiveRate !== null &&
      falsePositiveRate <= thresholds.maxFalsePositiveRate,
    falsePositiveRate,
    `finite ratio <= ${thresholds.maxFalsePositiveRate}`,
  );
  const obfuscatedRecall = ratio(metrics?.obfuscatedRecall);
  add(
    "metrics.obfuscated-recall",
    obfuscatedRecall !== null &&
      obfuscatedRecall >= thresholds.minObfuscatedRecall,
    obfuscatedRecall,
    `finite ratio >= ${thresholds.minObfuscatedRecall}`,
  );

  const performance = evidence.performance;
  const performanceSamples = nonNegativeInteger(performance?.sampleCount);
  add(
    "performance.sample-count",
    performanceSamples !== null &&
      performanceSamples >= thresholds.minPerformanceSamples,
    performanceSamples,
    `>= ${thresholds.minPerformanceSamples}`,
  );
  const overhead = finiteNumber(performance?.p95OverheadPercent);
  add(
    "performance.p95-overhead-percent",
    overhead !== null &&
      overhead >= 0 &&
      overhead <= thresholds.maxP95OverheadPercent,
    overhead,
    `finite percent between 0 and ${thresholds.maxP95OverheadPercent}`,
  );

  const breakage = evidence.breakage;
  const testedSites = nonNegativeInteger(breakage?.testedSites);
  const majorBreakages = nonNegativeInteger(breakage?.majorBreakages);
  add(
    "breakage.site-count",
    testedSites !== null && testedSites >= thresholds.minBreakageSites,
    testedSites,
    `>= ${thresholds.minBreakageSites}`,
  );
  const breakageCountsConsistent =
    testedSites !== null &&
    testedSites > 0 &&
    majorBreakages !== null &&
    majorBreakages <= testedSites;
  add(
    "breakage.count-consistent",
    breakageCountsConsistent,
    majorBreakages,
    "integer major breakages between 0 and tested sites",
  );
  const majorBreakageRate = breakageCountsConsistent
    ? majorBreakages / testedSites
    : null;
  add(
    "breakage.major-rate",
    majorBreakageRate !== null &&
      majorBreakageRate <= thresholds.maxMajorBreakageRate,
    majorBreakageRate,
    `<= ${thresholds.maxMajorBreakageRate}`,
  );

  const v8 = evidence.v8Shadow;
  const observedFunctions = nonNegativeInteger(v8?.observedFunctions);
  add(
    "v8.observed-functions",
    observedFunctions !== null &&
      observedFunctions >= thresholds.minV8ObservedFunctions,
    observedFunctions,
    `>= ${thresholds.minV8ObservedFunctions}`,
  );
  const distinctSites = nonNegativeInteger(v8?.distinctSites);
  add(
    "v8.distinct-sites",
    distinctSites !== null && distinctSites >= thresholds.minV8DistinctSites,
    distinctSites,
    `>= ${thresholds.minV8DistinctSites}`,
  );
  const crashes = nonNegativeInteger(v8?.crashes);
  const crashCountsConsistent =
    observedFunctions !== null &&
    observedFunctions > 0 &&
    crashes !== null &&
    crashes <= observedFunctions;
  add(
    "v8.crash-count-consistent",
    crashCountsConsistent,
    crashes,
    "integer crashes between 0 and observed functions",
  );
  const crashRate = crashCountsConsistent ? crashes / observedFunctions : null;
  add(
    "v8.crash-rate",
    crashRate !== null && crashRate <= thresholds.maxV8CrashRate,
    crashRate,
    `<= ${thresholds.maxV8CrashRate}`,
  );
  const wouldBlockCount = nonNegativeInteger(v8?.wouldBlockCount);
  add(
    "v8.would-block-zero",
    wouldBlockCount === 0,
    wouldBlockCount,
    "exactly 0",
  );

  const safety = evidence.safety;
  add(
    "safety.fail-open-verified",
    safety?.failOpenVerified === true,
    safety?.failOpenVerified ?? null,
    "true",
  );
  add(
    "safety.kill-switch-verified",
    safety?.killSwitchVerified === true,
    safety?.killSwitchVerified ?? null,
    "true",
  );
  add(
    "safety.rollback-verified",
    safety?.rollbackVerified === true,
    safety?.rollbackVerified ?? null,
    "true",
  );

  const privacy = evidence.privacy;
  add(
    "privacy.audit-complete",
    privacy?.auditComplete === true,
    privacy?.auditComplete ?? null,
    "true",
  );
  add(
    "privacy.source-free-telemetry",
    privacy?.sourceFreeTelemetryVerified === true,
    privacy?.sourceFreeTelemetryVerified ?? null,
    "true",
  );
  add(
    "privacy.bounded-retention",
    privacy?.boundedRetentionVerified === true,
    privacy?.boundedRetentionVerified ?? null,
    "true",
  );

  const components = evidence.optionalComponents;
  const localModelStatus = components?.localModel?.status ?? null;
  add(
    "components.local-model-status",
    localModelStatus !== null &&
      LOCAL_MODEL_STATUSES.has(localModelStatus as ScriptRiskLocalModelGateStatus),
    localModelStatus,
    "disabled, advisory-only, or validated-advisory",
  );
  add(
    "components.local-model-no-raw-source",
    components?.localModel?.receivesRawSource === false,
    components?.localModel?.receivesRawSource ?? null,
    "false",
  );
  add(
    "components.local-model-advisory-only",
    components?.localModel?.canChangeDecision === false,
    components?.localModel?.canChangeDecision ?? null,
    "false",
  );
  const federatedStatus = components?.federated?.status ?? null;
  add(
    "components.federated-status",
    federatedStatus !== null &&
      FEDERATED_STATUSES.has(
        federatedStatus as ScriptRiskFederatedGateStatus,
      ),
    federatedStatus,
    "disabled, simulation-only, or research-validated",
  );
  add(
    "components.federated-no-raw-updates",
    components?.federated?.retainsRawClientUpdates === false,
    components?.federated?.retainsRawClientUpdates ?? null,
    "false",
  );
  add(
    "components.federated-no-client-identifiers",
    components?.federated?.retainsClientIdentifiers === false,
    components?.federated?.retainsClientIdentifiers ?? null,
    "false",
  );
  add(
    "components.federated-not-enforcement",
    components?.federated?.usedForEnforcement === false,
    components?.federated?.usedForEnforcement ?? null,
    "false",
  );

  const failedChecks = checks
    .filter((check) => check.status === "fail")
    .map((check) => check.id);
  const claimsComplete = failedChecks.length === 0;
  return {
    schemaVersion: 1,
    trustLevel: "unverified-claims",
    currentMode: "observe-only",
    eligibility: "observe-only",
    wouldBlock: false,
    claimsComplete,
    authorizationEligible: false,
    limitedBlockingEligible: false,
    thresholds,
    checks,
    failedChecks,
  };
}
