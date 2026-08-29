// @ts-nocheck -- research-only Node ESM utility intentionally stays out of browser bundles.
import {
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  stat,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  acquirePublicPilot,
  buildPublicPilotPlan,
  sha256Hex,
} from "./public-pilot-acquisition.mjs";
import definition from "./protocols/miner-capability-public-v1.json";

const temporaryRoots: string[] = [];

afterEach(async () => {
  await Promise.all(temporaryRoots.splice(0).map((path) => rm(path, { recursive: true, force: true })));
});

function minimalDefinition(bytes: Buffer) {
  const digest = sha256Hex(bytes);
  const source = {
    name: "Fixture",
    repository: "owner/repository",
    revision: "1".repeat(40),
    retrievedAt: "2026-08-27T18:07:52.000Z",
    purposeEvidenceUrl: `https://github.com/owner/repository/tree/${"1".repeat(40)}`,
    license: {
      spdx: "MIT",
      url: `https://github.com/owner/repository/blob/${"1".repeat(40)}/LICENSE`,
    },
  };
  const sample = (sampleId: string, label: string, path: string) => ({
    sampleId,
    sourceRef: "fixture",
    familyGroup: sampleId,
    label,
    category: "test",
    obfuscationTier: "none",
    files: [{ remotePath: path, byteLength: bytes.length, sha256: digest }],
  });
  return {
    schemaVersion: 1,
    mode: "research-only",
    datasetId: "test-public-pilot",
    createdAt: "2026-08-27T18:07:52.000Z",
    task: {
      target: "browser-mining-capability",
      positiveLabel: "mining-capable",
      negativeLabel: "benign-control",
      publiclyInspectable: true,
      independentLabelReview: false,
      sealed: false,
      contextualMaliciousnessInferred: false,
    },
    acquisition: {
      transport: "https-pinned-github-raw",
      allowedHost: "raw.githubusercontent.com",
      sourceExecution: false,
      maxFileBytes: 1024,
      maxTotalBytes: 4096,
      localOnly: true,
      redistributeWithProduct: false,
    },
    sources: { fixture: source },
    samples: [
      sample("benign-one", "benign-control", "one.js"),
      sample("benign-two", "benign-control", "two.js"),
      sample("miner-one", "mining-capable", "three.js"),
    ],
  };
}

describe("public mining-capability pilot acquisition", () => {
  it("validates the pinned public definition without calling it malicious or sealed", () => {
    const plan = buildPublicPilotPlan(definition);
    expect(plan).toMatchObject({
      mode: "research-only",
      publicAndUnsealed: true,
      independentLabelReview: false,
      contextualMaliciousnessInferred: false,
      sourceCount: 13,
      sampleCount: 13,
      fileCount: 25,
      labels: { "benign-control": 10, "mining-capable": 3 },
    });
    expect(plan.totalBytes).toBe(1_167_195);
    expect(plan.definitionSha256).toMatch(/^[a-f0-9]{64}$/u);
    expect(plan.planSha256).toMatch(/^[a-f0-9]{64}$/u);
  });

  it("downloads only digest-bound bytes and supports a strict offline recheck", async () => {
    const bytes = Buffer.from("const value = 1;\n");
    const fixture = minimalDefinition(bytes);
    const root = await mkdtemp(join(tmpdir(), "aegis-public-pilot-test-"));
    temporaryRoots.push(root);
    const fetchImpl = async () => new Response(bytes, { status: 200 });
    const acquired = await acquirePublicPilot({
      definition: fixture,
      outputRoot: root,
      fetchImpl,
      acquiredAt: "2026-08-27T18:07:52.000Z",
    });
    expect(acquired).toMatchObject({
      releaseEligible: false,
      finalEvaluationEligible: false,
      enforcementAuthorized: false,
      acquisitionMode: "pinned-network-acquisition",
      sampleCount: 3,
      fileCount: 3,
      dataHandling: { sourceExecution: false, contextualMaliciousnessInferred: false },
    });
    expect(await readFile(join(root, "fixture", "one.js"))).toEqual(bytes);
    expect((await stat(join(root, "fixture", "one.js"))).mode & 0o777).toBe(0o600);
    const offline = await acquirePublicPilot({
      definition: fixture,
      outputRoot: root,
      offline: true,
      acquiredAt: "2026-08-27T18:07:52.000Z",
    });
    expect(offline.acquisitionMode).toBe("offline-verify");
  });

  it("rejects changed bytes before writing any sample", async () => {
    const bytes = Buffer.from("const value = 1;\n");
    const fixture = minimalDefinition(bytes);
    const root = await mkdtemp(join(tmpdir(), "aegis-public-pilot-test-"));
    temporaryRoots.push(root);
    const fetchImpl = async () => new Response(Buffer.from("changed\n"), { status: 200 });
    await expect(
      acquirePublicPilot({ definition: fixture, outputRoot: root, fetchImpl }),
    ).rejects.toThrow(/mismatch/u);
    await expect(readFile(join(root, "fixture", "one.js"))).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("uses the pinned entity digest when transport length describes compression", async () => {
    const bytes = Buffer.from("const value = 1;\n");
    const fixture = minimalDefinition(bytes);
    const root = await mkdtemp(join(tmpdir(), "aegis-public-pilot-test-"));
    temporaryRoots.push(root);
    const fetchImpl = async () =>
      new Response(bytes, {
        status: 200,
        headers: { "content-encoding": "gzip", "content-length": "3" },
      });
    const receipt = await acquirePublicPilot({ definition: fixture, outputRoot: root, fetchImpl });
    expect(receipt.fileCount).toBe(3);
  });

  it("rejects an outside-root leaf symlink before read or chmod with zero target side effects", async () => {
    const bytes = Buffer.from("const value = 1;\n");
    const fixture = minimalDefinition(bytes);
    const base = await mkdtemp(join(tmpdir(), "aegis-public-pilot-symlink-"));
    temporaryRoots.push(base);
    const root = join(base, "acquisition-root");
    const outside = join(base, "outside.js");
    const linkedLeaf = join(root, "fixture", "one.js");
    await mkdir(join(root, "fixture"), { recursive: true });
    await writeFile(outside, Buffer.from("outside target must remain unchanged\n"));
    await chmod(outside, 0o640);
    await symlink(outside, linkedLeaf);
    const beforeBytes = await readFile(outside);
    const beforeMode = (await stat(outside)).mode & 0o777;

    await expect(
      acquirePublicPilot({ definition: fixture, outputRoot: root, offline: true }),
    ).rejects.toThrow(/symbolic link/u);

    expect(await readFile(outside)).toEqual(beforeBytes);
    expect((await stat(outside)).mode & 0o777).toBe(beforeMode);
  });

  it("rejects path traversal, mutable revisions, and maliciousness label substitution", () => {
    const bytes = Buffer.from("const value = 1;\n");
    const traversal = minimalDefinition(bytes);
    traversal.samples[0].files[0].remotePath = "../escape.js";
    expect(() => buildPublicPilotPlan(traversal)).toThrow(/traversal/u);

    const mutable = minimalDefinition(bytes);
    mutable.sources.fixture.revision = "main";
    expect(() => buildPublicPilotPlan(mutable)).toThrow(/full commit/u);

    const mislabeled = minimalDefinition(bytes);
    mislabeled.samples[2].label = "malicious";
    expect(() => buildPublicPilotPlan(mislabeled)).toThrow(/label is invalid/u);
  });
});
