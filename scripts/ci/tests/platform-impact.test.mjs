import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdtempSync, mkdirSync, writeFileSync, rmSync, chmodSync, symlinkSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import test from 'node:test';
import YAML from 'yaml';
import {readFileSync} from 'node:fs';

const script = resolve('scripts/ci/platform-impact.mjs');
const routeDefaultSource = readFileSync('scripts/ci/fill-platform-route-defaults.mjs', 'utf8');
const assertTrustedRouteDefaults = run => {
  assert.match(run, /git show "\$ROUTE_BASE_SHA:scripts\/ci\/platform-impact\.mjs"/u);
  assert.match(run, /git show "\$ROUTE_BASE_SHA:scripts\/ci\/fill-platform-route-defaults\.mjs" > "\$RUNNER_TEMP\/fill-platform-route-defaults\.mjs"/u);
  assert.match(run, /node "\$RUNNER_TEMP\/fill-platform-route-defaults\.mjs"/u);
  assert.doesNotMatch(run, /node scripts\/ci\/fill-platform-route-defaults\.mjs/u);
  const fallback = run.match(/<<'EOF'\n([\s\S]*?)\nEOF/u);
  assert.ok(fallback, 'workflow must embed the trusted fallback');
  assert.equal(`${fallback[1]}\n`, routeDefaultSource);
};
test('platform routing binds real merge parents and rejects hidden product changes', () => {
  const root = mkdtempSync(join(tmpdir(), 'platform-impact-'));
  const git = (...args) => execFileSync('git', args, {cwd: root, encoding: 'utf8'}).trim();
  const doc = 'docs/plans/access-build-portability/acceptance.md';
  const iosDocs = ['en', 'zh-CN', 'zh-TW'].map(language => `docs/ios-webkit-protection.${language}.md`);
  const macDocs = ['toolbar-bubble', 'bubble-session'].map(topic => `docs/plans/macos-access-${topic}-NOTES.md`);
  const executableDocs = [
    'docs/plans/access-service-v1.0/spec.zh-CN.md',
    'docs/platform-features.zh-CN.md',
    'docs/audit/evidence/macos-access-product-phase1/README.md',
    'docs/audit/evidence/ios-access-product-phase1/correlation.md',
    'docs/plans/access-service-v1.0/interaction-example.html',
    'apps/browser/scripts/testdata/translation-quality/long-v1.json',
    'docs/unregistered-explanation.md',
  ];
  const save = (path, text) => { mkdirSync(join(root, path, '..'), {recursive: true}); writeFileSync(join(root, path), text); };
  try {
    git('init', '-b', 'develop'); git('config', 'user.name', 'Routing Test'); git('config', 'user.email', 'routing@example.invalid');
    for (const path of [doc, ...iosDocs, ...macDocs, ...executableDocs]) save(path, 'initial');
    git('add', '.'); git('commit', '-m', 'base');
    const earlierBase = git('rev-parse', 'HEAD');
    save('base-marker.txt', 'advanced base'); git('add', '.'); git('commit', '-m', 'base advanced');
    let base = git('rev-parse', 'HEAD');
    const closed = {docs: false, ios: false, android: false, macos: false, windows: false, linux: false};
    const documented = {...closed, docs: true, integrate: false, deep: false};
    const strictClosed = {...closed, integrate: true, deep: true};
    const run = (mutate, expected, message = 'docs: candidate') => {
      git('checkout', '-B', 'topic', base); mutate(); git('add', '-A'); git('commit', '-m', message);
      const head = git('rev-parse', 'HEAD');
      git('checkout', 'develop'); git('merge', '--no-ff', 'topic', '-m', 'candidate');
      const tested = git('rev-parse', 'HEAD');
      const event = join(root, 'event.json');
      writeFileSync(event, JSON.stringify({pull_request: {base: {sha: base}, head: {sha: head}}}));
      const env = {...process.env, CI_LIGHTWEIGHT_ADMITTED: 'true', GITHUB_EVENT_NAME: 'pull_request', GITHUB_SHA: tested, GITHUB_EVENT_PATH: event, GITHUB_OUTPUT: ''};
      const result = spawnSync(process.execPath, [script], {cwd: root, env, encoding: 'utf8'});
      assert.equal(result.status, 0, result.stderr);
      const plan = JSON.parse(result.stdout);
      assert.equal(plan.schemaVersion, 2);
      for (const [key, value] of Object.entries(expected)) assert.equal(plan[key], value, `${key} (${message})`);
      assert.equal(plan.base, base); assert.equal(plan.head, head); assert.equal(plan.tested, tested);
      if (expected.docs === true) {
        const unadmitted = spawnSync(process.execPath, [script], {cwd: root, env: {...env, CI_LIGHTWEIGHT_ADMITTED: 'false'}, encoding: 'utf8'});
        assert.equal(JSON.parse(unadmitted.stdout).docs, false, 'outside the trusted fork rollout retain full quality');
        assert.equal(JSON.parse(unadmitted.stdout).ios, false, 'unadmitted explanations still do not open iOS');
      }
      writeFileSync(event, JSON.stringify({pull_request: {base: {sha: earlierBase}, head: {sha: head}}}));
      const stale = spawnSync(process.execPath, [script], {cwd: root, env, encoding: 'utf8'});
      assert.equal(stale.status, 0, stale.stderr);
      assert.equal(JSON.parse(stale.stdout).base, base, 'route against actual merge parent despite lagging metadata');
      writeFileSync(event, JSON.stringify({pull_request: {base: {sha: base}, head: {sha: base}}}));
      assert.notEqual(spawnSync(process.execPath, [script], {cwd: root, env}).status, 0, 'wrong head must block');
      assert.notEqual(spawnSync(process.execPath, [script], {cwd: root, env: {...env, GITHUB_SHA: base}}).status, 0, 'wrong checkout must block');
      const push = spawnSync(process.execPath, [script], {cwd: root, env: {...env, GITHUB_EVENT_NAME: 'push'}, encoding: 'utf8'});
      const pushed = JSON.parse(push.stdout);
      assert.equal(pushed.ios, true, 'push without a before SHA retains iOS');
      assert.equal(pushed.macos, true, 'push without a before SHA retains macOS');
      assert.equal(pushed.android, false, 'legacy push must not open Android');
      assert.equal(pushed.windows, false, 'legacy push must not open Windows');
      assert.equal(pushed.linux, false, 'legacy push must not open Linux');
      assert.equal(pushed.docs, false);
      assert.equal(pushed.integrate, true);
      assert.equal(pushed.deep, true);
      rmSync(event); git('reset', '--hard', base);
      return plan;
    };
    run(() => save(doc, 'updated'), documented);
    for (const path of [...iosDocs, ...macDocs]) {
      run(() => save(path, 'updated'), documented);
      run(() => rmSync(join(root, path)), strictClosed);
      run(() => chmodSync(join(root, path), 0o755), strictClosed);
      run(() => {rmSync(join(root, path)); symlinkSync('untrusted.md', join(root, path));}, strictClosed);
      run(() => git('mv', path, 'docs/unregistered-renamed.md'), {...closed, macos: true, integrate: true, deep: true});
    }
    run(() => { for (const path of [doc, ...iosDocs, ...macDocs]) save(path, 'updated'); }, documented);
    for (const path of executableDocs) {
      const plan = run(() => {save(iosDocs[0], 'updated'); save(path, 'changed input');}, {...closed, macos: true, integrate: false, deep: false});
      assert.equal(plan.macos, true, `unregistered or consumed document keeps the macOS contract route: ${path}`);
      assert.equal(plan.ios, false, `unregistered document must not open iOS archive: ${path}`);
    }
    run(() => {save(iosDocs[0], 'updated'); save('scripts/ci/platform-impact.mjs', 'console.log("docs=true")');}, {docs: false, ios: true, android: true, macos: true, windows: true, linux: true, integrate: true, deep: true});
    run(() => {save(iosDocs[0], 'updated'); save('docs/ios-webkit-protection.new.md', 'new explanation');}, {...closed, macos: true, integrate: false, deep: false});
    run(() => {save(macDocs[0], 'updated'); save('docs/plans/macos-access-phase1-evidence-NOTES.md', 'unreviewed neighbor');}, {...closed, macos: true, integrate: false, deep: false});
    run(() => git('mv', '-f', iosDocs[0], iosDocs[1]), strictClosed);
    run(() => {save(doc, 'updated'); save('apps/ios/Feature.swift', 'invalid');}, {...closed, ios: true, integrate: false, deep: false});
    const iosOnly = run(() => save('apps/ios/Feature.swift', 'feature'), {...closed, ios: true, integrate: false, deep: false});
    assert.equal(iosOnly.macos, false);
    run(() => save('unknown.file', 'unknown'), {...closed, macos: true, integrate: false, deep: false});
    run(() => rmSync(join(root, doc)), strictClosed);
    run(() => git('mv', doc, 'docs/renamed.md'), {...closed, macos: true, integrate: true, deep: true});
    run(() => chmodSync(join(root, doc), 0o755), strictClosed);
    run(() => save('scripts/ci/platform-impact.mjs', 'console.log("ios=false")'), {docs: false, ios: true, android: true, macos: true, windows: true, linux: true, integrate: true, deep: true});
    git('rm', iosDocs[0]); git('commit', '-m', 'remove explanation from base');
    base = git('rev-parse', 'HEAD');
    run(() => save(iosDocs[0], 'new registered path'), {...closed, integrate: false, deep: false});
  } finally { rmSync(root, {recursive: true, force: true}); }
});

test('paths select platforms and commit types select stage depth', () => {
  const root = mkdtempSync(join(tmpdir(), 'platform-route-'));
  const git = (...args) => execFileSync('git', args, {cwd: root, encoding: 'utf8'}).trim();
  const save = (path, text) => { mkdirSync(join(root, path, '..'), {recursive: true}); writeFileSync(join(root, path), text); };
  const planFor = env => {
    const result = spawnSync(process.execPath, [script], {cwd: root, env: {...process.env, CI_LIGHTWEIGHT_ADMITTED: 'true', GITHUB_OUTPUT: '', ...env}, encoding: 'utf8'});
    assert.equal(result.status, 0, result.stderr);
    return JSON.parse(result.stdout);
  };
  try {
    git('init', '-b', 'develop'); git('config', 'user.name', 'Routing Test'); git('config', 'user.email', 'routing@example.invalid');
    save('README.md', 'base');
    save('docs/ios-webkit-protection.en.md', 'initial');
    git('add', '.'); git('commit', '-m', 'base');
    const before = git('rev-parse', 'HEAD');
    const pr = (mutate, message) => {
      git('checkout', '-B', 'topic', before); mutate(); git('add', '-A'); git('commit', '-m', message);
      const head = git('rev-parse', 'HEAD');
      git('checkout', 'develop'); git('merge', '--no-ff', 'topic', '-m', 'candidate');
      const tested = git('rev-parse', 'HEAD');
      const event = join(root, 'event.json');
      writeFileSync(event, JSON.stringify({pull_request: {base: {sha: before}, head: {sha: head}}}));
      const plan = planFor({GITHUB_EVENT_NAME: 'pull_request', GITHUB_SHA: tested, GITHUB_EVENT_PATH: event});
      rmSync(event); git('reset', '--hard', before);
      return plan;
    };
    const feature = pr(() => save('apps/ios/Feature.swift', 'feature'), 'feat(ios): add feature');
    assert.equal(feature.ios, true); assert.equal(feature.macos, false); assert.equal(feature.integrate, true); assert.equal(feature.deep, true);
    const tested = pr(() => save('apps/ios/FeatureTests.swift', 'test'), 'test(ios): cover feature');
    assert.equal(tested.integrate, true); assert.equal(tested.deep, false);
    const chore = pr(() => save('apps/ios/Notes.swift', 'chore'), 'chore(ios): tidy');
    assert.equal(chore.ios, true); assert.equal(chore.integrate, false); assert.equal(chore.deep, false);
    const android = pr(() => save('apps/browser/patches-android/change.patch', 'android'), 'fix: repair android');
    assert.equal(android.android, true); assert.equal(android.ios, false); assert.equal(android.macos, false); assert.equal(android.deep, true);
    const windows = pr(() => save('scripts/ci/platform-tests/windows-acceptance.ps1', 'win'), 'perf: speed windows');
    assert.equal(windows.windows, true); assert.equal(windows.macos, false); assert.equal(windows.deep, true);
    const linux = pr(() => save('scripts/ci/platform-tests/kcov-child.sh', 'kcov'), 'refactor: reshape coverage');
    assert.equal(linux.linux, true); assert.equal(linux.macos, false); assert.equal(linux.deep, true);
    const shared = pr(() => save('packages/core/src/core.ts', 'core'), 'build: refresh core');
    assert.equal(shared.macos, true); assert.equal(shared.ios, false); assert.equal(shared.android, false); assert.equal(shared.windows, false);
    git('checkout', '-B', 'topic', before);
    save('apps/ios/Feature.swift', 'one'); git('add', '-A'); git('commit', '-m', 'chore: first');
    save('apps/ios/Feature.swift', 'two'); git('add', '-A'); git('commit', '-m', 'feat: second');
    const head = git('rev-parse', 'HEAD');
    git('checkout', 'develop'); git('merge', '--no-ff', 'topic', '-m', 'candidate');
    const mixedEvent = join(root, 'event.json');
    writeFileSync(mixedEvent, JSON.stringify({pull_request: {base: {sha: before}, head: {sha: head}}}));
    const mixed = planFor({GITHUB_EVENT_NAME: 'pull_request', GITHUB_SHA: git('rev-parse', 'HEAD'), GITHUB_EVENT_PATH: mixedEvent});
    assert.equal(mixed.deep, true, 'mixed types take the stricter stage');
    assert.deepEqual(mixed.types, ['chore', 'feat']);
    rmSync(mixedEvent); git('reset', '--hard', before);
    const loose = pr(() => save('apps/ios/Feature.swift', 'loose'), 'update the feature');
    assert.equal(loose.strict, true); assert.equal(loose.deep, true); assert.equal(loose.ios, true);
    git('checkout', 'develop');
    save('apps/ios/Push.swift', 'push'); git('add', '-A'); git('commit', '-m', 'chore: push ios');
    const pushed = git('rev-parse', 'HEAD');
    const ranged = planFor({GITHUB_EVENT_NAME: 'push', GITHUB_SHA: pushed, ROUTE_PUSH_BEFORE: before});
    assert.equal(ranged.base, before); assert.equal(ranged.ios, true); assert.equal(ranged.macos, false); assert.equal(ranged.deep, true); assert.equal(ranged.docs, false);
    git('reset', '--hard', before);
    save('docs/ios-webkit-protection.en.md', 'updated'); git('add', '-A'); git('commit', '-m', 'docs: explain');
    const docsPush = git('rev-parse', 'HEAD');
    const docsPlan = planFor({GITHUB_EVENT_NAME: 'push', GITHUB_SHA: docsPush, ROUTE_PUSH_BEFORE: before});
    assert.equal(docsPlan.docs, false, 'push does not take the lightweight docs route');
    assert.equal(docsPlan.ios, false); assert.equal(docsPlan.macos, false);
    const legacy = planFor({GITHUB_EVENT_NAME: 'push', GITHUB_SHA: docsPush, ROUTE_PUSH_BEFORE: '0'.repeat(40)});
    assert.equal(legacy.reason, 'full-platform-fallback');
    assert.equal(legacy.ios, true); assert.equal(legacy.macos, true); assert.equal(legacy.android, false);
    const dispatch = planFor({GITHUB_EVENT_NAME: 'workflow_dispatch', GITHUB_SHA: docsPush});
    assert.equal(dispatch.ios, true); assert.equal(dispatch.macos, true); assert.equal(dispatch.android, false); assert.equal(dispatch.deep, true);
  } finally { rmSync(root, {recursive: true, force: true}); }
});

test('missing route keys default without overriding an explicit false', () => {
  const root = mkdtempSync(join(tmpdir(), 'route-defaults-'));
  const fill = resolve('scripts/ci/fill-platform-route-defaults.mjs');
  const output = join(root, 'output');
  const planPath = join(root, 'plan.json');
  try {
    writeFileSync(output, 'ios=true\nandroid=false\nintegrate=false\n');
    writeFileSync(planPath, JSON.stringify({ios: true, android: false, integrate: false}));
    const filled = spawnSync(process.execPath, [fill, planPath], {env: {...process.env, GITHUB_OUTPUT: output, ROUTE_DEFAULT_MISSING_MACOS: 'true'}, encoding: 'utf8'});
    assert.equal(filled.status, 0, filled.stderr);
    const text = readFileSync(output, 'utf8');
    assert.match(text, /^android=false$/m);
    assert.match(text, /^integrate=false$/m);
    assert.match(text, /^macos=true$/m);
    assert.match(text, /^windows=false$/m);
    assert.match(text, /^linux=false$/m);
    assert.match(text, /^deep=true$/m);
    assert.equal(JSON.parse(readFileSync(planPath, 'utf8')).platformReason, 'missing-platform-rule-default');
    const complete = ['docs=false', 'ios=false', 'android=false', 'macos=false', 'windows=false', 'linux=false', 'integrate=false', 'deep=false'].join('\n') + '\n';
    writeFileSync(output, complete);
    writeFileSync(planPath, JSON.stringify({android: false, integrate: false, deep: false}));
    const kept = spawnSync(process.execPath, [fill, planPath], {env: {...process.env, GITHUB_OUTPUT: output, ROUTE_DEFAULT_MISSING_MACOS: 'true', ROUTE_DEFAULT_MISSING_IOS: 'true'}, encoding: 'utf8'});
    assert.equal(kept.status, 0, kept.stderr);
    assert.equal(readFileSync(output, 'utf8'), complete);
    assert.equal(JSON.parse(readFileSync(planPath, 'utf8')).platformReason, undefined);
  } finally { rmSync(root, {recursive: true, force: true}); }
});

test('iOS archive waits for contracts and keeps failed archives out of distributable artifacts', () => {
  const workflow = YAML.parse(readFileSync('.github/workflows/ios-release-validation.yml', 'utf8'));
  assert.deepEqual(workflow.on.pull_request.branches, ['main', 'develop']);
  const job = workflow.jobs['ios-archive'];
  assert.deepEqual(job.needs, ['impact', 'contracts']);
  assert.equal(workflow.jobs.contracts.needs, 'impact');
  assert.match(workflow.jobs.impact.if, /inputs.exercise != 'cloud-poc'/u);
  assert.match(workflow.jobs.contracts.if, /needs.impact.outputs.ios == 'true'/u);
  assert.match(workflow.jobs.contracts.if, /needs.impact.outputs.integrate == 'true'/u);
  assert.match(workflow.jobs.contracts.if, /needs.impact.result == 'success'/u);
  assert.match(job.if, /needs.contracts.result == 'success'/u);
  assert.match(job.if, /needs.impact.outputs.deep == 'true'/u);
  assert.match(job.if, /github.event_name == 'workflow_dispatch'/u);
  const uploads = job.steps.filter(step => step.uses?.startsWith('actions/upload-artifact@'));
  const archive = uploads.find(step => step.with.name.startsWith('ios-unsigned-'));
  const diagnostics = uploads.find(step => step.with.name.startsWith('ios-archive-diagnostics-'));
  assert.match(archive.if, /success\(\)/u);
  assert.match(diagnostics.if, /failure\(\)/u);
  assert(!diagnostics.with.path.includes('.xcarchive'));
  assert.match(workflow.concurrency.group, /github.sha/u);
  assertTrustedRouteDefaults(workflow.jobs.impact.steps.find(step => step.id === 'impact').run);
});


test('macOS automatic contracts wait for trusted routing and exclude Draft or manual jobs', () => {
  const workflow = YAML.parse(readFileSync('.github/workflows/macos-delivery.yml', 'utf8'));
  const {impact, contracts, admission, package: packaging} = workflow.jobs;
  assert.equal(contracts.needs, 'impact');
  assert.match(contracts.if, /needs.impact.outputs.macos == 'true'/u);
  assert.match(contracts.if, /needs.impact.outputs.integrate == 'true'/u);
  assert.match(contracts.if, /needs.impact.result == 'success'/u);
  for (const job of [impact, contracts]) {
    assert.match(job.if, /toJSON\(github.event.pull_request.draft\) == 'false'/u);
    assert.match(job.if, /github.event_name != 'workflow_dispatch'/u);
  }
  assert(workflow.on.pull_request.types.includes('converted_to_draft'));
  assert.match(workflow.concurrency.group, /github.sha/u);
  assert.equal(workflow.concurrency['cancel-in-progress'], "${{ github.event_name == 'pull_request' }}");
  assert.match(admission.if, /workflow_dispatch/u);
  assert.deepEqual(packaging.needs, ['admission', 'access-tests']);
  const run = impact.steps.find(step => step.id === 'impact').run;
  assertTrustedRouteDefaults(run);
  assert.doesNotMatch(run, /echo 'macos=true'/u);
  assert.equal(impact.steps.find(step => step.id === 'impact').env.ROUTE_DEFAULT_MISSING_MACOS, 'true');
  assert.equal(impact.outputs.integrate, '${{ steps.impact.outputs.integrate }}');
});


test('quality preflight selects Linux docs and preserves full checks on all other routes', () => {
  const workflow = YAML.parse(readFileSync('.github/workflows/quality.yml', 'utf8'));
  const {impact, quality, 'quality-summary': summary} = workflow.jobs;
  assert.equal(impact['runs-on'], 'ubuntu-24.04');
  assert.equal(quality.needs, 'impact');
  assert.match(quality['runs-on'], /needs.impact.outputs.docs == 'true' && 'ubuntu-24.04'/u);
  assert.equal(summary['runs-on'], 'ubuntu-24.04');
  const admission = impact.steps.find(step => step.id === 'impact').env.CI_LIGHTWEIGHT_ADMITTED;
  for (const requirement of ["base.ref == 'develop'", 'head.repo.full_name == github.repository', 'github.repository == vars.AEGIS_SELF_HOSTED_TEST_REPOSITORY']) assert(admission.includes(requirement));
  const heavy = quality.steps.find(step => step.name === 'Run full quality gate');
  const docs = quality.steps.find(step => step.name === 'Run documentation quality gate');
  assert.equal(heavy.if, "${{ needs.impact.outputs.docs != 'true' }}");
  assert.equal(docs.if, "${{ needs.impact.outputs.docs == 'true' }}");
  assert.match(docs.run, /node scripts\/check-repo-contracts.mjs/u);
  assert.match(workflow.concurrency.group, /github.ref, github.sha/u);
  const other = workflow.jobs['other-platforms'];
  assert.equal(other['runs-on'], 'ubuntu-24.04');
  assert.deepEqual(other.needs, ['impact', 'quality']);
  assert.match(other.if, /needs.quality.result == 'success'/u);
  assert.match(other.if, /needs.impact.outputs.android == 'true'/u);
  assert.match(other.if, /needs.impact.outputs.windows == 'true'/u);
  assert.match(other.if, /needs.impact.outputs.integrate == 'true'/u);
  assert.match(other.steps.find(step => step.name === 'Run Android and Windows contract checks').run, /pnpm run quality:other-platforms/u);
  assert.equal(summary.steps.find(step => step.name === 'Require every mandatory job to succeed').env.REQUIRED_RESULTS, '{"quality":"${{ needs.quality.result }}"}');
  assert.equal(impact.outputs.android, '${{ steps.impact.outputs.android }}');
  assertTrustedRouteDefaults(impact.steps.find(step => step.id === 'impact').run);
});

test('archive compiler diagnostics reach Actions and retain exit status before sealing', () => {
  const workflow = YAML.parse(readFileSync('.github/workflows/ios-release-validation.yml', 'utf8'));
  const step = workflow.jobs['ios-archive'].steps.find(item => item.name === 'Compile uncredentialed native archive');
  const root = mkdtempSync(join(tmpdir(), 'archive-diagnostics-'));
  const bin = join(root, 'bin');
  const trace = join(root, 'python-calls.txt');
  mkdirSync(bin);
  writeFileSync(join(bin, 'python3'), '#!/bin/bash\nprintf "%s\\n" "$*" >> "$ARCHIVE_TEST_TRACE"\n');
  writeFileSync(join(bin, 'xcodebuild'), '#!/bin/bash\nprintf "archive-compiler-diagnostic\\n" >&2\nexit "$ARCHIVE_TEST_EXIT"\n');
  chmodSync(join(bin, 'python3'), 0o755);
  chmodSync(join(bin, 'xcodebuild'), 0o755);
  try {
    for (const exitCode of [65, 0]) {
      writeFileSync(trace, '');
      const result = spawnSync('bash', ['-e', '-c', step.run], {encoding: 'utf8', env: {
        ...process.env, PATH: `${bin}:${process.env.PATH}`, IOS_CI_ROOT: root,
        ARCHIVE_TEST_TRACE: trace, ARCHIVE_TEST_EXIT: String(exitCode),
      }});
      assert.equal(result.status, exitCode, result.stderr);
      assert.match(result.stdout + result.stderr, /archive-compiler-diagnostic/u);
      assert.match(readFileSync(join(root, 'xcodebuild.log'), 'utf8'), /archive-compiler-diagnostic/u);
      const calls = readFileSync(trace, 'utf8');
      assert.equal(calls.includes('verify-ios-archive.py'), exitCode === 0);
      assert.equal(calls.includes('ios-ci-storage.py seal'), exitCode === 0);
    }
  } finally { rmSync(root, {recursive: true, force: true}); }
});

test('archive package resolution inherits the existing GitHub transport policy', () => {
  const workflow = YAML.parse(readFileSync('.github/workflows/ios-release-validation.yml', 'utf8'));
  const step = workflow.jobs['ios-archive'].steps.find(item => item.name === 'Compile uncredentialed native archive');
  const root = mkdtempSync(join(tmpdir(), 'archive-git-policy-'));
  const bin = join(root, 'bin');
  mkdirSync(bin);
  const trace = join(root, 'git-policy.txt');
  const args = join(root, 'xcode-args.txt');
  const config = join(root, 'gitconfig');
  writeFileSync(config, '[http]\n proxy = http://127.0.0.1:9\n[credential]\n helper = retained-fixture-helper\n');
  const executables = {
    python3: '#!/bin/bash\nexit 0\n',
    scutil: '#!/bin/bash\nexit 0\n',
    xcodebuild: `#!/bin/bash
printf 'proxy=%s\\n' "$(git config --get-urlmatch http.proxy https://github.com/firebase/firebase-ios-sdk.git)" > "$ARCHIVE_TEST_TRACE"
printf 'http=%s\\n' "$(git config --get http.version)" >> "$ARCHIVE_TEST_TRACE"
printf 'credential=%s\\n' "$(git config --get credential.helper)" >> "$ARCHIVE_TEST_TRACE"
printf 'prompt=%s\\n' "\${GIT_TERMINAL_PROMPT-}" >> "$ARCHIVE_TEST_TRACE"
printf 'bypass=%s\\n' "\${NO_PROXY-}" >> "$ARCHIVE_TEST_TRACE"
printf '%s\\n' "$*" > "$ARCHIVE_TEST_ARGS"
exit 65
`,
  };
  for (const [name, body] of Object.entries(executables)) {
    writeFileSync(join(bin, name), body); chmodSync(join(bin, name), 0o755);
  }
  try {
    const environment = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_CONFIG_')));
    const result = spawnSync('bash', ['-e', '-c', step.run], {encoding: 'utf8', env: {
      ...environment, PATH: `${bin}:${process.env.PATH}`, IOS_CI_ROOT: root,
      GIT_CONFIG_GLOBAL: config, GIT_CONFIG_NOSYSTEM: '1',
      ARCHIVE_TEST_TRACE: trace, ARCHIVE_TEST_ARGS: args,
    }});
    assert.equal(result.status, 65, result.stderr);
    const policy = readFileSync(trace, 'utf8');
    assert.match(policy, /^proxy=$/mu);
    assert.match(policy, /^http=HTTP\/1\.1$/mu);
    assert.match(policy, /^credential=retained-fixture-helper$/mu);
    assert.match(policy, /^prompt=0$/mu);
    assert.match(policy, /bypass=.*github\.com/u);
    assert.match(readFileSync(args, 'utf8'), /-scmProvider system/u);
    assert.equal(readFileSync(config, 'utf8'), '[http]\n proxy = http://127.0.0.1:9\n[credential]\n helper = retained-fixture-helper\n');
  } finally { rmSync(root, {recursive: true, force: true}); }
});
