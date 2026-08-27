export const STATIC_SCRIPT_SIGNAL_CODES = [
  "ast.worker-construction",
  "ast.wasm-use",
  "ast.webgpu-compute",
  "ast.shared-memory",
  "ast.websocket",
  "ast.mining-protocol",
  "ast.hash-loop",
  "ast.dynamic-code",
  "ast.encoded-payload",
  "ast.remote-load",
  "ast.execution-guard",
] as const;

export type StaticScriptSignalCode =
  (typeof STATIC_SCRIPT_SIGNAL_CODES)[number];

export interface StaticScriptSignalEvidence {
  code: StaticScriptSignalCode;
  occurrences: number;
}

/**
 * Source-free result produced by the Node-only AST analyzer. Raw JavaScript is
 * deliberately excluded so this object is safe to pass to the browser core.
 */
export interface StaticScriptAnalysis {
  schemaVersion: 1;
  analyzer: "typescript-ast";
  parserVersion: string;
  parseStatus: "complete" | "failed";
  failureCode?: "parser-resource-limit";
  sourceLength: number;
  analyzedLength: number;
  truncated: boolean;
  nodeCount: number;
  maxDepth: number;
  branchCount: number;
  signals: StaticScriptSignalEvidence[];
}

export interface ScriptRiskControls {
  masterEnabled?: boolean;
  featureEnabled?: boolean;
  preferenceEnabled?: boolean;
  sitePaused?: boolean;
}

export type SensitiveDataKind =
  | "password"
  | "auth-token"
  | "private-key"
  | "cookie"
  | "storage";

interface ScriptBehaviorEventBase {
  /** Caller-provided monotonic or wall-clock timestamp, compared with nowMs. */
  atMs: number;
}

export type ScriptBehaviorEvent =
  | (ScriptBehaviorEventBase & {
      type: "cpu-sample";
      utilizationPercent: number;
      durationMs: number;
    })
  | (ScriptBehaviorEventBase & {
      type: "worker-count";
      activeWorkers: number;
    })
  | (ScriptBehaviorEventBase & {
      type: "wasm-execution";
      durationMs: number;
    })
  | (ScriptBehaviorEventBase & {
      type: "webgpu-compute";
      dispatchCount: number;
    })
  | (ScriptBehaviorEventBase & {
      type: "network-connect";
      transport: "websocket" | "http" | "other";
    })
  | (ScriptBehaviorEventBase & {
      type: "mining-protocol";
      protocol: "stratum" | "mining-json-rpc";
    })
  | (ScriptBehaviorEventBase & {
      type: "sensitive-read";
      dataKind: SensitiveDataKind;
      /** Opaque, in-memory correlation key. Never copied into assessment output. */
      flowId?: string;
    })
  | (ScriptBehaviorEventBase & {
      type: "network-send";
      /** Opaque keys proving an observed data flow; payloads are never accepted. */
      flowIds?: readonly string[];
    });

export type RuntimeScriptSignalCode =
  | "runtime.sustained-cpu"
  | "runtime.worker-fanout"
  | "runtime.wasm-execution"
  | "runtime.webgpu-compute"
  | "runtime.websocket"
  | "runtime.mining-protocol"
  | "runtime.sensitive-read"
  | "runtime.network-send"
  | "graph.sensitive-to-network"
  | "aggregate.mining-multisignal"
  | "aggregate.obfuscated-loader-multisignal"
  | "aggregate.sensitive-exfiltration";

export type ScriptRiskReasonCode =
  | StaticScriptSignalCode
  | RuntimeScriptSignalCode;

export interface ScriptRiskReason {
  code: ScriptRiskReasonCode;
  /** Diagnostic count only. Counts are capped and never multiply risk score. */
  occurrences: number;
}

export type ScriptRiskFindingKind =
  | "suspected-mining"
  | "sensitive-data-exfiltration"
  | "obfuscated-remote-loader";

export interface ScriptRiskFinding {
  kind: ScriptRiskFindingKind;
  confidence: "medium" | "high";
  score: number;
  reasonCodes: ScriptRiskReasonCode[];
}

export interface ScriptBehaviorGraphNode {
  id: string;
  kind: "script" | "capability" | "sensitive-data" | "network";
  /** Categorical label only; never a URL, payload, flow id, or source excerpt. */
  label: string;
}

export interface ScriptBehaviorGraphEdge {
  from: string;
  to: string;
  relation: "uses" | "reads" | "connects" | "sends" | "flows-to";
}

export interface ScriptBehaviorGraph {
  nodes: ScriptBehaviorGraphNode[];
  edges: ScriptBehaviorGraphEdge[];
}

export interface ScriptRiskObservation {
  /** A hostname or URL. Output is reduced to hostname only. */
  site: string;
  /** Explicit clock injection makes time-window behavior deterministic in tests. */
  nowMs: number;
  windowMs?: number;
  controls?: ScriptRiskControls;
  staticAnalysis?: StaticScriptAnalysis;
  events?: readonly ScriptBehaviorEvent[];
}

export interface ScriptRiskAssessment {
  schemaVersion: 1;
  mode: "observe-only";
  status: "active" | "disabled";
  site: string;
  decision: "observed" | "suspicious" | "high-confidence";
  /** Always false in this phase. The core has no enforcement side effect. */
  wouldBlock: false;
  riskScore: number;
  reasons: ScriptRiskReason[];
  findings: ScriptRiskFinding[];
  graph: ScriptBehaviorGraph;
}
