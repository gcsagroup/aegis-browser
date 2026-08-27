import { createHash, type Hash } from "node:crypto";
import ts from "typescript";

const DEFAULT_MAX_SOURCE_CHARS = 1_000_000;
const HARD_MAX_SOURCE_CHARS = 2_000_000;
const DEFAULT_MAX_NODES = 100_000;
const HARD_MAX_NODES = 200_000;
const DEFAULT_MAX_FUNCTIONS = 512;
const HARD_MAX_FUNCTIONS = 2_048;
const DEFAULT_MAX_BRANCHES = 2_048;
const HARD_MAX_BRANCHES = 8_192;

const LITERAL_KINDS = new Set<ts.SyntaxKind>([
  ts.SyntaxKind.StringLiteral,
  ts.SyntaxKind.NumericLiteral,
  ts.SyntaxKind.BigIntLiteral,
  ts.SyntaxKind.RegularExpressionLiteral,
  ts.SyntaxKind.NoSubstitutionTemplateLiteral,
  ts.SyntaxKind.TemplateHead,
  ts.SyntaxKind.TemplateMiddle,
  ts.SyntaxKind.TemplateTail,
  ts.SyntaxKind.TrueKeyword,
  ts.SyntaxKind.FalseKeyword,
  ts.SyntaxKind.NullKeyword,
]);

export type StructureSignatureFailureCode =
  | "parser-resource-limit"
  | "node-budget-exceeded"
  | "analysis-failed";

export type StructureFunctionKind =
  | "function-declaration"
  | "function-expression"
  | "arrow-function"
  | "method"
  | "constructor"
  | "getter"
  | "setter";

export type StructureBranchKind =
  | "if"
  | "conditional"
  | "switch"
  | "case"
  | "for"
  | "for-in"
  | "for-of"
  | "while"
  | "do"
  | "try"
  | "catch";

export interface StructureSourceRange {
  /** JavaScript UTF-16 源码偏移量；不会保留源码文本。 */
  start: number;
  end: number;
}

export interface StructureFunctionSummary {
  id: string;
  kind: StructureFunctionKind;
  range: StructureSourceRange;
  async: boolean;
  generator: boolean;
  parameterCount: number;
  nodeCount: number;
  branchCount: number;
  loopCount: number;
  callCount: number;
  structuralHash: string;
}

export interface StructureBranchSummary {
  id: string;
  kind: StructureBranchKind;
  range: StructureSourceRange;
  depth: number;
  nodeCount: number;
  structuralHash: string;
}

export interface StructureSignatureOptions {
  maxSourceChars?: number;
  maxNodes?: number;
  maxFunctions?: number;
  maxBranches?: number;
}

export interface ScriptStructureSignature {
  schemaVersion: 1;
  mode: "observe-only";
  parser: "typescript-ast";
  parserVersion: string;
  hashAlgorithm: "sha256-tree-v1";
  parseStatus: "complete" | "failed";
  failureCode?: StructureSignatureFailureCode;
  sourceLength: number;
  analyzedLength: number;
  truncated: boolean;
  nodeCount: number;
  maxDepth: number;
  structuralHash: string | null;
  functions: StructureFunctionSummary[];
  branches: StructureBranchSummary[];
  summariesTruncated: {
    functions: boolean;
    branches: boolean;
  };
  budgets: {
    maxSourceChars: number;
    maxNodes: number;
    maxFunctions: number;
    maxBranches: number;
  };
}

interface PendingFunctionSummary
  extends Omit<StructureFunctionSummary, "id"> {}

interface PendingBranchSummary extends Omit<StructureBranchSummary, "id"> {}

interface TraversalFrame {
  node: ts.Node;
  depth: number;
  children: ts.Node[];
  nextChild: number;
  hasher: ShapeHasher;
  nodeCount: number;
  branchCount: number;
  loopCount: number;
  callCount: number;
}

class NodeBudgetError extends Error {}

class ShapeHasher {
  private readonly hash: Hash = createHash("sha256");

  add(value: string): void {
    // 长度前缀避免不同片段序列产生相同拼接字节。
    this.hash.update(`${value.length}:`, "utf8");
    this.hash.update(value, "utf8");
  }

  digest(): string {
    return this.hash.digest("hex");
  }
}

function boundedInteger(
  requested: number | undefined,
  fallback: number,
  hardMaximum: number,
): number {
  if (!Number.isFinite(requested)) return fallback;
  return Math.max(1, Math.min(hardMaximum, Math.trunc(requested ?? 0)));
}

function normalizedNodeKind(node: ts.Node): string {
  if (ts.isIdentifier(node) || ts.isPrivateIdentifier(node)) {
    return "identifier";
  }
  if (LITERAL_KINDS.has(node.kind)) return "literal";
  return `kind:${node.kind}`;
}

function childrenOf(node: ts.Node): ts.Node[] {
  const children: ts.Node[] = [];
  ts.forEachChild(node, (child) => {
    children.push(child);
  });
  return children;
}

function functionKind(node: ts.Node): StructureFunctionKind | null {
  if (ts.isFunctionDeclaration(node)) return "function-declaration";
  if (ts.isFunctionExpression(node)) return "function-expression";
  if (ts.isArrowFunction(node)) return "arrow-function";
  if (ts.isMethodDeclaration(node)) return "method";
  if (ts.isConstructorDeclaration(node)) return "constructor";
  if (ts.isGetAccessorDeclaration(node)) return "getter";
  if (ts.isSetAccessorDeclaration(node)) return "setter";
  return null;
}

function branchKind(node: ts.Node): StructureBranchKind | null {
  if (ts.isIfStatement(node)) return "if";
  if (ts.isConditionalExpression(node)) return "conditional";
  if (ts.isSwitchStatement(node)) return "switch";
  if (ts.isCaseClause(node) || ts.isDefaultClause(node)) return "case";
  if (ts.isForStatement(node)) return "for";
  if (ts.isForInStatement(node)) return "for-in";
  if (ts.isForOfStatement(node)) return "for-of";
  if (ts.isWhileStatement(node)) return "while";
  if (ts.isDoStatement(node)) return "do";
  if (ts.isTryStatement(node)) return "try";
  if (ts.isCatchClause(node)) return "catch";
  return null;
}

function isLoopKind(kind: StructureBranchKind | null): boolean {
  return (
    kind === "for" ||
    kind === "for-in" ||
    kind === "for-of" ||
    kind === "while" ||
    kind === "do"
  );
}

function sourceRange(
  node: ts.Node,
  sourceFile: ts.SourceFile,
): StructureSourceRange {
  return {
    start: Math.max(0, node.getStart(sourceFile, false)),
    end: Math.max(0, node.end),
  };
}

function hasModifier(node: ts.Node, modifier: ts.SyntaxKind): boolean {
  return Boolean(
    ts.canHaveModifiers(node) &&
      ts.getModifiers(node)?.some((item) => item.kind === modifier),
  );
}

function createFrame(node: ts.Node, depth: number): TraversalFrame {
  const hasher = new ShapeHasher();
  hasher.add("node");
  hasher.add(normalizedNodeKind(node));
  return {
    node,
    depth,
    children: childrenOf(node),
    nextChild: 0,
    hasher,
    nodeCount: 1,
    branchCount: branchKind(node) ? 1 : 0,
    loopCount: isLoopKind(branchKind(node)) ? 1 : 0,
    callCount: ts.isCallExpression(node) || ts.isNewExpression(node) ? 1 : 0,
  };
}

function failedSignature(
  sourceLength: number,
  analyzedLength: number,
  budgets: ScriptStructureSignature["budgets"],
  failureCode: StructureSignatureFailureCode,
): ScriptStructureSignature {
  return {
    schemaVersion: 1,
    mode: "observe-only",
    parser: "typescript-ast",
    parserVersion: ts.version,
    hashAlgorithm: "sha256-tree-v1",
    parseStatus: "failed",
    failureCode,
    sourceLength,
    analyzedLength,
    truncated: analyzedLength !== sourceLength,
    nodeCount: 0,
    maxDepth: 0,
    structuralHash: null,
    functions: [],
    branches: [],
    summariesTruncated: { functions: false, branches: false },
    budgets,
  };
}

/**
 * 生成仅含 AST 形状、范围和计数的结构签名。标识符、字面量值、URL
 * 与源码片段不会进入返回值；本函数也不会执行或修改输入源码。
 */
export function createScriptStructureSignature(
  sourceText: string,
  options: StructureSignatureOptions = {},
): ScriptStructureSignature {
  const budgets = {
    maxSourceChars: boundedInteger(
      options.maxSourceChars,
      DEFAULT_MAX_SOURCE_CHARS,
      HARD_MAX_SOURCE_CHARS,
    ),
    maxNodes: boundedInteger(
      options.maxNodes,
      DEFAULT_MAX_NODES,
      HARD_MAX_NODES,
    ),
    maxFunctions: boundedInteger(
      options.maxFunctions,
      DEFAULT_MAX_FUNCTIONS,
      HARD_MAX_FUNCTIONS,
    ),
    maxBranches: boundedInteger(
      options.maxBranches,
      DEFAULT_MAX_BRANCHES,
      HARD_MAX_BRANCHES,
    ),
  };
  const analyzedSource = sourceText.slice(0, budgets.maxSourceChars);
  let sourceFile: ts.SourceFile;
  try {
    sourceFile = ts.createSourceFile(
      "observed-script.js",
      analyzedSource,
      ts.ScriptTarget.Latest,
      true,
      ts.ScriptKind.JS,
    );
  } catch {
    return failedSignature(
      sourceText.length,
      analyzedSource.length,
      budgets,
      "parser-resource-limit",
    );
  }

  try {
    let visitedNodes = 1;
    let maxDepth = 0;
    let rootHash: string | null = null;
    let functionsTruncated = false;
    let branchesTruncated = false;
    const pendingFunctions: PendingFunctionSummary[] = [];
    const pendingBranches: PendingBranchSummary[] = [];
    const stack: TraversalFrame[] = [createFrame(sourceFile, 0)];

    while (stack.length > 0) {
      const frame = stack[stack.length - 1];
      if (!frame) break;
      const child = frame.children[frame.nextChild];
      if (child) {
        if (visitedNodes >= budgets.maxNodes) throw new NodeBudgetError();
        frame.nextChild += 1;
        visitedNodes += 1;
        const depth = frame.depth + 1;
        maxDepth = Math.max(maxDepth, depth);
        stack.push(createFrame(child, depth));
        continue;
      }

      frame.hasher.add("end");
      const structuralHash = frame.hasher.digest();
      const kind = functionKind(frame.node);
      if (kind) {
        if (pendingFunctions.length < budgets.maxFunctions) {
          const functionNode = frame.node as ts.FunctionLikeDeclaration;
          pendingFunctions.push({
            kind,
            range: sourceRange(frame.node, sourceFile),
            async: hasModifier(frame.node, ts.SyntaxKind.AsyncKeyword),
            generator: Boolean(functionNode.asteriskToken),
            parameterCount: functionNode.parameters.length,
            nodeCount: frame.nodeCount,
            branchCount: frame.branchCount,
            loopCount: frame.loopCount,
            callCount: frame.callCount,
            structuralHash,
          });
        } else {
          functionsTruncated = true;
        }
      }

      const controlKind = branchKind(frame.node);
      if (controlKind) {
        if (pendingBranches.length < budgets.maxBranches) {
          pendingBranches.push({
            kind: controlKind,
            range: sourceRange(frame.node, sourceFile),
            depth: frame.depth,
            nodeCount: frame.nodeCount,
            structuralHash,
          });
        } else {
          branchesTruncated = true;
        }
      }

      stack.pop();
      const parent = stack[stack.length - 1];
      if (parent) {
        parent.hasher.add("child");
        parent.hasher.add(structuralHash);
        parent.nodeCount += frame.nodeCount;
        parent.branchCount += frame.branchCount;
        parent.loopCount += frame.loopCount;
        parent.callCount += frame.callCount;
      } else {
        rootHash = structuralHash;
      }
    }

    const functions = pendingFunctions
      .sort((left, right) => left.range.start - right.range.start)
      .map((summary, index) => ({ ...summary, id: `function:${index}` }));
    const branches = pendingBranches
      .sort((left, right) => left.range.start - right.range.start)
      .map((summary, index) => ({ ...summary, id: `branch:${index}` }));

    return {
      schemaVersion: 1,
      mode: "observe-only",
      parser: "typescript-ast",
      parserVersion: ts.version,
      hashAlgorithm: "sha256-tree-v1",
      parseStatus: "complete",
      sourceLength: sourceText.length,
      analyzedLength: analyzedSource.length,
      truncated: analyzedSource.length !== sourceText.length,
      nodeCount: visitedNodes,
      maxDepth,
      structuralHash: rootHash,
      functions,
      branches,
      summariesTruncated: {
        functions: functionsTruncated,
        branches: branchesTruncated,
      },
      budgets,
    };
  } catch (error) {
    return failedSignature(
      sourceText.length,
      analyzedSource.length,
      budgets,
      error instanceof NodeBudgetError
        ? "node-budget-exceeded"
        : error instanceof RangeError
          ? "parser-resource-limit"
          : "analysis-failed",
    );
  }
}
