import { defineConfig } from "vitest/config";
import { fileURLToPath } from "node:url";

const coverageDirectory = process.env.CORE_COVERAGE_DIR ?? "../../.artifacts/coverage/core";
const repositoryRoot = fileURLToPath(new URL("../..", import.meta.url));

export default defineConfig({
  test: {
    environment: "node",
    include: ["src/**/*.test.ts"],
    coverage: {
      provider: "v8",
      reportsDirectory: coverageDirectory,
      reporter: ["text", "json-summary", ["lcovonly", { projectRoot: repositoryRoot }]],
      include: ["src/**/*.ts"],
      exclude: ["src/**/*.test.ts", "src/**/*.d.ts", "src/**/*.d.mts"],
    },
  },
});
