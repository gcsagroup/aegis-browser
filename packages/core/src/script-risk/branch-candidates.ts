import type {
  ScriptStructureSignature,
  StructureBranchKind,
  StructureSourceRange,
} from "./structure-signature.js";

const HARD_MAX_LABELS = 50_000;
const DEFAULT_MINIMUM_INDEPENDENT_SITES = 2;

export type StructureLabelClass = "benign" | "tracking" | "malicious";

export interface StructureBranchLabel {
  structuralHash: string;
  branchKind: StructureBranchKind;
  label: StructureLabelClass;
  evidence: "synthetic" | "independent-review";
  /** 只用于计算独立站点数，不进入输出。 */
  siteGroup: string;
}

export interface StructureBranchCandidateOptions {
  minimumIndependentSites?: number;
  maxLabels?: number;
}

export interface StructureBranchCandidate {
  branchId: string;
  kind: StructureBranchKind;
  range: StructureSourceRange;
  classification: "tracking" | "malicious";
  independentSiteCount: number;
  matchingLabelCount: number;
  confidence: "candidate";
  wouldSlice: false;
}

export interface StructureBranchCandidatePlan {
  schemaVersion: 1;
  mode: "observe-only";
  status: "complete" | "source-analysis-failed" | "label-budget-exceeded";
  wouldSlice: false;
  candidates: StructureBranchCandidate[];
  rejected: {
    syntheticOnly: number;
    conflictingLabels: number;
    insufficientIndependentSites: number;
  };
  budgets: {
    labelsInspected: number;
    maxLabels: number;
    minimumIndependentSites: number;
  };
}

interface LabelSummary {
  benign: number;
  tracking: number;
  malicious: number;
  independentSites: Set<string>;
  independentPositiveLabels: number;
  syntheticPositiveLabels: number;
}

function boundedInteger(
  value: number | undefined,
  fallback: number,
  minimum: number,
  maximum: number,
): number {
  if (!Number.isFinite(value)) return fallback;
  return Math.max(minimum, Math.min(maximum, Math.trunc(value ?? fallback)));
}

function validHash(value: string): boolean {
  return /^[0-9a-f]{64}$/u.test(value);
}

function labelKey(hash: string, kind: StructureBranchKind): string {
  return `${kind}:${hash}`;
}

/**
 * ASTrack 风格的离线结构候选计划。这里只传播经独立复核的精确 AST 形状标签；
 * 不读取源码、不执行脚本，也不改写或删除任何分支。
 */
export function planStructureBranchCandidates(
  signature: ScriptStructureSignature,
  labels: readonly StructureBranchLabel[],
  options: StructureBranchCandidateOptions = {},
): StructureBranchCandidatePlan {
  const maxLabels = boundedInteger(
    options.maxLabels,
    HARD_MAX_LABELS,
    1,
    HARD_MAX_LABELS,
  );
  const minimumIndependentSites = boundedInteger(
    options.minimumIndependentSites,
    DEFAULT_MINIMUM_INDEPENDENT_SITES,
    DEFAULT_MINIMUM_INDEPENDENT_SITES,
    32,
  );
  const base: Omit<StructureBranchCandidatePlan, "status" | "candidates"> = {
    schemaVersion: 1,
    mode: "observe-only",
    wouldSlice: false,
    rejected: {
      syntheticOnly: 0,
      conflictingLabels: 0,
      insufficientIndependentSites: 0,
    },
    budgets: {
      labelsInspected: Math.min(labels.length, maxLabels),
      maxLabels,
      minimumIndependentSites,
    },
  };

  if (signature.parseStatus !== "complete") {
    return {...base, status: "source-analysis-failed", candidates: []};
  }
  if (labels.length > maxLabels) {
    return {...base, status: "label-budget-exceeded", candidates: []};
  }

  const index = new Map<string, LabelSummary>();
  for (const label of labels) {
    const siteGroup = label.siteGroup.trim();
    if (!validHash(label.structuralHash) || !siteGroup) continue;
    const key = labelKey(label.structuralHash, label.branchKind);
    const summary = index.get(key) ?? {
      benign: 0,
      tracking: 0,
      malicious: 0,
      independentSites: new Set<string>(),
      independentPositiveLabels: 0,
      syntheticPositiveLabels: 0,
    };
    summary[label.label] += 1;
    if (label.label !== "benign") {
      if (label.evidence === "independent-review") {
        summary.independentSites.add(siteGroup);
        summary.independentPositiveLabels += 1;
      } else {
        summary.syntheticPositiveLabels += 1;
      }
    }
    index.set(key, summary);
  }

  const candidates: StructureBranchCandidate[] = [];
  for (const branch of signature.branches) {
    const summary = index.get(labelKey(branch.structuralHash, branch.kind));
    if (!summary || summary.tracking + summary.malicious === 0) continue;
    if (summary.independentPositiveLabels === 0) {
      base.rejected.syntheticOnly += 1;
      continue;
    }
    if (summary.benign > 0 || (summary.tracking > 0 && summary.malicious > 0)) {
      base.rejected.conflictingLabels += 1;
      continue;
    }
    if (summary.independentSites.size < minimumIndependentSites) {
      base.rejected.insufficientIndependentSites += 1;
      continue;
    }
    candidates.push({
      branchId: branch.id,
      kind: branch.kind,
      range: branch.range,
      classification: summary.malicious > 0 ? "malicious" : "tracking",
      independentSiteCount: summary.independentSites.size,
      matchingLabelCount:
        summary.independentPositiveLabels + summary.syntheticPositiveLabels,
      confidence: "candidate",
      wouldSlice: false,
    });
  }

  return {...base, status: "complete", candidates};
}
