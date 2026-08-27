import { describe, expect, it } from "vitest";
import {
  buildSummarizePrompt,
  heuristicSummary,
  prepareSummary,
  redactPageSnapshotForModel,
} from "./orchestrator.js";

const snapshot = {
  url: "https://alice@example.com/account/alice%40example.com?token=tok_live_ABC123456789&email=bob%40example.com#secret-fragment",
  title: "Account for alice@example.com, phone 13812345678",
  textSample:
    "Contact bob@example.com. Authorization: Bearer abcdefghijklmnop.",
  forms: 1,
  passwordFields: 1,
};

describe("summary model boundary", () => {
  it("redacts body, URL, query, fragment, and title", () => {
    const safe = redactPageSnapshotForModel(snapshot);
    const serialized = JSON.stringify(safe);

    for (const secret of [
      "alice@example.com",
      "alice%40example.com",
      "bob@example.com",
      "bob%40example.com",
      "13812345678",
      "tok_live_ABC123456789",
      "secret-fragment",
      "abcdefghijklmnop",
    ]) {
      expect(serialized).not.toContain(secret);
    }
    expect(safe.url).toContain("token=%5BREDACTED%5D");
    expect(safe.url).toContain("email=%5BREDACTED%5D");
  });

  it("fails closed for invalid or unsupported snapshot URLs", () => {
    expect(
      redactPageSnapshotForModel({ ...snapshot, url: "not a valid URL" }).url,
    ).toBe("[INVALID_URL]");
    expect(
      redactPageSnapshotForModel({
        ...snapshot,
        url: "data:text/plain,alice@example.com",
      }).url,
    ).toBe("[UNSUPPORTED_URL]");
  });

  it("never places raw snapshot secrets in the model prompt", () => {
    const prompt = buildSummarizePrompt({ locale: "en", snapshot });
    const outbound = `${prompt.system}\n${prompt.user}`;

    for (const secret of [
      "alice@example.com",
      "bob@example.com",
      "13812345678",
      "tok_live_ABC123456789",
      "secret-fragment",
      "abcdefghijklmnop",
    ]) {
      expect(outbound).not.toContain(secret);
    }
  });

  it("redacts the heuristic fallback too", () => {
    const result = heuristicSummary(snapshot, "en");
    const rendered = JSON.stringify(result);
    expect(rendered).not.toContain("bob@example.com");
    expect(rendered).not.toContain("abcdefghijklmnop");
  });

  it("prepares a prompt-free structured browser handoff", () => {
    const prepared = prepareSummary(snapshot, "en");
    const serialized = JSON.stringify(prepared);

    expect(prepared.schemaVersion).toBe(1);
    expect(prepared.heuristic.summary.length).toBeGreaterThan(0);
    expect(serialized).not.toContain("alice@example.com");
    expect(serialized).not.toContain("abcdefghijklmnop");
    expect(serialized).not.toContain('"system"');
    expect(serialized).not.toContain('"user"');
    expect(serialized).not.toContain('"prompt"');
  });
});
