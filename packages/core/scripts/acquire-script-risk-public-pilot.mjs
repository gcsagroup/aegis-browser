#!/usr/bin/env node

import { lstatSync, realpathSync } from "node:fs";
import { mkdir, realpath, writeFile } from "node:fs/promises";
import { dirname, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import {
  acquirePublicPilot,
  readPublicPilotDefinition,
} from "../src/script-risk/evaluation/public-pilot-acquisition.mjs";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const coreDirectory = resolve(scriptDirectory, "..");
const repoRoot = resolve(coreDirectory, "..", "..");
const defaultDefinition = resolve(
  coreDirectory,
  "src/script-risk/evaluation/protocols/miner-capability-public-v1.json",
);
const allowedDataRoot = resolve(repoRoot, ".research-data", "script-risk");
const allowedReceiptRoot = resolve(repoRoot, ".artifacts", "research", "script-risk");

function fail(message) {
  throw new Error(message);
}

function pathWithin(root, candidate) {
  const value = relative(resolve(root), resolve(candidate));
  return value === "" || (value !== ".." && !value.startsWith(`..${sep}`));
}

function parseArgs(argv) {
  const options = { definition: defaultDefinition, offline: false };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--") continue;
    if (argument === "--offline") {
      options.offline = true;
      continue;
    }
    if (argument === "--help" || argument === "-h") {
      options.help = true;
      continue;
    }
    const key = {
      "--definition": "definition",
      "--output-root": "outputRoot",
      "--receipt": "receipt",
    }[argument];
    if (!key) fail(`未知参数：${argument}`);
    const value = argv[++index];
    if (!value || value.startsWith("--")) fail(`${argument} 缺少值`);
    options[key] = value;
  }
  return options;
}

function usage() {
  return `用法：
  node packages/core/scripts/acquire-script-risk-public-pilot.mjs \\
    --output-root .research-data/script-risk/miner-capability-public-v1 \\
    --receipt .artifacts/research/script-risk/acquisition-<批次>.json [--offline]

该工具只获取已固定 commit、SHA-256 和长度的公开开源 JS/TS 文本；不会执行源码。
原始文本只允许保存在 .research-data/script-risk，receipt 必须写入 .artifacts，
两者均拒绝路径逃逸、符号链接和覆盖既有证据。--offline 只复核本地字节。`;
}

async function canonicalAllowedRoot(path) {
  await mkdir(path, { recursive: true, mode: 0o700 });
  return realpath(path);
}

async function resolveOutputPath(value, allowedRoot, field, directory) {
  if (!value) fail(`${field} 必填`);
  const absolute = resolve(value);
  const canonicalAllowed = await canonicalAllowedRoot(allowedRoot);
  if (!pathWithin(canonicalAllowed, absolute)) fail(`${field} 必须位于 ${allowedRoot}`);
  if (directory) {
    await mkdir(absolute, { recursive: true, mode: 0o700 });
    const canonical = await realpath(absolute);
    if (!pathWithin(canonicalAllowed, canonical)) fail(`${field} 经符号链接逃逸`);
    return canonical;
  }
  const existing = (() => {
    try {
      return lstatSync(absolute);
    } catch (error) {
      if (error?.code === "ENOENT") return null;
      throw error;
    }
  })();
  if (existing) fail(`${field} 已存在，拒绝覆盖`);
  await mkdir(dirname(absolute), { recursive: true, mode: 0o700 });
  const canonicalParent = await realpath(dirname(absolute));
  if (!pathWithin(canonicalAllowed, canonicalParent)) fail(`${field} 父目录经符号链接逃逸`);
  return resolve(canonicalParent, absolute.slice(dirname(absolute).length + 1));
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    process.stdout.write(`${usage()}\n`);
    return;
  }
  const outputRoot = await resolveOutputPath(
    options.outputRoot,
    allowedDataRoot,
    "--output-root",
    true,
  );
  const receiptPath = await resolveOutputPath(
    options.receipt,
    allowedReceiptRoot,
    "--receipt",
    false,
  );
  const definitionPath = realpathSync(resolve(options.definition));
  if (!pathWithin(repoRoot, definitionPath)) fail("--definition 必须位于仓库内");
  const definition = readPublicPilotDefinition(definitionPath);
  const receipt = await acquirePublicPilot({
    definition,
    outputRoot,
    offline: options.offline,
  });
  await writeFile(receiptPath, `${JSON.stringify(receipt, null, 2)}\n`, {
    flag: "wx",
    mode: 0o600,
  });
  process.stdout.write(
    `${JSON.stringify({
      mode: receipt.mode,
      releaseEligible: receipt.releaseEligible,
      datasetId: receipt.datasetId,
      acquisitionMode: receipt.acquisitionMode,
      samples: receipt.sampleCount,
      files: receipt.fileCount,
      bytes: receipt.totalBytes,
      receipt: receiptPath,
    })}\n`,
  );
}

main().catch((error) => {
  process.stderr.write(`公开源码 pilot 获取失败：${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
});
