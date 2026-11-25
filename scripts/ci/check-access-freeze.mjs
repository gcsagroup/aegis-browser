#!/usr/bin/env node
import {execFileSync} from 'node:child_process';
import {readFileSync, statSync} from 'node:fs';
import {join, resolve} from 'node:path';
import {
  ensureRelativePath,
  fail,
  git,
  parseArgs,
  repoRoot,
  resolveCommit,
  sha256,
} from './common.mjs';

const freezeDirectory = 'docs/plans/access-service-v1.0';
const freezePath = `${freezeDirectory}/freeze.json`;
const trustedFallback = 'd60b5952b40e511d6f98f3f33be926dbe7ab1eb7';
const trustedFallbackManifestSha256 = 'ea90c1005787121924897d1dc0f7d5dcf573982e3ba499c26f48c8078983d4e0';
const revisionMigrations = Object.freeze([
  Object.freeze({
    fromRevision: 4,
    fromManifestSha256: trustedFallbackManifestSha256,
    toRevision: 5,
    toManifestSha256: 'b5e8586e6ca346bca2cdf02824de5765908fa9e2a88f09da4ae8f50cc61549e7',
  }),
]);
const embeddedManifestDigests = new Set(revisionMigrations.map(({toManifestSha256}) => toManifestSha256));

function gitFile(ref, path, cwd) {
  try {
    return execFileSync('git', ['show', `${ref}:${path}`], {
      cwd,
      encoding: 'buffer',
      maxBuffer: 16 * 1024 * 1024,
    });
  } catch {
    fail(`Missing ${path} at trusted baseline ${ref}`);
  }
}

function hasGitFile(ref, path, cwd) {
  try {
    git(['cat-file', '-e', `${ref}:${path}`], {cwd});
    return true;
  } catch {
    return false;
  }
}

function validateManifest(manifest) {
  const expected = {
    specVersion: 'V1.0',
    specRevision: 5,
    specificationStatus: 'FROZEN',
    authority: 'spec.zh-CN.md',
  };
  for (const [key, value] of Object.entries(expected)) {
    if (manifest[key] !== value) fail(`Frozen manifest ${key} must be ${value}`);
  }
  const counts = manifest.counts ?? {};
  if (
    counts.functionalAndDeliveryCases !== 118 ||
    counts.performanceMetrics !== 13 ||
    counts.deliveryGates !== 4
  ) {
    fail('Frozen manifest counts do not match revision 5');
  }
  if (manifest.documentChecks?.previewScenarioCount !== 13) {
    fail('Frozen preview scenario count must be 13');
  }
  if (manifest.documentChecks?.previewScript !== 'verify-preview.cjs') {
    fail('Frozen preview script identity changed');
  }
  const files = Object.entries(manifest.files ?? {});
  if (files.length === 0 || !Object.hasOwn(manifest.files, manifest.authority)) {
    fail('Frozen manifest has no protected files or omits its authority');
  }
  return files;
}

try {
  const {values} = parseArgs(process.argv.slice(2), ['base', 'repo']);
  const cwd = resolve(values.repo ?? repoRoot);
  const base = resolveCommit(values.base, cwd);
  const baseHasFreeze = hasGitFile(base, freezePath, cwd);
  const fallbackObjectAvailable = hasGitFile(trustedFallback, freezePath, cwd);
  const baseline = baseHasFreeze ? base : trustedFallback;
  const candidateBytes = readFileSync(join(cwd, freezePath));
  const candidateDigest = sha256(candidateBytes);
  const trustedAvailable = baseHasFreeze || fallbackObjectAvailable;
  let baselineManifest = null;
  let migration = null;
  if (trustedAvailable) {
    const baselineBytes = gitFile(baseline, freezePath, cwd);
    if (!candidateBytes.equals(baselineBytes)) {
      const baselineDigest = sha256(baselineBytes);
      migration = revisionMigrations.find(
        (entry) => entry.fromManifestSha256 === baselineDigest && entry.toManifestSha256 === candidateDigest,
      ) ?? null;
      if (!migration) fail(`freeze.json differs from trusted baseline ${baseline}`);
    }
    baselineManifest = JSON.parse(baselineBytes.toString('utf8'));
  } else if (!embeddedManifestDigests.has(candidateDigest)) {
    fail(`freeze.json differs from embedded digest for trusted baseline ${trustedFallback}`);
  }
  const manifest = JSON.parse(candidateBytes.toString('utf8'));
  const files = validateManifest(manifest);
  const trustedFiles = new Map(Object.entries(baselineManifest?.files ?? {}));
  for (const [name, contract] of files) {
    ensureRelativePath(name);
    if (name.includes('/') || name.includes('\\')) {
      fail(`Frozen file must remain directly inside ${freezeDirectory}: ${name}`);
    }
    const relativePath = `${freezeDirectory}/${name}`;
    const absolutePath = join(cwd, relativePath);
    const current = readFileSync(absolutePath);
    const trustedContract = trustedFiles.get(name);
    const contractUnchanged = trustedContract?.sha256 === contract.sha256 && trustedContract?.bytes === contract.bytes;
    if (trustedAvailable && (!migration || contractUnchanged)) {
      const trusted = gitFile(baseline, relativePath, cwd);
      if (!current.equals(trusted)) fail(`${relativePath} differs from trusted baseline ${baseline}`);
    }
    if (statSync(absolutePath).size !== contract.bytes) {
      fail(`${relativePath} byte count mismatch`);
    }
    if (sha256(current) !== contract.sha256) {
      fail(`${relativePath} SHA-256 mismatch`);
    }
  }
  console.log(JSON.stringify({
    status: 'PASS',
    base,
    baseline,
    fallbackUsed: !baseHasFreeze,
    specRevision: manifest.specRevision,
    migration: migration ? `${migration.fromRevision}->${migration.toRevision}` : null,
    files: files.length,
  }));
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
