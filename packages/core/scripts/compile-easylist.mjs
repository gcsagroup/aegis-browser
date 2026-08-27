#!/usr/bin/env node
/**
 * Compile EasyList-compatible text into JSON.
 * Parser must stay aligned with src/tracker/easylist.ts.
 *
 * Usage:
 *   node packages/core/scripts/compile-easylist.mjs [in.txt ...] [out.json]
 *   cat list.txt | node packages/core/scripts/compile-easylist.mjs - out.json
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

const COSMETIC_RE = /##|#@#|#\?#/;

function isPlausibleHost(host) {
  if (host.length < 3 || host.length > 253) {
    return false;
  }
  if (!host.includes(".")) {
    return false;
  }
  if (host.startsWith(".") || host.endsWith(".") || host.includes("..")) {
    return false;
  }
  return /^[a-z0-9.-]+$/i.test(host);
}

function parseEasyListRule(line) {
  let s = line.trim();
  if (!s || s.startsWith("!") || s.startsWith("[") || s.startsWith("#")) {
    return null;
  }
  if (COSMETIC_RE.test(s)) {
    return null;
  }
  let kind = "block";
  if (s.startsWith("@@")) {
    kind = "exception";
    s = s.slice(2);
  }
  if (!s.startsWith("||")) {
    return null;
  }
  s = s.slice(2);
  const dollar = s.indexOf("$");
  if (dollar >= 0) {
    const options = s.slice(dollar + 1).split(",");
    s = s.slice(0, dollar);
    if (
      options.some(
        (opt) => opt.startsWith("domain=") || opt.startsWith("~domain="),
      )
    ) {
      return null;
    }
  }
  if (s.endsWith("^")) {
    s = s.slice(0, -1);
  }
  if (s.includes("*") || s.includes("^") || s.includes("|")) {
    return null;
  }
  const slash = s.indexOf("/");
  const host = (slash < 0 ? s : s.slice(0, slash)).toLowerCase();
  if (!isPlausibleHost(host)) {
    return null;
  }
  const path = slash < 0 ? "" : s.slice(slash);
  return { kind, rule: path ? `${host}${path}` : host, path: Boolean(path) };
}

function compileEasyList(text, source = "easylist") {
  const hosts = new Set();
  const pathRules = new Set();
  const exceptions = new Set();
  let parsed = 0;
  let skipped = 0;
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed) {
      continue;
    }
    const parsedRule = parseEasyListRule(trimmed);
    if (!parsedRule) {
      skipped += 1;
      continue;
    }
    parsed += 1;
    if (parsedRule.kind === "exception") {
      exceptions.add(parsedRule.rule.split("/")[0] ?? parsedRule.rule);
      continue;
    }
    if (parsedRule.path) {
      pathRules.add(parsedRule.rule);
    } else {
      hosts.add(parsedRule.rule);
    }
  }
  const sort = (values) => [...values].sort();
  return {
    version: 1,
    source,
    generatedAt: new Date().toISOString(),
    hosts: sort(hosts),
    pathRules: sort(pathRules),
    exceptions: sort(exceptions),
    parsed,
    skipped,
  };
}

function mergeCompiledFilterLists(lists, source) {
  const hosts = new Set();
  const pathRules = new Set();
  const exceptions = new Set();
  let parsed = 0;
  let skipped = 0;
  for (const list of lists) {
    for (const host of list.hosts) {
      hosts.add(host);
    }
    for (const rule of list.pathRules) {
      pathRules.add(rule);
    }
    for (const host of list.exceptions) {
      exceptions.add(host);
    }
    parsed += list.parsed;
    skipped += list.skipped;
  }
  return {
    version: 1,
    source,
    generatedAt: new Date().toISOString(),
    hosts: [...hosts].sort(),
    pathRules: [...pathRules].sort(),
    exceptions: [...exceptions].sort(),
    parsed,
    skipped,
  };
}

const args = process.argv.slice(2);
if (args.length === 0) {
  console.error(
    "Usage: compile-easylist.mjs <in.txt ...|-> [out.json]\n" +
      "  Multiple inputs are merged. Use - for stdin.",
  );
  process.exit(1);
}

let outPath = "";
const inputs = [...args];
const last = inputs.at(-1) ?? "";
if (last !== "-" && last.endsWith(".json")) {
  outPath = resolve(last);
  inputs.pop();
}
if (inputs.length === 0) {
  inputs.push("-");
}

const lists = [];
for (const input of inputs) {
  const text =
    input === "-"
      ? readFileSync(0, "utf8")
      : readFileSync(resolve(input), "utf8");
  lists.push(compileEasyList(text, input === "-" ? "stdin" : input));
}

const compiled =
  lists.length === 1
    ? lists[0]
    : mergeCompiledFilterLists(lists, inputs.join("+"));

const json = `${JSON.stringify(compiled, null, 2)}\n`;
if (outPath) {
  mkdirSync(dirname(outPath), { recursive: true });
  writeFileSync(outPath, json, "utf8");
  console.error(
    `Wrote ${outPath} hosts=${compiled.hosts.length} path=${compiled.pathRules.length} exceptions=${compiled.exceptions.length}`,
  );
} else {
  process.stdout.write(json);
}
