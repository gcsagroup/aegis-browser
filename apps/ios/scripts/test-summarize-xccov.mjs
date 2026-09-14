#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import test from "node:test";

import { renderTextSummary, summarizeCoverage } from "./summarize-xccov.mjs";

test("summarizes product Swift files without double counting shared sources", () => {
  const report = {
    targets: [
      {
        name: "Aegis",
        files: [
          { path: "/checkout/apps/ios/App/Main.swift", coveredLines: 7, executableLines: 10, lineCoverage: 0.7 },
          { path: "/checkout/apps/ios/Shared/Gate.swift", coveredLines: 2, executableLines: 5, lineCoverage: 0.4 },
        ],
      },
      {
        name: "SafariWebExtension",
        files: [
          { path: "/checkout/apps/ios/Shared/Gate.swift", coveredLines: 0, executableLines: 5, lineCoverage: 0 },
        ],
      },
    ],
  };

  const summary = summarizeCoverage(report, [
    "App/Main.swift",
    "Extension/Handler.swift",
    "Shared/Gate.swift",
  ], { deviceLabel: "iPhone" });

  assert.deepEqual(summary.totals, {
    productSwiftFileCount: 3,
    measuredFileCount: 2,
    coveredFileCount: 2,
    uncoveredFileCount: 0,
    notMeasuredFileCount: 1,
    coveredLines: 9,
    executableLines: 15,
    measuredLineCoverage: 0.6,
  });
  assert.deepEqual(summary.uncoveredFiles, ["Extension/Handler.swift"]);
  assert.deepEqual(summary.notMeasuredFiles, ["Extension/Handler.swift"]);
  assert.equal(summary.files[2].selectedTarget, "Aegis");
  assert.match(renderTextSummary(summary), /measured_line_coverage: 60\.00% \(9\/15\)/);
});

test("rejects missing or empty product coverage", () => {
  assert.throws(
    () => summarizeCoverage({ targets: [] }, ["App/Main.swift"]),
    /no targets/,
  );
  assert.throws(
    () => summarizeCoverage({ targets: [{ name: "Tests", files: [] }] }, ["App/Main.swift"]),
    /no executable product Swift coverage/,
  );
});

test("rejects malformed line counts", () => {
  assert.throws(
    () => summarizeCoverage({
      targets: [{
        name: "Aegis",
        files: [{ path: "/checkout/apps/ios/App/Main.swift", coveredLines: 11, executableLines: 10, lineCoverage: 1.1 }],
      }],
    }, ["App/Main.swift"]),
    /more covered lines than executable lines/,
  );
});
