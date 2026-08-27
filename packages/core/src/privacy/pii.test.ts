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
});
