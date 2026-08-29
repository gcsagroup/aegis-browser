import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  AgentContractValidationError,
  validateAgentContractMessage,
  type AgentContractErrorCode,
} from "./agent-contract-v1.js";

interface ValidVector {
  name: string;
  message: unknown;
}

interface InvalidMutation {
  name: string;
  base: string;
  path: string[];
  value: unknown;
  expected_error: AgentContractErrorCode;
}

interface VectorDocument {
  vector_version: number;
  valid: ValidVector[];
  invalid_mutations: InvalidMutation[];
}

const vectors = JSON.parse(
  readFileSync(new URL("./agent-contract-v1.vectors.json", import.meta.url), "utf8"),
) as VectorDocument;
const schema = JSON.parse(
  readFileSync(new URL("./agent-contract-v1.schema.json", import.meta.url), "utf8"),
) as { oneOf?: unknown[]; $defs?: Record<string, { additionalProperties?: boolean }> };

function applyMutation(base: unknown, mutation: InvalidMutation): unknown {
  const copy = structuredClone(base) as Record<string, unknown>;
  let cursor: Record<string, unknown> = copy;
  for (const component of mutation.path.slice(0, -1)) {
    const next = cursor[component];
    if (typeof next !== "object" || next === null || Array.isArray(next)) {
      throw new Error(`无效向量路径: ${mutation.name}`);
    }
    cursor = next as Record<string, unknown>;
  }
  const leaf = mutation.path.at(-1);
  if (!leaf) throw new Error(`空向量路径: ${mutation.name}`);
  cursor[leaf] = mutation.value;
  return copy;
}

describe("Agent Contract v1 共享向量", () => {
  it("validates every frozen valid vector", () => {
    expect(vectors.vector_version).toBe(1);
    expect(vectors.valid.map((vector) => validateAgentContractMessage(vector.message))).toEqual([
      "task_grant",
      "document_lease",
      "action_digest_input",
      "action_digest_input",
    ]);
  });

  it("rejects each frozen invalid mutation with the exact error", () => {
    const bases = new Map(vectors.valid.map((vector) => [vector.name, vector.message]));
    for (const mutation of vectors.invalid_mutations) {
      const base = bases.get(mutation.base);
      expect(base, mutation.name).toBeDefined();
      try {
        validateAgentContractMessage(applyMutation(base, mutation));
        throw new Error(`向量未被拒绝: ${mutation.name}`);
      } catch (error) {
        expect(error, mutation.name).toBeInstanceOf(AgentContractValidationError);
        expect((error as AgentContractValidationError).code, mutation.name).toBe(mutation.expected_error);
      }
    }
  });

  it("keeps the published schema closed at every message boundary", () => {
    expect(schema.oneOf).toHaveLength(3);
    for (const name of [
      "task_grant_message",
      "document_lease_message",
      "action_digest_message",
      "task_grant_payload",
      "document_lease_payload",
      "action_digest_payload",
      "web_target",
      "native_target",
    ]) {
      expect(schema.$defs?.[name]?.additionalProperties, name).toBe(false);
    }
  });
});
