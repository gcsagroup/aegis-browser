import { describe, expect, it } from "vitest";
import {
  isFirstPartyCollectUrl,
  sanitizeUrlDecorations,
} from "../index.js";

describe("isFirstPartyCollectUrl", () => {
  it("matches first-party GA4 and GTM copies", () => {
    expect(isFirstPartyCollectUrl("https://shop.example/g/collect?v=2")).toBe(
      true,
    );
    expect(isFirstPartyCollectUrl("https://shop.example/gtm.js")).toBe(true);
    expect(isFirstPartyCollectUrl("https://shop.example/static/gtm.js")).toBe(
      true,
    );
    expect(isFirstPartyCollectUrl("https://shop.example/ag/g/c?v=2")).toBe(
      true,
    );
  });

  it("matches GA4 query artifacts on custom paths when v/tid/en/cid are present", () => {
    expect(
      isFirstPartyCollectUrl(
        "https://shop.example/metrics/hit?v=2&tid=G-ABC123&en=page_view&cid=1.2",
      ),
    ).toBe(true);
  });

  it("matches conservative sGTM collect copies", () => {
    expect(
      isFirstPartyCollectUrl("https://shop.example/sgtm/g/collect?v=2"),
    ).toBe(true);
    expect(
      isFirstPartyCollectUrl("https://shop.example/_sgtm/g/collect"),
    ).toBe(true);
  });

  it("does not match generic /collect APIs or partial GA4 queries", () => {
    expect(isFirstPartyCollectUrl("https://shop.example/api/collect")).toBe(
      false,
    );
    expect(
      isFirstPartyCollectUrl("https://shop.example/api?tid=order&v=2"),
    ).toBe(false);
    expect(
      isFirstPartyCollectUrl(
        "https://shop.example/metrics/hit?v=2&tid=G-ABC123",
      ),
    ).toBe(false);
    expect(isFirstPartyCollectUrl("https://shop.example/")).toBe(false);
  });
});

describe("sanitizeUrlDecorations extra click ids", () => {
  it("strips gbraid and wbraid", () => {
    const result = sanitizeUrlDecorations(
      "https://news.example/a?gbraid=1&keep=1",
    );
    expect(result.changed).toBe(true);
    expect(result.cleaned).toBe("https://news.example/a?keep=1");
  });
});
