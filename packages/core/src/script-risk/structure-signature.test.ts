import { describe, expect, it } from "vitest";
import { createScriptStructureSignature } from "./structure-signature.js";

describe("createScriptStructureSignature", () => {
  it("ignores identifier names and literal values in the structural hash", () => {
    const first = createScriptStructureSignature(`
      function alpha(input) {
        if (input > 10) return fetch("https://first.invalid/a");
        return 7;
      }
    `);
    const second = createScriptStructureSignature(`
      function omega(secret) {
        if (secret > 99) return fetch("https://second.invalid/b");
        return 3;
      }
    `);

    expect(first.parseStatus).toBe("complete");
    expect(second.parseStatus).toBe("complete");
    expect(first.structuralHash).toBe(second.structuralHash);
    expect(first.functions[0]?.structuralHash).toBe(
      second.functions[0]?.structuralHash,
    );
    expect(first.branches[0]?.structuralHash).toBe(
      second.branches[0]?.structuralHash,
    );
  });

  it("changes the signature when executable structure changes", () => {
    const branch = createScriptStructureSignature(
      "function f(x) { if (x) return x; return 0; }",
    );
    const loop = createScriptStructureSignature(
      "function f(x) { while (x) x--; return 0; }",
    );

    expect(branch.structuralHash).not.toBe(loop.structuralHash);
    expect(branch.branches[0]?.kind).toBe("if");
    expect(loop.branches[0]?.kind).toBe("while");
  });

  it("returns stable ranges and bounded function and branch summaries", () => {
    const source = `
      async function task(value) {
        for (let index = 0; index < value; index += 1) {
          await Promise.resolve(index);
        }
        return value ? 1 : 0;
      }
    `;
    const untouched = source;
    const result = createScriptStructureSignature(source);

    expect(source).toBe(untouched);
    expect(result).toMatchObject({
      mode: "observe-only",
      parseStatus: "complete",
      hashAlgorithm: "sha256-tree-v1",
    });
    expect(result.functions).toHaveLength(1);
    expect(result.functions[0]).toMatchObject({
      kind: "function-declaration",
      async: true,
      generator: false,
      parameterCount: 1,
      loopCount: 1,
    });
    expect(result.functions[0]?.range.start).toBeGreaterThanOrEqual(0);
    expect(result.functions[0]?.range.end).toBeLessThanOrEqual(source.length);
    expect(result.branches.map((branch) => branch.kind)).toEqual([
      "for",
      "conditional",
    ]);
  });

  it("never returns source, identifiers, literals, or URLs", () => {
    const source = `
      function secretFunction(secretToken) {
        return fetch("https://payload.invalid/private?token=abc123");
      }
    `;
    const serialized = JSON.stringify(createScriptStructureSignature(source));

    for (const secret of [
      "secretFunction",
      "secretToken",
      "payload.invalid",
      "abc123",
      "fetch(\"",
    ]) {
      expect(serialized).not.toContain(secret);
    }
  });

  it("fails source-free when the node budget is exceeded", () => {
    const result = createScriptStructureSignature(
      "function f(a, b, c) { return a + b + c; }",
      { maxNodes: 4 },
    );

    expect(result).toMatchObject({
      parseStatus: "failed",
      failureCode: "node-budget-exceeded",
      structuralHash: null,
      functions: [],
      branches: [],
    });
  });

  it("does not throw or echo adversarial parser nesting", () => {
    const source = `${"(".repeat(1_500)}deepSecret${")".repeat(1_500)}`;

    expect(() => createScriptStructureSignature(source)).not.toThrow();
    const result = createScriptStructureSignature(source);
    expect(result.parseStatus).toBe("failed");
    expect(JSON.stringify(result)).not.toContain("deepSecret");
  });
});
