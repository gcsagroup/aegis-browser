import { createHash } from "node:crypto";
import { constants, lstatSync, readFileSync, realpathSync } from "node:fs";
import {
  lstat,
  mkdir,
  open,
  realpath,
  unlink,
} from "node:fs/promises";
import { basename, dirname, relative, resolve, sep } from "node:path";

const SHA256_PATTERN = /^[a-f0-9]{64}$/u;
const REVISION_PATTERN = /^[a-f0-9]{40}$/u;
const REPOSITORY_PATTERN = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/u;
const ID_PATTERN = /^[a-z0-9][a-z0-9._-]{2,127}$/u;
const SOURCE_PATH_PATTERN = /^[A-Za-z0-9._/-]+\.(?:js|mjs|cjs|ts)$/u;
const LABELS = new Set(["benign-control", "mining-capable"]);
const OBFUSCATION_TIERS = new Set([
  "none",
  "minified",
  "identifier-renamed",
  "string-encoded",
  "control-flow",
]);

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

function canonicalValue(value) {
  if (value === null || typeof value === "boolean" || typeof value === "string") {
    return value;
  }
  if (typeof value === "number") {
    assert(Number.isFinite(value), "canonical JSON rejects non-finite numbers");
    return value;
  }
  if (Array.isArray(value)) return value.map(canonicalValue);
  assert(value && typeof value === "object", "canonical JSON rejects this value");
  const normalized = {};
  for (const key of Object.keys(value).sort()) {
    assert(value[key] !== undefined, "canonical JSON rejects undefined values");
    normalized[key] = canonicalValue(value[key]);
  }
  return normalized;
}

export function canonicalJson(value) {
  return JSON.stringify(canonicalValue(value));
}

export function sha256Hex(value) {
  return createHash("sha256").update(value).digest("hex");
}

function normalizedUtcTimestamp(value, field) {
  const text = requiredString(value, field, 64);
  const timestamp = Date.parse(text);
  assert(Number.isFinite(timestamp), `${field} must be an ISO timestamp`);
  assert(new Date(timestamp).toISOString() === text, `${field} must be normalized UTC`);
  return text;
}

function normalizedSourcePath(value, field) {
  const path = requiredString(value, field, 512);
  assert(SOURCE_PATH_PATTERN.test(path), `${field} must be a JavaScript/TypeScript path`);
  assert(!path.startsWith("/") && !path.includes("//"), `${field} must be relative`);
  const segments = path.split("/");
  assert(
    segments.every((segment) => segment !== "." && segment !== ".."),
    `${field} contains traversal`,
  );
  return path;
}

function pathWithin(root, candidate) {
  const fromRoot = relative(resolve(root), resolve(candidate));
  return (
    fromRoot === "" ||
    (fromRoot !== ".." && !fromRoot.startsWith(`..${sep}`) && !fromRoot.startsWith(sep))
  );
}

export function buildPublicPilotPlan(definition) {
  assert(definition && typeof definition === "object", "definition is required");
  assert(definition.schemaVersion === 1, "unsupported schemaVersion");
  assert(definition.mode === "research-only", "pilot must be research-only");
  const datasetId = requiredString(definition.datasetId, "datasetId", 128);
  normalizedUtcTimestamp(definition.createdAt, "createdAt");
  assert(definition.task?.target === "browser-mining-capability", "unexpected task target");
  assert(definition.task?.positiveLabel === "mining-capable", "unexpected positive label");
  assert(definition.task?.negativeLabel === "benign-control", "unexpected negative label");
  assert(definition.task?.publiclyInspectable === true, "pilot must remain public");
  assert(definition.task?.independentLabelReview === false, "pilot is not independently labeled");
  assert(definition.task?.sealed === false, "pilot is not sealed");
  assert(
    definition.task?.contextualMaliciousnessInferred === false,
    "source alone cannot establish malicious deployment context",
  );
  const acquisition = definition.acquisition;
  assert(acquisition?.transport === "https-pinned-github-raw", "unexpected transport");
  assert(acquisition?.allowedHost === "raw.githubusercontent.com", "unexpected host");
  assert(acquisition?.sourceExecution === false, "source execution must be disabled");
  assert(acquisition?.localOnly === true, "pilot artifacts must stay local");
  assert(acquisition?.redistributeWithProduct === false, "pilot artifacts cannot ship");
  assert(
    Number.isSafeInteger(acquisition?.maxFileBytes) && acquisition.maxFileBytes > 0,
    "maxFileBytes is invalid",
  );
  assert(
    Number.isSafeInteger(acquisition?.maxTotalBytes) &&
      acquisition.maxTotalBytes >= acquisition.maxFileBytes,
    "maxTotalBytes is invalid",
  );
  assert(definition.sources && typeof definition.sources === "object", "sources required");
  assert(Array.isArray(definition.samples) && definition.samples.length >= 3, "samples required");

  const normalizedSources = new Map();
  for (const [sourceId, source] of Object.entries(definition.sources)) {
    assert(ID_PATTERN.test(sourceId), `invalid source id: ${sourceId}`);
    const repository = requiredString(source?.repository, `${sourceId}.repository`, 256);
    const revision = requiredString(source?.revision, `${sourceId}.revision`, 40);
    assert(REPOSITORY_PATTERN.test(repository), `${sourceId}.repository is invalid`);
    assert(REVISION_PATTERN.test(revision), `${sourceId}.revision must be a full commit`);
    normalizedUtcTimestamp(source?.retrievedAt, `${sourceId}.retrievedAt`);
    const purposeEvidenceUrl = new URL(
      requiredString(source?.purposeEvidenceUrl, `${sourceId}.purposeEvidenceUrl`),
    );
    assert(purposeEvidenceUrl.protocol === "https:", `${sourceId} evidence must use HTTPS`);
    assert(purposeEvidenceUrl.hostname === "github.com", `${sourceId} evidence must use GitHub`);
    assert(
      purposeEvidenceUrl.pathname.includes(`/${revision}`),
      `${sourceId} evidence URL must pin the revision`,
    );
    const licenseUrl = new URL(requiredString(source?.license?.url, `${sourceId}.license.url`));
    assert(licenseUrl.protocol === "https:", `${sourceId} license must use HTTPS`);
    assert(licenseUrl.hostname === "github.com", `${sourceId} license must use GitHub`);
    assert(
      licenseUrl.pathname.includes(`/${revision}/`),
      `${sourceId} license URL must pin the revision`,
    );
    normalizedSources.set(sourceId, {
      repository,
      revision,
      licenseSpdx: requiredString(source?.license?.spdx, `${sourceId}.license.spdx`, 64),
    });
  }

  const seenSamples = new Set();
  const filesByKey = new Map();
  const labelCounts = { "benign-control": 0, "mining-capable": 0 };
  const samples = definition.samples.map((sample, sampleIndex) => {
    const field = `samples[${sampleIndex}]`;
    const sampleId = requiredString(sample?.sampleId, `${field}.sampleId`, 128);
    assert(ID_PATTERN.test(sampleId), `${field}.sampleId is invalid`);
    assert(!seenSamples.has(sampleId), `duplicate sampleId: ${sampleId}`);
    seenSamples.add(sampleId);
    const sourceRef = requiredString(sample?.sourceRef, `${field}.sourceRef`, 128);
    const source = normalizedSources.get(sourceRef);
    assert(source, `${field}.sourceRef is unknown`);
    const label = requiredString(sample?.label, `${field}.label`, 32);
    assert(LABELS.has(label), `${field}.label is invalid`);
    labelCounts[label] += 1;
    const obfuscationTier = requiredString(
      sample?.obfuscationTier,
      `${field}.obfuscationTier`,
      64,
    );
    assert(OBFUSCATION_TIERS.has(obfuscationTier), `${field}.obfuscationTier is invalid`);
    assert(Array.isArray(sample?.files) && sample.files.length > 0, `${field}.files required`);
    const files = sample.files.map((file, fileIndex) => {
      const fileField = `${field}.files[${fileIndex}]`;
      const remotePath = normalizedSourcePath(file?.remotePath, `${fileField}.remotePath`);
      const byteLength = file?.byteLength;
      assert(
        Number.isSafeInteger(byteLength) && byteLength >= 0 && byteLength <= acquisition.maxFileBytes,
        `${fileField}.byteLength is invalid`,
      );
      const sha256 = requiredString(file?.sha256, `${fileField}.sha256`, 64);
      assert(SHA256_PATTERN.test(sha256), `${fileField}.sha256 is invalid`);
      const key = `${sourceRef}\0${remotePath}`;
      const retained = filesByKey.get(key);
      const descriptor = { sourceRef, ...source, remotePath, byteLength, sha256 };
      assert(
        !retained || canonicalJson(retained) === canonicalJson(descriptor),
        `conflicting descriptor for ${sourceRef}/${remotePath}`,
      );
      filesByKey.set(key, descriptor);
      return { remotePath, byteLength, sha256 };
    });
    return {
      sampleId,
      sourceRef,
      familyGroup: requiredString(sample?.familyGroup, `${field}.familyGroup`, 128),
      label,
      category: requiredString(sample?.category, `${field}.category`, 128),
      obfuscationTier,
      files,
    };
  });
  assert(labelCounts["benign-control"] > 0, "pilot needs benign controls");
  assert(labelCounts["mining-capable"] > 0, "pilot needs mining-capable controls");

  const files = [...filesByKey.values()]
    .sort((left, right) =>
      `${left.sourceRef}/${left.remotePath}`.localeCompare(`${right.sourceRef}/${right.remotePath}`),
    )
    .map((file) => {
      const url = new URL(
        `https://raw.githubusercontent.com/${file.repository}/${file.revision}/${file.remotePath}`,
      );
      assert(url.hostname === acquisition.allowedHost, "raw URL host mismatch");
      assert(url.username === "" && url.password === "", "raw URL cannot contain credentials");
      assert(url.search === "" && url.hash === "", "raw URL cannot contain query or fragment");
      return {
        sourceRef: file.sourceRef,
        remotePath: file.remotePath,
        localPath: `${file.sourceRef}/${file.remotePath}`,
        url: url.href,
        byteLength: file.byteLength,
        sha256: file.sha256,
      };
    });
  const totalBytes = files.reduce((total, file) => total + file.byteLength, 0);
  assert(totalBytes <= acquisition.maxTotalBytes, "pilot exceeds maxTotalBytes");
  const unsigned = {
    schemaVersion: 1,
    mode: "research-only",
    datasetId,
    publicAndUnsealed: true,
    independentLabelReview: false,
    contextualMaliciousnessInferred: false,
    labels: labelCounts,
    sourceCount: normalizedSources.size,
    sampleCount: samples.length,
    fileCount: files.length,
    totalBytes,
    samples,
    files,
  };
  return {
    ...unsigned,
    definitionSha256: sha256Hex(canonicalJson(definition)),
    planSha256: sha256Hex(canonicalJson(unsigned)),
  };
}

function validateBytes(bytes, descriptor) {
  assert(bytes.length === descriptor.byteLength, `${descriptor.localPath} byte length mismatch`);
  assert(sha256Hex(bytes) === descriptor.sha256, `${descriptor.localPath} SHA-256 mismatch`);
}

async function safeLstat(path) {
  try {
    return await lstat(path);
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

function sameIdentity(left, right) {
  return left.dev === right.dev && left.ino === right.ino;
}

async function safeLocalPath(canonicalRoot, localPath) {
  const candidate = resolve(canonicalRoot, localPath);
  assert(pathWithin(canonicalRoot, candidate), `local path escapes output root: ${localPath}`);
  let parent = canonicalRoot;
  const relativeParent = relative(canonicalRoot, dirname(candidate));
  const segments = relativeParent === "" ? [] : relativeParent.split(sep);
  for (const segment of segments) {
    const requestedDirectory = resolve(parent, segment);
    assert(
      pathWithin(canonicalRoot, requestedDirectory),
      `local parent escapes output root: ${localPath}`,
    );
    await mkdir(requestedDirectory, { mode: 0o700 }).catch((error) => {
      if (error?.code !== "EEXIST") throw error;
    });
    const leaf = await lstat(requestedDirectory);
    assert(
      !leaf.isSymbolicLink() && leaf.isDirectory(),
      `local parent must be a non-symbolic-link directory: ${localPath}`,
    );
    const canonicalParent = await realpath(requestedDirectory);
    assert(
      pathWithin(canonicalRoot, canonicalParent),
      `local parent escapes output root: ${localPath}`,
    );
    parent = canonicalParent;
  }
  const localFile = resolve(parent, basename(candidate));
  assert(pathWithin(canonicalRoot, localFile), `local path escapes output root: ${localPath}`);
  return localFile;
}

function noFollowFlag() {
  return typeof constants.O_NOFOLLOW === "number" ? constants.O_NOFOLLOW : 0;
}

async function validateOpenedLeaf({ canonicalRoot, localPath, descriptor, handle, before }) {
  const opened = await handle.stat();
  assert(opened.isFile(), `${descriptor.localPath} is not a regular file`);
  const after = await lstat(localPath);
  assert(
    !after.isSymbolicLink() && after.isFile(),
    `${descriptor.localPath} must not be a symbolic link`,
  );
  assert(sameIdentity(opened, after), `${descriptor.localPath} changed while opening`);
  if (before) {
    assert(sameIdentity(before, opened), `${descriptor.localPath} changed while opening`);
  }
  const canonicalParent = await realpath(dirname(localPath));
  assert(
    pathWithin(canonicalRoot, canonicalParent),
    `${descriptor.localPath} parent escaped output root`,
  );
  const canonicalFile = await realpath(localPath);
  assert(
    pathWithin(canonicalRoot, canonicalFile),
    `${descriptor.localPath} escaped output root`,
  );
  assert(opened.nlink === 1, `${descriptor.localPath} must not be hard-linked`);
  return opened;
}

async function readExactFromHandle(handle, byteLength) {
  const bytes = Buffer.alloc(byteLength);
  let offset = 0;
  while (offset < bytes.length) {
    const { bytesRead } = await handle.read(
      bytes,
      offset,
      bytes.length - offset,
      offset,
    );
    assert(bytesRead > 0, "file ended before its declared byte length");
    offset += bytesRead;
  }
  return bytes;
}

async function readExistingBoundFile({
  canonicalRoot,
  localPath,
  descriptor,
  normalizeMode,
}) {
  const before = await safeLstat(localPath);
  if (!before) return null;
  // 必须在 open/read/chmod 前检查调用方给出的原始叶子，而不是 realpath 后的目标。
  assert(
    !before.isSymbolicLink() && before.isFile(),
    `${descriptor.localPath} must not be a symbolic link`,
  );
  const canonicalParent = await realpath(dirname(localPath));
  assert(
    pathWithin(canonicalRoot, canonicalParent),
    `${descriptor.localPath} parent escaped output root`,
  );
  const handle = await open(
    localPath,
    constants.O_RDONLY | noFollowFlag(),
  );
  try {
    const opened = await validateOpenedLeaf({
      canonicalRoot,
      localPath,
      descriptor,
      handle,
      before,
    });
    assert(opened.size === descriptor.byteLength, `${descriptor.localPath} byte length mismatch`);
    const bytes = await readExactFromHandle(handle, descriptor.byteLength);
    validateBytes(bytes, descriptor);
    if (normalizeMode) {
      const beforeChmod = await handle.stat();
      assert(
        sameIdentity(opened, beforeChmod) && beforeChmod.nlink === 1,
        `${descriptor.localPath} changed before chmod`,
      );
      await handle.chmod(0o600);
    }
    return bytes;
  } finally {
    await handle.close();
  }
}

async function unlinkCreatedIfOwned(item) {
  const current = await safeLstat(item.localPath);
  if (
    current &&
    !current.isSymbolicLink() &&
    sameIdentity(current, item.identity)
  ) {
    await unlink(item.localPath);
  }
}

async function createBoundFile({ canonicalRoot, localPath, descriptor, bytes }) {
  const before = await safeLstat(localPath);
  assert(!before, `${descriptor.localPath} appeared before exclusive creation`);
  const canonicalParent = await realpath(dirname(localPath));
  assert(
    pathWithin(canonicalRoot, canonicalParent),
    `${descriptor.localPath} parent escaped output root`,
  );
  const handle = await open(
    localPath,
    constants.O_CREAT |
      constants.O_EXCL |
      constants.O_RDWR |
      noFollowFlag(),
    0o600,
  );
  let identity;
  let failure;
  try {
    // 先记录 O_EXCL 刚创建的 inode；后续任何范围校验失败也只回滚这一 inode。
    identity = await handle.stat();
    const validatedIdentity = await validateOpenedLeaf({
      canonicalRoot,
      localPath,
      descriptor,
      handle,
      before: null,
    });
    assert(
      sameIdentity(identity, validatedIdentity),
      `${descriptor.localPath} changed after exclusive creation`,
    );
    await handle.writeFile(bytes);
    await handle.sync();
    const written = await handle.stat();
    assert(
      sameIdentity(identity, written) && written.size === descriptor.byteLength,
      `${descriptor.localPath} changed while writing`,
    );
    const stored = await readExactFromHandle(handle, descriptor.byteLength);
    validateBytes(stored, descriptor);
    const beforeChmod = await handle.stat();
    assert(
      sameIdentity(identity, beforeChmod) && beforeChmod.nlink === 1,
      `${descriptor.localPath} changed before chmod`,
    );
    await handle.chmod(0o600);
    await handle.sync();
    return { localPath, identity };
  } catch (error) {
    failure = error;
  } finally {
    await handle.close();
  }
  if (identity) await unlinkCreatedIfOwned({ localPath, identity });
  throw failure;
}

async function fetchPinnedFile(descriptor, fetchImpl) {
  const response = await fetchImpl(descriptor.url, {
    cache: "no-store",
    credentials: "omit",
    redirect: "error",
    referrerPolicy: "no-referrer",
  });
  assert(response?.status === 200 && response.ok === true, `${descriptor.localPath} HTTP failure`);
  const declaredLength = response.headers?.get?.("content-length");
  const contentEncoding = response.headers?.get?.("content-encoding");
  // fetch 返回的是解压后的实体字节；压缩传输的 Content-Length 不是实体长度。
  if (
    declaredLength !== null &&
    declaredLength !== undefined &&
    (!contentEncoding || contentEncoding === "identity")
  ) {
    assert(Number(declaredLength) === descriptor.byteLength, `${descriptor.localPath} Content-Length mismatch`);
  }
  const bytes = Buffer.from(await response.arrayBuffer());
  validateBytes(bytes, descriptor);
  return bytes;
}

/**
 * 获取对象只会被当作字节保存和哈希；本函数不会 import、eval 或运行其内容。
 */
export async function acquirePublicPilot({
  definition,
  outputRoot,
  offline = false,
  fetchImpl = globalThis.fetch,
  acquiredAt = new Date().toISOString(),
}) {
  const plan = buildPublicPilotPlan(definition);
  assert(typeof fetchImpl === "function", "fetch implementation is required");
  await mkdir(outputRoot, { recursive: true, mode: 0o700 });
  const outputLeaf = await lstat(resolve(outputRoot));
  assert(
    !outputLeaf.isSymbolicLink() && outputLeaf.isDirectory(),
    "outputRoot must be a non-symbolic-link directory",
  );
  const canonicalRoot = await realpath(outputRoot);
  const prepared = [];
  for (const descriptor of plan.files) {
    const localPath = await safeLocalPath(canonicalRoot, descriptor.localPath);
    const existing = await readExistingBoundFile({
      canonicalRoot,
      localPath,
      descriptor,
      normalizeMode: false,
    });
    if (offline) {
      assert(existing, `${descriptor.localPath} missing in offline mode`);
      prepared.push({ descriptor, localPath, bytes: existing, existing: true });
    } else {
      const bytes = await fetchPinnedFile(descriptor, fetchImpl);
      prepared.push({ descriptor, localPath, bytes, existing: existing !== null });
    }
  }

  const created = [];
  try {
    for (const item of prepared) {
      if (!item.existing) {
        created.push(
          await createBoundFile({
            canonicalRoot,
            localPath: item.localPath,
            descriptor: item.descriptor,
            bytes: item.bytes,
          }),
        );
      } else {
        const retained = await readExistingBoundFile({
          canonicalRoot,
          localPath: item.localPath,
          descriptor: item.descriptor,
          normalizeMode: true,
        });
        assert(retained, `${item.descriptor.localPath} disappeared before commit`);
      }
    }
  } catch (error) {
    for (const item of created.reverse()) await unlinkCreatedIfOwned(item);
    throw error;
  }

  normalizedUtcTimestamp(acquiredAt, "acquiredAt");
  return {
    schemaVersion: 1,
    mode: "research-only",
    releaseEligible: false,
    finalEvaluationEligible: false,
    enforcementAuthorized: false,
    datasetId: plan.datasetId,
    acquisitionMode: offline ? "offline-verify" : "pinned-network-acquisition",
    acquiredAt,
    definitionSha256: plan.definitionSha256,
    planSha256: plan.planSha256,
    sampleCount: plan.sampleCount,
    sourceCount: plan.sourceCount,
    fileCount: plan.fileCount,
    totalBytes: plan.totalBytes,
    labels: plan.labels,
    dataHandling: {
      sourceExecution: false,
      localOnly: true,
      redistributedWithProduct: false,
      publiclyInspectable: true,
      independentLabelReview: false,
      contextualMaliciousnessInferred: false,
    },
    files: prepared.map(({ descriptor }) => ({
      localPath: descriptor.localPath,
      byteLength: descriptor.byteLength,
      sha256: descriptor.sha256,
    })),
  };
}

export function readPublicPilotDefinition(path) {
  const requestedPath = resolve(path);
  const leaf = lstatSync(requestedPath);
  assert(leaf.isFile() && !leaf.isSymbolicLink(), "definition must be a regular file");
  const canonicalPath = realpathSync(requestedPath);
  const metadata = lstatSync(canonicalPath);
  assert(metadata.isFile(), "definition must be a regular file");
  return JSON.parse(readFileSync(canonicalPath, "utf8"));
}
