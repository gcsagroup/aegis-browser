#!/usr/bin/env node

import {
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  openSync,
  readFileSync,
  realpathSync,
} from "node:fs";
import { dirname, extname, isAbsolute, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import {
  buildBlindEnvelope,
  buildLabelEnvelope,
  canonicalJson,
  readJsonFile,
  repositoryFile,
  sha256Hex,
  validatePredictionEnvelope,
  validatePredictionOutput,
  verifyCandidateEnvironment,
  writeJsonExclusive,
} from "../src/script-risk/evaluation/blind-protocol.mjs";
import {
  buildPublicPilotPlan,
  readPublicPilotDefinition,
} from "../src/script-risk/evaluation/public-pilot-acquisition.mjs";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const defaultRepoRoot = resolve(scriptDirectory, "../../..");
const DEFAULT_DEFINITION_PATH =
  "packages/core/src/script-risk/evaluation/protocols/miner-capability-public-v1.json";
const SHA256_PATTERN = /^[a-f0-9]{64}$/u;

function fail(message) {
  throw new Error(message);
}

function exactKeys(value, required, field) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    fail(`${field} 必须是对象`);
  }
  const allowed = new Set(required);
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) fail(`${field}.${key} 不允许出现`);
  }
  for (const key of required) {
    if (!Object.hasOwn(value, key)) fail(`${field}.${key} 必填`);
  }
}

function normalizedTimestamp(value, field) {
  if (typeof value !== "string" || new Date(Date.parse(value)).toISOString() !== value) {
    fail(`${field} 必须是规范 UTC 时间`);
  }
}

function pathWithin(root, candidate) {
  const fromRoot = relative(root, candidate);
  return (
    fromRoot === "" ||
    (fromRoot !== ".." &&
      !fromRoot.startsWith(`..${sep}`) &&
      !isAbsolute(fromRoot))
  );
}

function usage() {
  return `用法：
  node packages/core/scripts/bridge-script-risk-public-pilot.mjs prepare \\
    --candidate <candidate.json> --receipt <acquisition.json> \\
    --source-root <已获取源码目录> --envelope-id <id> --output <unlabelled.json>

  node packages/core/scripts/bridge-script-risk-public-pilot.mjs reveal \\
    --candidate <candidate.json> --receipt <acquisition.json> \\
    --source-root <已获取源码目录> --input <unlabelled.json> \\
    --predictions <predictions.json> --output <labels.json>

可选：--repo-root <path>、--definition <仓库内 miner-capability-public-v1.json>。

prepare 会重建 pinned public plan，严格核对 receipt 和每个本地文件的长度/SHA-256，
再生成不含真实标签、且使用伪名 sampleId 的 blind-v1 envelope。reveal 会再次核对同一
plan、receipt、字节、输入和预测摘要，之后才生成绑定 predictionDigest 的标签 envelope。
公开定义本身包含可查看标签，因此结果始终只是 operator-blinded-local，不是独立 sealed
test。两个模式都拒绝覆盖、拒绝 --final，且不执行任何源码。`;
}

function parseArguments(argv) {
  // pnpm 的嵌套脚本转发会在子命令前保留标准参数分隔符。
  const normalizedArguments = argv.filter((argument) => argument !== "--");
  const [mode, ...rest] = normalizedArguments;
  if (mode === "--help" || mode === "-h") return { help: true };
  if (!['prepare', 'reveal'].includes(mode)) fail("首个参数必须是 prepare 或 reveal");
  const options = {
    mode,
    repoRoot: defaultRepoRoot,
    definition: DEFAULT_DEFINITION_PATH,
  };
  for (let index = 0; index < rest.length; index += 1) {
    const argument = rest[index];
    if (argument === "--") continue;
    if (argument === "--help" || argument === "-h") {
      options.help = true;
      continue;
    }
    if (argument === "--final") {
      fail("--final 不可用：公开标签的本地流程不是 independent-sealed test");
    }
    const key = {
      "--repo-root": "repoRoot",
      "--definition": "definition",
      "--candidate": "candidate",
      "--receipt": "receipt",
      "--source-root": "sourceRoot",
      "--envelope-id": "envelopeId",
      "--input": "input",
      "--predictions": "predictions",
      "--output": "output",
    }[argument];
    if (!key) fail(`未知参数：${argument}`);
    const value = rest[++index];
    if (!value || value.startsWith("--")) fail(`${argument} 缺少值`);
    options[key] = value;
  }
  return options;
}

function validateReceipt(receipt, plan) {
  exactKeys(
    receipt,
    [
      "schemaVersion",
      "mode",
      "releaseEligible",
      "finalEvaluationEligible",
      "enforcementAuthorized",
      "datasetId",
      "acquisitionMode",
      "acquiredAt",
      "definitionSha256",
      "planSha256",
      "sampleCount",
      "sourceCount",
      "fileCount",
      "totalBytes",
      "labels",
      "dataHandling",
      "files",
    ],
    "receipt",
  );
  if (
    receipt.schemaVersion !== 1 ||
    receipt.mode !== "research-only" ||
    receipt.releaseEligible !== false ||
    receipt.finalEvaluationEligible !== false ||
    receipt.enforcementAuthorized !== false
  ) {
    fail("receipt 不能授权发布、final evaluation 或阻断");
  }
  if (!['pinned-network-acquisition', 'offline-verify'].includes(receipt.acquisitionMode)) {
    fail("receipt.acquisitionMode 无效");
  }
  normalizedTimestamp(receipt.acquiredAt, "receipt.acquiredAt");
  for (const [field, expected] of [
    ["datasetId", plan.datasetId],
    ["definitionSha256", plan.definitionSha256],
    ["planSha256", plan.planSha256],
    ["sampleCount", plan.sampleCount],
    ["sourceCount", plan.sourceCount],
    ["fileCount", plan.fileCount],
    ["totalBytes", plan.totalBytes],
  ]) {
    if (receipt[field] !== expected) fail(`receipt.${field} 与 pinned plan 不一致`);
  }
  if (canonicalJson(receipt.labels) !== canonicalJson(plan.labels)) {
    fail("receipt.labels 与 pinned plan 不一致");
  }
  exactKeys(
    receipt.dataHandling,
    [
      "sourceExecution",
      "localOnly",
      "redistributedWithProduct",
      "publiclyInspectable",
      "independentLabelReview",
      "contextualMaliciousnessInferred",
    ],
    "receipt.dataHandling",
  );
  if (
    receipt.dataHandling.sourceExecution !== false ||
    receipt.dataHandling.localOnly !== true ||
    receipt.dataHandling.redistributedWithProduct !== false ||
    receipt.dataHandling.publiclyInspectable !== true ||
    receipt.dataHandling.independentLabelReview !== false ||
    receipt.dataHandling.contextualMaliciousnessInferred !== false
  ) {
    fail("receipt.dataHandling 越过公开 research-only 边界");
  }
  if (!Array.isArray(receipt.files)) fail("receipt.files 必须是数组");
  const expectedFiles = plan.files.map(({ localPath, byteLength, sha256 }) => ({
    localPath,
    byteLength,
    sha256,
  }));
  if (canonicalJson(receipt.files) !== canonicalJson(expectedFiles)) {
    fail("receipt.files 与 pinned plan 不一致");
  }
}

function canonicalSourceRoot(sourceRoot) {
  const requested = resolve(sourceRoot);
  const metadata = lstatSync(requested);
  if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
    fail("--source-root 必须是非符号链接目录");
  }
  return realpathSync(requested);
}

function readBoundSource(sourceRoot, descriptor) {
  const candidate = resolve(sourceRoot, descriptor.localPath);
  if (!pathWithin(sourceRoot, candidate)) fail(`${descriptor.localPath} 逃逸 source root`);
  const before = lstatSync(candidate);
  if (before.isSymbolicLink() || !before.isFile()) {
    fail(`${descriptor.localPath} 必须是非符号链接普通文件`);
  }
  const canonicalParent = realpathSync(dirname(candidate));
  if (!pathWithin(sourceRoot, canonicalParent)) {
    fail(`${descriptor.localPath} 父目录经真实路径逃逸`);
  }
  const noFollow = typeof constants.O_NOFOLLOW === "number" ? constants.O_NOFOLLOW : 0;
  const fileDescriptor = openSync(candidate, constants.O_RDONLY | noFollow);
  try {
    const metadata = fstatSync(fileDescriptor);
    const after = lstatSync(candidate);
    if (
      !metadata.isFile() ||
      after.isSymbolicLink() ||
      !after.isFile() ||
      metadata.dev !== after.dev ||
      metadata.ino !== after.ino
    ) {
      fail(`${descriptor.localPath} 打开期间发生替换`);
    }
    const canonical = realpathSync(candidate);
    if (!pathWithin(sourceRoot, canonical)) fail(`${descriptor.localPath} 经真实路径逃逸`);
    if (metadata.size !== descriptor.byteLength) {
      fail(`${descriptor.localPath} byte length mismatch`);
    }
    const bytes = readFileSync(fileDescriptor);
    if (sha256Hex(bytes) !== descriptor.sha256) {
      fail(`${descriptor.localPath} SHA-256 mismatch`);
    }
    return bytes;
  } finally {
    closeSync(fileDescriptor);
  }
}

function blindedSampleId(candidateDigestSha256, planSha256, sampleId) {
  return `public-${sha256Hex(
    `blind-v1\0${candidateDigestSha256}\0${planSha256}\0${sampleId}`,
  ).slice(0, 32)}`;
}

function blindedLogicalPath(index, remotePath) {
  const extension = extname(remotePath);
  if (!/^\.(?:js|mjs|cjs|ts)$/u.test(extension)) {
    fail("pinned source extension 不在 blind-v1 安全白名单");
  }
  return `file-${String(index + 1).padStart(4, "0")}${extension}`;
}

function loadAuditedPilot({ repoRoot, definitionPath, receiptPath, sourceRoot }) {
  const definitionFile = repositoryFile(repoRoot, definitionPath, "public pilot definition");
  if (definitionFile.repoPath !== DEFAULT_DEFINITION_PATH) {
    fail(`--definition 必须是 ${DEFAULT_DEFINITION_PATH}`);
  }
  const definition = readPublicPilotDefinition(definitionFile.absolute);
  const plan = buildPublicPilotPlan(definition);
  const receiptInput = readJsonFile(receiptPath, 4 * 1024 * 1024, "public pilot receipt");
  validateReceipt(receiptInput.value, plan);
  const canonicalRoot = canonicalSourceRoot(sourceRoot);
  const bytesByLocalPath = new Map();
  for (const descriptor of plan.files) {
    bytesByLocalPath.set(
      descriptor.localPath,
      readBoundSource(canonicalRoot, descriptor),
    );
  }
  return {
    definition,
    plan,
    bytesByLocalPath,
    publicPilot: {
      datasetId: plan.datasetId,
      definitionSha256: plan.definitionSha256,
      planSha256: plan.planSha256,
      receiptSha256: sha256Hex(readFileSync(receiptInput.path)),
      publiclyInspectable: true,
      independentLabelReview: false,
      sealed: false,
    },
  };
}

function materializeEnvelope({ candidate, environment, audited, envelopeId, createdAt }) {
  const { protocol } = environment;
  if (
    audited.definition.task.positiveLabel !== protocol.labels.positiveLabel ||
    audited.definition.task.negativeLabel !== protocol.labels.negativeLabel
  ) {
    fail("public pilot 标签定义与 blind-v1 协议不一致");
  }
  const descriptorByKey = new Map(
    audited.plan.files.map((descriptor) => [
      `${descriptor.sourceRef}\0${descriptor.remotePath}`,
      descriptor,
    ]),
  );
  const seenBlindIds = new Set();
  const samples = audited.plan.samples.map((sample) => {
    const sampleId = blindedSampleId(
      candidate.candidateDigestSha256,
      audited.plan.planSha256,
      sample.sampleId,
    );
    if (seenBlindIds.has(sampleId)) fail("blinded sampleId collision");
    seenBlindIds.add(sampleId);
    return {
      sampleId,
      files: sample.files.map((file, fileIndex) => {
        const descriptor = descriptorByKey.get(
          `${sample.sourceRef}\0${file.remotePath}`,
        );
        if (!descriptor) fail(`${sample.sampleId}/${file.remotePath} 缺少 pinned descriptor`);
        const source = audited.bytesByLocalPath.get(descriptor.localPath);
        if (!source) fail(`${descriptor.localPath} 缺少已校验字节`);
        // envelope 只保留无语义序号与安全扩展名，不能泄露 sourceRef 或仓库路径。
        return {
          path: blindedLogicalPath(fileIndex, file.remotePath),
          source,
        };
      }),
    };
  });
  return buildBlindEnvelope({
    protocol,
    protocolSha256: candidate.protocol.sha256,
    candidateDigestSha256: candidate.candidateDigestSha256,
    envelopeId,
    createdAt,
    publicPilot: audited.publicPilot,
    samples,
  });
}

async function prepare(options, candidate, environment, audited) {
  if (!options.envelopeId) fail("prepare 需要 --envelope-id");
  const envelope = materializeEnvelope({
    candidate,
    environment,
    audited,
    envelopeId: options.envelopeId,
    createdAt: new Date().toISOString(),
  });
  if (Date.parse(candidate.frozenAt) > Date.parse(envelope.createdAt)) {
    fail("blind input.createdAt 不能早于 candidate.frozenAt");
  }
  const outputPath = writeJsonExclusive(options.output, envelope);
  process.stdout.write(
    `${JSON.stringify({
      mode: "prepare",
      evaluationClass: "operator-blinded-local",
      publicAndUnsealed: true,
      labelsIncluded: false,
      sampleCount: envelope.samples.length,
      envelopeDigestSha256: envelope.envelopeDigestSha256,
      outputPath,
    })}\n`,
  );
}

async function reveal(options, candidate, environment, audited) {
  if (!options.input || !options.predictions) {
    fail("reveal 需要 --input 和 --predictions");
  }
  const input = readJsonFile(
    options.input,
    environment.protocol.limits.maxJsonBytes,
    "blind prediction envelope",
  ).value;
  validatePredictionEnvelope(input, environment.protocol, {
    protocolSha256: candidate.protocol.sha256,
    candidateDigestSha256: candidate.candidateDigestSha256,
  });
  const expected = materializeEnvelope({
    candidate,
    environment,
    audited,
    envelopeId: input.envelopeId,
    createdAt: input.createdAt,
  });
  if (canonicalJson(expected) !== canonicalJson(input)) {
    fail("blind prediction envelope 不是由当前 pinned plan、receipt 和本地字节生成");
  }
  const predictions = readJsonFile(
    options.predictions,
    environment.protocol.limits.maxJsonBytes,
    "blind predictions",
  ).value;
  validatePredictionOutput(predictions, environment.protocol, candidate, input);
  const labels = audited.plan.samples.map((sample) => ({
    sampleId: blindedSampleId(
      candidate.candidateDigestSha256,
      audited.plan.planSha256,
      sample.sampleId,
    ),
    actualLabel: sample.label,
    obfuscationTier: sample.obfuscationTier,
  }));
  const createdAt = new Date(
    Math.max(Date.now(), Date.parse(predictions.predictedAt) + 1),
  ).toISOString();
  const labelEnvelope = buildLabelEnvelope({
    protocol: environment.protocol,
    protocolSha256: candidate.protocol.sha256,
    candidateDigestSha256: candidate.candidateDigestSha256,
    predictionDigestSha256: predictions.predictionDigestSha256,
    inputEnvelopeDigestSha256: input.envelopeDigestSha256,
    createdAt,
    publicPilot: audited.publicPilot,
    labels,
  });
  const outputPath = writeJsonExclusive(options.output, labelEnvelope);
  process.stdout.write(
    `${JSON.stringify({
      mode: "reveal",
      evaluationClass: "operator-blinded-local",
      publicAndUnsealed: true,
      independentLabelReview: false,
      sampleCount: labelEnvelope.labels.length,
      predictionDigestSha256: predictions.predictionDigestSha256,
      labelEnvelopeDigestSha256: labelEnvelope.envelopeDigestSha256,
      outputPath,
    })}\n`,
  );
}

export async function main(argv = process.argv.slice(2)) {
  const options = parseArguments(argv);
  if (options.help) {
    process.stdout.write(`${usage()}\n`);
    return;
  }
  for (const key of ["candidate", "receipt", "sourceRoot", "output"]) {
    if (!options[key]) fail(`--${key.replace(/[A-Z]/g, (value) => `-${value.toLowerCase()}`)} 必填`);
  }
  const repoRoot = resolve(options.repoRoot);
  const candidate = readJsonFile(
    resolve(repoRoot, options.candidate),
    2 * 1024 * 1024,
    "candidate lock",
  ).value;
  const environment = verifyCandidateEnvironment(repoRoot, candidate);
  const audited = loadAuditedPilot({
    repoRoot,
    definitionPath: options.definition,
    receiptPath: resolve(repoRoot, options.receipt),
    sourceRoot: resolve(repoRoot, options.sourceRoot),
  });
  const rootedOptions = {
    ...options,
    input: options.input ? resolve(repoRoot, options.input) : undefined,
    predictions: options.predictions
      ? resolve(repoRoot, options.predictions)
      : undefined,
    output: resolve(repoRoot, options.output),
  };
  if (options.mode === "prepare") {
    await prepare(rootedOptions, candidate, environment, audited);
  } else {
    await reveal(rootedOptions, candidate, environment, audited);
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    process.stderr.write(
      `公开 pilot blind bridge 失败：${error instanceof Error ? error.message : String(error)}\n`,
    );
    process.exitCode = 1;
  });
}
