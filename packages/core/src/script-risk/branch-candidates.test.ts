import {describe, expect, it} from "vitest";
import {planStructureBranchCandidates, type StructureBranchLabel} from "./branch-candidates.js";
import {createScriptStructureSignature} from "./structure-signature.js";

function firstBranch(source: string) {
  const signature = createScriptStructureSignature(source);
  const branch = signature.branches[0];
  if (!branch) throw new Error("fixture did not produce a branch");
  return {signature, branch};
}

function label(
  hash: string,
  kind: StructureBranchLabel["branchKind"],
  patch: Partial<StructureBranchLabel> = {},
): StructureBranchLabel {
  return {
    structuralHash: hash,
    branchKind: kind,
    label: "tracking",
    evidence: "independent-review",
    siteGroup: "site-a",
    ...patch,
  };
}

describe("structure branch candidate planning", () => {
  it("matches normalized branch shapes but never slices code", () => {
    const left = firstBranch("if (alpha > 7) { send('one'); }");
    const right = firstBranch("if (renamed > 99) { transmit('other'); }");
    expect(left.branch.structuralHash).toBe(right.branch.structuralHash);
    const labels = [
      label(left.branch.structuralHash, left.branch.kind),
      label(left.branch.structuralHash, left.branch.kind, {siteGroup: "site-b"}),
    ];
    const plan = planStructureBranchCandidates(right.signature, labels);
    expect(plan).toMatchObject({
      status: "complete",
      mode: "observe-only",
      wouldSlice: false,
    });
    expect(plan.candidates).toHaveLength(1);
    expect(plan.candidates[0]?.wouldSlice).toBe(false);
  });

  it("rejects synthetic-only and single-site propagation", () => {
    const {signature, branch} = firstBranch("if (x) collect();");
    const synthetic = planStructureBranchCandidates(signature, [
      label(branch.structuralHash, branch.kind, {evidence: "synthetic"}),
    ]);
    expect(synthetic.candidates).toHaveLength(0);
    expect(synthetic.rejected.syntheticOnly).toBe(1);

    const oneSite = planStructureBranchCandidates(signature, [
      label(branch.structuralHash, branch.kind),
    ]);
    expect(oneSite.candidates).toHaveLength(0);
    expect(oneSite.rejected.insufficientIndependentSites).toBe(1);
  });

  it("does not count whitespace aliases or a lowered option as independent sites", () => {
    const {signature, branch} = firstBranch("if (x) collect();");
    const aliases = [
      label(branch.structuralHash, branch.kind, {siteGroup: "site-a"}),
      label(branch.structuralHash, branch.kind, {siteGroup: " site-a "}),
    ];
    const plan = planStructureBranchCandidates(signature, aliases, {
      minimumIndependentSites: 1,
    });

    expect(plan.budgets.minimumIndependentSites).toBe(2);
    expect(plan.candidates).toHaveLength(0);
    expect(plan.rejected.insufficientIndependentSites).toBe(1);
  });

  it("abstains when benign and positive labels conflict", () => {
    const {signature, branch} = firstBranch("if (x) render();");
    const labels = [
      label(branch.structuralHash, branch.kind),
      label(branch.structuralHash, branch.kind, {siteGroup: "site-b"}),
      label(branch.structuralHash, branch.kind, {
        label: "benign",
        siteGroup: "site-c",
      }),
    ];
    const plan = planStructureBranchCandidates(signature, labels);
    expect(plan.candidates).toHaveLength(0);
    expect(plan.rejected.conflictingLabels).toBe(1);
  });

  it("fails closed to observe-only when parser or label budget fails", () => {
    const failed = createScriptStructureSignature("x".repeat(20), {maxNodes: 1});
    expect(planStructureBranchCandidates(failed, [])).toMatchObject({
      status: "source-analysis-failed",
      candidates: [],
      wouldSlice: false,
    });

    const {signature, branch} = firstBranch("if (x) run();");
    const labels = [
      label(branch.structuralHash, branch.kind),
      label(branch.structuralHash, branch.kind, {siteGroup: "site-b"}),
    ];
    expect(planStructureBranchCandidates(signature, labels, {maxLabels: 1})).toMatchObject({
      status: "label-budget-exceeded",
      candidates: [],
    });
  });
});
