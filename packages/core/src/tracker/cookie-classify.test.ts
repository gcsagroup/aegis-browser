import { describe, expect, it } from "vitest";
import { classifyCookie, shouldRejectCookie } from "./cookie-classify.js";

describe("classifyCookie", () => {
  it("flags analytics and advertising names", () => {
    expect(
      classifyCookie({
        name: "_ga",
        value: "1",
        domain: "example.com",
        path: "/",
        secure: true,
        httpOnly: false,
        session: false,
        expirationDate: Date.now() / 1000 + 86400,
      }),
    ).toBe("analytics");
    expect(
      classifyCookie({
        name: "IDE",
        value: "1",
        domain: ".doubleclick.net",
        path: "/",
        secure: true,
        httpOnly: false,
        session: false,
      }),
    ).toBe("advertising");
    expect(
      classifyCookie({
        name: "_fbp",
        value: "1",
        domain: "shop.example",
        path: "/",
        secure: true,
        httpOnly: false,
        session: false,
      }),
    ).toBe("advertising");
    expect(
      classifyCookie({
        name: "_ga_ABC123",
        value: "1",
        domain: "example.com",
        path: "/",
        secure: true,
        httpOnly: false,
        session: false,
      }),
    ).toBe("analytics");
  });

  it("does not treat Facebook login cookies as ads", () => {
    expect(
      classifyCookie({
        name: "c_user",
        value: "1",
        domain: ".facebook.com",
        path: "/",
        secure: true,
        httpOnly: true,
        session: false,
        expirationDate: Date.now() / 1000 + 86400 * 400,
      }),
    ).toBe("necessary");
    expect(
      classifyCookie({
        name: "datr",
        value: "1",
        domain: ".facebook.com",
        path: "/",
        secure: true,
        httpOnly: true,
        session: false,
      }),
    ).toBe("necessary");
    expect(
      classifyCookie({
        name: "session",
        value: "1",
        domain: ".facebook.com",
        path: "/",
        secure: true,
        httpOnly: true,
        session: true,
      }),
    ).not.toBe("advertising");
  });

  it("does not treat facebook.com as an ad network", () => {
    expect(
      classifyCookie({
        name: "locale",
        value: "en_US",
        domain: ".facebook.com",
        path: "/",
        secure: true,
        httpOnly: false,
        session: false,
      }),
    ).not.toBe("advertising");
  });

  it("never rejects necessary cookies", () => {
    expect(shouldRejectCookie("necessary", ["analytics", "advertising"])).toBe(
      false,
    );
    expect(shouldRejectCookie("analytics", ["analytics", "advertising"])).toBe(
      true,
    );
  });
});
