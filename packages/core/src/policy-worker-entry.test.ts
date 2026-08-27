import { describe, expect, it } from "vitest";
import { aegisEvaluate } from "./policy-worker-entry.js";

describe("policy worker entry", () => {
  it("pings", () => {
    const out = JSON.parse(aegisEvaluate(JSON.stringify({ op: "ping" }))) as {
      ok: boolean;
      worker: string;
    };
    expect(out.ok).toBe(true);
    expect(out.worker).toBe("aegis-policy");
  });

  it("scores a phishing URL the same way as core", () => {
    const out = JSON.parse(
      aegisEvaluate(
        JSON.stringify({
          op: "scorePhish",
          url: "http://paypal-secure-login.tk",
        }),
      ),
    ) as { score: number; shouldBlock: boolean };
    expect(out.score).toBeGreaterThanOrEqual(55);
    expect(out.shouldBlock).toBe(true);
  });

  it("redacts PII before summarize", () => {
    const scan = JSON.parse(
      aegisEvaluate(
        JSON.stringify({
          op: "scanPii",
          text: "Contact alice@example.com",
        }),
      ),
    ) as { blocked: boolean; redacted: string };
    expect(scan.blocked).toBe(true);
    expect(scan.redacted).not.toContain("alice@example.com");
  });

  it("requires a valid structured snapshot for summary preparation", () => {
    const out = JSON.parse(
      aegisEvaluate(
        JSON.stringify({
          op: "prepareSummary",
          locale: "en",
          url: "https://example.com/?token=raw-secret",
          text: "alice@example.com",
        }),
      ),
    ) as { error: string };
    expect(out.error).toContain("valid structured snapshot required");
  });

  it("returns only a redacted structured handoff", () => {
    const out = JSON.parse(
      aegisEvaluate(
        JSON.stringify({
          op: "prepareSummary",
          locale: "en",
          snapshot: {
            url: "https://example.com/?token=tok_live_ABC123456789#private",
            title: "alice@example.com",
            textSample: "Bearer abcdefghijklmnop",
            forms: 0,
            passwordFields: 0,
          },
        }),
      ),
    ) as Record<string, unknown>;
    const handoff = JSON.stringify(out);
    expect(out["schemaVersion"]).toBe(1);
    expect(Object.keys(out).sort()).toEqual([
      "heuristic",
      "sanitizedSnapshot",
      "schemaVersion",
    ]);
    expect(handoff).not.toContain("tok_live_ABC123456789");
    expect(handoff).not.toContain("private");
    expect(handoff).not.toContain("alice@example.com");
    expect(handoff).not.toContain("abcdefghijklmnop");
    expect(handoff).not.toContain('"system"');
    expect(handoff).not.toContain('"user"');
    expect(handoff).not.toContain('"prompt"');
  });

  it("does not expose legacy summary or prompt-building operations", () => {
    for (const op of ["summarize", "buildPrompt"]) {
      const out = JSON.parse(
        aegisEvaluate(JSON.stringify({ op, snapshot: {} })),
      ) as { error: string };
      expect(out.error).toContain("unknown op");
    }
  });

  it("rejects unknown ops", () => {
    const out = JSON.parse(aegisEvaluate(JSON.stringify({ op: "nope" }))) as {
      error: string;
    };
    expect(out.error).toContain("unknown op");
  });
});
