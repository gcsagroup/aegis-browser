// @ts-nocheck
import { describe, expect, it } from "vitest";
import {
  compileThreatIndex,
  parseCertPl,
  parsePhishTank,
  parseUrlhaus,
} from "../../scripts/threat-feed-lib.mjs";

describe("threat feed adapters", () => {
  it("parses CERT.PL domains and canonicalizes IDNs", () => {
    expect(parseCertPl("# generated\nevil.example\nżółć.example\n")).toEqual([
      { kind: 1, value: "evil.example" },
      { kind: 1, value: "xn--kda4b0koi.example" },
    ]);
  });

  it("rejects a single-label domain that could block an entire TLD", () => {
    expect(() => parseCertPl("com\n")).toThrow("invalid domain");
  });

  it("keeps only verified online PhishTank URLs", () => {
    const entries = parsePhishTank(JSON.stringify([
      { url: "https://evil.example/login#x", verified: "yes", online: "yes" },
      { url: "https://offline.example/", verified: "yes", online: "no" },
    ]));
    expect(entries).toEqual([{ kind: 2, value: "https://evil.example/login" }]);
  });

  it("parses URLhaus text and quoted CSV", () => {
    expect(parseUrlhaus([
      "https://evil.example/payload#fragment",
      '"1","2026-08-25","http://malware.example/a.exe","online"',
    ].join("\n"))).toEqual([
      { kind: 2, value: "https://evil.example/payload" },
      { kind: 2, value: "http://malware.example/a.exe" },
    ]);
  });
});

describe("threat index compiler", () => {
  it("emits the native binary contract and merges duplicate sources", () => {
    const result = compileThreatIndex([
      { source: "cert-pl", entries: [{ kind: 1, value: "evil.example" }] },
      { source: "phishtank", entries: [{ kind: 2, value: "https://evil.example/login" }] },
      { source: "urlhaus", entries: [{ kind: 2, value: "https://evil.example/login" }] },
    ], { generatedAt: 100, expiresAt: 200 });

    expect(result.count).toBe(2);
    expect(result.bytes.subarray(0, 8).toString("ascii")).toBe("AEGISTI1");
    expect(result.bytes.readUInt32LE(8)).toBe(1);
    expect(result.bytes.readBigUInt64LE(12)).toBe(100n);
    expect(result.bytes.readBigUInt64LE(20)).toBe(200n);
    expect(result.bytes.readUInt32LE(28)).toBe(2);
    expect(result.bytes.length).toBe(36 + 2 * 36);
    expect([...result.bytes].includes(3)).toBe(true);
  });
});
