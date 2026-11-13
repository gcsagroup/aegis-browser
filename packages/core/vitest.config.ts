import { configDefaults, defineConfig } from "vitest/config";
import { fileURLToPath } from "node:url";

const coverageDirectory = process.env.CORE_COVERAGE_DIR ?? "../../.artifacts/coverage/core";
const repositoryRoot = fileURLToPath(new URL("../..", import.meta.url));

export default defineConfig({
  test: {
    environment: "node",
    // Subprocess-based protocol tests share CPU with other jobs on CI runners.
    maxWorkers: 2,
    include: ["src/**/*.test.ts"],
    reporters: process.env.NODE_V8_COVERAGE
      ? [...configDefaults.reporters, fileURLToPath(new URL("./vitest-coverage-exit.mjs", import.meta.url))]
      : configDefaults.reporters,
    execArgv: process.env.NODE_V8_COVERAGE
      ? ["--import", fileURLToPath(new URL("./vitest-coverage-exit.mjs", import.meta.url))]
      : [],
    coverage: {
      provider: "v8",
      reportsDirectory: coverageDirectory,
      reporter: ["text", "json-summary", ["lcovonly", { projectRoot: repositoryRoot }]],
      include: ["src/**/*.ts"],
      exclude: ["src/**/*.test.ts", "src/**/*.d.ts", "src/**/*.d.mts"],
    },
  },
});
