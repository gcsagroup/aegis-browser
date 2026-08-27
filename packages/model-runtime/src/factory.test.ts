import { describe, expect, it } from "vitest";
import { createModelRuntime } from "./factory.js";

describe("createModelRuntime", () => {
  it("returns mock runtime by default", async () => {
    const runtime = createModelRuntime({ backend: "mock" });
    expect(await runtime.ready()).toBe(true);
    const out = await runtime.chat([{ role: "user", content: "hello world" }]);
    expect(out).toContain("Mock backend");
  });
});
