import ts from "typescript";
import {
  STATIC_SCRIPT_SIGNAL_CODES,
  type StaticScriptAnalysis,
  type StaticScriptSignalCode,
} from "./types.js";

export type {
  StaticScriptAnalysis,
  StaticScriptSignalCode,
  StaticScriptSignalEvidence,
} from "./types.js";

const DEFAULT_MAX_SOURCE_CHARS = 1_000_000;
const HARD_MAX_SOURCE_CHARS = 2_000_000;
const MAX_RECORDED_OCCURRENCES = 255;

const MINING_PROTOCOL_LITERAL =
  /(?:^|\s)stratum\+(?:tcp|ssl):\/\/|\bmining\.(?:subscribe|authorize|submit)\b/i;

const BITWISE_OPERATORS = new Set<ts.SyntaxKind>([
  ts.SyntaxKind.AmpersandToken,
  ts.SyntaxKind.BarToken,
  ts.SyntaxKind.CaretToken,
  ts.SyntaxKind.LessThanLessThanToken,
  ts.SyntaxKind.GreaterThanGreaterThanToken,
  ts.SyntaxKind.GreaterThanGreaterThanGreaterThanToken,
]);

const EXECUTION_GUARD_PATHS = new Set([
  "document.hidden",
  "document.visibilityState",
  "navigator.deviceMemory",
  "navigator.hardwareConcurrency",
]);

export interface AnalyzeScriptAstOptions {
  maxSourceChars?: number;
}

function boundedSourceLimit(requested: number | undefined): number {
  if (!Number.isFinite(requested)) return DEFAULT_MAX_SOURCE_CHARS;
  return Math.max(
    1,
    Math.min(HARD_MAX_SOURCE_CHARS, Math.trunc(requested ?? 0)),
  );
}

function expressionPath(node: ts.Expression): string | null {
  const segments: string[] = [];
  let current: ts.Expression = node;
  while (!ts.isIdentifier(current)) {
    if (ts.isPropertyAccessExpression(current)) {
      segments.push(current.name.text);
      current = current.expression;
      continue;
    }
    if (
      ts.isElementAccessExpression(current) &&
      current.argumentExpression &&
      ts.isStringLiteralLike(current.argumentExpression)
    ) {
      segments.push(current.argumentExpression.text);
      current = current.expression;
      continue;
    }
    return null;
  }
  segments.push(current.text);
  return segments.reverse().join(".");
}

function callPath(node: ts.CallExpression | ts.NewExpression): string | null {
  return expressionPath(node.expression);
}

function childrenOf(node: ts.Node): ts.Node[] {
  const children: ts.Node[] = [];
  ts.forEachChild(node, (child) => {
    children.push(child);
  });
  return children;
}

function containsExecutionGuard(node: ts.Node): boolean {
  const stack = [node];
  while (stack.length > 0) {
    const current = stack.pop();
    if (!current) continue;
    if (
      ts.isPropertyAccessExpression(current) ||
      ts.isElementAccessExpression(current)
    ) {
      const path = expressionPath(current);
      if (path && EXECUTION_GUARD_PATHS.has(path)) return true;
    }
    stack.push(...childrenOf(current));
  }
  return false;
}

function hashPrimitiveCounts(node: ts.Node): {
  bitwise: number;
  imul: number;
} {
  let bitwise = 0;
  let imul = 0;
  const stack = [node];
  while (stack.length > 0) {
    const current = stack.pop();
    if (!current) continue;
    if (
      ts.isBinaryExpression(current) &&
      BITWISE_OPERATORS.has(current.operatorToken.kind)
    ) {
      bitwise += 1;
    }
    if (ts.isCallExpression(current) && callPath(current) === "Math.imul") {
      imul += 1;
    }
    stack.push(...childrenOf(current));
  }
  return { bitwise, imul };
}

function isLoop(node: ts.Node): node is
  | ts.ForStatement
  | ts.ForInStatement
  | ts.ForOfStatement
  | ts.WhileStatement
  | ts.DoStatement {
  return (
    ts.isForStatement(node) ||
    ts.isForInStatement(node) ||
    ts.isForOfStatement(node) ||
    ts.isWhileStatement(node) ||
    ts.isDoStatement(node)
  );
}

function isBranch(node: ts.Node): node is ts.IfStatement | ts.ConditionalExpression {
  return ts.isIfStatement(node) || ts.isConditionalExpression(node);
}

function branchCondition(
  node: ts.IfStatement | ts.ConditionalExpression,
): ts.Expression {
  return ts.isIfStatement(node) ? node.expression : node.condition;
}

function record(
  occurrences: Map<StaticScriptSignalCode, number>,
  code: StaticScriptSignalCode,
): void {
  occurrences.set(
    code,
    Math.min(MAX_RECORDED_OCCURRENCES, (occurrences.get(code) ?? 0) + 1),
  );
}

function inspectCallOrConstruction(
  node: ts.CallExpression | ts.NewExpression,
  occurrences: Map<StaticScriptSignalCode, number>,
): void {
  const path = callPath(node);
  if (!path) return;

  if (
    ts.isNewExpression(node) &&
    (path === "Worker" || path === "SharedWorker")
  ) {
    record(occurrences, "ast.worker-construction");
  }
  if (path.startsWith("WebAssembly.")) {
    record(occurrences, "ast.wasm-use");
  }
  if (
    path === "navigator.gpu" ||
    path.endsWith(".createComputePipeline") ||
    path.endsWith(".createComputePipelineAsync") ||
    path.endsWith(".dispatchWorkgroups") ||
    path.endsWith(".dispatchWorkgroupsIndirect")
  ) {
    record(occurrences, "ast.webgpu-compute");
  }
  if (
    (ts.isNewExpression(node) && path === "SharedArrayBuffer") ||
    path.startsWith("Atomics.")
  ) {
    record(occurrences, "ast.shared-memory");
  }
  if (ts.isNewExpression(node) && path === "WebSocket") {
    record(occurrences, "ast.websocket");
  }
  if (path === "eval" || path === "Function") {
    record(occurrences, "ast.dynamic-code");
  }
  if (path === "atob" || path === "String.fromCharCode") {
    record(occurrences, "ast.encoded-payload");
  }
  if (
    path === "fetch" ||
    (ts.isNewExpression(node) && path === "XMLHttpRequest")
  ) {
    record(occurrences, "ast.remote-load");
  }
}

/**
 * Parse JavaScript into a real TypeScript AST and extract conservative static
 * signals. This Node-only analyzer never evaluates source and returns no source
 * excerpts, literals, URLs, or payloads.
 */
export function analyzeScriptAst(
  sourceText: string,
  options: AnalyzeScriptAstOptions = {},
): StaticScriptAnalysis {
  const maxSourceChars = boundedSourceLimit(options.maxSourceChars);
  const analyzedSource = sourceText.slice(0, maxSourceChars);
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
    // TypeScript's recursive parser can reject adversarial nesting. Fail open
    // without echoing parser errors or source; production callers must still
    // run this Node-only entry in a time- and memory-bounded worker/utility.
    return {
      schemaVersion: 1,
      analyzer: "typescript-ast",
      parserVersion: ts.version,
      parseStatus: "failed",
      failureCode: "parser-resource-limit",
      sourceLength: sourceText.length,
      analyzedLength: analyzedSource.length,
      truncated: analyzedSource.length !== sourceText.length,
      nodeCount: 0,
      maxDepth: 0,
      branchCount: 0,
      signals: [],
    };
  }

  try {
    const occurrences = new Map<StaticScriptSignalCode, number>();
    let nodeCount = 0;
    let maxDepth = 0;
    let branchCount = 0;
    const stack: Array<{ node: ts.Node; depth: number }> = [
      { node: sourceFile, depth: 0 },
    ];

    while (stack.length > 0) {
      const item = stack.pop();
      if (!item) continue;
      const { node, depth } = item;
      nodeCount += 1;
      maxDepth = Math.max(maxDepth, depth);

      if (ts.isCallExpression(node) || ts.isNewExpression(node)) {
        inspectCallOrConstruction(node, occurrences);
      }

      if (
        ts.isStringLiteralLike(node) &&
        MINING_PROTOCOL_LITERAL.test(node.text)
      ) {
        record(occurrences, "ast.mining-protocol");
      }

      if (isLoop(node)) {
        const primitives = hashPrimitiveCounts(node.statement);
        if (
          primitives.bitwise >= 4 &&
          (primitives.imul >= 1 || primitives.bitwise >= 8)
        ) {
          record(occurrences, "ast.hash-loop");
        }
      }

      if (isBranch(node)) {
        branchCount += 1;
        if (containsExecutionGuard(branchCondition(node))) {
          record(occurrences, "ast.execution-guard");
        }
      }

      const children = childrenOf(node);
      for (let index = children.length - 1; index >= 0; index -= 1) {
        const child = children[index];
        if (child) stack.push({ node: child, depth: depth + 1 });
      }
    }

    return {
      schemaVersion: 1,
      analyzer: "typescript-ast",
      parserVersion: ts.version,
      parseStatus: "complete",
      sourceLength: sourceText.length,
      analyzedLength: analyzedSource.length,
      truncated: analyzedSource.length !== sourceText.length,
      nodeCount,
      maxDepth,
      branchCount,
      signals: STATIC_SCRIPT_SIGNAL_CODES.flatMap((code) => {
        const count = occurrences.get(code);
        return count ? [{ code, occurrences: count }] : [];
      }),
    };
  } catch {
    return {
      schemaVersion: 1,
      analyzer: "typescript-ast",
      parserVersion: ts.version,
      parseStatus: "failed",
      failureCode: "parser-resource-limit",
      sourceLength: sourceText.length,
      analyzedLength: analyzedSource.length,
      truncated: analyzedSource.length !== sourceText.length,
      nodeCount: 0,
      maxDepth: 0,
      branchCount: 0,
      signals: [],
    };
  }
}
