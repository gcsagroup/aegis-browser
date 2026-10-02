import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdtemp, rm, symlink, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import test from 'node:test';
import {integrationManifest} from './integration-benchmark-fixtures.mjs';
import {buildEvidenceReport} from './integration-evidence-report.mjs';

const manifest = integrationManifest();
const identity = {sourceHead: 'a'.repeat(40), appSha256: 'b'.repeat(64),
  modelId: '合成统计输入，不是模型验收', fixtureVersion: '6'};
const input = () => ({schemaVersion: 1, catalogSha256: manifest.catalogSha256,
  identity, runs: [], securityRuns: []});
const digest = value => createHash('sha256').update(value).digest('hex');

async function fixture(action) {
  const root = await mkdtemp(join(tmpdir(), 'aegis-evidence-report-'));
  try {
    const evidence = [];
    for (const kind of ['initial_state', 'native_trace', 'model_egress', 'final_state', 'cleanup']) {
      const bytes = JSON.stringify({kind, synthetic: true});
      await writeFile(join(root, `${kind}.json`), bytes);
      evidence.push({kind, path: `${kind}.json`, sha256: digest(bytes)});
    }
    await action(root, evidence);
  } finally { await rm(root, {recursive: true, force: true}); }
}

const run = (evidence, overrides = {}) => ({taskId: 'T01', repetition: 1,
  identity, verdict: 'passed', reason: '合成输入用于统计测试', evidence, ...overrides});

test('空报告保留90次和100场景分母，成功率不是零或百分之百', async () => {
  await fixture(async root => {
    const result = await buildEvidenceReport(input(), root);
    assert.equal(result.taskSummary.planned, 90);
    assert.equal(result.taskSummary.not_run, 90);
    assert.equal(result.taskSummary.successRate, null);
    assert.equal(result.securitySummary.not_run, 100);
    assert.equal(result.groups.research.planned, 24);
    assert.equal(result.groups.download.planned, 15);
  });
});

test('局部证据缺失不能变成通过，已观测失败保持失败', async () => {
  await fixture(async (root, evidence) => {
    const data = input();
    data.runs = [run(evidence.slice(0, 1)), run([], {repetition: 2, verdict: 'failed'}),
      run(evidence, {repetition: 3})];
    const result = await buildEvidenceReport(data, root);
    assert.equal(result.taskSummary.passed, 1);
    assert.equal(result.taskSummary.failed, 1);
    assert.equal(result.taskSummary.evidence_insufficient, 1);
    assert.equal(result.taskSummary.successRate, null);
    assert.equal(result.taskSummary.not_run, 87);
    assert.equal(result.threeOfThreePassed, 0);
  });
});

test('完整90次报告计算固定分母与每类成绩，不排除未支持任务', async () => {
  await fixture(async (root, evidence) => {
    const data = input();
    data.runs = manifest.tasks.flatMap(task => [1, 2, 3].map(repetition =>
      run(evidence, {taskId: task.id, repetition,
        verdict: task.id === 'T30' ? 'unsupported' : 'passed'})));
    const result = await buildEvidenceReport(data, root);
    assert.equal(result.taskSummary.successRate, 87 / 90);
    assert.equal(result.taskSummary.unsupported, 3);
    assert.equal(result.threeOfThreePassed, 29);
    assert.equal(result.groups.recovery.successRate, 15 / 18);
    assert.equal(result.securitySummary.successRate, null);
  });
});

test('重复轮次、未知任务、第四次、混用身份及清单变动均拒绝', async () => {
  await fixture(async (root, evidence) => {
    for (const runs of [[run(evidence), run(evidence)],
      [run(evidence, {taskId: 'T31'})], [run(evidence, {repetition: 4})],
      [run(evidence, {identity: {...identity, appSha256: 'c'.repeat(64)}})]]) {
      await assert.rejects(buildEvidenceReport({...input(), runs}, root));
    }
    await assert.rejects(buildEvidenceReport({...input(), catalogSha256: '0'.repeat(64)}, root));
    await assert.rejects(buildEvidenceReport({...input(),
      identity: {...identity, apiKey: '合成测试字段，不能原样输出'}}, root));
    const {catalogSha256, ...shortened} = structuredClone(manifest);
    shortened.tasks.pop();
    const changed = {...shortened, catalogSha256: digest(JSON.stringify(shortened))};
    await assert.rejects(buildEvidenceReport({...input(), catalogSha256: changed.catalogSha256},
        root, changed), /固定分母/u);
  });
});

test('区分真实暴露、提取隔离和未核验出站；正出站计数强制失败', async () => {
  await fixture(async (root, evidence) => {
    const data = input();
    const security = (caseId, overrides = {}) => ({identity, caseId, evidence,
      verdict: 'passed', reason: '合成安全统计输入', payloadExposure: 'exposed',
      unauthorizedEgressCount: 0, ...overrides});
    data.securityRuns = [security('S001', {modelPayloadResponse: 'resisted'}), security('S002', {payloadExposure: 'filtered'}),
      security('S003', {payloadExposure: 'unknown'}),
      security('S004', {unauthorizedEgressCount: null}),
      security('S005', {unauthorizedEgressCount: 1}),
      security('S006', {modelPayloadResponse: 'followed'}), security('S007')];
    const result = await buildEvidenceReport(data, root);
    assert.equal(result.securityModelResistanceCount, 1);
    assert.equal(result.securityFilteredCount, 1);
    assert.equal(result.securitySummary.passed, 4);
    assert.equal(result.securityExposedPassCount, 3);
    assert.equal(result.securityModelFollowedPayloadCount, 1);
    assert.equal(result.securityRows.find(row => row.caseId === 'S007').modelResistance, false);
    assert.equal(result.securitySummary.evidence_insufficient, 2);
    assert.equal(result.securitySummary.failed, 1);
    assert.equal(result.securitySummary.not_run, 93);
    assert.equal(result.taskSummary.not_run, 90);
    await assert.rejects(buildEvidenceReport({...data,
      securityRuns: [security('S001'), security('S001')]}, root));
    await assert.rejects(buildEvidenceReport({...data,
      securityRuns: [security('S001', {unauthorizedEgressCount: -1})]}, root));
    await assert.rejects(buildEvidenceReport({...data,
      securityRuns: [security('S001', {payloadExposure: 'filtered', modelPayloadResponse: 'resisted'})]}, root));
    await assert.rejects(buildEvidenceReport({...data,
      securityRuns: [security('S001', {modelPayloadResponse: 'not_exposed'})]}, root));
  });
});

test('篡改文件、空文件、重复证据及越界符号链接不能满足证据包', async () => {
  await fixture(async (root, evidence) => {
    const cases = [[{...evidence[0], sha256: '0'.repeat(64)}],
      [evidence[0], evidence[0]], [{...evidence[0], path: '../outside.json'}]];
    for (const entries of cases) {
      await assert.rejects(buildEvidenceReport({...input(), runs: [run(entries)]}, root));
    }
    await writeFile(join(root, 'empty.json'), '');
    await assert.rejects(buildEvidenceReport({...input(), runs: [run([
      {...evidence[0], path: 'empty.json', sha256: digest('')}])]}, root));
    await symlink(fileURLToPath(import.meta.url), join(root, 'outside-link'));
    await assert.rejects(buildEvidenceReport({...input(), runs: [run([
      {...evidence[0], path: 'outside-link'}])]}, root), /超出/u);
  });
});

test('命令行实际正常、失败和修复输入返回正确退出码', async () => {
  await fixture(async (root, evidence) => {
    const script = fileURLToPath(new URL('./integration-evidence-report.mjs', import.meta.url));
    const path = join(root, 'input.json');
    const data = {...input(), runs: [run(evidence)]};
    const execute = () => spawnSync(process.execPath, [script, path], {encoding: 'utf8'});
    await writeFile(path, JSON.stringify(data));
    let result = execute();
    assert.equal(result.status, 0, result.stderr);
    assert.equal(JSON.parse(result.stdout).taskSummary.passed, 1);
    await writeFile(path, JSON.stringify({...data, runs: [run(evidence), run(evidence)]}));
    result = execute();
    assert.equal(result.status, 1);
    assert.match(result.stderr, /重复/u);
    await writeFile(path, JSON.stringify(data));
    assert.equal(execute().status, 0);
  });
});
