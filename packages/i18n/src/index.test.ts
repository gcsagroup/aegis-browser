import { describe, expect, it } from "vitest";
import { resolveLocale, t } from "./index.js";

describe("i18n", () => {
  it("defaults auto zh browser to zh-CN", () => {
    expect(resolveLocale("auto", "zh")).toBe("zh-CN");
  });

  it("resolves traditional chinese", () => {
    expect(resolveLocale("auto", "zh-TW")).toBe("zh-TW");
  });

  it("translates keys", () => {
    expect(t("en", "popup.blocked")).toBe("Blocked");
    expect(t("zh-CN", "popup.blocked")).toBe("已拦截");
  });
});
