import { STATIC_SCRIPT_SIGNAL_CODES, type ScriptRiskAssessment } from "./types.js";

const MAX_FEATURES = 64;
const MAX_CLIENTS = 1_000;
const MAX_EXAMPLES_PER_CLIENT = 10_000;
const MAX_ROUNDS = 100;
const MAX_LOCAL_EPOCHS = 10;

export const SCRIPT_RISK_FEDERATED_FEATURES = [
  ...STATIC_SCRIPT_SIGNAL_CODES,
  "runtime.sustained-cpu",
  "runtime.worker-fanout",
  "runtime.wasm-execution",
  "runtime.webgpu-compute",
  "runtime.websocket",
  "runtime.mining-protocol",
  "runtime.sensitive-read",
  "runtime.network-send",
  "graph.sensitive-to-network",
  "aggregate.mining-multisignal",
  "aggregate.obfuscated-loader-multisignal",
  "aggregate.sensitive-exfiltration",
  "meta.risk-score",
  "meta.medium-findings",
  "meta.high-findings",
] as const;

export interface FederatedScriptRiskExample {
  features: readonly number[];
  label: 0 | 1;
}

export interface FederatedScriptRiskClient {
  /** Used only by the caller. It is never copied into the simulation report. */
  clientId: string;
  examples: readonly FederatedScriptRiskExample[];
}

export interface FederatedPrivacyOptions {
  /** Participant-level target for this bounded simulation, not a deployment claim. */
  epsilon: number;
  delta: number;
  clipNorm: number;
}

export interface FederatedSimulationOptions {
  rounds?: number;
  clientsPerRound?: number;
  localEpochs?: number;
  learningRate?: number;
  simulationSeed?: number;
  privacy: FederatedPrivacyOptions;
}

export interface FederatedRoundReport {
  round: number;
  selectedClients: number;
  clippedUpdates: number;
  meanClientLoss: number;
  gaussianNoiseStddev: number;
  maskCancellationResidual: number;
}

export interface FederatedScriptRiskModel {
  schemaVersion: 1;
  kind: "script-risk-logistic-regression";
  featureCount: number;
  weights: number[];
  bias: number;
}

export interface FederatedSimulationReport {
  schemaVersion: 1;
  mode: "local-federated-simulation";
  model: FederatedScriptRiskModel;
  rounds: FederatedRoundReport[];
  privacy: {
    adjacency: "replace-one-participant";
    accountant: "basic-composition-gaussian-upper-bound";
    targetEpsilon: number;
    targetDelta: number;
    clipNorm: number;
  };
  secureAggregation: "pairwise-mask-simulation";
  rawClientUpdatesRetained: false;
  clientIdentifiersRetained: false;
  deploymentEligible: false;
}

function finiteInRange(
  value: number,
  name: string,
  minimum: number,
  maximum: number,
): number {
  if (!Number.isFinite(value) || value < minimum || value > maximum) {
    throw new RangeError(`${name} must be between ${minimum} and ${maximum}`);
  }
  return value;
}

function requireFinite(value: number, name: string): number {
  if (!Number.isFinite(value)) {
    throw new RangeError(`${name} must remain finite`);
  }
  return value;
}

function requireFiniteVector(values: readonly number[], name: string): void {
  if (!values.every(Number.isFinite)) {
    throw new RangeError(`${name} must contain only finite values`);
  }
}

function boundedInteger(
  value: number | undefined,
  fallback: number,
  name: string,
  maximum: number,
): number {
  const selected = value ?? fallback;
  if (!Number.isSafeInteger(selected) || selected < 1 || selected > maximum) {
    throw new RangeError(`${name} must be an integer between 1 and ${maximum}`);
  }
  return selected;
}

function seededRandom(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let value = state;
    value = Math.imul(value ^ (value >>> 15), value | 1);
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
    return ((value ^ (value >>> 14)) >>> 0) / 4_294_967_296;
  };
}

function gaussian(random: () => number): number {
  const left = Math.max(Number.EPSILON, random());
  const right = random();
  return Math.sqrt(-2 * Math.log(left)) * Math.cos(2 * Math.PI * right);
}

function sigmoid(value: number): number {
  if (value >= 0) {
    const exponent = Math.exp(-value);
    return 1 / (1 + exponent);
  }
  const exponent = Math.exp(value);
  return exponent / (1 + exponent);
}

function dot(left: readonly number[], right: readonly number[]): number {
  let total = 0;
  for (let index = 0; index < left.length; index += 1) {
    total += (left[index] ?? 0) * (right[index] ?? 0);
  }
  return total;
}

function l2Norm(values: readonly number[]): number {
  return Math.sqrt(values.reduce((sum, value) => sum + value * value, 0));
}

function clampFeature(value: number): number {
  if (!Number.isFinite(value)) return 0;
  return Math.max(-1, Math.min(1, value));
}

/** Stable, categorical vector with no site, URL, source, payload, or flow ID. */
export function vectorizeScriptRiskForFederatedTraining(
  assessment: ScriptRiskAssessment,
): number[] {
  const counts = new Map(assessment.reasons.map((reason) => [reason.code, reason.occurrences]));
  const medium = assessment.findings.filter((finding) => finding.confidence === "medium").length;
  const high = assessment.findings.filter((finding) => finding.confidence === "high").length;
  return SCRIPT_RISK_FEDERATED_FEATURES.map((feature) => {
    if (feature === "meta.risk-score") return clampFeature(assessment.riskScore / 100);
    if (feature === "meta.medium-findings") return clampFeature(medium / 4);
    if (feature === "meta.high-findings") return clampFeature(high / 4);
    return clampFeature((counts.get(feature) ?? 0) / 8);
  });
}

function validateClients(clients: readonly FederatedScriptRiskClient[]): number {
  if (clients.length < 2 || clients.length > MAX_CLIENTS) {
    throw new RangeError(`clients must contain between 2 and ${MAX_CLIENTS} participants`);
  }
  let featureCount = 0;
  for (const client of clients) {
    if (!client.clientId.trim()) throw new TypeError("clientId must not be empty");
    if (client.examples.length < 1 || client.examples.length > MAX_EXAMPLES_PER_CLIENT) {
      throw new RangeError(
        `each client must contain between 1 and ${MAX_EXAMPLES_PER_CLIENT} examples`,
      );
    }
    for (const example of client.examples) {
      if (example.label !== 0 && example.label !== 1) {
        throw new TypeError("labels must be 0 or 1");
      }
      if (featureCount === 0) featureCount = example.features.length;
      if (
        example.features.length !== featureCount ||
        featureCount < 1 ||
        featureCount > MAX_FEATURES
      ) {
        throw new RangeError(`all examples must have 1 to ${MAX_FEATURES} features`);
      }
      if (example.features.some((value) => !Number.isFinite(value))) {
        throw new TypeError("features must be finite");
      }
    }
  }
  return featureCount;
}

function clientDelta(
  client: FederatedScriptRiskClient,
  weights: readonly number[],
  bias: number,
  learningRate: number,
  localEpochs: number,
): { delta: number[]; biasDelta: number; meanLoss: number } {
  const localWeights = [...weights];
  let localBias = bias;
  let totalLoss = 0;
  for (let epoch = 0; epoch < localEpochs; epoch += 1) {
    const gradient = new Array<number>(weights.length).fill(0);
    let biasGradient = 0;
    totalLoss = 0;
    for (const example of client.examples) {
      const features = example.features.map(clampFeature);
      const prediction = sigmoid(dot(localWeights, features) + localBias);
      const error = prediction - example.label;
      for (let index = 0; index < gradient.length; index += 1) {
        gradient[index] = (gradient[index] ?? 0) + error * (features[index] ?? 0);
      }
      biasGradient += error;
      const probability = Math.max(1e-12, Math.min(1 - 1e-12, prediction));
      totalLoss += example.label === 1 ? -Math.log(probability) : -Math.log(1 - probability);
    }
    const scale = 1 / client.examples.length;
    for (let index = 0; index < localWeights.length; index += 1) {
      localWeights[index] =
        (localWeights[index] ?? 0) - learningRate * (gradient[index] ?? 0) * scale;
    }
    localBias -= learningRate * biasGradient * scale;
  }
  return {
    delta: localWeights.map((value, index) => value - (weights[index] ?? 0)),
    biasDelta: localBias - bias,
    meanLoss: totalLoss / client.examples.length,
  };
}

function clipUpdate(
  delta: readonly number[],
  biasDelta: number,
  clipNorm: number,
): { values: number[]; clipped: boolean } {
  const values = [...delta, biasDelta];
  const norm = l2Norm(values);
  requireFinite(norm, "participant update norm");
  if (norm <= clipNorm || norm === 0) return { values, clipped: false };
  const scale = clipNorm / norm;
  return { values: values.map((value) => value * scale), clipped: true };
}

function selectClients(
  clients: readonly FederatedScriptRiskClient[],
  count: number,
  random: () => number,
): FederatedScriptRiskClient[] {
  const indices = clients.map((_, index) => index);
  for (let index = indices.length - 1; index > 0; index -= 1) {
    const swap = Math.floor(random() * (index + 1));
    [indices[index], indices[swap]] = [indices[swap] ?? index, indices[index] ?? swap];
  }
  return indices.slice(0, count).map((index) => clients[index] as FederatedScriptRiskClient);
}

function pairwiseMaskedMean(
  updates: readonly number[][],
  random: () => number,
): { mean: number[]; residual: number } {
  const masked = updates.map((update) => [...update]);
  const unmaskedSum = new Array<number>(updates[0]?.length ?? 0).fill(0);
  for (const update of updates) {
    update.forEach((value, index) => {
      unmaskedSum[index] = (unmaskedSum[index] ?? 0) + value;
    });
  }
  for (let left = 0; left < masked.length; left += 1) {
    for (let right = left + 1; right < masked.length; right += 1) {
      for (let feature = 0; feature < unmaskedSum.length; feature += 1) {
        const mask = (random() - 0.5) * 2;
        masked[left]![feature] = (masked[left]![feature] ?? 0) + mask;
        masked[right]![feature] = (masked[right]![feature] ?? 0) - mask;
      }
    }
  }
  const maskedSum = new Array<number>(unmaskedSum.length).fill(0);
  for (const update of masked) {
    update.forEach((value, index) => {
      maskedSum[index] = (maskedSum[index] ?? 0) + value;
    });
  }
  const residual = l2Norm(
    maskedSum.map((value, index) => value - (unmaskedSum[index] ?? 0)),
  );
  return {
    mean: maskedSum.map((value) => value / updates.length),
    residual,
  };
}

/**
 * Reproducible local simulator for participant-clipped federated learning. The
 * deterministic seed makes this suitable for tests, not for real privacy. A
 * deployment must replace it with cryptographic randomness and real secure
 * aggregation while preserving the reported clipping/accounting contract.
 */
export function simulatePrivateFederatedScriptRiskTraining(
  clients: readonly FederatedScriptRiskClient[],
  options: FederatedSimulationOptions,
): FederatedSimulationReport {
  const featureCount = validateClients(clients);
  const rounds = boundedInteger(options.rounds, 5, "rounds", MAX_ROUNDS);
  const clientsPerRound = boundedInteger(
    options.clientsPerRound,
    clients.length,
    "clientsPerRound",
    clients.length,
  );
  if (clientsPerRound < 2) throw new RangeError("clientsPerRound must be at least 2");
  const localEpochs = boundedInteger(
    options.localEpochs,
    1,
    "localEpochs",
    MAX_LOCAL_EPOCHS,
  );
  const learningRate = finiteInRange(
    options.learningRate ?? 0.1,
    "learningRate",
    Number.EPSILON,
    10,
  );
  const epsilon = finiteInRange(
    options.privacy.epsilon,
    "privacy.epsilon",
    0.01,
    1_000,
  );
  const delta = finiteInRange(
    options.privacy.delta,
    "privacy.delta",
    Number.MIN_VALUE,
    0.1,
  );
  const clipNorm = finiteInRange(
    options.privacy.clipNorm,
    "privacy.clipNorm",
    Number.EPSILON,
    1_000,
  );
  const seed = options.simulationSeed ?? 0x41e615;
  if (!Number.isSafeInteger(seed)) throw new TypeError("simulationSeed must be an integer");
  const random = seededRandom(seed);
  const weights = new Array<number>(featureCount).fill(0);
  let bias = 0;
  const roundReports: FederatedRoundReport[] = [];

  const epsilonPerRound = epsilon / rounds;
  const deltaPerRound = delta / rounds;
  if (
    !Number.isFinite(epsilonPerRound) ||
    epsilonPerRound <= 0 ||
    !Number.isFinite(deltaPerRound) ||
    deltaPerRound <= 0
  ) {
    throw new RangeError("per-round privacy parameters must remain finite and positive");
  }
  const gaussianLogTerm = Math.log(1.25) - Math.log(deltaPerRound);
  if (!Number.isFinite(gaussianLogTerm) || gaussianLogTerm <= 0) {
    throw new RangeError("per-round privacy delta cannot produce finite Gaussian noise");
  }
  const sensitivity = (2 * clipNorm) / clientsPerRound;
  const noiseStddev = requireFinite(
    (sensitivity * Math.sqrt(2 * gaussianLogTerm)) / epsilonPerRound,
    "Gaussian noise standard deviation",
  );
  for (let round = 1; round <= rounds; round += 1) {
    const selected = selectClients(clients, clientsPerRound, random);
    const updates: number[][] = [];
    let clippedUpdates = 0;
    let loss = 0;
    for (const client of selected) {
      const local = clientDelta(client, weights, bias, learningRate, localEpochs);
      requireFiniteVector(local.delta, "participant update");
      requireFinite(local.biasDelta, "participant bias update");
      requireFinite(local.meanLoss, "participant mean loss");
      const clipped = clipUpdate(local.delta, local.biasDelta, clipNorm);
      requireFiniteVector(clipped.values, "clipped participant update");
      if (clipped.clipped) clippedUpdates += 1;
      updates.push(clipped.values);
      loss += local.meanLoss;
    }
    const aggregate = pairwiseMaskedMean(updates, random);
    requireFiniteVector(aggregate.mean, "aggregated update");
    requireFinite(aggregate.residual, "mask cancellation residual");
    const noised = aggregate.mean.map((value) => value + gaussian(random) * noiseStddev);
    requireFiniteVector(noised, "noised aggregate update");
    for (let index = 0; index < weights.length; index += 1) {
      weights[index] = (weights[index] ?? 0) + (noised[index] ?? 0);
    }
    bias += noised[weights.length] ?? 0;
    requireFiniteVector(weights, "global model weights");
    requireFinite(bias, "global model bias");
    const meanClientLoss = requireFinite(
      loss / selected.length,
      "round mean client loss",
    );
    roundReports.push({
      round,
      selectedClients: selected.length,
      clippedUpdates,
      meanClientLoss,
      gaussianNoiseStddev: noiseStddev,
      maskCancellationResidual: aggregate.residual,
    });
  }

  requireFiniteVector(weights, "final model weights");
  requireFinite(bias, "final model bias");
  for (const report of roundReports) {
    requireFinite(report.meanClientLoss, "reported mean client loss");
    requireFinite(report.gaussianNoiseStddev, "reported Gaussian noise");
    requireFinite(report.maskCancellationResidual, "reported mask residual");
  }

  return {
    schemaVersion: 1,
    mode: "local-federated-simulation",
    model: {
      schemaVersion: 1,
      kind: "script-risk-logistic-regression",
      featureCount,
      weights,
      bias,
    },
    rounds: roundReports,
    privacy: {
      adjacency: "replace-one-participant",
      accountant: "basic-composition-gaussian-upper-bound",
      targetEpsilon: epsilon,
      targetDelta: delta,
      clipNorm,
    },
    secureAggregation: "pairwise-mask-simulation",
    rawClientUpdatesRetained: false,
    clientIdentifiersRetained: false,
    deploymentEligible: false,
  };
}

export function predictFederatedScriptRisk(
  model: FederatedScriptRiskModel,
  features: readonly number[],
): number {
  if (features.length !== model.featureCount || model.weights.length !== model.featureCount) {
    throw new RangeError("feature vector does not match model");
  }
  requireFiniteVector(model.weights, "model weights");
  requireFinite(model.bias, "model bias");
  const probability = sigmoid(
    dot(model.weights, features.map(clampFeature)) + model.bias,
  );
  return requireFinite(probability, "prediction probability");
}
