#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const PRODUCT_EXCLUDED_DIRECTORIES = new Set([
  ".build",
  "DerivedData",
  "Tests",
]);

function fail(message) {
  throw new Error(message);
}

function finiteNonNegativeNumber(value, label) {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
    fail(`${label} must be a finite non-negative number`);
  }
  return value;
}

export function collectProductSwiftFiles(iosRoot) {
  const files = [];

  function visit(directory, relativeDirectory = "") {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      if (entry.isSymbolicLink()) continue;
      const relativePath = path.join(relativeDirectory, entry.name);
      if (entry.isDirectory()) {
        if (!PRODUCT_EXCLUDED_DIRECTORIES.has(entry.name)) {
          visit(path.join(directory, entry.name), relativePath);
        }
      } else if (entry.isFile() && entry.name.endsWith(".swift")) {
        files.push(relativePath.split(path.sep).join("/"));
      }
    }
  }

  visit(iosRoot);
  return files.sort();
}

function measurementsForFile(report, relativePath) {
  const normalizedSuffix = `/${relativePath}`;
  const measurements = [];

  for (const target of report.targets ?? []) {
    for (const file of target.files ?? []) {
      const sourcePath = String(file.path ?? "").replaceAll("\\", "/");
      if (sourcePath !== relativePath && !sourcePath.endsWith(normalizedSuffix)) continue;
      measurements.push({
        target: String(target.name ?? "<unnamed-target>"),
        sourcePath,
        coveredLines: finiteNonNegativeNumber(file.coveredLines, `${relativePath}.coveredLines`),
        executableLines: finiteNonNegativeNumber(file.executableLines, `${relativePath}.executableLines`),
        lineCoverage: finiteNonNegativeNumber(file.lineCoverage, `${relativePath}.lineCoverage`),
      });
    }
  }

  return measurements;
}

export function summarizeCoverage(report, productSwiftFiles, metadata = {}) {
  if (!report || !Array.isArray(report.targets) || report.targets.length === 0) {
    fail("xccov report has no targets");
  }
  if (!Array.isArray(productSwiftFiles) || productSwiftFiles.length === 0) {
    fail("product Swift inventory is empty");
  }

  const files = productSwiftFiles.map((relativePath) => {
    const measurements = measurementsForFile(report, relativePath);
    if (measurements.length === 0) {
      return {
        path: relativePath,
        status: "not-measured",
        coveredLines: 0,
        executableLines: 0,
        lineCoverage: null,
        selectedTarget: null,
        measuredTargets: [],
      };
    }

    // A shared Swift source can be compiled into more than one target. Counting
    // each target would duplicate physical source lines, so choose the most
    // complete measurement, then the one with the most covered lines.
    measurements.sort((left, right) =>
      right.executableLines - left.executableLines
      || right.coveredLines - left.coveredLines
      || left.target.localeCompare(right.target));
    const selected = measurements[0];
    if (selected.coveredLines > selected.executableLines) {
      fail(`${relativePath} has more covered lines than executable lines`);
    }

    return {
      path: relativePath,
      status: selected.coveredLines > 0 ? "covered" : "uncovered",
      coveredLines: selected.coveredLines,
      executableLines: selected.executableLines,
      lineCoverage: selected.executableLines === 0
        ? null
        : selected.coveredLines / selected.executableLines,
      selectedTarget: selected.target,
      measuredTargets: measurements.map((measurement) => measurement.target),
    };
  });

  const measuredFiles = files.filter((file) => file.status !== "not-measured");
  const coveredLines = measuredFiles.reduce((sum, file) => sum + file.coveredLines, 0);
  const executableLines = measuredFiles.reduce((sum, file) => sum + file.executableLines, 0);
  if (measuredFiles.length === 0 || executableLines === 0) {
    fail("xccov report contains no executable product Swift coverage");
  }

  return {
    schemaVersion: 1,
    generatedAtUtc: new Date().toISOString(),
    metadata,
    aggregation: "one measurement per physical Swift file; prefer greatest executableLines, then coveredLines",
    totals: {
      productSwiftFileCount: files.length,
      measuredFileCount: measuredFiles.length,
      coveredFileCount: files.filter((file) => file.status === "covered").length,
      uncoveredFileCount: files.filter((file) => file.status === "uncovered").length,
      notMeasuredFileCount: files.filter((file) => file.status === "not-measured").length,
      coveredLines,
      executableLines,
      measuredLineCoverage: coveredLines / executableLines,
    },
    coveredFiles: files.filter((file) => file.status === "covered").map((file) => file.path),
    uncoveredFiles: files.filter((file) => file.status !== "covered").map((file) => file.path),
    notMeasuredFiles: files.filter((file) => file.status === "not-measured").map((file) => file.path),
    files,
  };
}

export function renderTextSummary(summary) {
  const percent = (summary.totals.measuredLineCoverage * 100).toFixed(2);
  const lines = [
    "Aegis product Swift coverage",
    `device: ${summary.metadata.deviceLabel ?? "<unknown>"}`,
    `git_sha: ${summary.metadata.gitSha ?? "<unknown>"}`,
    `git_tree_state: ${summary.metadata.gitTreeState ?? "<unknown>"}`,
    `input_manifest_sha256: ${summary.metadata.inputManifestSha256 ?? "<unknown>"}`,
    `runtime: ${summary.metadata.runtimeId ?? "<unknown>"}`,
    `simulator: ${summary.metadata.deviceName ?? "<unknown>"} (${summary.metadata.deviceUdid ?? "<unknown>"})`,
    `xcode: ${summary.metadata.xcodeVersion ?? "<unknown>"}`,
    `measured_line_coverage: ${percent}% (${summary.totals.coveredLines}/${summary.totals.executableLines})`,
    `product_swift_files: ${summary.totals.productSwiftFileCount}`,
    `covered_files: ${summary.totals.coveredFileCount}`,
    `uncovered_files: ${summary.totals.uncoveredFileCount}`,
    `not_measured_files: ${summary.totals.notMeasuredFileCount}`,
    "",
    "status\tcovered/executable\tcoverage\ttarget\tpath",
  ];

  for (const file of summary.files) {
    const filePercent = file.lineCoverage === null ? "n/a" : `${(file.lineCoverage * 100).toFixed(2)}%`;
    lines.push([
      file.status,
      `${file.coveredLines}/${file.executableLines}`,
      filePercent,
      file.selectedTarget ?? "<not-measured>",
      file.path,
    ].join("\t"));
  }
  return `${lines.join("\n")}\n`;
}

function parseArguments(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith("--") || value === undefined) fail(`invalid argument: ${key ?? "<missing>"}`);
    values[key.slice(2)] = value;
  }
  for (const required of ["xccov-json", "ios-root", "output-json", "output-text", "device-label"]) {
    if (!values[required]) fail(`missing --${required}`);
  }
  return values;
}

function main() {
  const args = parseArguments(process.argv.slice(2));
  const iosRoot = path.resolve(args["ios-root"]);
  const report = JSON.parse(fs.readFileSync(args["xccov-json"], "utf8"));
  const inventory = collectProductSwiftFiles(iosRoot);
  const summary = summarizeCoverage(report, inventory, {
    deviceLabel: args["device-label"],
    gitSha: args["git-sha"] ?? "<unknown>",
    gitTreeState: args["git-tree-state"] ?? "<unknown>",
    inputManifestSha256: args["input-manifest-sha256"] ?? "<unknown>",
    runtimeId: args["runtime-id"] ?? "<unknown>",
    deviceName: args["device-name"] ?? "<unknown>",
    deviceUdid: args["device-udid"] ?? "<unknown>",
    xcodeVersion: args["xcode-version"] ?? "<unknown>",
  });

  fs.writeFileSync(args["output-json"], `${JSON.stringify(summary, null, 2)}\n`);
  fs.writeFileSync(args["output-text"], renderTextSummary(summary));
  const percent = (summary.totals.measuredLineCoverage * 100).toFixed(2);
  process.stdout.write(
    `IOS_SWIFT_COVERAGE device=${args["device-label"]} percent=${percent} covered=${summary.totals.coveredLines} executable=${summary.totals.executableLines} product_files=${summary.totals.productSwiftFileCount} covered_files=${summary.totals.coveredFileCount} uncovered_files=${summary.totals.uncoveredFileCount} not_measured_files=${summary.totals.notMeasuredFileCount}\n`,
  );
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  try {
    main();
  } catch (error) {
    console.error(`错误：无法汇总 Swift coverage：${error.message}`);
    process.exit(1);
  }
}
