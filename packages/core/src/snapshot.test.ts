import { describe, expect, it } from "vitest";
import { createPolicySnapshot } from "./snapshot.js";
import { BUILTIN_TRACKER_HOSTS } from "./tracker/builtin-rules.js";
import { BUILTIN_PHISH_HOSTS } from "./phish/builtin-hosts.js";

describe("createPolicySnapshot", () => {
  it("embeds builtin tracker and phish seeds", () => {
    const snap = createPolicySnapshot(new Date("2026-01-01T00:00:00.000Z"));
    expect(snap.version).toBe(1);
    expect(snap.source).toBe("@gcsa-aegis/core");
    expect(snap.generatedAt).toBe("2026-01-01T00:00:00.000Z");
    expect(snap.trackerHosts).toEqual([...BUILTIN_TRACKER_HOSTS]);
    expect(snap.phishHosts).toEqual([...BUILTIN_PHISH_HOSTS]);
    expect(snap.trackingQueryParams).toContain("gbraid");
    expect(snap.firstPartyCollectPaths).toContain("/g/collect");
    expect(snap.firstPartyCollectPaths).toContain("/ag/g/c");
    expect(snap.firstPartyCollectPaths).toContain("/sgtm/g/collect");
    expect(snap.phishBrandKeywords).toContain("paypal");
  });
});
