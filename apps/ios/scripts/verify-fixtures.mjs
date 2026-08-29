#!/usr/bin/env node

import { readFile, stat } from "node:fs/promises";
import { createHash } from "node:crypto";
import { dirname, extname, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
let fixtureRoot = resolve(scriptDirectory, "../Tests/Fixtures");

for (let index = 2; index < process.argv.length; index += 1) {
  const argument = process.argv[index];
  if (argument === "--root") {
    const value = process.argv[index + 1];
    if (!value) throw new Error("--root 缺少路径");
    fixtureRoot = resolve(value);
    index += 1;
  } else if (argument === "-h" || argument === "--help") {
    console.log("用法：node apps/ios/scripts/verify-fixtures.mjs [--root PATH]");
    process.exit(0);
  } else {
    throw new Error(`未知参数：${argument}`);
  }
}

const failures = [];
const checkedFiles = new Set();

function fail(message) {
  failures.push(message);
}

function resolveFixture(relativePath) {
  if (typeof relativePath !== "string" || relativePath.length === 0) {
    fail(`fixture 路径无效：${String(relativePath)}`);
    return null;
  }
  const absolutePath = resolve(fixtureRoot, relativePath);
  if (!absolutePath.startsWith(`${fixtureRoot}${sep}`)) {
    fail(`fixture 路径越界：${relativePath}`);
    return null;
  }
  if (![".html", ".json"].includes(extname(absolutePath))) {
    fail(`fixture 只允许 HTML/JSON：${relativePath}`);
    return null;
  }
  return absolutePath;
}

async function readFixture(relativePath) {
  const absolutePath = resolveFixture(relativePath);
  if (!absolutePath) return null;
  try {
    const fileStat = await stat(absolutePath);
    if (!fileStat.isFile()) {
      fail(`fixture 不是普通文件：${relativePath}`);
      return null;
    }
    const contents = await readFile(absolutePath, "utf8");
    checkedFiles.add(relativePath);
    if (/https?:\/\//i.test(contents)) {
      fail(`离线 fixture 含公网 URL：${relativePath}`);
    }
    if (extname(absolutePath) === ".json") {
      try {
        JSON.parse(contents);
      } catch (error) {
        fail(`JSON 无法解析：${relativePath} (${error.message})`);
      }
    }
    return contents;
  } catch (error) {
    fail(`fixture 不存在或不可读：${relativePath} (${error.code ?? error.message})`);
    return null;
  }
}

const manifestText = await readFixture("manifest.json");
let manifest = null;
if (manifestText) {
  try {
    manifest = JSON.parse(manifestText);
  } catch {
    // readFixture 已记录具体错误。
  }
}

if (manifest) {
  if (manifest.schema_version !== 1) fail("manifest.schema_version 必须为 1");
  if (manifest.network_policy !== "offline_only") fail("manifest.network_policy 必须为 offline_only");
  if (!Array.isArray(manifest.cases) || manifest.cases.length < 5) {
    fail("manifest.cases 至少包含五类 fixture");
  } else {
    const identifiers = new Set();
    for (const fixtureCase of manifest.cases) {
      if (!fixtureCase?.id || identifiers.has(fixtureCase.id)) {
        fail(`fixture case id 缺失或重复：${String(fixtureCase?.id)}`);
      } else {
        identifiers.add(fixtureCase.id);
      }
      await readFixture(fixtureCase.entry);
      for (const resource of fixtureCase.resources ?? []) await readFixture(resource);
    }
    for (const requiredKind of ["browser", "injection", "research", "download", "shopping"]) {
      if (!manifest.cases.some((item) => item.kind === requiredKind)) {
        fail(`缺少 fixture 类型：${requiredKind}`);
      }
    }
  }

  const sourcesText = await readFixture(manifest.research?.sources);
  if (sourcesText) {
    const sources = JSON.parse(sourcesText);
    if (!Array.isArray(sources) || sources.length !== 10) {
      fail("研究 fixture 必须恰好包含 10 个来源");
    } else {
      const sourceIdentifiers = new Set();
      for (const source of sources) {
        if (!source.id || sourceIdentifiers.has(source.id)) {
          fail(`研究来源 id 缺失或重复：${String(source.id)}`);
        } else {
          sourceIdentifiers.add(source.id);
        }
        if (!source.title || !source.expected_claim) fail(`研究来源字段不完整：${String(source.id)}`);
        await readFixture(source.path);
      }
    }
  }

  const injectionText = await readFixture(manifest.security?.prompt_injection_page);
  if (injectionText) {
    for (const marker of [
      'data-injection-vector="visible"',
      'data-injection-vector="hidden"',
      'data-injection-vector="aria"',
      'data-injection-vector="shadow-dom"',
    ]) {
      if (!injectionText.includes(marker)) fail(`注入 fixture 缺少标记：${marker}`);
    }
  }

  const downloadCatalogText = await readFixture(manifest.downloads?.catalog);
  if (downloadCatalogText) {
    const downloadCatalog = JSON.parse(downloadCatalogText);
    for (const item of downloadCatalog.items ?? []) {
      if (!item.expected_sha256) continue;
      const payload = await readFixture(item.path);
      if (!payload) continue;
      const actualHash = createHash("sha256").update(payload).digest("hex");
      if (actualHash !== item.expected_sha256) {
        fail(`下载 fixture 哈希不一致：${item.path}`);
      }
    }
  }

  const shoppingText = await readFixture(manifest.shopping?.page);
  const shoppingDataText = await readFixture(manifest.shopping?.catalog);
  if (manifest.shopping?.final_submit_policy !== "forbidden") {
    fail("shopping.final_submit_policy 必须为 forbidden");
  }
  if (shoppingText) {
    const button = shoppingText.match(/<button\b[^>]*data-aegis-final-submit="forbidden"[^>]*>/i)?.[0];
    if (!button || !/\bdisabled\b/i.test(button)) {
      fail("购物 fixture 的最终提交按钮必须显式标为 forbidden 且 disabled");
    }
  }
  if (shoppingDataText) {
    const shoppingData = JSON.parse(shoppingDataText);
    if (shoppingData.final_submit?.policy !== "forbidden" || shoppingData.final_submit?.enabled !== false) {
      fail("购物 JSON 必须把 final_submit 标为 forbidden/enabled=false");
    }
  }
}

if (failures.length > 0) {
  console.error("FIXTURE_VERIFY=FAIL");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log(`FIXTURE_VERIFY=PASS files=${checkedFiles.size} research_sources=10 final_submit=forbidden`);
