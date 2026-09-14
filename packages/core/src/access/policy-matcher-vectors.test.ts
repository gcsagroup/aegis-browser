import fs from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const vectorPath = fileURLToPath(
  new URL(
    "../../../../apps/browser/overlay/components/aegis_access/testdata/policy_matcher_vectors.json",
    import.meta.url,
  ),
);

describe("access policy matcher golden vectors", () => {
  it("provides a valid unique cross-language fixture set", () => {
    const vectors: unknown = JSON.parse(fs.readFileSync(vectorPath, "utf8"));
    expect(vectors).toMatchObject({ schemaVersion: 1 });
    expect(vectors).toHaveProperty("policyVectors");

    const policyVectors = (vectors as { policyVectors: unknown[] })
      .policyVectors;
    expect(policyVectors).toHaveLength(14);
    const names = policyVectors.map((value) => {
      expect(value).toHaveProperty("name");
      expect(value).toHaveProperty("context.targetUrl");
      expect(value).toHaveProperty("rules");
      expect(value).toHaveProperty("expected.state");
      return (value as { name: string }).name;
    });
    expect(new Set(names).size).toBe(names.length);
  });
});
