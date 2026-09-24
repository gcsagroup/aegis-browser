import { describe, expect, it, vi } from "vitest";
import { PolicyEngine } from "./policy.js";
import type { AegisPorts, NetRule, StorageCookie } from "./ports.js";
import type { AegisSettings, PageSnapshot } from "./types.js";
import { DEFAULT_SETTINGS } from "./types.js";

const suspiciousSnapshot: PageSnapshot = {
  url: "http://paypal-secure-login.tk/signin",
  title: "PayPal Login",
  textSample: "Verify your account immediately",
  forms: 1,
  passwordFields: 1,
};

function cloneSettings(
  overrides: Partial<Omit<AegisSettings, "modules">> & {
    modules?: Partial<AegisSettings["modules"]>;
  } = {},
): AegisSettings {
  return {
    ...DEFAULT_SETTINGS,
    ...overrides,
    modules: { ...DEFAULT_SETTINGS.modules, ...overrides.modules },
    trackerWhitelist: [
      ...(overrides.trackerWhitelist ?? DEFAULT_SETTINGS.trackerWhitelist),
    ],
    rejectedCookieCategories: [
      ...(
        overrides.rejectedCookieCategories ??
        DEFAULT_SETTINGS.rejectedCookieCategories
      ),
    ],
    phishAllowlist: [
      ...(overrides.phishAllowlist ?? DEFAULT_SETTINGS.phishAllowlist),
    ],
  };
}

function makeCookie(overrides: Partial<StorageCookie> = {}): StorageCookie {
  return {
    name: "analytics",
    value: "1",
    domain: "example.com",
    path: "/",
    secure: true,
    httpOnly: false,
    session: true,
    ...overrides,
  };
}

function makeHarness(initialSettings = cloneSettings()) {
  let currentSettings = cloneSettings(initialSettings);

  const applyRules = vi.fn(async (_rules: NetRule[]) => {});
  const clearRules = vi.fn(async (_ids?: number[]) => {});
  const listCookies = vi.fn(async (_url?: string): Promise<StorageCookie[]> => []);
  const removeCookie = vi.fn(async (_cookie: StorageCookie) => {});
  const classifyCookie = vi.fn(
    (_cookie: StorageCookie): "necessary" | "analytics" => "analytics",
  );
  const modelReady = vi.fn(async () => true);
  const modelChat = vi.fn(
    async (_messages: { role: string; content: string }[]) => "summary",
  );
  const settingsGet = vi.fn(async () => cloneSettings(currentSettings));
  const settingsSet = vi.fn(
    async (patch: Partial<AegisSettings>): Promise<AegisSettings> => {
      currentSettings = cloneSettings({
        ...currentSettings,
        ...patch,
      });
      return cloneSettings(currentSettings);
    },
  );

  const ports: AegisPorts = {
    net: {
      applyRules,
      clearRules,
    },
    storage: {
      listCookies,
      removeCookie,
      classifyCookie,
    },
    page: {
      getSnapshot: vi.fn(async () => ({
        url: "https://example.com/",
        title: "Example",
        textSample: "Example",
        forms: 0,
        passwordFields: 0,
      })),
    },
    model: {
      ready: modelReady,
      chat: modelChat,
    },
    settings: {
      get: settingsGet,
      set: settingsSet,
    },
  };

  return {
    ports,
    applyRules,
    clearRules,
    listCookies,
    removeCookie,
    classifyCookie,
    modelReady,
    modelChat,
    settingsGet,
    settingsSet,
  };
}

describe("PolicyEngine", () => {
  it("loads settings and applies tracker rules during init", async () => {
    const harness = makeHarness(
      cloneSettings({
        locale: "en",
        trackerWhitelist: ["trusted.example"],
      }),
    );
    const engine = new PolicyEngine(harness.ports);

    await engine.init();

    expect(harness.settingsGet).toHaveBeenCalledTimes(1);
    expect(engine.getSettings().locale).toBe("en");
    expect(harness.applyRules).toHaveBeenCalledTimes(1);
  });

  it("does not refresh tracker rules for unrelated settings", async () => {
    const harness = makeHarness();
    const engine = new PolicyEngine(harness.ports);
    await engine.init();

    await engine.updateSettings({ locale: "en" });

    expect(harness.settingsSet).toHaveBeenCalledWith({ locale: "en" });
    expect(harness.applyRules).toHaveBeenCalledTimes(1);
    expect(harness.clearRules).not.toHaveBeenCalled();
  });

  it("publishes updated whitelist domains and removes stale exemptions", async () => {
    const harness = makeHarness();
    const engine = new PolicyEngine(harness.ports);
    await engine.init();

    await engine.updateSettings({ trackerWhitelist: ["trusted.example"] });

    expect(harness.applyRules).toHaveBeenCalledTimes(2);
    const initialRules = harness.applyRules.mock.calls[1][0];
    expect(initialRules.length).toBeGreaterThan(0);
    for (const rule of initialRules) {
      expect(rule.excludedDomains).toEqual(["trusted.example"]);
    }

    await engine.updateSettings({ trackerWhitelist: ["replacement.example"] });

    expect(harness.applyRules).toHaveBeenCalledTimes(3);
    const replacementRules = harness.applyRules.mock.calls[2][0];
    expect(replacementRules.length).toBeGreaterThan(0);
    for (const rule of replacementRules) {
      expect(rule.excludedDomains).toEqual(["replacement.example"]);
    }

    await engine.updateSettings({ trackerWhitelist: [] });

    expect(harness.applyRules).toHaveBeenCalledTimes(4);
    const clearedRules = harness.applyRules.mock.calls[3][0];
    expect(clearedRules.length).toBeGreaterThan(0);
    for (const rule of clearedRules) {
      expect(rule.excludedDomains ?? []).toEqual([]);
    }
  });

  it("clears rules when tracker protection is disabled and reapplies on enable", async () => {
    const harness = makeHarness();
    const engine = new PolicyEngine(harness.ports);
    await engine.init();

    await engine.updateSettings({
      modules: {
        ...engine.getSettings().modules,
        tracker: false,
      },
    });

    expect(harness.clearRules).toHaveBeenCalledTimes(1);

    await engine.updateSettings({
      modules: {
        ...engine.getSettings().modules,
        tracker: true,
      },
    });

    expect(harness.applyRules).toHaveBeenCalledTimes(2);
  });

  it("preserves caller-supplied rules during tracker synchronization", async () => {
    const harness = makeHarness();
    const engine = new PolicyEngine(harness.ports);
    await engine.init();
    harness.applyRules.mockClear();

    const extraRule: NetRule = {
      id: 999_001,
      action: "block",
      urlFilter: "||example.invalid^",
    };

    const rules = await engine.syncTrackerRules([extraRule]);

    expect(rules).toContainEqual(extraRule);
    expect(harness.applyRules).toHaveBeenCalledWith(
      expect.arrayContaining([extraRule]),
    );
  });

  it("propagates tracker rule application failures", async () => {
    const harness = makeHarness();
    const engine = new PolicyEngine(harness.ports);
    await engine.init();

    harness.applyRules.mockRejectedValueOnce(new Error("rule apply failed"));

    await expect(engine.syncTrackerRules()).rejects.toThrow(
      "rule apply failed",
    );
  });

  it("tracks per-tab block counts and reset", () => {
    const harness = makeHarness();
    const engine = new PolicyEngine(harness.ports);

    engine.recordBlock({
      id: "ad-1",
      tabId: 7,
      url: "https://ads.example/ad.js",
      type: "ad",
      timestamp: 1,
    });
    engine.recordBlock({
      id: "tracker-1",
      tabId: 7,
      url: "https://tracker.example/pixel",
      type: "tracker",
      timestamp: 2,
    });

    expect(engine.getTabStats(7)).toMatchObject({
      tabId: 7,
      blocked: 2,
      ads: 1,
      trackers: 1,
      lastUrl: "https://tracker.example/pixel",
    });

    engine.resetTabStats(7);

    expect(engine.getTabStats(7)).toEqual({
      tabId: 7,
      blocked: 0,
      ads: 0,
      trackers: 0,
    });
  });

  it("returns a non-blocking phishing result when phishing protection is disabled", async () => {
    const harness = makeHarness(
      cloneSettings({
        modules: {
          phish: false,
        },
      }),
    );
    const engine = new PolicyEngine(harness.ports);
    await engine.init();

    expect(engine.assessPage(suspiciousSnapshot)).toEqual({
      score: 0,
      severity: "low",
      reasons: [],
      shouldBlock: false,
      url: suspiciousSnapshot.url,
    });
  });

  it("uses the synchronous phishing heuristic for navigation decisions", async () => {
    const harness = makeHarness();
    const engine = new PolicyEngine(harness.ports);
    await engine.init();

    const assessment = engine.assessPage(suspiciousSnapshot);

    expect(assessment.url).toBe(suspiciousSnapshot.url);
    expect(assessment.shouldBlock).toBe(true);
    expect(assessment.reasons.length).toBeGreaterThan(0);
  });

  it("normalizes phishing feedback hosts and returns defensive copies", () => {
    const harness = makeHarness();
    const engine = new PolicyEngine(harness.ports);

    engine.markPhishFeedback("EVIL.TK", "phish");
    const feedback = engine.getPhishFeedback();

    expect(feedback).toEqual({ "evil.tk": "phish" });

    feedback["evil.tk"] = "safe";

    expect(engine.getPhishFeedback()).toEqual({ "evil.tk": "phish" });
  });

  it("fails closed for cloud prompts when cloud models are disabled", () => {
    const harness = makeHarness();
    const engine = new PolicyEngine(harness.ports);

    expect(engine.gateCloudPrompt("hello@example.com", true)).toMatchObject({
      allowed: false,
      payload: "hello@example.com",
      reason: "cloud_disabled",
    });
    expect(engine.cloudUploadAllowedForUrl("https://example.com/")).toBe(false);
  });

  it("keeps URLs unchanged when link sanitization is disabled", async () => {
    const harness = makeHarness(
      cloneSettings({ sanitizeLinkDecorations: false }),
    );
    const engine = new PolicyEngine(harness.ports);
    await engine.init();

    const url = "https://example.com/?utm_source=test";

    expect(engine.sanitizeUrl(url)).toEqual({
      original: url,
      cleaned: url,
      removed: [],
      changed: false,
    });
  });

  it("does not invoke the model when privacy AI is disabled", async () => {
    const harness = makeHarness(
      cloneSettings({
        modules: {
          privacyAi: false,
        },
      }),
    );
    const engine = new PolicyEngine(harness.ports);
    await engine.init();

    const result = await engine.summarize({
      url: "https://example.com/",
      title: "Example",
      textSample: "Example",
    });

    expect(result).toMatchObject({
      summary: "",
      bullets: [],
      risks: [],
      modelReady: false,
    });
    expect(harness.modelReady).not.toHaveBeenCalled();
    expect(harness.modelChat).not.toHaveBeenCalled();
  });

  it("uses the storage classifier override when enforcing cookie policy", async () => {
    const harness = makeHarness();
    const engine = new PolicyEngine(harness.ports);
    await engine.init();

    const necessary = makeCookie({ name: "_ga" });
    const analytics = makeCookie();

    harness.listCookies.mockResolvedValueOnce([necessary, analytics]);
    harness.classifyCookie.mockImplementation((cookie) =>
      cookie.name === "_ga" ? "necessary" : "analytics",
    );

    await expect(
      engine.enforceCookiePolicy("https://example.com/"),
    ).resolves.toBe(1);
    expect(harness.classifyCookie).toHaveBeenCalledTimes(2);
    expect(harness.classifyCookie).toHaveBeenCalledWith(necessary);
    expect(harness.classifyCookie).toHaveBeenCalledWith(analytics);
    expect(harness.removeCookie).not.toHaveBeenCalledWith(necessary);
    expect(harness.removeCookie).toHaveBeenCalledTimes(1);
    expect(harness.removeCookie).toHaveBeenCalledWith(analytics);
  });

  it("propagates cookie removal failures", async () => {
    const harness = makeHarness();
    const engine = new PolicyEngine(harness.ports);
    await engine.init();

    const analytics = makeCookie();

    harness.listCookies.mockResolvedValueOnce([analytics]);
    harness.classifyCookie.mockReturnValueOnce("analytics");
    harness.removeCookie.mockRejectedValueOnce(new Error("remove failed"));

    await expect(engine.enforceCookiePolicy()).rejects.toThrow(
      "remove failed",
    );
  });

  it("falls back to the disabled phishing path for async assessment", async () => {
    const harness = makeHarness(
      cloneSettings({
        modules: {
          phish: false,
        },
      }),
    );
    const engine = new PolicyEngine(harness.ports);
    await engine.init();

    await expect(engine.assessPageAsync(suspiciousSnapshot)).resolves.toMatchObject({
      shouldBlock: false,
      score: 0,
      url: suspiciousSnapshot.url,
    });
  });

  it("uses the configured phishing model for async assessment", async () => {
    const harness = makeHarness();
    const engine = new PolicyEngine(harness.ports);
    await engine.init();

    const score = vi.fn(async (_snapshot: PageSnapshot) => 100);
    engine.setPhishModel({ score });

    const assessment = await engine.assessPageAsync(suspiciousSnapshot);

    expect(score).toHaveBeenCalledTimes(1);
    expect(assessment.shouldBlock).toBe(true);
    expect(
      assessment.reasons.some(
        (reason) => reason.code === "lightweight_model_blend",
      ),
    ).toBe(true);
  });

  it("loads phishing feedback by value", () => {
    const harness = makeHarness();
    const engine = new PolicyEngine(harness.ports);
    const feedback: Record<string, "safe" | "phish"> = {
      "evil.tk": "safe",
    };

    engine.loadPhishFeedback(feedback);
    feedback["evil.tk"] = "phish";

    expect(engine.getPhishFeedback()).toEqual({ "evil.tk": "safe" });
  });

  it("resolves auto locale for enabled privacy summaries", async () => {
    const harness = makeHarness(cloneSettings({ locale: "auto" }));
    const engine = new PolicyEngine(harness.ports);
    await engine.init();

    const result = await engine.summarize({
      url: "https://example.com/",
      title: "",
      textSample: "",
    });

    expect(result).toMatchObject({
      summary: "未能提取可读页面文本。",
      backend: "mock",
      modelReady: true,
    });
    expect(harness.modelReady).not.toHaveBeenCalled();
    expect(harness.modelChat).not.toHaveBeenCalled();
  });

  it("allows safe cloud use but blocks sensitive origins when cloud models are enabled", async () => {
    const harness = makeHarness(cloneSettings({ allowCloudModels: true }));
    const engine = new PolicyEngine(harness.ports);
    await engine.init();

    expect(engine.gateCloudPrompt("safe text", true)).toMatchObject({
      allowed: true,
      reason: "ok",
    });
    expect(engine.cloudUploadAllowedForUrl("https://paypal.com/login")).toBe(
      false,
    );
    expect(engine.cloudUploadAllowedForUrl("https://example.com/")).toBe(true);
  });

  it("removes tracking decorations when link sanitization is enabled", async () => {
    const harness = makeHarness();
    const engine = new PolicyEngine(harness.ports);
    await engine.init();

    const result = engine.sanitizeUrl(
      "https://example.com/?utm_source=test&keep=1#utm_campaign=spring",
    );

    expect(result.changed).toBe(true);
    expect(result.removed).toEqual(
      expect.arrayContaining(["utm_source", "#tracking-hash"]),
    );
    expect(result.cleaned).toContain("keep=1");
    expect(result.cleaned).not.toContain("utm_source");
  });

  it("preserves rejected cookies on tracker-whitelisted domains", async () => {
    const harness = makeHarness(
      cloneSettings({ trackerWhitelist: ["trusted.example"] }),
    );
    const engine = new PolicyEngine(harness.ports);
    await engine.init();

    const analytics = makeCookie({ name: "_ga", domain: ".trusted.example" });
    harness.listCookies.mockResolvedValueOnce([analytics]);
    harness.classifyCookie.mockReturnValueOnce("analytics");

    await expect(engine.enforceCookiePolicy()).resolves.toBe(0);
    expect(harness.removeCookie).not.toHaveBeenCalled();
  });

  it("falls back to the built-in cookie classifier", async () => {
    const harness = makeHarness();
    delete harness.ports.storage.classifyCookie;
    const engine = new PolicyEngine(harness.ports);
    await engine.init();

    const analytics = makeCookie({ name: "_ga" });
    harness.listCookies.mockResolvedValueOnce([analytics]);

    await expect(engine.enforceCookiePolicy()).resolves.toBe(1);
    expect(harness.removeCookie).toHaveBeenCalledWith(analytics);
  });
});
