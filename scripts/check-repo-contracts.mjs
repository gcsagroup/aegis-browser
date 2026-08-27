#!/usr/bin/env node

import {
  existsSync,
  readFileSync,
  readdirSync,
  statSync,
} from 'node:fs';
import {dirname, extname, join, relative, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const browserRoot = join(repoRoot, 'apps/browser');
const failures = [];

function fail(message) {
  failures.push(message);
}

function read(path) {
  return readFileSync(path, 'utf8');
}

function walkMarkdown(root) {
  const files = [];
  if (!existsSync(root)) {
    return files;
  }
  for (const name of readdirSync(root).sort()) {
    const path = join(root, name);
    const entry = statSync(path);
    if (entry.isDirectory()) {
      files.push(...walkMarkdown(path));
    } else if (entry.isFile() && extname(path) === '.md') {
      files.push(path);
    }
  }
  return files;
}

function checkBrowserOnly() {
  const workspace = read(join(repoRoot, 'pnpm-workspace.yaml'));
  const packages = [...workspace.matchAll(/^\s*-\s+"([^"]+)"\s*$/gmu)].map(
    (match) => match[1],
  );
  const expected = ['apps/browser', 'packages/core'];
  if (JSON.stringify(packages) !== JSON.stringify(expected)) {
    fail(`Workspace 产品边界漂移：${packages.join(', ')}`);
  }
  if (existsSync(join(repoRoot, 'apps/extension'))) {
    fail('Browser-only 边界失败：apps/extension 重新出现');
  }
  const rootPackage = read(join(repoRoot, 'package.json'));
  if (rootPackage.includes('@gcsa-aegis/extension')) {
    fail('Browser-only 边界失败：根 package.json 引用 Extension');
  }
}

function checkPatchSeries() {
  const seriesPath = join(browserRoot, 'patches/series');
  const entries = read(seriesPath)
    .split(/\r?\n/gu)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith('#'));
  if (entries.length < 30) {
    fail(`补丁序列异常缩短：${entries.length} < 30`);
  }
  const seen = new Set();
  entries.forEach((name, index) => {
    const expectedPrefix = `${String(index + 1).padStart(4, '0')}-`;
    if (!name.startsWith(expectedPrefix) || name.includes('/') || name.includes('..')) {
      fail(`补丁 ${index + 1} 名称或路径不安全：${name}`);
    }
    if (seen.has(name)) {
      fail(`补丁序列重复：${name}`);
    }
    seen.add(name);
    const path = join(browserRoot, 'patches', name);
    if (!existsSync(path)) {
      fail(`补丁文件缺失：${name}`);
      return;
    }
    if (!/^From [0-9a-f]{40} /u.test(read(path).split(/\r?\n/u)[0])) {
      fail(`补丁缺少 format-patch 身份：${name}`);
    }
  });

  const patchFiles = readdirSync(join(browserRoot, 'patches'))
    .filter((name) => name.endsWith('.patch'))
    .sort();
  for (const name of patchFiles) {
    if (!seen.has(name)) {
      fail(`补丁文件未列入 series：${name}`);
    }
  }
}

function checkPinnedVersion() {
  const version = read(join(browserRoot, 'CHROMIUM_VERSION')).trim();
  const commit = read(join(browserRoot, 'CHROMIUM_COMMIT')).trim();
  if (!/^\d+\.\d+\.\d+\.\d+$/u.test(version)) {
    fail(`Chromium 版本格式无效：${version}`);
  }
  if (!/^[0-9a-f]{40}$/u.test(commit)) {
    fail(`Chromium commit 格式无效：${commit}`);
  }
  for (const path of [
    join(browserRoot, 'README.md'),
    join(browserRoot, 'docs/android.md'),
  ]) {
    if (!read(path).includes(version)) {
      fail(`${relative(repoRoot, path)} 未引用当前 Chromium 版本 ${version}`);
    }
  }
}

function checkMarkdownLinks() {
  const files = [
    join(repoRoot, 'README.md'),
    join(browserRoot, 'README.md'),
    ...walkMarkdown(join(repoRoot, 'docs')),
    ...walkMarkdown(join(browserRoot, 'docs')),
    join(browserRoot, 'patches/README.md'),
  ];
  const uniqueFiles = [...new Set(files)];
  const linkPattern = /!?\[[^\]]*\]\(([^)]+)\)/gu;
  for (const file of uniqueFiles) {
    const content = read(file);
    for (const match of content.matchAll(linkPattern)) {
      let target = match[1].trim();
      if (target.startsWith('<') && target.endsWith('>')) {
        target = target.slice(1, -1);
      }
      target = target.split(/\s+["']/u)[0].split('#')[0];
      if (!target || /^(?:https?:|mailto:|data:)/iu.test(target)) {
        continue;
      }
      let decoded;
      try {
        decoded = decodeURIComponent(target);
      } catch {
        fail(`${relative(repoRoot, file)} 含无法解码的链接：${target}`);
        continue;
      }
      const resolved = decoded.startsWith('/')
        ? resolve(repoRoot, `.${decoded}`)
        : resolve(dirname(file), decoded);
      if (!existsSync(resolved)) {
        fail(
          `${relative(repoRoot, file)} 内部链接不存在：${target}`,
        );
      }
    }
  }
}

function checkDocumentedCommands() {
  const rootPackage = JSON.parse(read(join(repoRoot, 'package.json')));
  const browserPackage = JSON.parse(read(join(browserRoot, 'package.json')));
  const documents = [
    read(join(repoRoot, 'README.md')),
    read(join(browserRoot, 'README.md')),
  ].join('\n');

  for (const match of documents.matchAll(/pnpm run ([a-z0-9:_-]+)/giu)) {
    if (!rootPackage.scripts?.[match[1]]) {
      fail(`README 引用了不存在的根命令：pnpm run ${match[1]}`);
    }
  }
  for (const match of documents.matchAll(
    /pnpm --filter @gcsa-aegis\/browser ([a-z0-9:_-]+)/giu,
  )) {
    if (!browserPackage.scripts?.[match[1]]) {
      fail(`README 引用了不存在的 Browser 命令：${match[1]}`);
    }
  }
}

checkBrowserOnly();
checkPatchSeries();
checkPinnedVersion();
checkMarkdownLinks();
checkDocumentedCommands();

if (failures.length > 0) {
  for (const message of failures) {
    process.stderr.write(`仓库合同失败：${message}\n`);
  }
  process.exit(1);
}

process.stdout.write('仓库合同通过：Browser-only、补丁、版本、链接和命令一致。\n');
