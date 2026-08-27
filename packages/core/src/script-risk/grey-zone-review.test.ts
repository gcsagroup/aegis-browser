import { describe, expect, it, vi } from "vitest";
import {
  reviewScriptRiskGreyZone,
  sanitizeScriptRiskForLocalReview,
  type ScriptRiskLocalModelPort,
} from "./grey-zone-review.js";
import type { ScriptRiskAssessment } from "./types.js";

function assessment(
  patch: Partial<ScriptRiskAssessment> = {},
): ScriptRiskAssessment {
  return {
    schemaVersion: 1,
    mode: "observe-only",
    status: "active",
    site: "sensitive.example.test",
    decision: "suspicious",
    wouldBlock: false,
    riskScore: 65,
    reasons: [
      { code: "ast.dynamic-code", occurrences: 1 },
      { code: "ast.encoded-payload", occurrences: 2 },
      { code: "ast.remote-load", occurrences: 1 },
    ],
    findings: [
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
    ],
    graph: {
      nodes: [
        { id: "script:0", kind: "script", label: "observed-script" },
        { id: "event:0", kind: "network", label: "outbound" },
      ],
      edges: [{ from: "script:0", to: "event:0", relation: "sends" }],
    },
    ...patch,
  };
}

function model(raw: string): ScriptRiskLocalModelPort {
  return {
    location: "loopback",
    ready: vi.fn().mockResolvedValue(true),
    chat: vi.fn().mockResolvedValue(raw),
  };
}

describe("local grey-zone script review", () => {
  it("sends only categorical source-free evidence to a local model", async () => {
    const port = model(
      JSON.stringify({
        advisory: "suspicious",
        confidence: 0.71,
        tags: ["static-only"],
      }),
    );
    const result = await reviewScriptRiskGreyZone(port, assessment());
    expect(result).toMatchObject({
      status: "reviewed",
      advisory: "suspicious",
      confidence: 0.71,
      wouldBlock: false,
      modelLocation: "loopback",
    });
    const messages = vi.mocked(port.chat).mock.calls[0]?.[0];
    const serialized = JSON.stringify(messages);
    expect(serialized).not.toContain("sensitive.example.test");
    expect(serialized).not.toContain("flowId");
    expect(serialized).not.toContain("observed-script");
  });

  it("does not review high-confidence or non-grey-zone decisions", async () => {
    const port = model("{}");
    const result = await reviewScriptRiskGreyZone(
      port,
      assessment({ decision: "high-confidence", riskScore: 92 }),
    );
    expect(result).toMatchObject({
      status: "skipped",
      advisory: "abstain",
      reason: "outside-grey-zone",
      wouldBlock: false,
    });
    expect(port.ready).not.toHaveBeenCalled();
  });

  it("fails open on malformed or oversized model output", async () => {
    const malformed = await reviewScriptRiskGreyZone(model("not-json"), assessment());
    const oversized = await reviewScriptRiskGreyZone(
      model("x".repeat(5_000)),
      assessment(),
    );
    expect(malformed).toMatchObject({
      status: "invalid-output",
      advisory: "abstain",
      wouldBlock: false,
    });
    expect(oversized.status).toBe("invalid-output");
  });

  it("rejects unknown tags and out-of-range confidence", async () => {
    const result = await reviewScriptRiskGreyZone(
      model(
        JSON.stringify({
          advisory: "malicious",
          confidence: 4,
          tags: ["execute-this-page"],
        }),
      ),
      assessment(),
    );
    expect(result.status).toBe("invalid-output");
  });

  it("sanitizer caps counts and excludes site identity", () => {
    const sanitized = sanitizeScriptRiskForLocalReview(
      assessment({
        reasons: [{ code: "ast.remote-load", occurrences: 1000 }],
      }),
    );
    expect(sanitized.reasons[0]?.occurrences).toBe(8);
    expect(JSON.stringify(sanitized)).not.toContain("sensitive.example.test");
  });

  it("rejects runtime categorical injection before any model call", async () => {
    const injected = "https://secret.invalid/token?cookie=session-secret";
    const invalidAssessments = [
      { ...assessment(), decision: injected },
      {
        ...assessment(),
        reasons: [{ code: injected, occurrences: 1 }],
      },
      {
        ...assessment(),
        findings: [
          {
            kind: injected,
            confidence: "medium",
            score: 50,
            reasonCodes: ["ast.remote-load"],
          },
        ],
      },
      {
        ...assessment(),
        findings: [
          {
            kind: "obfuscated-remote-loader",
            confidence: "medium",
            score: 50,
            reasonCodes: [injected],
          },
        ],
      },
      {
        ...assessment(),
        graph: {
          nodes: [{ id: "node:0", kind: injected, label: "ignored" }],
          edges: [],
        },
      },
      {
        ...assessment(),
        graph: {
          nodes: [{ id: "node:0", kind: "script", label: "ignored" }],
          edges: [{ from: "node:0", to: "node:0", relation: injected }],
        },
      },
    ] as unknown as ScriptRiskAssessment[];

    for (const invalidAssessment of invalidAssessments) {
      const port = model(
        JSON.stringify({
          advisory: "suspicious",
          confidence: 0.5,
          tags: ["static-only"],
        }),
      );
      const result = await reviewScriptRiskGreyZone(port, invalidAssessment);
      expect(result).toMatchObject({
        status: "invalid-input",
        advisory: "abstain",
        reason: "invalid-input",
        wouldBlock: false,
      });
      expect(port.ready).not.toHaveBeenCalled();
      expect(port.chat).not.toHaveBeenCalled();
      expect(JSON.stringify(vi.mocked(port.chat).mock.calls)).not.toContain(
        injected,
      );
    }

    expect(() =>
      sanitizeScriptRiskForLocalReview(invalidAssessments[1]!),
    ).toThrow(/invalid reason/);
  });

  it("rejects a non-local model location before ready or chat", async () => {
    const port = model("{}");
    (port as unknown as { location: string }).location = "remote";

    const result = await reviewScriptRiskGreyZone(port, assessment());

    expect(result).toMatchObject({
      status: "invalid-input",
      advisory: "abstain",
      reason: "invalid-input",
      wouldBlock: false,
    });
    expect(port.ready).not.toHaveBeenCalled();
    expect(port.chat).not.toHaveBeenCalled();
  });
});
