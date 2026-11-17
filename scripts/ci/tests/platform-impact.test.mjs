import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdtempSync, mkdirSync, writeFileSync, rmSync, chmodSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import test from 'node:test';
import YAML from 'yaml';
import {readFileSync} from 'node:fs';

const script = resolve('scripts/ci/platform-impact.mjs');
test('platform routing binds real merge parents and rejects hidden product changes', () => {
  const root = mkdtempSync(join(tmpdir(), 'platform-impact-'));
  const git = (...args) => execFileSync('git', args, {cwd: root, encoding: 'utf8'}).trim();
  const doc = 'docs/plans/access-build-portability/acceptance.md';
  const save = (path, text) => { mkdirSync(join(root, path, '..'), {recursive: true}); writeFileSync(join(root, path), text); };
  try {
    git('init', '-b', 'develop'); git('config', 'user.name', 'Routing Test'); git('config', 'user.email', 'routing@example.invalid');
    save(doc, 'initial'); git('add', '.'); git('commit', '-m', 'base');
    const earlierBase = git('rev-parse', 'HEAD');
    save('base-marker.txt', 'advanced base'); git('add', '.'); git('commit', '-m', 'base advanced');
    const base = git('rev-parse', 'HEAD');
    const run = (mutate, expected) => {
      git('checkout', '-B', 'topic', base); mutate(); git('add', '-A'); git('commit', '-m', 'docs: candidate');
      const head = git('rev-parse', 'HEAD');
      git('checkout', 'develop'); git('merge', '--no-ff', 'topic', '-m', 'candidate');
      const tested = git('rev-parse', 'HEAD');
      const event = join(root, 'event.json');
      writeFileSync(event, JSON.stringify({pull_request: {base: {sha: base}, head: {sha: head}}}));
      const env = {...process.env, GITHUB_EVENT_NAME: 'pull_request', GITHUB_SHA: tested, GITHUB_EVENT_PATH: event, GITHUB_OUTPUT: ''};
      const result = spawnSync(process.execPath, [script], {cwd: root, env, encoding: 'utf8'});
      assert.equal(result.status, 0, result.stderr);
      const plan = JSON.parse(result.stdout);
      assert.equal(plan.ios, expected); assert.equal(plan.base, base); assert.equal(plan.head, head); assert.equal(plan.tested, tested);
      writeFileSync(event, JSON.stringify({pull_request: {base: {sha: earlierBase}, head: {sha: head}}}));
      const stale = spawnSync(process.execPath, [script], {cwd: root, env, encoding: 'utf8'});
      assert.equal(stale.status, 0, stale.stderr);
      assert.equal(JSON.parse(stale.stdout).base, base, 'route against actual merge parent despite lagging metadata');
      writeFileSync(event, JSON.stringify({pull_request: {base: {sha: base}, head: {sha: base}}}));
      assert.notEqual(spawnSync(process.execPath, [script], {cwd: root, env}).status, 0, 'wrong head must block');
      assert.notEqual(spawnSync(process.execPath, [script], {cwd: root, env: {...env, GITHUB_SHA: base}}).status, 0, 'wrong checkout must block');
      const push = spawnSync(process.execPath, [script], {cwd: root, env: {...env, GITHUB_EVENT_NAME: 'push'}, encoding: 'utf8'});
      assert.equal(JSON.parse(push.stdout).ios, true, 'actual push retains full platform checks');
      rmSync(event); git('reset', '--hard', base);
      return plan;
    };
    run(() => save(doc, 'updated'), false);
    run(() => {save(doc, 'updated'); save('apps/ios/Feature.swift', 'invalid');}, true);
    run(() => save('unknown.file', 'unknown'), true);
    run(() => rmSync(join(root, doc)), true);
    run(() => git('mv', doc, 'docs/renamed.md'), true);
    run(() => chmodSync(join(root, doc), 0o755), true);
    run(() => save('scripts/ci/platform-impact.mjs', 'console.log("ios=false")'), true);
  } finally { rmSync(root, {recursive: true, force: true}); }
});

test('iOS archive waits for contracts and keeps failed archives out of distributable artifacts', () => {
  const workflow = YAML.parse(readFileSync('.github/workflows/ios-release-validation.yml', 'utf8'));
  assert.deepEqual(workflow.on.pull_request.branches, ['main', 'develop']);
  const job = workflow.jobs['ios-archive'];
  assert.equal(job.needs, 'contracts');
  assert.match(job.if, /needs.contracts.outputs.ios == 'true'/u);
  const uploads = job.steps.filter(step => step.uses?.startsWith('actions/upload-artifact@'));
  const archive = uploads.find(step => step.with.name.startsWith('ios-unsigned-'));
  const diagnostics = uploads.find(step => step.with.name.startsWith('ios-archive-diagnostics-'));
  assert.match(archive.if, /success\(\)/u);
  assert.match(diagnostics.if, /failure\(\)/u);
  assert(!diagnostics.with.path.includes('.xcarchive'));
  assert.match(workflow.concurrency.group, /github.sha/u);
});
