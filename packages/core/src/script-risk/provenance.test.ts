import { describe, expect, it } from "vitest";
import {
  PROVENANCE_LIMITS,
  assessDocumentProvenance,
  type ProvenanceEvent,
} from "./provenance.js";

const NOW_MS = 100_000;
const DOCUMENT_ID = "document-secret-1";

function assess(events: readonly ProvenanceEvent[]) {
  return assessDocumentProvenance({
    documentId: DOCUMENT_ID,
    nowMs: NOW_MS,
    events,
  });
}

describe("assessDocumentProvenance", () => {
  it("covers script and function access to DOM, storage, network, worker, and wasm", () => {
    const result = assess([
      {
        documentId: DOCUMENT_ID,
        atMs: NOW_MS - 5,
        scriptId: "script-secret",
        functionId: "function-secret",
        capability: "dom",
        operation: "read",
        flowRole: "source",
        flowIds: ["opaque-flow"],
      },
      {
        documentId: DOCUMENT_ID,
        atMs: NOW_MS - 4,
        scriptId: "script-secret",
        functionId: "function-secret",
        capability: "storage",
        operation: "write",
      },
      {
        documentId: DOCUMENT_ID,
        atMs: NOW_MS - 3,
        scriptId: "script-secret",
        functionId: "function-secret",
        capability: "network",
        operation: "send",
        flowRole: "sink",
        flowIds: ["opaque-flow"],
      },
      {
        documentId: DOCUMENT_ID,
        atMs: NOW_MS - 2,
        scriptId: "script-secret",
        capability: "worker",
        operation: "create",
      },
      {
        documentId: DOCUMENT_ID,
        atMs: NOW_MS - 1,
        scriptId: "script-secret",
        capability: "wasm",
        operation: "execute",
      },
    ]);

    expect(result).toMatchObject({
      mode: "observe-only",
      wouldBlock: false,
      scope: "document",
      classification: "correlated-flow",
      correlatedFlows: 1,
    });
    expect(
      result.graph.nodes
        .filter((node) => node.kind === "capability")
        .map((node) => node.label),
    ).toEqual([
      "dom.read",
      "storage.write",
      "network.send",
      "worker.create",
      "wasm.execute",
    ]);
    expect(result.graph.edges.map((edge) => edge.relation)).toEqual(
      expect.arrayContaining([
        "contains",
        "reads",
        "writes",
        "sends",
        "creates",
        "executes",
        "flows-to",
      ]),
    );
  });

  it("enforces document scope and the observation window", () => {
    const result = assess([
      {
        documentId: "different-document",
        atMs: NOW_MS,
        scriptId: "foreign-script",
        capability: "network",
        operation: "send",
      },
      {
        documentId: DOCUMENT_ID,
        atMs: NOW_MS - 30_001,
        scriptId: "expired-script",
        capability: "storage",
        operation: "read",
      },
    ]);

    expect(result.graph).toEqual({ nodes: [], edges: [] });
    expect(result.budget).toMatchObject({
      retainedEvents: 0,
      droppedEvents: 2,
      documentMismatches: 1,
      outsideWindow: 1,
      truncated: true,
    });
  });

  it("links only a source observed before its sink", () => {
    const reversed = assess([
      {
        documentId: DOCUMENT_ID,
        atMs: NOW_MS - 2,
        scriptId: "script-a",
        capability: "network",
        operation: "send",
        flowRole: "sink",
        flowIds: ["causal-flow"],
      },
      {
        documentId: DOCUMENT_ID,
        atMs: NOW_MS - 1,
        scriptId: "script-a",
        capability: "dom",
        operation: "read",
        flowRole: "source",
        flowIds: ["causal-flow"],
      },
    ]);

    expect(reversed.classification).toBe("observed");
    expect(reversed.correlatedFlows).toBe(0);
    expect(
      reversed.graph.edges.some((edge) => edge.relation === "flows-to"),
    ).toBe(false);
  });

  it("does not leak document, actor, flow, source, literal, or URL values", () => {
    const result = assess([
      {
        documentId: DOCUMENT_ID,
        atMs: NOW_MS - 2,
        scriptId: "https://script.invalid/private.js",
        functionId: "stealToken",
        capability: "storage",
        operation: "read",
        flowRole: "source",
        flowIds: ["top-secret-flow-id"],
      },
      {
        documentId: DOCUMENT_ID,
        atMs: NOW_MS - 1,
        scriptId: "https://script.invalid/private.js",
        functionId: "stealToken",
        capability: "network",
        operation: "send",
        flowRole: "sink",
        flowIds: ["top-secret-flow-id"],
      },
    ]);
    const serialized = JSON.stringify(result);

    for (const secret of [
      DOCUMENT_ID,
      "script.invalid",
      "private.js",
      "stealToken",
      "top-secret-flow-id",
    ]) {
      expect(serialized).not.toContain(secret);
    }
  });

  it("keeps event, node, edge, actor, and flow memory within hard budgets", () => {
    const events: ProvenanceEvent[] = Array.from({ length: 5_000 }, (_, index) => ({
      documentId: DOCUMENT_ID,
      atMs: NOW_MS - 2_000 + index,
      scriptId: `script-${index}`,
      functionId: `function-${index}`,
      capability: index % 2 === 0 ? "network" : "dom",
      operation: index % 2 === 0 ? "send" : "read",
      flowRole: index % 2 === 0 ? "sink" : "source",
      flowIds: [`flow-${index}`],
    })) as ProvenanceEvent[];

    const result = assess(events);

    expect(result.budget.truncated).toBe(true);
    expect(result.budget.retainedEvents).toBeLessThanOrEqual(
      PROVENANCE_LIMITS.maxEventsPerBucket * 15,
    );
    expect(result.graph.nodes.length).toBeLessThanOrEqual(
      PROVENANCE_LIMITS.maxGraphNodes,
    );
    expect(result.graph.edges.length).toBeLessThanOrEqual(
      PROVENANCE_LIMITS.maxGraphEdges,
    );
    expect(result.budget.eventBucketOverflow).toBeGreaterThan(0);
    expect(result.budget.inspectedEvents).toBe(
      PROVENANCE_LIMITS.maxInspectedEvents,
    );
    expect(result.budget.inputEventLimitDrops).toBe(904);
  });

  it("rejects runtime label injection without echoing it", () => {
    const injected = [
      {
        documentId: DOCUMENT_ID,
        atMs: NOW_MS,
        scriptId: "script",
        capability: "network",
        operation: "https://secret.invalid/payload",
      },
    ] as unknown as ProvenanceEvent[];
    const result = assess(injected);

    expect(result.graph).toEqual({ nodes: [], edges: [] });
    expect(result.budget.invalidEvents).toBe(1);
    expect(JSON.stringify(result)).not.toContain("secret.invalid");
  });
});
