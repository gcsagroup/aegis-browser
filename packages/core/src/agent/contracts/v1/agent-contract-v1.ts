export type AgentContractErrorCode =
  | "invalid_message"
  | "unsupported_version"
  | "unknown_field"
  | "invalid_value"
  | "non_canonical_set";

export class AgentContractValidationError extends Error {
  constructor(readonly code: AgentContractErrorCode) {
    super(code);
  }
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const TIMESTAMP_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;
const RISKS = new Set(["R0", "R1", "R2", "R3"]);
const SURFACES = new Set(["aegis_browser", "safari_read_only"]);
const TOOLS = new Set([
  "page.observe",
  "page.extract",
  "url.health",
  "bookmarks.list",
  "bookmarks.plan",
  "bookmarks.apply",
  "bookmarks.undo",
  "downloads.verify",
  "downloads.start",
  "downloads.cancel",
  "browser.tabs.create",
  "page.click",
]);

type JSONObject = Record<string, unknown>;

function object(value: unknown): JSONObject {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new AgentContractValidationError("invalid_message");
  }
  return value as JSONObject;
}

function exactKeys(value: JSONObject, required: readonly string[]): void {
  const allowed = new Set(required);
  if (Object.keys(value).some((key) => !allowed.has(key))) {
    throw new AgentContractValidationError("unknown_field");
  }
  if (required.some((key) => !(key in value))) {
    throw new AgentContractValidationError("invalid_value");
  }
}

function string(value: unknown): string {
  if (typeof value !== "string") throw new AgentContractValidationError("invalid_value");
  return value;
}

function nonEmptyString(value: unknown): string {
  const result = string(value);
  if (result.length === 0) throw new AgentContractValidationError("invalid_value");
  return result;
}

function uuid(value: unknown): void {
  if (!UUID_PATTERN.test(string(value))) throw new AgentContractValidationError("invalid_value");
}

function timestamp(value: unknown): void {
  const result = string(value);
  if (!TIMESTAMP_PATTERN.test(result) || Number.isNaN(Date.parse(result))) {
    throw new AgentContractValidationError("invalid_value");
  }
}

function safeInteger(value: unknown, minimum = 0): void {
  if (!Number.isSafeInteger(value) || (value as number) < minimum) {
    throw new AgentContractValidationError("invalid_value");
  }
}

function boolean(value: unknown): void {
  if (typeof value !== "boolean") throw new AgentContractValidationError("invalid_value");
}

function canonicalStrings(value: unknown, values?: Set<string>): void {
  if (!Array.isArray(value) || value.some((entry) => typeof entry !== "string" || entry.length === 0)) {
    throw new AgentContractValidationError("invalid_value");
  }
  const strings = value as string[];
  if (new Set(strings).size !== strings.length || [...strings].sort().some((entry, index) => entry !== strings[index])) {
    throw new AgentContractValidationError("non_canonical_set");
  }
  if (values && strings.some((entry) => !values.has(entry))) {
    throw new AgentContractValidationError("invalid_value");
  }
}

function canonicalUUIDs(value: unknown): void {
  canonicalStrings(value);
  for (const entry of value as string[]) uuid(entry);
}

function validateTabScope(value: unknown): void {
  const scope = object(value);
  exactKeys(scope, ["approved_existing_tab_ids", "may_create_tabs"]);
  canonicalUUIDs(scope.approved_existing_tab_ids);
  boolean(scope.may_create_tabs);
}

function validateBookmarkScope(value: unknown): void {
  const scope = object(value);
  exactKeys(scope, ["root_ids", "may_write"]);
  canonicalUUIDs(scope.root_ids);
  boolean(scope.may_write);
}

function validateDownloadScope(value: unknown): void {
  const scope = object(value);
  exactKeys(scope, ["approved_existing_ids", "may_start_downloads"]);
  canonicalUUIDs(scope.approved_existing_ids);
  boolean(scope.may_start_downloads);
}

function validateModelDestination(value: unknown): void {
  if (value === null) return;
  const destination = object(value);
  exactKeys(destination, ["provider", "exact_https_host", "purpose", "data_classes", "max_request_bytes"]);
  nonEmptyString(destination.provider);
  nonEmptyString(destination.exact_https_host);
  nonEmptyString(destination.purpose);
  canonicalStrings(destination.data_classes);
  safeInteger(destination.max_request_bytes, 1);
}

function validateTaskGrant(value: unknown): void {
  const payload = object(value);
  exactKeys(payload, [
    "task_id",
    "grant_id",
    "surface",
    "profile_id",
    "allowed_top_origins",
    "allowed_frame_origins",
    "allowed_tools",
    "data_classes",
    "risk_ceiling",
    "max_steps",
    "time_budget_seconds",
    "byte_budget",
    "cost_budget",
    "tab_scope",
    "bookmark_scope",
    "download_scope",
    "expires_at",
    "policy_version",
    "model_version",
    "model_destination",
  ]);
  uuid(payload.task_id);
  uuid(payload.grant_id);
  uuid(payload.profile_id);
  if (!SURFACES.has(string(payload.surface))) throw new AgentContractValidationError("invalid_value");
  canonicalStrings(payload.allowed_top_origins);
  canonicalStrings(payload.allowed_frame_origins);
  canonicalStrings(payload.allowed_tools, TOOLS);
  canonicalStrings(payload.data_classes);
  if (!RISKS.has(string(payload.risk_ceiling))) throw new AgentContractValidationError("invalid_value");
  safeInteger(payload.max_steps, 1);
  safeInteger(payload.time_budget_seconds, 1);
  safeInteger(payload.byte_budget);
  if (!/^(0|[1-9][0-9]*)(\.[0-9]+)?$/.test(string(payload.cost_budget))) {
    throw new AgentContractValidationError("invalid_value");
  }
  validateTabScope(payload.tab_scope);
  validateBookmarkScope(payload.bookmark_scope);
  validateDownloadScope(payload.download_scope);
  timestamp(payload.expires_at);
  nonEmptyString(payload.policy_version);
  nonEmptyString(payload.model_version);
  validateModelDestination(payload.model_destination);
}

function validateDocumentLease(value: unknown): void {
  const payload = object(value);
  exactKeys(payload, [
    "lease_id",
    "task_id",
    "grant_id",
    "profile_id",
    "process_instance_id",
    "browser_session_id",
    "web_view_id",
    "tab_id",
    "frame_id",
    "committed_top_origin",
    "frame_origin",
    "navigation_epoch",
    "document_nonce",
    "call_sequence",
    "expires_at",
  ]);
  for (const key of [
    "lease_id",
    "task_id",
    "grant_id",
    "profile_id",
    "process_instance_id",
    "browser_session_id",
    "web_view_id",
    "tab_id",
  ]) uuid(payload[key]);
  for (const key of ["frame_id", "committed_top_origin", "frame_origin", "document_nonce"]) {
    nonEmptyString(payload[key]);
  }
  safeInteger(payload.navigation_epoch);
  safeInteger(payload.call_sequence);
  timestamp(payload.expires_at);
}

function validateTarget(value: unknown): void {
  const target = object(value);
  const kind = string(target.kind);
  if (kind === "native") {
    exactKeys(target, ["kind", "resource_type", "registry_revision", "resource_id"]);
    if (!["bookmark_plan", "bookmark_transaction", "tab_batch", "download"].includes(string(target.resource_type))) {
      throw new AgentContractValidationError("invalid_value");
    }
    safeInteger(target.registry_revision);
    uuid(target.resource_id);
    return;
  }
  if (kind === "web") {
    exactKeys(target, [
      "kind",
      "lease_id",
      "browser_session_id",
      "web_view_id",
      "tab_id",
      "frame_id",
      "top_origin",
      "frame_origin",
      "navigation_epoch",
      "document_nonce",
      "call_sequence",
      "document_digest",
      "node_fingerprint",
    ]);
    for (const key of ["lease_id", "browser_session_id", "web_view_id", "tab_id"]) uuid(target[key]);
    for (const key of [
      "frame_id",
      "top_origin",
      "frame_origin",
      "document_nonce",
      "document_digest",
      "node_fingerprint",
    ]) nonEmptyString(target[key]);
    safeInteger(target.navigation_epoch);
    safeInteger(target.call_sequence);
    return;
  }
  throw new AgentContractValidationError("invalid_value");
}

function validateActionDigest(value: unknown): void {
  const payload = object(value);
  exactKeys(payload, [
    "task_id",
    "grant_id",
    "profile_id",
    "process_instance_id",
    "surface",
    "policy_version",
    "tool",
    "normalized_parameters",
    "call_sequence",
    "target",
    "confirmation_digest",
    "expires_at",
  ]);
  for (const key of ["task_id", "grant_id", "profile_id", "process_instance_id"]) uuid(payload[key]);
  if (!SURFACES.has(string(payload.surface))) throw new AgentContractValidationError("invalid_value");
  nonEmptyString(payload.policy_version);
  if (!TOOLS.has(string(payload.tool))) throw new AgentContractValidationError("invalid_value");
  string(payload.normalized_parameters);
  safeInteger(payload.call_sequence);
  validateTarget(payload.target);
  if (payload.confirmation_digest !== null) string(payload.confirmation_digest);
  timestamp(payload.expires_at);
}

export function validateAgentContractMessage(value: unknown): "task_grant" | "document_lease" | "action_digest_input" {
  const message = object(value);
  if (message.contract_version !== 1) {
    throw new AgentContractValidationError("unsupported_version");
  }
  exactKeys(message, ["contract_version", "message_type", "payload"]);
  const messageType = string(message.message_type);
  switch (messageType) {
    case "task_grant":
      validateTaskGrant(message.payload);
      return messageType;
    case "document_lease":
      validateDocumentLease(message.payload);
      return messageType;
    case "action_digest_input":
      validateActionDigest(message.payload);
      return messageType;
    default:
      throw new AgentContractValidationError("invalid_value");
  }
}
