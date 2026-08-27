export const PROVENANCE_LIMITS = {
  maxInspectedEvents: 4_096,
  maxEventsPerBucket: 16,
  maxScriptNodes: 32,
  maxFunctionNodes: 128,
  maxGraphNodes: 512,
  maxGraphEdges: 1_024,
  maxFlowIds: 128,
  maxFlowIdsPerEvent: 8,
  maxSourcesPerFlow: 4,
  maxWindowMs: 5 * 60_000,
} as const;

const DEFAULT_WINDOW_MS = 30_000;
const MAX_OPAQUE_ID_CHARS = 128;

const CAPABILITY_OPERATIONS = {
  dom: ["read", "write", "mutate"],
  storage: ["read", "write"],
  network: ["connect", "receive", "send"],
  worker: ["create", "receive", "post-message"],
  wasm: ["compile", "instantiate", "execute"],
} as const;

export type ProvenanceCapability = keyof typeof CAPABILITY_OPERATIONS;
export type ProvenanceFlowRole = "source" | "sink";

type ProvenanceOperationMap = {
  [Capability in ProvenanceCapability]:
    (typeof CAPABILITY_OPERATIONS)[Capability][number];
};

interface ProvenanceEventBase {
  /** 只用于输入过滤；document id 不进入输出。 */
  documentId: string;
  atMs: number;
  /** 仅作为本次计算内的关联键，不进入输出。 */
  scriptId: string;
  /** 仅作为本次计算内的关联键，不进入输出。 */
  functionId?: string;
  /** flow id 仅在内存中做等值关联，最多读取固定数量。 */
  flowIds?: readonly string[];
  flowRole?: ProvenanceFlowRole;
}

export type ProvenanceEvent = {
  [Capability in ProvenanceCapability]: ProvenanceEventBase & {
    capability: Capability;
    operation: ProvenanceOperationMap[Capability];
  };
}[ProvenanceCapability];

export interface ProvenanceObservation {
  documentId: string;
  nowMs: number;
  windowMs?: number;
  events: readonly ProvenanceEvent[];
}

export interface ProvenanceGraphNode {
  id: string;
  kind: "script" | "function" | "capability";
  /** 只允许固定类别标签，不允许 URL、源码或调用者标识符。 */
  label: string;
}

export interface ProvenanceGraphEdge {
  from: string;
  to: string;
  relation:
    | "contains"
    | "reads"
    | "writes"
    | "connects"
    | "receives"
    | "sends"
    | "creates"
    | "executes"
    | "flows-to";
}

export interface ProvenanceAssessment {
  schemaVersion: 1;
  mode: "observe-only";
  wouldBlock: false;
  scope: "document";
  classification: "observed" | "correlated-flow";
  correlatedFlows: number;
  graph: {
    nodes: ProvenanceGraphNode[];
    edges: ProvenanceGraphEdge[];
  };
  budget: {
    retainedEvents: number;
    representedEvents: number;
    droppedEvents: number;
    inspectedEvents: number;
    inputEventLimitDrops: number;
    documentMismatches: number;
    outsideWindow: number;
    invalidEvents: number;
    eventBucketOverflow: number;
    actorBudgetDrops: number;
    nodeBudgetDrops: number;
    flowBudgetDrops: number;
    edgeBudgetDrops: number;
    truncated: boolean;
  };
}

interface RetainedEvent {
  atMs: number;
  inputIndex: number;
  scriptId: string;
  functionId: string | null;
  capability: ProvenanceCapability;
  operation: ProvenanceOperationMap[ProvenanceCapability];
  flowRole: ProvenanceFlowRole | null;
  flowIds: string[];
}

interface FlowSource {
  nodeId: string;
  atMs: number;
  inputIndex: number;
}

interface MutableBudget {
  retainedEvents: number;
  representedEvents: number;
  droppedEvents: number;
  inspectedEvents: number;
  inputEventLimitDrops: number;
  documentMismatches: number;
  outsideWindow: number;
  invalidEvents: number;
  eventBucketOverflow: number;
  actorBudgetDrops: number;
  nodeBudgetDrops: number;
  flowBudgetDrops: number;
  edgeBudgetDrops: number;
}

function normalizedOpaqueId(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const normalized = value.trim();
  if (!normalized || normalized.length > MAX_OPAQUE_ID_CHARS) return null;
  return normalized;
}

function boundedWindowMs(requested: number | undefined): number {
  if (!Number.isFinite(requested)) return DEFAULT_WINDOW_MS;
  return Math.max(
    1,
    Math.min(PROVENANCE_LIMITS.maxWindowMs, Math.trunc(requested ?? 0)),
  );
}

function isCapability(value: unknown): value is ProvenanceCapability {
  return (
    typeof value === "string" &&
    Object.prototype.hasOwnProperty.call(CAPABILITY_OPERATIONS, value)
  );
}

function isOperation(
  capability: ProvenanceCapability,
  value: unknown,
): value is ProvenanceOperationMap[ProvenanceCapability] {
  return (CAPABILITY_OPERATIONS[capability] as readonly unknown[]).includes(value);
}

function normalizedFlowIds(value: unknown, budget: MutableBudget): string[] {
  if (!Array.isArray(value)) return [];
  const normalized = new Set<string>();
  const limit = Math.min(value.length, PROVENANCE_LIMITS.maxFlowIdsPerEvent);
  budget.flowBudgetDrops += Math.max(0, value.length - limit);
  for (let index = 0; index < limit; index += 1) {
    const flowId = normalizedOpaqueId(value[index]);
    if (flowId) {
      normalized.add(flowId);
    } else {
      budget.flowBudgetDrops += 1;
    }
  }
  return [...normalized];
}

function eventRelation(
  capability: ProvenanceCapability,
  operation: ProvenanceOperationMap[ProvenanceCapability],
): ProvenanceGraphEdge["relation"] {
  if (operation === "read") return "reads";
  if (operation === "write" || operation === "mutate") return "writes";
  if (operation === "connect") return "connects";
  if (operation === "receive") return "receives";
  if (operation === "send" || operation === "post-message") return "sends";
  if (operation === "create") return "creates";
  if (
    capability === "wasm" &&
    (operation === "compile" ||
      operation === "instantiate" ||
      operation === "execute")
  ) {
    return "executes";
  }
  return "executes";
}

function retentionBucket(event: RetainedEvent): string {
  return `${event.capability}:${event.flowRole ?? "use"}`;
}

function compareEvents(left: RetainedEvent, right: RetainedEvent): number {
  return left.atMs - right.atMs || left.inputIndex - right.inputIndex;
}

function retainNewest(
  bucket: RetainedEvent[],
  event: RetainedEvent,
): boolean {
  if (bucket.length < PROVENANCE_LIMITS.maxEventsPerBucket) {
    bucket.push(event);
    return true;
  }
  let oldestIndex = 0;
  for (let index = 1; index < bucket.length; index += 1) {
    const current = bucket[index];
    const oldest = bucket[oldestIndex];
    if (current && oldest && compareEvents(current, oldest) < 0) {
      oldestIndex = index;
    }
  }
  const oldest = bucket[oldestIndex];
  if (!oldest || compareEvents(event, oldest) <= 0) return false;
  bucket[oldestIndex] = event;
  return true;
}

function collectBoundedEvents(
  observation: ProvenanceObservation,
  documentId: string,
  budget: MutableBudget,
): RetainedEvent[] {
  const earliest = observation.nowMs - boundedWindowMs(observation.windowMs);
  const buckets = new Map<string, RetainedEvent[]>();

  const inspectedEvents = Math.min(
    observation.events.length,
    PROVENANCE_LIMITS.maxInspectedEvents,
  );
  budget.inspectedEvents = inspectedEvents;
  budget.inputEventLimitDrops = Math.max(
    0,
    observation.events.length - inspectedEvents,
  );
  budget.droppedEvents += budget.inputEventLimitDrops;

  for (let inputIndex = 0; inputIndex < inspectedEvents; inputIndex += 1) {
    const rawEvent = observation.events[inputIndex];
    if (!rawEvent) {
      budget.droppedEvents += 1;
      budget.invalidEvents += 1;
      continue;
    }
    const event = rawEvent as Partial<ProvenanceEvent>;
    const eventDocumentId = normalizedOpaqueId(event.documentId);
    if (eventDocumentId !== documentId) {
      budget.droppedEvents += 1;
      budget.documentMismatches += 1;
      continue;
    }
    if (
      !Number.isFinite(event.atMs) ||
      (event.atMs ?? 0) < earliest ||
      (event.atMs ?? 0) > observation.nowMs
    ) {
      budget.droppedEvents += 1;
      budget.outsideWindow += 1;
      continue;
    }
    const scriptId = normalizedOpaqueId(event.scriptId);
    const functionId =
      event.functionId === undefined
        ? null
        : normalizedOpaqueId(event.functionId);
    if (
      !scriptId ||
      (event.functionId !== undefined && !functionId) ||
      !isCapability(event.capability) ||
      !isOperation(event.capability, event.operation) ||
      (event.flowRole !== undefined &&
        event.flowRole !== "source" &&
        event.flowRole !== "sink")
    ) {
      budget.droppedEvents += 1;
      budget.invalidEvents += 1;
      continue;
    }

    const retained: RetainedEvent = {
      atMs: event.atMs as number,
      inputIndex,
      scriptId,
      functionId,
      capability: event.capability,
      operation: event.operation,
      flowRole: event.flowRole ?? null,
      flowIds: normalizedFlowIds(event.flowIds, budget),
    };
    const bucketName = retentionBucket(retained);
    const bucket = buckets.get(bucketName) ?? [];
    const wasFull = bucket.length >= PROVENANCE_LIMITS.maxEventsPerBucket;
    if (!retainNewest(bucket, retained)) {
      budget.droppedEvents += 1;
      budget.eventBucketOverflow += 1;
      continue;
    }
    if (wasFull) {
      // 固定桶已满；保留较新的事件意味着逐出一个旧事件。
      budget.droppedEvents += 1;
      budget.eventBucketOverflow += 1;
    }
    buckets.set(bucketName, bucket);
  }

  const events = [...buckets.values()].flat().sort(compareEvents);
  budget.retainedEvents = events.length;
  return events;
}

/**
 * 在单一 document scope 内构建固定预算的信息流图。所有调用者标识符和
 * flow id 只在本次调用内关联，输出仅含顺序编号与固定类别标签。
 */
export function assessDocumentProvenance(
  observation: ProvenanceObservation,
): ProvenanceAssessment {
  const documentId = normalizedOpaqueId(observation.documentId);
  if (!documentId) throw new TypeError("documentId must be a bounded opaque id");
  if (!Number.isFinite(observation.nowMs)) {
    throw new TypeError("nowMs must be finite");
  }

  const budget: MutableBudget = {
    retainedEvents: 0,
    representedEvents: 0,
    droppedEvents: 0,
    inspectedEvents: 0,
    inputEventLimitDrops: 0,
    documentMismatches: 0,
    outsideWindow: 0,
    invalidEvents: 0,
    eventBucketOverflow: 0,
    actorBudgetDrops: 0,
    nodeBudgetDrops: 0,
    flowBudgetDrops: 0,
    edgeBudgetDrops: 0,
  };
  const events = collectBoundedEvents(observation, documentId, budget);
  const nodes: ProvenanceGraphNode[] = [];
  const edges: ProvenanceGraphEdge[] = [];
  const edgeKeys = new Set<string>();
  const scripts = new Map<string, string>();
  const functions = new Map<string, string>();
  const sourcesByFlow = new Map<string, FlowSource[]>();
  const correlatedFlowIds = new Set<string>();

  const addNode = (
    kind: ProvenanceGraphNode["kind"],
    label: string,
  ): string | null => {
    if (nodes.length >= PROVENANCE_LIMITS.maxGraphNodes) {
      budget.nodeBudgetDrops += 1;
      return null;
    }
    const id = `${kind}:${nodes.length}`;
    nodes.push({ id, kind, label });
    return id;
  };

  const addEdge = (
    from: string,
    to: string,
    relation: ProvenanceGraphEdge["relation"],
  ): boolean => {
    const key = `${from}\0${to}\0${relation}`;
    if (edgeKeys.has(key)) return true;
    if (edges.length >= PROVENANCE_LIMITS.maxGraphEdges) {
      budget.edgeBudgetDrops += 1;
      return false;
    }
    edgeKeys.add(key);
    edges.push({ from, to, relation });
    return true;
  };

  const scriptNode = (scriptId: string): string | null => {
    const existing = scripts.get(scriptId);
    if (existing) return existing;
    if (scripts.size >= PROVENANCE_LIMITS.maxScriptNodes) {
      budget.actorBudgetDrops += 1;
      return null;
    }
    const nodeId = addNode("script", "script");
    if (nodeId) scripts.set(scriptId, nodeId);
    return nodeId;
  };

  const actorNode = (event: RetainedEvent): string | null => {
    const script = scriptNode(event.scriptId);
    if (!script || !event.functionId) return script;
    const key = `${event.scriptId}\0${event.functionId}`;
    const existing = functions.get(key);
    if (existing) return existing;
    if (functions.size >= PROVENANCE_LIMITS.maxFunctionNodes) {
      budget.actorBudgetDrops += 1;
      return script;
    }
    const functionNode = addNode("function", "function");
    if (!functionNode) return script;
    functions.set(key, functionNode);
    addEdge(script, functionNode, "contains");
    return functionNode;
  };

  for (const event of events) {
    const actor = actorNode(event);
    if (!actor) {
      budget.droppedEvents += 1;
      continue;
    }
    const capabilityNode = addNode(
      "capability",
      `${event.capability}.${event.operation}`,
    );
    if (!capabilityNode) {
      budget.droppedEvents += 1;
      continue;
    }
    budget.representedEvents += 1;
    addEdge(
      actor,
      capabilityNode,
      eventRelation(event.capability, event.operation),
    );

    if (!event.flowRole || event.flowIds.length === 0) continue;
    if (event.flowRole === "source") {
      for (const flowId of event.flowIds) {
        let sources = sourcesByFlow.get(flowId);
        if (!sources) {
          if (sourcesByFlow.size >= PROVENANCE_LIMITS.maxFlowIds) {
            budget.flowBudgetDrops += 1;
            continue;
          }
          sources = [];
          sourcesByFlow.set(flowId, sources);
        }
        if (sources.length >= PROVENANCE_LIMITS.maxSourcesPerFlow) {
          budget.flowBudgetDrops += 1;
          continue;
        }
        sources.push({
          nodeId: capabilityNode,
          atMs: event.atMs,
          inputIndex: event.inputIndex,
        });
      }
      continue;
    }

    for (const flowId of event.flowIds) {
      const sources = sourcesByFlow.get(flowId) ?? [];
      for (const source of sources) {
        if (
          source.atMs > event.atMs ||
          (source.atMs === event.atMs && source.inputIndex > event.inputIndex)
        ) {
          continue;
        }
        if (addEdge(source.nodeId, capabilityNode, "flows-to")) {
          correlatedFlowIds.add(flowId);
        }
      }
    }
  }

  return {
    schemaVersion: 1,
    mode: "observe-only",
    wouldBlock: false,
    scope: "document",
    classification:
      correlatedFlowIds.size > 0 ? "correlated-flow" : "observed",
    correlatedFlows: correlatedFlowIds.size,
    graph: { nodes, edges },
    budget: {
      ...budget,
      truncated:
        budget.droppedEvents > 0 ||
        budget.actorBudgetDrops > 0 ||
        budget.nodeBudgetDrops > 0 ||
        budget.flowBudgetDrops > 0 ||
        budget.edgeBudgetDrops > 0,
    },
  };
}
