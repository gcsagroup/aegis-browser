#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
import {createHash} from 'node:crypto';
import {existsSync, readFileSync, readdirSync, statSync, writeFileSync} from 'node:fs';
import {join, relative, resolve, sep} from 'node:path';
import {fail, git, isInside, parseArgs, repoRoot, resolveCommit} from './common.mjs';
import {
  parseCoverageSummary,
  parseLcov,
  validateCoverage as validateTypeScriptCoverage,
} from './validate-coverage.mjs';

function repoPath(path) {
  return relative(repoRoot, path).split(sep).join('/');
}

function freshFile(path, notBefore) {
  if (!existsSync(path) || !statSync(path).isFile()) fail(`Coverage output is missing: ${path}`);
  const stat = statSync(path);
  if (stat.size === 0) fail(`Coverage output is empty: ${path}`);
  if (stat.mtimeMs < notBefore) fail(`Coverage output is stale: ${path}`);
  return readFileSync(path, 'utf8');
}

function hash(source) {
  return createHash('sha256').update(source).digest('hex');
}

function requireExactFiles(files, expectedFiles, label) {
  const expected = [...expectedFiles].sort();
  if (JSON.stringify(files) !== JSON.stringify(expected)) {
    const missing = expected.filter((file) => !files.includes(file));
    const unexpected = files.filter((file) => !expected.includes(file));
    fail(`${label} scope mismatch; missing=${missing.join(',') || '<none>'}; unexpected=${unexpected.join(',') || '<none>'}`);
  }
}

function parseLlvmSummary(source, expectedFiles, lcovTotals) {
  let summary;
  try { summary = JSON.parse(source); } catch { fail('C++ coverage summary JSON is invalid'); }
  if (!Array.isArray(summary?.data) || summary.data.length !== 1) fail('C++ coverage summary must contain exactly one data set');
  const data = summary.data[0];
  const files = (data.files ?? []).map((file) => {
    const absolute = resolve(file.filename ?? '');
    if (!isInside(repoRoot, absolute) || !existsSync(absolute) || !statSync(absolute).isFile()) {
      fail(`C++ coverage summary contains an invalid source: ${file.filename ?? '<missing>'}`);
    }
    return repoPath(absolute);
  }).sort();
  requireExactFiles(files, expectedFiles, 'C++ coverage summary');
  for (const [name, llvmName] of [['lines', 'lines'], ['functions', 'functions'], ['branches', 'branches']]) {
    const metric = data.totals?.[llvmName];
    if (
      !Number.isInteger(metric?.count) || metric.count < 0 ||
      !Number.isInteger(metric?.covered) || metric.covered < 0 || metric.covered > metric.count ||
      !Number.isFinite(metric?.percent) || metric.percent < 0 || metric.percent > 100
    ) fail(`C++ coverage summary contains invalid ${llvmName} totals`);
    const expectedPercent = metric.count === 0 ? 0 : (metric.covered / metric.count) * 100;
    if (Math.abs(metric.percent - expectedPercent) > 1e-9) fail(`C++ coverage summary contains inconsistent ${llvmName} percentage`);
    if (metric.count !== lcovTotals[name].total || metric.covered !== lcovTotals[name].covered) {
      fail(`C++ ${llvmName} totals disagree between JSON and LCOV`);
    }
  }
  return data.totals;
}

function discover(directory, extensions, excluded = () => false) {
  const files = [];
  for (const entry of readdirSync(directory, {withFileTypes: true})) {
    const absolute = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...discover(absolute, extensions, excluded));
    else if (entry.isFile() && extensions.some((extension) => entry.name.endsWith(extension))) {
      const path = repoPath(absolute);
      if (!excluded(path)) files.push(path);
    }
  }
  return files;
}

function inventory() {
  const files = git(['ls-files', '-z']).split('\0').filter(Boolean);
  const count = (expression) => files.filter((path) => expression.test(path)).length;
  return {
    typescript: count(/\.ts$/u), mts: count(/\.mts$/u),
    javascript: count(/\.js$/u), mjs: count(/\.mjs$/u), cjs: count(/\.cjs$/u),
    cpp: count(/\.cc$/u), cppHeaders: count(/\.h$/u), swift: count(/\.swift$/u),
    python: count(/\.py$/u), bash: count(/\.sh$/u), powershell: count(/\.ps1$/u),
    java: count(/\.java$/u),
  };
}

try {
  const {values} = parseArgs(process.argv.slice(2), ['coverage-root', 'output', 'tested-sha', 'not-before']);
  if (!values['coverage-root'] || !values.output || !values['tested-sha'] || !values['not-before']) {
    fail('--coverage-root, --output, --tested-sha and --not-before are required');
  }
  const coverageRoot = resolve(values['coverage-root']);
  const output = resolve(values.output);
  const notBefore = Date.parse(values['not-before']);
  if (!isInside(repoRoot, coverageRoot) || !isInside(repoRoot, output)) fail('Coverage paths must stay inside the repository');
  if (!Number.isFinite(notBefore)) fail('--not-before must be an ISO timestamp');
  const testedSha = resolveCommit(values['tested-sha']);

  const typescript = validateTypeScriptCoverage({
    coverageDirectory: join(coverageRoot, 'core'),
    sourceDirectory: join(repoRoot, 'packages/core/src'),
    notBefore,
  });

  const javascriptFiles = [
    ...discover(join(repoRoot, 'scripts'), ['.mjs'], (path) => path.includes('/tests/')),
    ...discover(join(repoRoot, 'packages/core/scripts'), ['.mjs'], (path) => /(?:^|\/)(?:fixtures)(?:\/|$)|(?:_test|\.test)\.mjs$/u.test(path)),
    ...discover(join(repoRoot, 'packages/core/src'), ['.mjs'], (path) => /(?:_test|\.test)\.mjs$/u.test(path)),
    ...discover(join(repoRoot, 'apps/browser/scripts'), ['.js', '.mjs', '.cjs'], (path) => /(?:^|\/)(?:fixtures)(?:\/|$)|(?:_test|\.test)\.(?:js|mjs|cjs)$/u.test(path)),
  ].sort();
  const javascriptLcovPath = join(coverageRoot, 'javascript/lcov.info');
  const javascriptLcov = freshFile(javascriptLcovPath, notBefore);
  const javascriptLcovResult = parseLcov(javascriptLcov, repoRoot);
  requireExactFiles(javascriptLcovResult.files, javascriptFiles, 'JavaScript LCOV');
  const javascriptSummaryPath = join(coverageRoot, 'javascript/coverage-summary.json');
  const javascriptTotals = parseCoverageSummary(
    freshFile(javascriptSummaryPath, notBefore), 'JavaScript coverage summary',
  );
  for (const metric of ['lines', 'functions', 'branches']) {
    if (
      javascriptTotals[metric].total !== javascriptLcovResult.totals[metric].total ||
      javascriptTotals[metric].covered !== javascriptLcovResult.totals[metric].covered
    ) fail(`JavaScript ${metric} totals disagree between JSON and LCOV`);
  }

  const cppFiles = [
    'apps/browser/overlay/components/aegis_access/access_base_proxy_config_generation_state.cc',
    'apps/browser/overlay/components/aegis_access/access_identity_generation_state.cc',
    'apps/browser/overlay/components/aegis_access/access_proxy_selection_generation_state.cc',
    'apps/browser/overlay/components/aegis_access/access_route_planner.cc',
    'apps/browser/overlay/components/aegis_access/browser_request_metadata_seed.cc',
    'apps/browser/overlay/components/aegis_access/published_request_runtime.cc',
    'apps/browser/overlay/components/aegis_access/request_dispatch_gate.cc',
    'apps/browser/overlay/components/aegis_access/request_generation_tuple_builder.cc',
    'apps/browser/overlay/components/aegis_access/request_ownership_registry.cc',
    'apps/browser/overlay/components/aegis_access/site_proxy_rule_group.cc',
  ];
  const cppLcovPath = join(coverageRoot, 'cpp-access-standalone/lcov.info');
  const cppLcov = freshFile(cppLcovPath, notBefore);
  const cpp = parseLcov(cppLcov, repoRoot);
  requireExactFiles(cpp.files, cppFiles, 'C++ LCOV');
  const cppSummaryPath = join(coverageRoot, 'cpp-access-standalone/coverage-summary.json');
  const cppSummary = freshFile(cppSummaryPath, notBefore);
  const cppTotals = parseLlvmSummary(cppSummary, cppFiles, cpp.totals);

  const pythonJsonPath = join(coverageRoot, 'python/coverage.json');
  freshFile(join(coverageRoot, 'python/coverage.xml'), notBefore);
  freshFile(join(coverageRoot, 'python/lcov.info'), notBefore);
  let pythonJson;
  try { pythonJson = JSON.parse(freshFile(pythonJsonPath, notBefore)); } catch { fail('Python coverage JSON is invalid'); }
  const pythonFiles = [
    'apps/browser/overlay/components/aegis_access/generate_policy_matcher_vectors.py',
    'apps/browser/overlay/components/aegis_access/generate_route_planner_vectors.py',
    'apps/browser/scripts/check-chromium-upstream.py',
    'apps/browser/scripts/ci/candidate.py',
    'apps/browser/scripts/local-pypi-proxy.py',
  ];
  if (JSON.stringify(Object.keys(pythonJson.files ?? {}).sort()) !== JSON.stringify(pythonFiles)) fail('Python coverage scope does not match the five production tools');
  const pythonLcovPath = join(coverageRoot, 'python/lcov.info');
  const pythonLcov = parseLcov(freshFile(pythonLcovPath, notBefore), repoRoot);
  requireExactFiles(pythonLcov.files, pythonFiles, 'Python LCOV');
  const pythonTotals = pythonJson.totals;
  for (const [field, coveredField] of [['num_statements', 'covered_lines'], ['num_branches', 'covered_branches']]) {
    if (
      !Number.isInteger(pythonTotals?.[field]) || pythonTotals[field] < 0 ||
      !Number.isInteger(pythonTotals?.[coveredField]) || pythonTotals[coveredField] < 0 ||
      pythonTotals[coveredField] > pythonTotals[field]
    ) fail(`Python coverage JSON has invalid ${field}/${coveredField}`);
  }
  const pythonDenominator = pythonTotals.num_statements + pythonTotals.num_branches;
  const pythonNumerator = pythonTotals.covered_lines + pythonTotals.covered_branches;
  const expectedPythonPercent = pythonDenominator === 0 ? 100 : (pythonNumerator / pythonDenominator) * 100;
  if (
    !Number.isFinite(pythonTotals.percent_covered) || pythonTotals.percent_covered < 0 ||
    pythonTotals.percent_covered > 100 || Math.abs(pythonTotals.percent_covered - expectedPythonPercent) > 1e-9
  ) fail('Python coverage JSON has an invalid or inconsistent percent_covered');
  if (
    pythonTotals.num_statements !== pythonLcov.totals.lines.total ||
    pythonTotals.covered_lines !== pythonLcov.totals.lines.covered ||
    pythonTotals.num_branches !== pythonLcov.totals.branches.total ||
    pythonTotals.covered_branches !== pythonLcov.totals.branches.covered
  ) fail('Python coverage totals disagree between JSON and LCOV');

  const manifest = {
    schemaVersion: 1,
    testedSha,
    generatedAt: new Date().toISOString(),
    aggregateCoverage: null,
    inventory: inventory(),
    languages: {
      typescript: {...typescript, note: 'packages/core production TypeScript only; this is not browser or C++ coverage'},
      javascript: {
        status: 'MEASURED', scopeKind: 'node-tooling-production', files: javascriptLcovResult.files.length,
        reports: {lcov: repoPath(javascriptLcovPath), summary: repoPath(javascriptSummaryPath)},
        lcovSha256: hash(javascriptLcov), totals: javascriptTotals,
        note: 'Node-executed CI/core/browser tooling only; browser-renderer JavaScript is not measured',
      },
      cpp: {
        status: 'MEASURED', scopeKind: 'aegis-access-standalone-production-units', files: cpp.files.length,
        reports: {lcov: repoPath(cppLcovPath), summary: repoPath(cppSummaryPath)},
        lcovSha256: hash(cppLcov), totals: cppTotals,
        note: 'Standalone Access unit only; Chromium GN/GTest and full browser C++ are not measured',
      },
      python: {
        status: 'MEASURED', scopeKind: 'proxy-vector-and-upstream-tools-production', files: pythonFiles.length,
        reports: {json: repoPath(pythonJsonPath), xml: repoPath(join(coverageRoot, 'python/coverage.xml')), lcov: repoPath(pythonLcovPath)},
        totals: pythonTotals,
        note: 'Proxy and two vector generators only; prototype workers are not measured',
      },
      swift: {status: 'MANUAL_REPORTING_WORKFLOW', totals: null, note: 'Product-only xccov runs in the manual-only iOS Coverage workflow; it is outside the current Mac quality gate and Codacy conversion remains pending'},
      bash: {status: 'MANUAL_REPORTING_WORKFLOW', totals: null, note: 'Behavior tests and syntax checks exist; line coverage is produced by the Linux coverage job'},
      powershell: {status: 'MANUAL_REPORTING_WORKFLOW', totals: null, note: 'Windows Pester coverage runs separately and does not establish UI acceptance'},
      java: {status: 'MANUAL_REPORTING_WORKFLOW', totals: null, note: 'Driver.java instrumentation-helper JaCoCo runs in the manual-only Android Java Coverage workflow; it is outside the Mac quality gate and does not measure browser runtime'},
    },
    nonCodeOrUninstrumented: ['HTML', 'CSS', 'JSON/data', 'GN/GNI'],
  };
  writeFileSync(output, `${JSON.stringify(manifest, null, 2)}\n`);
  console.log(JSON.stringify(manifest));
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
