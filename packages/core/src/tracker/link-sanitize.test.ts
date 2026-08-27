import { describe, expect, it } from "vitest";
import { sanitizeUrlDecorations } from "./link-sanitize.js";

describe("sanitizeUrlDecorations", () => {
  it("strips utm and click ids", () => {
    const result = sanitizeUrlDecorations(
      "https://news.example/a?utm_source=x&fbclid=123&keep=1",
    );
    expect(result.changed).toBe(true);
    expect(result.cleaned).toBe("https://news.example/a?keep=1");
    expect(result.removed).toEqual(expect.arrayContaining(["utm_source", "fbclid"]));
  });
});
