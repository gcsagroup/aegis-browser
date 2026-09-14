#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
import {readFileSync, writeFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {resolve} from 'node:path';
import {fail, isInside, parseArgs, repoRoot} from './common.mjs';

const require = createRequire(import.meta.url);
const packages = ['@eslint/js', 'eslint', 'typescript-eslint', 'c8', '@vitest/coverage-v8', 'vitest'];

try {
  const {values} = parseArgs(process.argv.slice(2), ['output']);
  if (!values.output) fail('--output is required');
  const output = resolve(values.output);
  if (!isInside(repoRoot, output)) fail('License metadata output must stay inside the repository');
  const license = readFileSync(resolve(repoRoot, 'LICENSE'), 'utf8');
  if (!license.includes('Apache License') || !license.includes('Copyright 2026 GCSA')) fail('Root Apache-2.0 license or GCSA notice is missing');
  for (const path of ['package.json', 'packages/core/package.json', 'apps/browser/package.json']) {
    const manifest = JSON.parse(readFileSync(resolve(repoRoot, path), 'utf8'));
    if (manifest.license !== 'Apache-2.0') fail(`${path} must declare Apache-2.0`);
  }
  const notices = readFileSync(resolve(repoRoot, 'THIRD_PARTY_NOTICES.md'), 'utf8');
  for (const reference of ['151.0.7922.77', 'aegis_libtorrent/LICENSE', 'aegis_libtorrent/README.aegis']) {
    if (!notices.includes(reference)) fail(`THIRD_PARTY_NOTICES.md is missing ${reference}`);
  }
  const dependencies = packages.map((name) => {
    const manifest = require(`${name}/package.json`);
    return {
      name,
      version: manifest.version,
      declaredLicense: manifest.license ?? null,
      metadataStatus: manifest.license ? 'RECORDED' : 'UNKNOWN',
      compatibilityReviewed: false,
    };
  });
  dependencies.push({
    name: 'coverage.py', version: '7.16.1', declaredLicense: 'Apache-2.0',
    metadataStatus: 'RECORDED_FROM_PIN', compatibilityReviewed: false,
  });
  const report = {
    schemaVersion: 1,
    projectLicense: 'Apache-2.0',
    dependencyMetadataOnly: true,
    completeSbom: false,
    legalCompatibilityOpinion: false,
    dependencies,
  };
  writeFileSync(output, `${JSON.stringify(report, null, 2)}\n`);
  console.log(JSON.stringify({status: 'PASS', output, dependencies: dependencies.length}));
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
