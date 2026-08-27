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

  it("returns a heuristic summary", () => {
    const out = JSON.parse(
      aegisEvaluate(
        JSON.stringify({
          op: "summarize",
          locale: "zh-CN",
          snapshot: {
            url: "https://example.com/login",
            title: "Login",
            textSample: "Please sign in to continue. Password expired soon.",
            passwordFields: 1,
            forms: 1,
          },
        }),
      ),
    ) as { summary: string; risks: string[]; backend: string };
    expect(out.summary.length).toBeGreaterThan(0);
    expect(out.risks.some((r) => r.includes("密码"))).toBe(true);
    expect(out.backend).toBe("mock");
  });

  it("rejects unknown ops", () => {
    const out = JSON.parse(aegisEvaluate(JSON.stringify({ op: "nope" }))) as {
      error: string;
    };
    expect(out.error).toContain("unknown op");
  });
});
