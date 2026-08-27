import { describe, expect, it } from "vitest";
import { gateOutboundText, scanPii } from "./pii.js";

describe("scanPii", () => {
  it("detects email and phone", () => {
    const result = scanPii("Contact me at alice@example.com or 13812345678");
    expect(result.matches.some((m) => m.kind === "email")).toBe(true);
    expect(result.matches.some((m) => m.kind === "phone")).toBe(true);
    expect(result.redacted).not.toContain("alice@example.com");
    expect(result.blocked).toBe(true);
  });

  it("gates outbound until approved", () => {
    const blocked = gateOutboundText("SSN 123-45-6789", false);
    expect(blocked.allowed).toBe(false);
    const approved = gateOutboundText("SSN 123-45-6789", true);
    expect(approved.allowed).toBe(true);
    expect(approved.payload).toContain("***-**-****");
  });

  it("redacts bearer tokens and labelled secrets", () => {
    const input =
      "Authorization: Bearer abcdefghijklmnop and token=tok_live_ABC123456789";
    const result = scanPii(input);
    expect(result.matches.filter((m) => m.kind === "secret")).toHaveLength(2);
    expect(result.redacted).not.toContain("abcdefghijklmnop");
    expect(result.redacted).not.toContain("tok_live_ABC123456789");
    expect(result.redacted).toContain("[REDACTED_SECRET]");
  });
});
