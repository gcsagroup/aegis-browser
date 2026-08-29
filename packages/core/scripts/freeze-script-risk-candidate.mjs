#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import {
  DEFAULT_ANALYZER_PATH,
  DEFAULT_CLASSIFIER_PATH,
  DEFAULT_LOCKFILE_PATH,
  DEFAULT_PROTOCOL_PATH,
  createCandidateLock,
  writeJsonExclusive,
} from "../src/script-risk/evaluation/blind-protocol.mjs";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const defaultRepoRoot = resolve(scriptDirectory, "../../..");

function usage() {
  return `Usage:
  node packages/core/scripts/freeze-script-risk-candidate.mjs \\
    --candidate-id <id> --output <path> [--repo-root <path>] \\
    [--analyzer <repository-relative path>]

候选锁绑定 AST analyzer bundle、corpus-eval.mjs 分类规则、blind-v1 协议、
pnpm-lock、Git commit/tree/dirty 状态及 Node/TypeScript 身份。仓库内输出必须位于
Git 已忽略路径，且永不覆盖已有文件。它只建立 operator-blinded-local 研究候选，
不是 independent-sealed test，也不授权发布或页面阻断。--final 始终闭锁。`;
}

function parseArguments(argv) {
  const options = {
    repoRoot: defaultRepoRoot,
    analyzer: DEFAULT_ANALYZER_PATH,
    classifier: DEFAULT_CLASSIFIER_PATH,
    protocol: DEFAULT_PROTOCOL_PATH,
    lockfile: DEFAULT_LOCKFILE_PATH,
  };
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
      "--candidate-id": "candidateId",
      "--output": "output",
      "--repo-root": "repoRoot",
      "--analyzer": "analyzer",
      "--classifier": "classifier",
      "--protocol": "protocol",
      "--lockfile": "lockfile",
    }[argument];
    if (!key) throw new Error(`unknown argument: ${argument}`);
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) throw new Error(`${argument} requires a value`);
    options[key] = value;
    index += 1;
  }
  return options;
}

function outputMustNotChangeSnapshot(repoRoot, outputPath) {
  const root = realpathSync(repoRoot);
  const output = resolve(outputPath);
  const fromRoot = relative(root, output);
  const inside =
    fromRoot !== "" &&
    fromRoot !== ".." &&
    !fromRoot.startsWith(`..${sep}`) &&
    !isAbsolute(fromRoot);
  if (!inside) return;
  try {
    execFileSync("git", ["check-ignore", "--quiet", "--no-index", "--", fromRoot], {
      cwd: root,
      stdio: "ignore",
    });
  } catch {
    throw new Error(
      "repository-local candidate output must already be covered by .gitignore",
    );
  }
}

export function main(argv = process.argv.slice(2)) {
  const options = parseArguments(argv);
  if (options.help) {
    process.stdout.write(`${usage()}\n`);
    return null;
  }
  if (!options.candidateId) throw new Error("--candidate-id is required");
  if (!options.output) throw new Error("--output is required");
  const repoRoot = realpathSync(options.repoRoot);
  const output = resolve(repoRoot, options.output);
  outputMustNotChangeSnapshot(repoRoot, output);
  const candidate = createCandidateLock({
    repoRoot,
    candidateId: options.candidateId,
    analyzerPath: options.analyzer,
    classifierPath: options.classifier,
    protocolPath: options.protocol,
    lockfilePath: options.lockfile,
  });
  const outputPath = writeJsonExclusive(output, candidate);
  process.stdout.write(
    `${JSON.stringify({
      candidateId: candidate.candidateId,
      candidateDigestSha256: candidate.candidateDigestSha256,
      evaluationClass: candidate.evaluationClass,
      independentSealVerified: false,
      finalEvaluationEligible: false,
      outputPath,
    })}\n`,
  );
  return { candidate, outputPath };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    process.stderr.write(
      `script-risk candidate freeze failed: ${
        error instanceof Error ? error.message : String(error)
      }\n`,
    );
    process.exitCode = 1;
  }
}
