import {
  STATIC_SCRIPT_SIGNAL_CODES,
  type ScriptBehaviorEvent,
  type ScriptBehaviorGraph,
  type ScriptBehaviorGraphEdge,
  type ScriptBehaviorGraphNode,
  type ScriptRiskAssessment,
  type ScriptRiskFinding,
  type ScriptRiskObservation,
  type ScriptRiskReason,
  type ScriptRiskReasonCode,
} from "./types.js";

export const SCRIPT_RISK_DEFAULT_WINDOW_MS = 30_000;
export const SCRIPT_RISK_MAX_WINDOW_MS = 5 * 60_000;

const MAX_EVENTS_PER_BUCKET = 16;
const MAX_FLOW_EDGES = 256;
const MAX_REASON_OCCURRENCES = 8;
const CPU_THRESHOLD_PERCENT = 80;
const CPU_THRESHOLD_DURATION_MS = 15_000;
const WORKER_FANOUT_THRESHOLD = 4;
const WEBGPU_DISPATCH_THRESHOLD = 50;

const RUNTIME_REASON_ORDER: ScriptRiskReasonCode[] = [
  "runtime.sustained-cpu",
  "runtime.worker-fanout",
  "runtime.wasm-execution",
  "runtime.webgpu-compute",
  "runtime.websocket",
  "runtime.mining-protocol",
  "runtime.sensitive-read",
  "runtime.network-send",
  "graph.sensitive-to-network",
  "aggregate.mining-multisignal",
  "aggregate.obfuscated-loader-multisignal",
  "aggregate.sensitive-exfiltration",
];

const REASON_ORDER: ScriptRiskReasonCode[] = [
  ...STATIC_SCRIPT_SIGNAL_CODES,
  ...RUNTIME_REASON_ORDER,
];

interface IndexedEvent {
  event: ScriptBehaviorEvent;
  inputIndex: number;
}

interface FlowSource {
  nodeId: string;
  atMs: number;
}

interface FlowSink {
  nodeId: string;
  atMs: number;
}

function normalizeSite(rawSite: string): string {
  const trimmed = rawSite.trim();
  if (!trimmed) return "unknown";
  try {
    const candidate = trimmed.includes("://") ? trimmed : `https://${trimmed}`;
    return new URL(candidate).hostname.toLowerCase() || "unknown";
  } catch {
    return "unknown";
  }
}

function controlsActive(controls: ScriptRiskObservation["controls"]): boolean {
  return (
    controls?.masterEnabled !== false &&
    controls?.featureEnabled !== false &&
    controls?.preferenceEnabled !== false &&
    controls?.sitePaused !== true
  );
}

function emptyAssessment(
  site: string,
  status: ScriptRiskAssessment["status"],
): ScriptRiskAssessment {
  return {
    schemaVersion: 1,
    mode: "observe-only",
    status,
    site,
    decision: "observed",
    wouldBlock: false,
    riskScore: 0,
    reasons: [],
    findings: [],
    graph: { nodes: [], edges: [] },
  };
}

function boundedWindowMs(requested: number | undefined): number {
  if (!Number.isFinite(requested)) return SCRIPT_RISK_DEFAULT_WINDOW_MS;
  return Math.max(
    1,
    Math.min(SCRIPT_RISK_MAX_WINDOW_MS, Math.trunc(requested ?? 0)),
  );
}

function recentEvents(
  events: readonly ScriptBehaviorEvent[],
  nowMs: number,
  windowMs: number,
): IndexedEvent[] {
  const earliest = nowMs - windowMs;
  const buckets = new Map<string, IndexedEvent[]>();
  events.forEach((event, inputIndex) => {
    if (
      !Number.isFinite(event.atMs) ||
      event.atMs < earliest ||
      event.atMs > nowMs
    ) {
      return;
    }
    const bucket = eventBucket(event);
    const retained = buckets.get(bucket) ?? [];
    if (retained.length >= MAX_EVENTS_PER_BUCKET) retained.shift();
    retained.push({ event, inputIndex });
    buckets.set(bucket, retained);
  });
  return [...buckets.values()]
    .flat()
    .sort(
      (left, right) =>
        left.event.atMs - right.event.atMs ||
        left.event.type.localeCompare(right.event.type) ||
        left.inputIndex - right.inputIndex,
    );
}

function eventBucket(event: ScriptBehaviorEvent): string {
  if (event.type === "cpu-sample") {
    const isSignal =
      Number.isFinite(event.utilizationPercent) &&
      Number.isFinite(event.durationMs) &&
      event.utilizationPercent >= CPU_THRESHOLD_PERCENT &&
      event.durationMs >= CPU_THRESHOLD_DURATION_MS;
    return isSignal ? "cpu:signal" : "cpu:other";
  }
  if (event.type === "worker-count") {
    const isSignal =
      Number.isFinite(event.activeWorkers) &&
      event.activeWorkers >= WORKER_FANOUT_THRESHOLD;
    return isSignal ? "worker:signal" : "worker:other";
  }
  if (event.type === "wasm-execution") {
    const isSignal = Number.isFinite(event.durationMs) && event.durationMs > 0;
    return isSignal ? "wasm:signal" : "wasm:other";
  }
  if (event.type === "webgpu-compute") {
    const isSignal =
      Number.isFinite(event.dispatchCount) &&
      event.dispatchCount >= WEBGPU_DISPATCH_THRESHOLD;
    return isSignal ? "webgpu:signal" : "webgpu:other";
  }
  if (event.type === "network-connect") {
    return event.transport === "websocket"
      ? "network:websocket"
      : "network:other";
  }
  if (event.type === "sensitive-read") {
    return `sensitive:${event.dataKind}`;
  }
  return event.type;
}

function normalizedFlowId(flowId: string | undefined): string | null {
  if (!flowId) return null;
  const normalized = flowId.trim();
  if (!normalized || normalized.length > 128) return null;
  return normalized;
}

function addReason(
  counts: Map<ScriptRiskReasonCode, number>,
  code: ScriptRiskReasonCode,
  occurrences = 1,
): void {
  const increment = Number.isFinite(occurrences)
    ? Math.max(1, Math.trunc(occurrences))
    : 1;
  counts.set(
    code,
    Math.min(
      MAX_REASON_OCCURRENCES,
      (counts.get(code) ?? 0) + increment,
    ),
  );
}

function addEventNode(
  graph: ScriptBehaviorGraph,
  eventIndex: number,
  kind: ScriptBehaviorGraphNode["kind"],
  label: string,
  relation: ScriptBehaviorGraphEdge["relation"],
): string {
  const id = `event:${eventIndex}`;
  graph.nodes.push({ id, kind, label });
  graph.edges.push({ from: "script:0", to: id, relation });
  return id;
}

function reasonCodes(
  counts: Map<ScriptRiskReasonCode, number>,
  codes: readonly ScriptRiskReasonCode[],
): ScriptRiskReasonCode[] {
  return codes.filter((code) => counts.has(code));
}

function buildMiningFinding(
  counts: Map<ScriptRiskReasonCode, number>,
): ScriptRiskFinding | null {
  const computeCodes: ScriptRiskReasonCode[] = [
    "ast.wasm-use",
    "ast.webgpu-compute",
    "ast.hash-loop",
    "runtime.sustained-cpu",
    "runtime.wasm-execution",
    "runtime.webgpu-compute",
  ];
  const transportCodes: ScriptRiskReasonCode[] = [
    "ast.websocket",
    "runtime.websocket",
  ];
  const protocolCodes: ScriptRiskReasonCode[] = [
    "ast.mining-protocol",
    "runtime.mining-protocol",
  ];
  const coordinationCodes: ScriptRiskReasonCode[] = [
    "ast.worker-construction",
    "ast.shared-memory",
    "runtime.worker-fanout",
  ];

  const evidence = [
    ...reasonCodes(counts, computeCodes),
    ...reasonCodes(counts, transportCodes),
    ...reasonCodes(counts, protocolCodes),
    ...reasonCodes(counts, coordinationCodes),
  ];
  if (
    !computeCodes.some((code) => counts.has(code)) ||
    !transportCodes.some((code) => counts.has(code)) ||
    !protocolCodes.some((code) => counts.has(code))
  ) {
    return null;
  }

  addReason(counts, "aggregate.mining-multisignal");
  const fullyObservedAtRuntime =
    [
      "runtime.sustained-cpu",
      "runtime.wasm-execution",
      "runtime.webgpu-compute",
    ].some((code) => counts.has(code as ScriptRiskReasonCode)) &&
    counts.has("runtime.websocket") &&
    counts.has("runtime.mining-protocol");
  return {
    kind: "suspected-mining",
    confidence: fullyObservedAtRuntime ? "high" : "medium",
    score: fullyObservedAtRuntime ? 90 : 70,
    reasonCodes: [...evidence, "aggregate.mining-multisignal"],
  };
}

function buildObfuscatedLoaderFinding(
  counts: Map<ScriptRiskReasonCode, number>,
): ScriptRiskFinding | null {
  const evidence: ScriptRiskReasonCode[] = [
    "ast.dynamic-code",
    "ast.encoded-payload",
    "ast.remote-load",
  ];
  if (!evidence.every((code) => counts.has(code))) return null;
  addReason(counts, "aggregate.obfuscated-loader-multisignal");
  return {
    kind: "obfuscated-remote-loader",
    confidence: "medium",
    score: 65,
    reasonCodes: [
      ...evidence,
      "aggregate.obfuscated-loader-multisignal",
    ],
  };
}

function buildExfiltrationFinding(
  counts: Map<ScriptRiskReasonCode, number>,
  correlatedFlows: number,
): ScriptRiskFinding | null {
  if (correlatedFlows === 0) return null;
  addReason(counts, "aggregate.sensitive-exfiltration");
  return {
    kind: "sensitive-data-exfiltration",
    confidence: "high",
    score: 92,
    reasonCodes: [
      "runtime.sensitive-read",
      "runtime.network-send",
      "graph.sensitive-to-network",
      "aggregate.sensitive-exfiltration",
    ],
  };
}

/**
 * Aggregate source-free AST signals and bounded behavior observations. This is
 * a pure, observe-only function: it cannot pause workers, close sockets, or
 * block execution, and `wouldBlock` is always false.
 */
export function assessObservedScriptRisk(
  observation: ScriptRiskObservation,
): ScriptRiskAssessment {
  if (!Number.isFinite(observation.nowMs)) {
    throw new TypeError("nowMs must be finite");
  }

  const site = normalizeSite(observation.site);
  if (!controlsActive(observation.controls)) {
    return emptyAssessment(site, "disabled");
  }

  const reasonCounts = new Map<ScriptRiskReasonCode, number>();
  const staticSignals =
    observation.staticAnalysis?.parseStatus === "complete"
      ? observation.staticAnalysis.signals
      : [];
  for (const signal of staticSignals) {
    if ((STATIC_SCRIPT_SIGNAL_CODES as readonly string[]).includes(signal.code)) {
      addReason(reasonCounts, signal.code, signal.occurrences);
    }
  }

  const graph: ScriptBehaviorGraph = {
    nodes: [{ id: "script:0", kind: "script", label: "observed-script" }],
    edges: [],
  };
  const sensitiveByFlow = new Map<string, FlowSource[]>();
  const networkByFlow = new Map<string, FlowSink[]>();
  const events = recentEvents(
    observation.events ?? [],
    observation.nowMs,
    boundedWindowMs(observation.windowMs),
  );

  events.forEach(({ event }, eventIndex) => {
    if (event.type === "cpu-sample") {
      addEventNode(graph, eventIndex, "capability", "cpu", "uses");
      if (
        Number.isFinite(event.utilizationPercent) &&
        Number.isFinite(event.durationMs) &&
        event.utilizationPercent >= CPU_THRESHOLD_PERCENT &&
        event.durationMs >= CPU_THRESHOLD_DURATION_MS
      ) {
        addReason(reasonCounts, "runtime.sustained-cpu");
      }
      return;
    }
    if (event.type === "worker-count") {
      addEventNode(graph, eventIndex, "capability", "worker", "uses");
      if (
        Number.isFinite(event.activeWorkers) &&
        event.activeWorkers >= WORKER_FANOUT_THRESHOLD
      ) {
        addReason(reasonCounts, "runtime.worker-fanout");
      }
      return;
    }
    if (event.type === "wasm-execution") {
      addEventNode(graph, eventIndex, "capability", "wasm", "uses");
      if (Number.isFinite(event.durationMs) && event.durationMs > 0) {
        addReason(reasonCounts, "runtime.wasm-execution");
      }
      return;
    }
    if (event.type === "webgpu-compute") {
      addEventNode(graph, eventIndex, "capability", "webgpu", "uses");
      if (
        Number.isFinite(event.dispatchCount) &&
        event.dispatchCount >= WEBGPU_DISPATCH_THRESHOLD
      ) {
        addReason(reasonCounts, "runtime.webgpu-compute");
      }
      return;
    }
    if (event.type === "network-connect") {
      addEventNode(graph, eventIndex, "network", event.transport, "connects");
      if (event.transport === "websocket") {
        addReason(reasonCounts, "runtime.websocket");
      }
      return;
    }
    if (event.type === "mining-protocol") {
      addEventNode(graph, eventIndex, "network", event.protocol, "uses");
      addReason(reasonCounts, "runtime.mining-protocol");
      return;
    }
    if (event.type === "sensitive-read") {
      const nodeId = addEventNode(
        graph,
        eventIndex,
        "sensitive-data",
        event.dataKind,
        "reads",
      );
      addReason(reasonCounts, "runtime.sensitive-read");
      const flowId = normalizedFlowId(event.flowId);
      if (flowId) {
        const sources = sensitiveByFlow.get(flowId) ?? [];
        sources.push({ nodeId, atMs: event.atMs });
        sensitiveByFlow.set(flowId, sources);
      }
      return;
    }

    const nodeId = addEventNode(
      graph,
      eventIndex,
      "network",
      "outbound",
      "sends",
    );
    addReason(reasonCounts, "runtime.network-send");
    const flowIds = new Set(
      (event.flowIds ?? [])
        .map((flowId) => normalizedFlowId(flowId))
        .filter((flowId): flowId is string => Boolean(flowId)),
    );
    for (const flowId of flowIds) {
      const sinks = networkByFlow.get(flowId) ?? [];
      sinks.push({ nodeId, atMs: event.atMs });
      networkByFlow.set(flowId, sinks);
    }
  });

  let correlatedFlows = 0;
  const flowEdges = new Set<string>();
  for (const [flowId, sources] of sensitiveByFlow) {
    const sinks = networkByFlow.get(flowId) ?? [];
    for (const source of sources) {
      for (const sink of sinks) {
        if (correlatedFlows >= MAX_FLOW_EDGES) break;
        if (sink.atMs < source.atMs) continue;
        const key = `${source.nodeId}\0${sink.nodeId}`;
        if (flowEdges.has(key)) continue;
        flowEdges.add(key);
        graph.edges.push({
          from: source.nodeId,
          to: sink.nodeId,
          relation: "flows-to",
        });
        correlatedFlows += 1;
      }
      if (correlatedFlows >= MAX_FLOW_EDGES) break;
    }
    if (correlatedFlows >= MAX_FLOW_EDGES) break;
  }
  if (correlatedFlows > 0) {
    addReason(
      reasonCounts,
      "graph.sensitive-to-network",
      correlatedFlows,
    );
  }

  const findings = [
    buildMiningFinding(reasonCounts),
    buildExfiltrationFinding(reasonCounts, correlatedFlows),
    buildObfuscatedLoaderFinding(reasonCounts),
  ].filter((finding): finding is ScriptRiskFinding => Boolean(finding));

  const reasons: ScriptRiskReason[] = REASON_ORDER.flatMap((code) => {
    const occurrences = reasonCounts.get(code);
    return occurrences ? [{ code, occurrences }] : [];
  });
  const riskScore = findings.reduce(
    (highest, finding) => Math.max(highest, finding.score),
    0,
  );
  const decision = findings.some((finding) => finding.confidence === "high")
    ? "high-confidence"
    : findings.length > 0
      ? "suspicious"
      : "observed";

  return {
    schemaVersion: 1,
    mode: "observe-only",
    status: "active",
    site,
    decision,
    wouldBlock: false,
    riskScore,
    reasons,
    findings,
    graph,
  };
}
