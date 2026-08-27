import { describe, expect, it } from "vitest";
import {
  assessPhishing,
  applyLocalFeedback,
  scorePhishingUrl,
} from "./detector.js";

describe("scorePhishingUrl", () => {
  it("blocks brand+suspicious-TLD on URL features alone", () => {
    const result = scorePhishingUrl("http://paypal-secure-login.tk/signin");
    expect(result.shouldBlock).toBe(true);
    expect(result.score).toBe(70);
    expect(result.reasons.map((r) => r.code)).toEqual([
      "insecure_http",
      "suspicious_tld",
      "brand_spoof_host",
      "credential_path",
    ]);
  });

  it("does not block ordinary https sites", () => {
    expect(scorePhishingUrl("https://example.com/docs").shouldBlock).toBe(false);
  });

  it("detects digit substitutions in brand lookalikes", () => {
    const result = scorePhishingUrl("https://micros0ft.com/");
    expect(result.score).toBe(40);
    expect(result.reasons[0]).toMatchObject({
      code: "brand_lookalike_host",
      detail: "microsoft",
    });
  });

  it("treats shorteners as context instead of blocking them alone", () => {
    const result = scorePhishingUrl("https://bit.ly/example");
    expect(result.score).toBe(15);
    expect(result.shouldBlock).toBe(false);
    expect(result.reasons[0]?.code).toBe("shortened_url");
  });

  it("recognizes brand and credential words hidden in a path", () => {
    const result = scorePhishingUrl("https://example.com/paypal/login");
    expect(result.score).toBe(25);
    expect(result.reasons.map((reason) => reason.code)).toEqual([
      "brand_in_path",
      "credential_path",
    ]);
  });

  it("blocks punycode + suspicious TLD + http", () => {
    const result = scorePhishingUrl("http://xn--80ak6aa92e.tk/");
    expect(result.shouldBlock).toBe(true);
    expect(result.reasons.some((r) => r.code === "punycode_host")).toBe(true);
  });
});

describe("assessPhishing", () => {
  it("flags brand spoof hosts with password fields", () => {
    const result = assessPhishing({
      url: "http://paypal-secure-login.tk/signin",
      title: "PayPal Login",
      textSample: "Verify your account immediately",
      forms: 1,
      passwordFields: 1,
    });
    expect(result.shouldBlock).toBe(true);
    expect(result.score).toBeGreaterThanOrEqual(55);
    expect(result.reasons.some((r) => r.code === "brand_spoof_host")).toBe(true);
  });

  it("allows benign https sites", () => {
    const result = assessPhishing({
      url: "https://example.com/docs",
      title: "Example Domain",
      textSample: "This domain is for use in illustrative examples.",
      forms: 0,
      passwordFields: 0,
    });
    expect(result.shouldBlock).toBe(false);
    expect(result.severity).toBe("low");
  });

  it("blocks http + suspicious TLD when a password form is present", () => {
    const result = assessPhishing({
      url: "http://evil.tk/login",
      title: "Login",
      textSample: "",
      forms: 1,
      passwordFields: 1,
    });
    expect(result.shouldBlock).toBe(true);
    expect(result.score).toBeGreaterThanOrEqual(55);
    expect(result.reasons.some((r) => r.code === "password_on_risky_origin")).toBe(
      true,
    );
  });

  it("blocks a clean-looking page that submits a password cross-site", () => {
    const result = assessPhishing({
      url: "https://example.com/login",
      title: "Account login",
      textSample: "Enter your password",
      forms: 1,
      passwordFields: 1,
      crossSiteFormActions: 1,
    });
    expect(result.shouldBlock).toBe(true);
    expect(result.reasons.some((r) => r.code === "cross_site_credential_submit")).toBe(
      true,
    );
  });

  it("blocks a punycode credential page without requiring urgency copy", () => {
    const result = assessPhishing({
      url: "https://xn--pple-43d.com/",
      title: "Sign in",
      textSample: "",
      forms: 1,
      passwordFields: 1,
    });
    expect(result.shouldBlock).toBe(true);
    expect(result.score).toBeGreaterThanOrEqual(55);
  });

  it("respects allowlist", () => {
    const result = assessPhishing(
      {
        url: "http://paypal-secure-login.tk/signin",
        title: "x",
        textSample: "verify your account",
        passwordFields: 1,
      },
      ["paypal-secure-login.tk"],
    );
    expect(result.shouldBlock).toBe(false);
    expect(result.reasons[0]?.code).toBe("allowlisted");
  });
});

describe("applyLocalFeedback", () => {
  it("dampens score for safe feedback", () => {
    const base = assessPhishing({
      url: "http://evil.tk/login",
      title: "Login",
      textSample: "verify your account",
      passwordFields: 1,
    });
    const adjusted = applyLocalFeedback(base, { "evil.tk": "safe" });
    expect(adjusted.score).toBeLessThan(base.score);
  });
});
