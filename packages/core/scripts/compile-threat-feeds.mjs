#!/usr/bin/env node

import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { gunzipSync } from "node:zlib";
import { compileThreatIndex, parseFeed } from "./threat-feed-lib.mjs";

const INVOCATION_ROOT = resolve(process.env.INIT_CWD || process.cwd());

function usage() {
  return "用法: compile-threat-feeds.mjs --out <file> [--cert-pl <path|url>] [--phishtank <path|url>] [--urlhaus <path|url>] [--ttl-hours <1..24>]";
}

function parseArgs(argv) {
  const options = { feeds: [], ttlHours: 2, out: "" };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--") continue;
    const value = argv[index + 1];
    if (arg === "--out" && value) options.out = value;
    else if (arg === "--ttl-hours" && value) options.ttlHours = Number(value);
    else if (["--cert-pl", "--phishtank", "--urlhaus"].includes(arg) && value) {
      options.feeds.push({ source: arg.slice(2), location: value });
    } else throw new Error(usage());
    index += 1;
  }
  if (!options.out || options.feeds.length === 0 || !Number.isInteger(options.ttlHours) ||
      options.ttlHours < 1 || options.ttlHours > 24) throw new Error(usage());
  return options;
}

async function readLocation(source, location) {
  if (!/^https?:\/\//i.test(location)) {
    return readFile(resolve(INVOCATION_ROOT, location), "utf8");
  }
  const headers = { "User-Agent": "GCSA-aegis-threat-feed-compiler/1" };
  if (source === "phishtank") {
    const key = process.env.PHISHTANK_APP_KEY;
    if (!key) throw new Error("PhishTank 网络导入需要 PHISHTANK_APP_KEY，密钥不会写入索引");
    const escapedKey = encodeURIComponent(key);
    if (location.includes("{appkey}")) location = location.replace("{appkey}", escapedKey);
    else location = location.replace("/data/online-valid.", `/data/${escapedKey}/online-valid.`);
  }
  if (source === "urlhaus") {
    const key = process.env.URLHAUS_AUTH_KEY;
    if (!key) throw new Error("URLhaus 网络导入需要 URLHAUS_AUTH_KEY，密钥不会写入索引");
    headers["Auth-Key"] = key;
  }
  const response = await fetch(location, { headers, redirect: "follow" });
  if (!response.ok) throw new Error(`${source} download failed: HTTP ${response.status}`);
  const length = Number(response.headers.get("content-length") ?? 0);
  if (length > 64 * 1024 * 1024) throw new Error(`${source} download exceeds 64 MiB`);
  let bytes = Buffer.from(await response.arrayBuffer());
  if (bytes.length > 64 * 1024 * 1024) throw new Error(`${source} download exceeds 64 MiB`);
  if (bytes[0] === 0x1f && bytes[1] === 0x8b) bytes = gunzipSync(bytes);
  if (bytes.length > 64 * 1024 * 1024) throw new Error(`${source} expanded feed exceeds 64 MiB`);
  return bytes.toString("utf8");
}

const options = parseArgs(process.argv.slice(2));
const feeds = [];
for (const requested of options.feeds) {
  const text = await readLocation(requested.source, requested.location);
  feeds.push({ source: requested.source, entries: parseFeed(requested.source, text) });
}
const generatedAt = Math.floor(Date.now() / 1000);
const compiled = compileThreatIndex(feeds, {
  generatedAt,
  expiresAt: generatedAt + options.ttlHours * 60 * 60,
});
const output = resolve(INVOCATION_ROOT, options.out);
await mkdir(dirname(output), { recursive: true });
const temporary = `${output}.tmp-${process.pid}`;
await writeFile(temporary, compiled.bytes, { mode: 0o600 });
await rename(temporary, output);
process.stdout.write(`${JSON.stringify({ output, entries: compiled.count, sources: feeds.map((feed) => feed.source) })}\n`);
