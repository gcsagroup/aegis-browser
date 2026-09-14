import fs from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const vectorPath = fileURLToPath(
  new URL(
    "../../../../apps/browser/overlay/components/aegis_access/testdata/route_planner_vectors.json",
    import.meta.url,
  ),
);

describe("access route planner golden vectors", () => {
  it("provides a valid unique cross-language fixture set", () => {
    const vectors: unknown = JSON.parse(fs.readFileSync(vectorPath, "utf8"));
    expect(vectors).toMatchObject({ schemaVersion: 1 });
    expect(vectors).toHaveProperty("defaults");
    expect(vectors).toHaveProperty("plannerVectors");

    const plannerVectors = (vectors as { plannerVectors: unknown[] })
      .plannerVectors;
    expect(plannerVectors).toHaveLength(42);
    const names = plannerVectors.map((value) => {
      expect(value).toHaveProperty("name");
      expect(value).toHaveProperty("input");
      expect(value).toHaveProperty("expected.action");
      expect(value).toHaveProperty("expected.reason");
      return (value as { name: string }).name;
    });
    expect(new Set(names).size).toBe(names.length);
  });
});
