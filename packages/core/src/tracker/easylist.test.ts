import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  compileEasyList,
  mergeCompiledFilterLists,
  parseEasyListRule,
} from "./easylist.js";

const fixture = readFileSync(
  resolve(dirname(fileURLToPath(import.meta.url)), "easylist.fixture.txt"),
  "utf8",
);

describe("parseEasyListRule", () => {
  it("parses host, path, exception, and skips cosmetics", () => {
    expect(parseEasyListRule("||ads.example.com^$third-party")).toEqual({
      kind: "block",
      rule: "ads.example.com",
      path: false,
    });
    expect(parseEasyListRule("||tracker.example.com/pixel")).toEqual({
      kind: "block",
      rule: "tracker.example.com/pixel",
      path: true,
    });
    expect(parseEasyListRule("@@||cdn.example.com^")).toEqual({
      kind: "exception",
      rule: "cdn.example.com",
      path: false,
    });
    expect(parseEasyListRule("example.com##.ad")).toBeNull();
    expect(parseEasyListRule("||x.com^$domain=a.com")).toBeNull();
  });
});

describe("compileEasyList", () => {
  it("compiles the fixture into unique host tables", () => {
    const compiled = compileEasyList(
      fixture,
      "fixture",
      new Date("2026-01-01T00:00:00.000Z"),
    );
    expect(compiled.hosts).toEqual([
      "ads.example.com",
      "doubleclick.net",
      "ok-host.co.uk",
    ]);
    expect(compiled.pathRules).toEqual(["tracker.example.com/pixel"]);
    expect(compiled.exceptions).toEqual(["cdn.example.com"]);
    expect(compiled.parsed).toBe(5);
    expect(compiled.skipped).toBeGreaterThan(0);
  });

  it("merges lists without duplicating hosts", () => {
    const a = compileEasyList("||a.example^");
    const b = compileEasyList("||a.example^\n||b.example^");
    const merged = mergeCompiledFilterLists([a, b], "a+b");
    expect(merged.hosts).toEqual(["a.example", "b.example"]);
  });
});
