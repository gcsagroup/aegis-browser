import assert from 'node:assert/strict';
import test from 'node:test';
import {copyFileSync, existsSync, readFileSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync} from 'node:fs';
import {execFileSync, spawnSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {parse} from 'yaml';
import {runInNewContext} from 'node:vm';

const sha = 'a'.repeat(40);
const repository = 'gcsagroup/aegis-browser';
const environment = {GH_TOKEN: 'fixture', GITHUB_ACTIONS: 'true', GITHUB_REPOSITORY: repository,
  GITHUB_REPOSITORY_ID: '1348409663', GITHUB_SHA: sha, GITHUB_REF: 'refs/heads/main',
  GITHUB_EVENT_NAME: 'workflow_dispatch', AEGIS_IOS_RELEASE_ENABLED: 'true', RELEASE_DESTINATION: 'artifacts'};
const load = async () => {
  const {iosReleasePreflight: preflight} = await import('../ios-release-preflight.mjs');
  return {iosReleasePreflight: (source, options) => preflight(source, {authorize: async () => true, ...options})};
};

test('private Beta inputs stay in the protected manual package step', () => {
  const workflow = parse(readFileSync('.github/workflows/ios-delivery.yml', 'utf8'));
  const job = workflow.jobs['ios-package'];
  assert.equal(job.environment, 'aegis-ios-signing');
  const step = job.steps.find(item => item.id === 'package');
  for (const name of ['AEGIS_IOS_TEST_NODE_BASE64', 'AEGIS_IOS_TEST_SUBSCRIPTION_BASE64']) {
    const expression = step.env[name];
    assert(expression.includes("outputs.profile == 'beta'"));
    assert(expression.includes("outputs.signing_mode == 'manual'"));
    assert(expression.includes("outputs.private_beta == 'true'"));
    assert(expression.endsWith("|| '' }}"));
    assert(!JSON.stringify({...job, steps: job.steps.filter(item => item !== step)}).includes(name));
    for (const [id, other] of Object.entries(workflow.jobs)) {
      if (id === 'private-alpha') {
        assert(!JSON.stringify({...other, steps: other.steps.filter(item => item.id !== 'inputs')}).includes(name));
      } else if (id !== 'ios-package') {
        assert(!JSON.stringify(other).includes(name));
      }
    }
  }
});

test('private Alpha hands off to the protected store without publishing artifacts', context => {
  const simple = parse(readFileSync('.github/workflows/ios-delivery.yml', 'utf8'));
  const full = parse(readFileSync('.github/workflows/ios-delivery-full.yml', 'utf8'));
  assert.equal(simple.on.workflow_dispatch.inputs.private_alpha.default, 'no');
  assert.equal(full.on.workflow_dispatch.inputs.private_alpha, undefined);
  const {jobs} = simple;
  const job = jobs['private-alpha'];
  const store = jobs['private-alpha-store'];
  assert.equal(job.environment, 'aegis-ios-signing');
  assert.deepEqual(job['runs-on'], {
    group: '${{ needs.admission.outputs.private_alpha_runner_group }}',
    labels: ['self-hosted', 'macOS', 'ARM64', '${{ needs.admission.outputs.private_alpha_runner_label }}'],
  });
  const runnerAdmission = jobs.admission.steps.find(step => step.name === 'Require a dedicated runner for private Alpha');
  assert(runnerAdmission.if.includes("steps.plan.outputs.private_alpha == 'true'"));
  const sharedAdmission = jobs.admission.steps.find(step => step.id === 'shared-runner');
  assert.equal(sharedAdmission.if, "${{ !startsWith(steps.plan.outputs.operation, 'status-') }}",
    'every route that can schedule macOS work validates the shared selector; hosted status queries do not');
  assert.equal(jobs['status-query']['runs-on'], 'ubuntu-24.04');
  const admissionIds = jobs.admission.steps.map(step => step.id);
  assert(admissionIds.indexOf('plan') < admissionIds.indexOf('shared-runner'));
  assert(admissionIds.indexOf('shared-runner') < admissionIds.indexOf('private-alpha-runner'));
  assert.equal(sharedAdmission.env.SHARED_IOS_LABEL, '${{ vars.AEGIS_IOS_RUNNER_LABEL }}');
  assert.equal(sharedAdmission.env.PRIVATE_ALPHA_LABEL, '${{ vars.AEGIS_IOS_PRIVATE_ALPHA_RUNNER_LABEL }}');
  // Scheduling must use the literal label admission checked; a JSON round trip could decode escapes.
  const sharedJobs = Object.entries(jobs).filter(([, value]) => JSON.stringify(value['runs-on'] ?? '').includes('AEGIS_IOS_RUNNER_LABEL'));
  assert(sharedJobs.length >= 5, 'expected the shared macOS delivery jobs');
  for (const [name, value] of sharedJobs) {
    assert.deepEqual(value['runs-on'], ['self-hosted', 'macOS', 'ARM64', '${{ vars.AEGIS_IOS_RUNNER_LABEL }}'], name);
  }
  assert(!readFileSync('.github/workflows/ios-delivery.yml', 'utf8').includes('fromJSON(format('),
    'delivery runner selectors must not be built through fromJSON');
  assert.equal(jobs.admission.outputs.private_alpha_runner_group, '${{ steps.private-alpha-runner.outputs.group }}');
  assert.equal(jobs.admission.outputs.private_alpha_runner_label, '${{ steps.private-alpha-runner.outputs.label }}');
  const directory = mkdtempSync(join(tmpdir(), 'private-alpha-runner-'));
  context.after(() => rmSync(directory, {recursive: true, force: true}));
  const output = join(directory, 'output');
  const dedicated = {PRIVATE_ALPHA_GROUP: 'Private Group', PRIVATE_ALPHA_LABEL: 'Private-Runner', SHARED_IOS_LABEL: 'shared'};
  const utf8Locale = process.platform === 'darwin' ? 'en_US.UTF-8' : 'C.UTF-8';
  // Hosted Ubuntu runs a modern Bash; stock macOS /bin/bash is 3.2.
  for (const shell of ['bash', ...(existsSync('/bin/bash') ? ['/bin/bash'] : [])]) {
    // Ordinary delivery: no private_alpha condition, with and without a configured private label.
    const admitShared = env => spawnSync(shell, ['-c', sharedAdmission.run],
      {env: {...process.env, PRIVATE_ALPHA_LABEL: '', SHARED_IOS_LABEL: 'shared', ...env}});
    for (const valid of [{}, {PRIVATE_ALPHA_LABEL: 'Private-Runner'}, {SHARED_IOS_LABEL: 'aegis-ios-upstream'},
      {SHARED_IOS_LABEL: 'aegis.ios_upstream-1'}]) {
      assert.equal(admitShared(valid).status, 0, `${shell}: ${JSON.stringify(valid)}`);
    }
    for (const invalid of [
      {SHARED_IOS_LABEL: ''}, {SHARED_IOS_LABEL: '   '}, {SHARED_IOS_LABEL: ' shared'}, {SHARED_IOS_LABEL: 'shared\nx'},
      ...['ARM64', 'arm64', 'macOS', 'SELF-hosted', 'x64', 'Linux'].map(label => ({SHARED_IOS_LABEL: label})),
      ...['ARM64', 'MacOS'].map(label => ({SHARED_IOS_LABEL: label, PRIVATE_ALPHA_LABEL: 'Private-Runner'})),
      {SHARED_IOS_LABEL: 'Private-Runner', PRIVATE_ALPHA_LABEL: 'private-runner'},
      // Non-ASCII case pairs collide on GitHub but not under tr.
      {SHARED_IOS_LABEL: 'build-\u00e9', PRIVATE_ALPHA_LABEL: 'build-\u00c9'},
      {SHARED_IOS_LABEL: 'build-\u00e9'}, {SHARED_IOS_LABEL: 'shared', PRIVATE_ALPHA_LABEL: 'build-\u00c9'},
      {SHARED_IOS_LABEL: 'shared/x'},
    ]) {
      assert.equal(admitShared(invalid).status, 1, `${shell}: ${JSON.stringify(invalid)}`);
    }
    const admitRunner = env => {
      writeFileSync(output, '');
      return spawnSync(shell, ['-c', runnerAdmission.run],
        {env: {...process.env, LC_ALL: utf8Locale, ...dedicated, ...env, GITHUB_OUTPUT: output}});
    };
    assert.equal(admitRunner({}).status, 0, shell);
    assert.equal(readFileSync(output, 'utf8'), 'group=Private Group\nlabel=Private-Runner\n');
    for (const invalid of [
      {PRIVATE_ALPHA_GROUP: ''}, {PRIVATE_ALPHA_GROUP: 'DeFaUlT'}, {PRIVATE_ALPHA_GROUP: 'private\nlabel=shared'},
      {PRIVATE_ALPHA_GROUP: '\u2003'}, {PRIVATE_ALPHA_GROUP: '\u2003Private'}, {PRIVATE_ALPHA_GROUP: 'Private\u2003'},
      {PRIVATE_ALPHA_LABEL: ''}, {SHARED_IOS_LABEL: ''}, {SHARED_IOS_LABEL: '   '},
      ...['SHARED', 'self-HOSTED', 'macOS', 'ARM64', ' shared '].map(label => ({PRIVATE_ALPHA_LABEL: label})),
      ...['SELF-hosted', 'MacOS', 'arm64'].map(label => ({SHARED_IOS_LABEL: label})),
      {PRIVATE_ALPHA_LABEL: 'build-\u00c9', SHARED_IOS_LABEL: 'build-\u00e9'},
      {PRIVATE_ALPHA_LABEL: 'Private-Runner', SHARED_IOS_LABEL: 'build-\u00e9'},
    ]) {
      assert.equal(admitRunner(invalid).status, 1, `${shell}: ${JSON.stringify(invalid)}`);
      assert.equal(readFileSync(output, 'utf8'), '');
    }
  }
  assert.deepEqual(job.needs, ['admission', 'check-unused']);
  for (const condition of ["private_alpha == 'true'", "private_beta == 'false'", "profile == 'alpha'",
    "signing_mode == 'manual'", "operation == 'package-upload'", "destination == 'testflight'",
    "github.ref == 'refs/heads/main'", "github.event_name == 'workflow_dispatch'", 'github.run_attempt == 1']) {
    assert(job.if.includes(condition), condition);
  }
  for (const id of ['archive-settings', 'ios-archive', 'ios-package']) {
    assert(jobs[id].if.includes("needs.admission.outputs.private_alpha == 'false'"));
  }
  for (const id of ['ios-draft', 'seal-package', 'upload-new']) {
    assert(jobs[id].if.includes("needs.ios-package.result == 'success'"));
  }
  const steps = job.steps;
  const inputs = steps.find(step => step.id === 'inputs');
  const names = ['AEGIS_IOS_ALPHA_NODES_BASE64', 'AEGIS_IOS_TEST_NODE_BASE64', 'AEGIS_IOS_TEST_SUBSCRIPTION_BASE64'];
  assert.deepEqual(Object.keys(inputs.env), names);
  for (const name of names) assert.equal(inputs.env[name], '${{ secrets.' + name + ' }}');
  assert(!JSON.stringify({...job, steps: steps.filter(step => step !== inputs)}).includes('AEGIS_IOS_ALPHA_NODES_BASE64'));
  assert(!JSON.stringify(full).includes('AEGIS_IOS_ALPHA_NODES_BASE64'));
  assert(!JSON.stringify(job).includes('AEGIS_ASC_'));
  const removeSigning = steps.findIndex(step => step.run?.endsWith('hosted-signing.py cleanup'));
  const retain = steps.findIndex(step => step.run?.endsWith('private_alpha_inputs.py retain'));
  assert(removeSigning >= 0 && removeSigning < retain);
  assert.equal(job.outputs.manifest_sha256, '${{ steps.retain.outputs.manifest_sha256 }}');
  assert.equal(store.environment, 'aegis-ios-store');
  assert.equal(job.name, 'private-alpha-package');
  assert.deepEqual(store['runs-on'], job['runs-on']);
  assert.deepEqual(store.needs, ['admission', 'private-alpha']);
  assert(store.if.includes("needs.private-alpha.result == 'success'"));
  assert(store.if.includes('github.run_attempt == 1'));
  assert.equal(store.env.RELEASE_MANIFEST_SHA256, '${{ needs.private-alpha.outputs.manifest_sha256 }}');
  assert(!names.some(name => JSON.stringify(store).includes(name)));
  assert(!JSON.stringify(store).includes('DISTRIBUTION'));
  const quota = store.steps.find(step => step.id === 'quota');
  const authorize = store.steps.find(step => step.run?.endsWith('private_alpha_inputs.py require-preflight'));
  const upload = store.steps.find(step => step.run?.endsWith('private_alpha_inputs.py upload'));
  assert(store.steps.indexOf(quota) < store.steps.indexOf(authorize));
  assert(store.steps.indexOf(authorize) < store.steps.indexOf(upload));
  assert.equal(authorize.env.AEGIS_PRIVATE_ALPHA_VERIFIED_MANIFEST_SHA256, '${{ steps.quota.outputs.manifest_sha256 }}');
  assert.equal(upload.env.AEGIS_PRIVATE_ALPHA_VERIFIED_MANIFEST_SHA256, '${{ steps.quota.outputs.manifest_sha256 }}');
  assert.equal(upload.env.AEGIS_ASC_KEY_BASE64, '${{ secrets.AEGIS_ASC_KEY_BASE64 }}');
  assert(!JSON.stringify({...store, steps: store.steps.filter(step => step !== upload)}).includes('AEGIS_ASC_'));
  assert(![...steps, ...store.steps].some(step => /(?:upload|download)-artifact/u.test(step.uses || '')));
  assert(jobs['check-unused'].steps.find(step => step.uses?.startsWith('actions/upload-artifact@'))
    .if.includes("needs.admission.outputs.private_alpha == 'false'"));
  const cleanup = steps.find(step => step.run?.endsWith('private_alpha_inputs.py cleanup'));
  assert(cleanup.if.includes('always()'));
  assert.equal(cleanup.env.AEGIS_PRIVATE_ALPHA_DIRECTORY, '${{ steps.inputs.outputs.directory }}');
  assert.equal(store.steps.find(step => step.id === 'checkout').with.ref, '${{ github.sha }}');
  const cleanupHandoff = store.steps.find(step => step.run?.endsWith('private_alpha_inputs.py cleanup-handoff'));
  assert.equal(cleanupHandoff.if, "${{ always() && steps.checkout.outcome == 'success' }}");
});

test('archive gets only non-secret settings from the existing environment', () => {
  const {jobs} = parse(readFileSync('.github/workflows/ios-delivery.yml', 'utf8'));
  const archive = jobs['ios-archive'];
  assert.equal(archive.environment, undefined);
  assert.equal(archive.env.DEVELOPER_DIR, '/Applications/Xcode.app/Contents/Developer');
  assert(!JSON.stringify(archive).includes('secrets.'));
  assert(archive.needs.includes('archive-settings'));
  assert.equal(archive.outputs.manifest_sha256, '${{ steps.archive.outputs.manifest_sha256 }}');
  const build = archive.steps.find(step => step.id === 'archive');
  assert(build.run.includes('--github-output "$GITHUB_OUTPUT"'));
  assert.equal(jobs['ios-package'].steps.find(step => step.id === 'package').env.AEGIS_CLOUD_ARCHIVE_MANIFEST_SHA256,
    '${{ needs.ios-archive.outputs.manifest_sha256 }}');
  const settings = jobs['archive-settings'];
  assert.equal(settings.environment, 'aegis-ios-signing');
  assert(!JSON.stringify(settings).includes('actions/checkout'));
  assert(!JSON.stringify(settings).includes('secrets.'));
  const code = settings.steps[0].run.replace(/^python3 - <<'PY'\n/u, '').replace(/\nPY\n?$/u, '');
  const temp = mkdtempSync(join(tmpdir(), 'aegis-settings-'));
  try {
    const output = join(temp, 'settings');
    const env = {...process.env, TEAM: 'ABCDEFGHIJ', FIREBASE_DEV: 'YWJj', FIREBASE_PROD: '', GITHUB_OUTPUT: output};
    execFileSync('python3', ['-c', code], {env});
    assert.equal(readFileSync(output, 'utf8'), 'team=ABCDEFGHIJ\nfirebase_dev=YWJj\nfirebase_prod=\n');
    assert.throws(() => execFileSync('python3', ['-c', code], {env: {...env, FIREBASE_DEV: 'YWJj\nrogue=secret'}, stdio: 'pipe'}));
    assert(!readFileSync(output, 'utf8').includes('rogue'));
  } finally {
    rmSync(temp, {recursive: true, force: true});
  }
});
function apiFixture({moved = false, parent = repository, pending = false} = {}) {
  let reads = 0;
  return async (repo, path) => {
    if (path === '') return repo === repository ? {id: 1348409663, default_branch: 'main'} : {id: 1363949860, fork: true, parent: {full_name: parent}};
    if (path.startsWith('/git/ref/heads/')) {
      const name = path.slice('/git/ref/heads/'.length);
      if (name === 'main') return {object: {sha: moved && ++reads > 1 ? 'b'.repeat(40) : sha}};
      return {object: {sha: 'c'.repeat(40)}};
    }
    if (path.startsWith('/commits/')) return {sha: moved ? 'b'.repeat(40) : sha};
    const run = {id: 12, run_attempt: 2, head_sha: sha, head_branch: 'codex/ios-release-upstream-20261030',
      repository: {full_name: repo}, event: 'push', path: '.github/workflows/ios-release-validation.yml', status: pending ? 'in_progress' : 'completed', conclusion: pending ? null : 'success'};
    if (path.includes('/workflows/')) return {workflow_runs: [run, {...run, id: 11, run_attempt: 1, status: 'completed', conclusion: 'success'}]};
    if (path.endsWith('/jobs?per_page=100')) return {total_count: 2, jobs: ['contracts', 'ios-archive'].map(name => ({name, run_id: 12, run_attempt: 2, head_sha: sha, status: 'completed', conclusion: 'success'}))};
    if (path === '/actions/runs/12') return run;
    throw new Error(`Unexpected fixture endpoint ${path}`);
  };
}
test('upstream admission rechecks main after quality and rejects moving main or tag', async () => {
  const {iosReleasePreflight} = await load();
  assert.equal((await iosReleasePreflight(sha, {environment, api: apiFixture(), quality: async () => true})).admission, 'upstream_quality_verified');
  await assert.rejects(iosReleasePreflight(sha, {environment, api: apiFixture({moved: true}), quality: async () => true}), /release line|changed/u);
  await assert.rejects(iosReleasePreflight(sha, {environment: {...environment, RELEASE_DESTINATION: 'github-draft', RELEASE_TAG: 'candidate/ios/1.0.0-alpha.6'}, api: apiFixture({moved: true}), quality: async () => true}), /tag|main/u);
});
test('disabled path and wrong repository identity cannot reach quality', async () => {
  const {iosReleasePreflight} = await load();
  for (const changes of [{AEGIS_IOS_RELEASE_ENABLED: 'false'}, {GITHUB_REPOSITORY_ID: '123'}, {GITHUB_EVENT_NAME: 'pull_request'}]) {
    await assert.rejects(iosReleasePreflight(sha, {environment: {...environment, ...changes}, api: apiFixture(), quality: async () => {throw new Error('credential boundary crossed');}}), /enabled|identity|dispatch/u);
  }
});
test('retired fork cannot regain privileged delivery through old opt-in flags', async () => {
  const {iosReleasePreflight} = await load();
  const fork = {...environment, GITHUB_REPOSITORY: 'quinn521/aegis-browser', GITHUB_REPOSITORY_ID: '1363949860',
    GITHUB_REF: 'refs/heads/codex/ios-release-upstream-20261030', AEGIS_IOS_FORK_REPOSITORY_ID: '1363949860',
    AEGIS_IOS_FORK_REF: 'refs/heads/codex/ios-release-upstream-20261030', AEGIS_IOS_FORK_REHEARSAL: 'true'};
  await assert.rejects(iosReleasePreflight(sha, {environment: fork, api: apiFixture()}), /canonical|upstream/iu);
});
test('operator denial stops source admission before source and quality APIs', async () => {
  const {iosReleasePreflight} = await load();
  let sourceReads = 0;
  await assert.rejects(iosReleasePreflight(sha, {environment, authorize: async () => {throw new Error('Admin required');},
    api: async () => {sourceReads++; return {};}, quality: async () => {sourceReads++; return true;}}), /Admin required/u);
  assert.equal(sourceReads, 0);
});
test('iOS workflow credentials and permissions stay in their protected stage', () => {
  const workflow = name => parse(readFileSync(`.github/workflows/${name}.yml`, 'utf8'));
  const validation = workflow('ios-release-validation');
  assert.deepEqual(validation.permissions, {contents: 'read', actions: 'read'});
  for (const id of ['impact', 'contracts', 'ios-archive']) assert(!JSON.stringify(validation.jobs[id]).includes('secrets.'));
  const poc = validation.jobs['cloud-poc'];
  assert.equal(poc.environment, 'aegis-ios-cloud-poc');
  assert(poc.if.includes("github.event_name == 'workflow_dispatch'"));
  assert(poc.steps.find(s => s.run === 'node scripts/ci/ios-cloud-poc-admission.mjs'));
  assert(!JSON.stringify(poc).includes('DISTRIBUTION_P12'));
  const release = workflow('ios-delivery');
  assert.equal(release.jobs['ios-package'].environment, 'aegis-ios-signing');
  assert.equal(release.jobs['ios-draft'].environment, 'aegis-ios-draft');
  assert.equal(release.jobs['ios-draft'].permissions.contents, 'write');
  const packageStep = release.jobs['ios-package'].steps.find(s => s.id === 'package');
  for (const name of ['AEGIS_ASC_KEY_ID', 'AEGIS_ASC_ISSUER_ID', 'AEGIS_ASC_KEY_BASE64']) {
    assert(packageStep.env[name].includes("outputs.signing_mode == 'cloud'"));
    assert(!Object.hasOwn(release.jobs['ios-package'].env, name));
  }
  assert(!JSON.stringify(release.jobs.admission).includes('secrets.'));
  const store = release;
  assert.equal(store.jobs.store.environment, 'aegis-ios-store');
  assert(!JSON.stringify(store.jobs.import).includes('secrets.'));
  assert(!JSON.stringify(store).includes('contents:write'));
  for (const doc of [release, store]) {
    assert(!JSON.stringify(doc).includes('secrets:inherit'));
    assert(!JSON.stringify(doc).includes('pull_request_target'));
  }
});

test('unsigned archive isolates fork PRs and tolerates missing runner labels', () => {
  const workflow = parse(readFileSync('.github/workflows/ios-release-validation.yml', 'utf8'));
  const route = workflow.jobs['ios-archive']['runs-on'];
  const configured = route.indexOf("vars.AEGIS_IOS_RUNNER_LABEL != ''");
  const trusted = route.indexOf("github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository");
  const selfHosted = route.indexOf('fromJSON(');
  assert(configured >= 0 && configured < selfHosted, 'empty labels must select the hosted fallback');
  assert(trusted >= 0 && trusted < selfHosted, 'fork PRs must select the hosted fallback');
  assert(route.endsWith("|| 'macos-26' }}"), 'unsigned validation uses the standard hosted Mac fallback');
  assert(!workflow.jobs['ios-archive'].environment, 'unsigned validation must not require a protected signing environment');
  assert(!workflow.jobs['ios-archive'].steps.some(s => String(s.uses ?? '').startsWith('actions/setup-go@')),
    'unsigned archive must keep Go setup inside the supervisor');
  const prepare = workflow.jobs['ios-archive'].steps.find(s => s.name === 'Prepare locked EmbeddedCore XCFramework');
  assert.match(prepare?.run ?? '', /--prepare-embedded-core/u, 'prepare must run behind the iOS archive supervisor');
  assert.equal(prepare?.env?.IOS_CI_SOURCE, '${{ steps.storage.outputs.source }}');
});

test('archive EmbeddedCore preparation uses the private script, bridge root and Git HEAD', () => {
  const workflow = parse(readFileSync('.github/workflows/ios-release-validation.yml', 'utf8'));
  const prepare = workflow.jobs['ios-archive'].steps.find(step => step.name === 'Prepare locked EmbeddedCore XCFramework');
  const root = mkdtempSync(join(realpathSync(tmpdir()), 'embedded-core-source-'));
  const shared = join(root, 'shared checkout');
  const source = join(root, 'Source');
  const bin = join(root, 'bin');
  const receipt = join(root, 'fixture-receipt.txt');
  const lock = 'apps/ios/EmbeddedCore/embedded-core-lock.json';
  const gitEnv = {HOME: root, GIT_CONFIG_NOSYSTEM: '1', GIT_ALLOW_PROTOCOL: 'file', PATH: process.env.PATH};
  const identities = new Map();
  try {
    for (const [checkout, marker] of [[shared, 'shared'], [source, 'private']]) {
      const git = (...args) => execFileSync('git', ['-c', 'core.hooksPath=/dev/null', '-c', 'core.autocrlf=false',
        '-c', 'user.name=EmbeddedCore Fixture', '-c', 'user.email=embedded-core@example.invalid', ...args], {
        cwd: checkout, encoding: 'utf8', env: {...gitEnv,
          GIT_AUTHOR_DATE: '2020-01-01T00:00:00Z', GIT_COMMITTER_DATE: '2020-01-01T00:00:00Z'},
      }).trim();
      mkdirSync(join(checkout, 'scripts/release'), {recursive: true});
      mkdirSync(join(checkout, 'apps/ios/EmbeddedCore/bridge'), {recursive: true});
      writeFileSync(join(checkout, lock), '{}\n');
      writeFileSync(join(checkout, 'apps/ios/EmbeddedCore/bridge/origin'), marker);
      writeFileSync(join(checkout, 'scripts/release/prepare-ios-access-core.sh'), `#!/bin/bash
set -euo pipefail
source_sha="$(git rev-parse HEAD)"
source_tree="$(git rev-parse 'HEAD^{tree}')"
git diff-index --cached --quiet HEAD --
printf '%s\\n' '${marker}' "$(cat apps/ios/EmbeddedCore/bridge/origin)" "$source_sha" "$source_tree" \
  "$PWD" "$1" "$AEGIS_EMBEDDED_CORE_DIGEST_MODE" > "$EMBEDDED_TEST_RECEIPT"
mkdir -p "$2/AegisEmbeddedCore.xcframework"
`);
      git('init', '--quiet', '--template=');
      git('add', '--', 'apps', 'scripts');
      git('commit', '--quiet', '--no-gpg-sign', '-m', `${marker} fixture`);
      identities.set(marker, git('rev-parse', 'HEAD', 'HEAD^{tree}').split('\n'));
    }
    mkdirSync(join(source, 'scripts/ci'));
    for (const file of ['ios-archive-supervisor.py', 'run-ios-embedded-core-prepare.sh']) {
      copyFileSync(`scripts/ci/${file}`, join(source, 'scripts/ci', file));
    }
    mkdirSync(bin);
    writeFileSync(join(source, 'scripts/ci/ios-archive-go.py'), `import sys\nfrom pathlib import Path\n`
      + `root = Path(sys.argv[2]) / "go/bin"\nroot.mkdir(parents=True)\n`);
    writeFileSync(join(bin, 'gomobile'), '#!/bin/bash\nexit 2\n', {mode: 0o755});
    const run = privateSource => spawnSync('bash', ['-e', '-o', 'pipefail', '-c', prepare.run], {
      cwd: shared, encoding: 'utf8', env: {...gitEnv, PATH: `${bin}:${process.env.PATH}`,
        GIT_DIR: join(shared, '.git'), GIT_WORK_TREE: shared, GIT_COMMON_DIR: join(shared, '.git'),
        GIT_OBJECT_DIRECTORY: join(shared, '.git', 'objects'), GIT_INDEX_FILE: join(shared, '.git', 'index'),
        IOS_CI_ROOT: root, IOS_CI_SOURCE: privateSource, EMBEDDED_TEST_RECEIPT: receipt},
    });
    const prepared = run(source);
    assert.equal(prepared.status, 0, prepared.stderr);
    assert.deepEqual(readFileSync(receipt, 'utf8').trim().split('\n'),
      ['private', 'private', ...identities.get('private'), source, join(source, lock), 'ci-rebuild']);
    rmSync(receipt);
    const missing = run(join(root, 'missing'));
    assert.equal(missing.status, 1, missing.stderr);
    assert.throws(() => readFileSync(receipt), {code: 'ENOENT'});
  } finally {
    rmSync(root, {recursive: true, force: true});
  }
});
test('every protected delivery route depends on Admin admission and normalized operation', () => {
  const workflow = parse(readFileSync('.github/workflows/ios-delivery.yml', 'utf8'));
  for (const id of ['ios-package', 'ios-draft', 'import', 'store']) {
    const job = workflow.jobs[id];
    assert([job.needs].flat().includes('admission'), id+' must await Admin admission');
    assert(job.if.includes('needs.admission.outputs.operation'), id+' must select normalized operation');
    assert(!JSON.stringify(job).includes('inputs.'), id+' must not consume unverified raw inputs');
  }
  assert(workflow.jobs['ios-package'].if.includes("== 'package'"));
  assert(workflow.jobs.store.if.includes("!= 'package'"));
  assert(!JSON.stringify(workflow.on).includes('branches'));
  for (const name of ['ios-release-validation', 'ios-coverage']) {
    const quality = parse(readFileSync('.github/workflows/'+name+'.yml', 'utf8'));
    for (const job of Object.values(quality.jobs)) {
      const guard = job.steps.findIndex(s => s.run?.includes('ios-operator.mjs --context') || s.run?.includes('ios-cloud-poc-admission.mjs'));
      assert(guard >= 0, name+' requires manual Admin guard');
      if (name === 'ios-release-validation' && job.environment !== 'aegis-ios-cloud-poc') assert.equal(job.steps[guard].if, "${{ github.event_name == 'workflow_dispatch' }}");
      const expensive = job.steps.findIndex(s => s.run?.includes('bundle exec') || s.run?.includes('xcodebuild ') ||
        s.run?.includes('run-ios-unsigned-archive.sh') || s.run?.includes('run-simulator-tests.sh'));
      if (expensive >= 0) assert(guard < expensive, name+' must authorize before expensive work');
    }
  }
});

test('candidate Draft survives its skipped upload-only ancestor while requiring successful admission and package', () => {
  const {jobs} = parse(readFileSync('.github/workflows/ios-delivery.yml', 'utf8'));
  assert(jobs['ios-package'].needs.includes('check-unused'));
  assert(jobs['check-unused'].if.includes("== 'package-upload'"));
  const draft = jobs['ios-draft'];
  assert.deepEqual(draft.needs, ['admission', 'ios-package']);
  assert(draft.if.includes('!cancelled()'), 'override implicit success() for the skipped ancestor');
  for (const dependency of draft.needs) assert(draft.if.includes(`needs.${dependency}.result == 'success'`));
  assert(draft.if.includes("outputs.destination == 'github-draft'"));
});

test('Bot controller keeps App key access behind canonical main and administrator admission', () => {
  const doc = parse(readFileSync('.github/workflows/ios-delivery-bot.yml', 'utf8'));
  assert.deepEqual(Object.keys(doc.on), ['workflow_dispatch']);
  assert.deepEqual(doc.permissions, {contents: 'read', actions: 'read'});
  const job = doc.jobs.controller;
  assert.equal(job.environment, 'aegis-ios-bot');
  for (const condition of ["github.repository == 'gcsagroup/aegis-browser'", "github.ref == 'refs/heads/main'",
    "github.event_name == 'workflow_dispatch'", 'github.run_attempt == 1']) assert(job.if.includes(condition));
  const guard = job.steps.findIndex(step => step.run === 'node scripts/ci/ios-operator.mjs --context controller');
  const keyStep = job.steps.findIndex(step => step.env?.AEGIS_IOS_BOT_PRIVATE_KEY);
  assert(guard >= 0 && keyStep > guard);
  assert.equal(job.steps[keyStep].run, 'bash scripts/ci/run-ios-delivery-bot.sh');
  assert.equal(job.steps[keyStep].env.BOT_INPUTS, '${{ toJSON(inputs) }}');
  assert(!JSON.stringify(doc).includes('AEGIS_ASC_'));
  assert.equal(doc.on.workflow_dispatch.inputs.operation.default, 'Status');
  assert.deepEqual(doc.on.workflow_dispatch.inputs.operation.options, [
    'Status', 'Wait', 'Package', 'Package and upload', 'Draft',
    'Preview GitHub release', 'Publish prerelease', 'Promote to stable',
  ]);
});

test('Bot summary confinement and failure receipts execute through the real shell adapter', () => {
  execFileSync('python3', ['-B', '-m', 'unittest', 'discover', '-s', 'scripts/release', '-p', 'test_ios_delivery_bot_summary.py'], {stdio: 'pipe'});
});

test('Simple and Full expose bounded English forms and share the same exact-source engine', () => {
  const workflow = name => parse(readFileSync(`.github/workflows/${name}.yml`, 'utf8'));
  const simple = workflow('ios-delivery');
  const full = workflow('ios-delivery-full');
  const inputs = simple.on.workflow_dispatch.inputs;
  assert.deepEqual(Object.keys(inputs), ['operation', 'version', 'build', 'product', 'signing_mode', 'archive_signing',
    'private_alpha', 'private_beta', 'approved_source_sha']);
  assert.equal(inputs.signing_mode.default, 'cloud');
  assert.deepEqual(inputs.signing_mode.options, ['cloud', 'manual']);
  assert.equal(inputs.archive_signing.default, 'development');
  assert.deepEqual(inputs.archive_signing.options, ['development', 'ad-hoc', 'unsigned']);
  assert.equal(simple.name, 'iOS Delivery · Simple');
  assert.equal(full.name, 'iOS Delivery · Full');
  assert.deepEqual(inputs.operation.options, ['Package', 'Package and upload', 'Status', 'Wait', 'Release Wait']);
  assert.deepEqual(inputs.product.options, ['Alpha', 'Beta', 'Release']);
  assert.equal(inputs.product.default, 'Alpha');
  const fullInputs = full.on.workflow_dispatch.inputs;
  assert.equal(fullInputs.signing_mode.default, 'cloud');
  assert.deepEqual(fullInputs.signing_mode.options, ['cloud', 'manual']);
  assert.deepEqual(fullInputs.archive_signing.options, ['development', 'ad-hoc', 'unsigned']);
  assert.deepEqual(fullInputs.operation.options, [
    'Package', 'Package and upload', 'Draft', 'Upload', 'Wait', 'Status',
    'Metadata', 'Compliance', 'Distribute internal', 'Distribute external',
  ]);
  assert.deepEqual(fullInputs.product.options, ['Auto', ...inputs.product.options]);
  assert.equal(fullInputs.product.default, 'Auto');
  assert.equal(inputs.version.required, true);
  assert.equal(inputs.build.required, true);
  assert(!inputs.source && !inputs.advanced);
  assert.deepEqual(Object.keys(full.on.workflow_dispatch.inputs), ['operation', 'version', 'build', 'product', 'source', 'signing_mode', 'archive_signing', 'private_beta', 'package_entrypoint', 'groups', 'stage_input', 'approved_source_sha']);
  assert.deepEqual(Object.keys(full.jobs), ['delivery']);
  assert.equal(full.jobs.delivery.uses, './.github/workflows/ios-delivery.yml');
  assert.equal(full.jobs.delivery.with.delivery_mode, 'full');
  assert.equal(full.jobs.delivery.with.delivery_inputs, '${{ toJSON(inputs) }}');
  assert(!full.on.push && !full.on.workflow_call);
  assert.equal(full.permissions.contents, 'write', 'caller must allow the protected Draft job; inner jobs reduce permissions');
  for (const doc of [simple, full]) {
    assert.equal(doc.on.workflow_dispatch.inputs.operation.default, 'Status');
    assert.doesNotMatch(JSON.stringify(doc.on.workflow_dispatch.inputs), /\p{Script=Han}/u);
    assert(!JSON.stringify(doc).includes('secrets:inherit'));
    assert(!JSON.stringify(doc.on).includes('submit'));
  }
  for (const id of ['ios-package', 'store']) {
    const steps = simple.jobs[id].steps;
    const emit = steps.findIndex(s => s.run === 'python3 scripts/release/ios-action.py receipt');
    assert(emit > 0);
    assert.equal(steps[emit].if, id === 'ios-package'
      ? "${{ steps.package.outputs.private_beta == 'false' }}" : undefined);
  }
});

test('version/build-only status has no artifact, signing or mutation route', () => {
  const doc = parse(readFileSync('.github/workflows/ios-delivery.yml', 'utf8'));
  const query = doc.jobs['status-query'];
  assert.equal(query.needs, 'admission');
  assert(query.if.includes("== 'status-query'") && query.if.includes("== 'status-wait'"));
  assert.equal(query.environment, 'aegis-ios-store');
  const serialized = JSON.stringify(query);
  for (const forbidden of ['download-artifact', 'ios-action.py', 'RELEASE_MANIFEST_SHA256', 'PACKAGE_RUN_ID', 'AEGIS_IOS_CERT', 'inputs.']) assert(!serialized.includes(forbidden));
  const auth = query.steps.findIndex(s => s.run?.includes('ios-release-preflight.mjs'));
  const read = query.steps.findIndex(s => s.run === 'bundle exec ruby scripts/release/ios-status.rb');
  assert(auth >= 0 && read > auth);
  assert(query.steps[read].env.AEGIS_ASC_KEY_BASE64.includes('secrets.'));
  assert.equal(query['timeout-minutes'], 40, 'allow the 30-minute wait plus setup and report upload');
  assert(!query['continue-on-error'] && !query.steps[read]['continue-on-error'], 'timeout must remain a failure');
  const report = query.steps.find(s => s.uses?.startsWith('actions/upload-artifact@'));
  assert.equal(report.if, "${{ !cancelled() && hashFiles('.artifacts/ios-status/status.json') != '' }}");
  assert.equal(report.with.path, '.artifacts/ios-status/status.json');
  assert.equal(report.with['if-no-files-found'], 'error');
  for (const id of ['import', 'store']) assert(doc.jobs[id].if.includes("!= 'status-query'"));
});

test('maintenance release lines package from their own tip, not current main', async () => {
  const lines = JSON.parse(readFileSync('scripts/ci/ios-release-lines.json', 'utf8')).lines;
  const pushed = parse(readFileSync('.github/workflows/quality.yml', 'utf8')).on.push.branches;
  assert.deepEqual(lines.map(line => line.name), ['main', 'releases/ios/1.0']);
  for (const line of lines) assert.ok(pushed.includes(line.name));
  const patchSha = 'd'.repeat(40);
  const {iosReleasePreflight} = await load();
  let qualityBranch;
  const api = async (repo, path) => {
    if (path === '') return {id: 1348409663, default_branch: 'main'};
    if (path === '/git/ref/heads/main') return {object: {sha}};
    if (path === '/git/ref/heads/releases/ios/1.0') return {object: {sha: patchSha}};
    throw new Error(`Unexpected fixture endpoint ${path}`);
  };
  const admitted = await iosReleasePreflight(patchSha, {
    environment: {...environment, GITHUB_SHA: patchSha, GITHUB_REF: 'refs/heads/releases/ios/1.0'},
    api, quality: async (_repo, branch) => { qualityBranch = branch; return true; },
  });
  assert.equal(admitted.line, 'releases/ios/1.0');
  assert.equal(qualityBranch, 'releases/ios/1.0');
  await assert.rejects(iosReleasePreflight(sha, {
    environment: {...environment, GITHUB_REF: 'refs/heads/releases/ios/1.0'},
    api, quality: async () => true,
  }), /release line/u);
  await assert.rejects(iosReleasePreflight(patchSha, {
    environment: {...environment, GITHUB_SHA: patchSha, GITHUB_REF: 'refs/heads/foreign'},
    api, quality: async () => { throw new Error('credential boundary crossed'); },
  }), /dispatch/u);
});

test('candidate admission bounds version components and rejects trailing data before tag lookup', async () => {
  const {iosReleasePreflight} = await load();
  const run = async tag => iosReleasePreflight(sha, {environment: {...environment, RELEASE_DESTINATION: 'github-draft', RELEASE_TAG: tag}, api: apiFixture(), quality: async () => true});
  for (const tag of ['candidate/ios/1.0-alpha.6', 'candidate/ios/1.0.0-beta.7', 'candidate/ios/1.0.0-release.8']) {
    assert.equal((await run(tag)).admission, 'upstream_quality_verified');
  }
  for (const tag of [`candidate/ios/${'1'.repeat(128)}.0.0-alpha.6`, 'candidate/ios/1.0.0-release.8\n', 'candidate/ios/1.0.0.0-alpha.6', 'candidate/ios/1.0.0-alpha.0']) {
    await assert.rejects(run(tag), /candidate tag/iu);
  }
});

test('public package upload is bound to the successful same-run producer', () => {
  const doc = parse(readFileSync('.github/workflows/ios-delivery.yml', 'utf8'));
  const packageJob = doc.jobs['ios-package'];
  assert(packageJob.needs.includes('check-unused'));
  assert(packageJob.if.includes("needs.check-unused.result == 'success'"));
  assert.equal(packageJob.env.RELEASE_STAGE, 'package');
  assert(!JSON.stringify(packageJob.env).includes('AEGIS_ASC'));
  assert(packageJob.steps.find(s => s.name === 'Install signing material on the ephemeral runner').if.includes("== 'manual'"));
  const fresh = doc.jobs['check-unused'];
  assert.equal(fresh.env.RELEASE_QUERY_MODE, 'unused');
  assert.equal(fresh.environment, 'aegis-ios-store');
  const upload = doc.jobs['upload-new'];
  assert.deepEqual(upload.needs, ['admission', 'ios-package', 'seal-package']);
  assert(upload.if.includes("needs.admission.outputs.operation == 'package-upload'"));
  assert.equal(upload.env.RELEASE_MANIFEST_SHA256, '${{ needs.ios-package.outputs.manifest_sha256 }}');
  assert.equal(upload.env.PACKAGE_RUN_ID, '${{ github.run_id }}');
  assert.equal(upload.env.IMPORT_KIND, 'new-upload');
  assert.equal(upload.env.RELEASE_STAGE, 'upload');
  assert(upload.steps.find(s => s.run?.includes('ios-restore.py')));
  assert(upload.steps.find(s => s.run === 'python3 scripts/release/ios-action.py export').if.includes('always()'));
  assert.equal(upload.steps.find(s => s.run === 'python3 scripts/release/ios-action.py receipt').if, undefined);
});

test('new upload survives an optional skipped ancestor but rejects failed prerequisites and cancellation', () => {
  const {jobs} = parse(readFileSync('.github/workflows/ios-delivery.yml', 'utf8'));
  const expression = jobs['upload-new'].if.slice(3, -2).replace(/needs\.([a-z-]+)/gu, 'needs["$1"]');
  const eligible = (patch = {}, cancelled = false) => {
    const needs = {admission: {result: 'success', outputs: {operation: 'package-upload'}},
      'ios-package': {result: 'success', outputs: {private_beta: 'false'}}, 'seal-package': {result: 'success'}, ...patch};
    // GitHub adds success() unless the condition explicitly uses a status function.
    const implicitSuccess = !/\b(?:always|cancelled|failure|success)\(/u.test(expression);
    return !implicitSuccess && runInNewContext(expression, {needs, cancelled: () => cancelled});
  };
  assert.equal(eligible(), true, 'manual signing skips cloud archive ancestors');
  assert.equal(eligible({}, true), false);
  for (const name of jobs['upload-new'].needs) {
    for (const result of ['failure', 'cancelled', 'skipped']) {
      const outputs = name === 'admission' ? {operation: 'package-upload'} : {private_beta: 'false'};
      assert.equal(eligible({[name]: {result, outputs}}), false, `${name}: ${result}`);
    }
  }
  assert.equal(eligible({admission: {result: 'success', outputs: {operation: 'package'}}}), false);
  assert.equal(eligible({'ios-package': {result: 'success', outputs: {private_beta: 'true'}}}), false);
});

test('private Beta crosses the store gate without publishing its package', () => {
  const {jobs} = parse(readFileSync('.github/workflows/ios-delivery.yml', 'utf8'));
  const steps = jobs['ios-package'].steps;
  const pack = steps.findIndex(s => s.id === 'package');
  const cleanup = steps.findIndex(s => s.run === 'python3 scripts/release/hosted-signing.py cleanup');
  const retain = steps.findIndex(s => s.run === 'python3 scripts/release/ios-action.py retain-private-beta');
  assert(pack >= 0 && pack < cleanup && cleanup < retain);
  assert(!steps.some(s => s.run === 'python3 scripts/release/ios-action.py private-beta-upload'));
  const store = jobs['private-beta-store'];
  assert.equal(store.environment, 'aegis-ios-store');
  assert(store.needs.includes('ios-package'));
  assert(store.if.includes("needs.ios-package.result == 'success'"));
  assert(store.if.includes("needs.ios-package.outputs.private_beta == 'true'"));
  assert.equal(store.env.RELEASE_MANIFEST_SHA256, '${{ needs.ios-package.outputs.manifest_sha256 }}');
  const restore = store.steps.findIndex(s => s.run === 'python3 scripts/release/ios-action.py restore-private-beta');
  const upload = store.steps.findIndex(s => s.run === 'python3 scripts/release/ios-action.py private-beta-upload');
  const quota = store.steps.findIndex(s => s.run === 'python3 scripts/release/ios-action.py private-beta-preflight');
  assert(restore >= 0 && restore < quota && quota < upload);
  assert.equal(store.steps[quota].env, undefined);
  const authorize = store.steps.findIndex(s => s.run === 'python3 scripts/release/ios-action.py require-private-beta-preflight');
  assert(quota < authorize && authorize < upload);
  assert.equal(store.steps[authorize].env.AEGIS_PRIVATE_BETA_VERIFIED_MANIFEST_SHA256, '${{ steps.quota.outputs.manifest_sha256 }}');
  assert(!Object.keys(store.steps[authorize].env).some(key => key.startsWith('AEGIS_ASC_')));
  assert.equal(store.steps[upload].if, undefined);
  assert.equal(store.steps[upload].env.AEGIS_PRIVATE_BETA_VERIFIED_MANIFEST_SHA256, '${{ steps.quota.outputs.manifest_sha256 }}');
  assert.equal(store.steps[upload].env.AEGIS_ASC_KEY_BASE64, '${{ secrets.AEGIS_ASC_KEY_BASE64 }}');
  assert(!Object.keys(store.steps[upload].env).some(key => key.includes('TEST_NODE') || key.includes('DISTRIBUTION')));
  const archive = steps.find(s => s.with?.path === '.artifacts/ios-delivery/package.zip');
  assert.equal(archive.if, "${{ steps.package.outputs.private_beta == 'false' }}");
  const uploads = store.steps.filter(s => s.uses?.startsWith('actions/upload-artifact@'));
  assert.equal(uploads.length, 1);
  assert.equal(uploads[0].with.path, '${{ steps.private-evidence.outputs.receipt_path }}');
  assert(store.steps.some(s => s.run === 'python3 scripts/release/ios-action.py cleanup-private-beta-handoff'));
  const cancelledRestoreCleanup = store.steps.find(s => s.run === 'python3 scripts/release/ios-action.py cleanup-private-beta-restore');
  assert.equal(cancelledRestoreCleanup.if, "${{ always() && steps.restore.outcome != 'skipped' }}");
  assert.equal(cancelledRestoreCleanup.id, 'restore-cleanup');
  assert(!store.steps.some(s => s.run === 'python3 scripts/release/ios-action.py cleanup-private-beta'));
  assert(store.steps.find(s => s.run === 'python3 scripts/release/ios-action.py cleanup-private-beta-handoff').if.includes("steps.restore-cleanup.outcome == 'success'"));
  for (const job of ['seal-package', 'upload-new', 'ios-draft']) {
    assert(jobs[job].if.includes("needs.ios-package.outputs.private_beta == 'false'"));
  }
});

test('Full explicitly forwards named secrets while protected jobs resolve environment values', () => {
  const simple = parse(readFileSync('.github/workflows/ios-delivery.yml', 'utf8'));
  const full = parse(readFileSync('.github/workflows/ios-delivery-full.yml', 'utf8'));
  const expected = ['AEGIS_ASC_KEY_ID', 'AEGIS_ASC_ISSUER_ID', 'AEGIS_ASC_KEY_BASE64'];
  const signing = ['AEGIS_IOS_DISTRIBUTION_P12_BASE64', 'AEGIS_IOS_DISTRIBUTION_P12_PASSWORD',
    'AEGIS_IOS_APP_PROFILE_BASE64', 'AEGIS_IOS_SAFARI_PROFILE_BASE64', 'AEGIS_IOS_SHARE_PROFILE_BASE64'];
  const privateBeta = ['AEGIS_IOS_TEST_NODE_BASE64', 'AEGIS_IOS_TEST_SUBSCRIPTION_BASE64'];
  assert.deepEqual(Object.keys(simple.on.workflow_call.secrets),
    ['AEGIS_IOS_ALPHA_NODES_BASE64', ...privateBeta, ...expected, ...signing]);
  assert.equal(simple.on.workflow_call.secrets.AEGIS_IOS_ALPHA_NODES_BASE64.required, false);
  for (const name of privateBeta) assert.equal(simple.on.workflow_call.secrets[name].required, false);
  assert.deepEqual(Object.keys(full.jobs.delivery.secrets), [...expected, ...signing]);
  for (const name of expected) {
    assert.equal(simple.on.workflow_call.secrets[name].required, true);
    assert.equal(full.jobs.delivery.secrets[name], '${{ secrets.'+name+' }}');
  }
  assert.notEqual(full.jobs.delivery.secrets, 'inherit');
  for (const id of ['status-query', 'check-unused', 'store', 'upload-new']) assert.equal(simple.jobs[id].environment, 'aegis-ios-store');
  assert(!JSON.stringify(simple.jobs.admission).includes('secrets.'));
  assert(!JSON.stringify(simple.jobs['ios-package'].env).includes('AEGIS_ASC'));
  for (const name of signing) {
    assert.equal(simple.on.workflow_call.secrets[name].required, false);
    assert.equal(full.jobs.delivery.secrets[name], '${{ secrets.'+name+' }}');
  }
});

test('hosted signing loads only environment secrets after source admission and cleans up before artifact upload', () => {
  const doc = parse(readFileSync('.github/workflows/ios-delivery.yml', 'utf8'));
  const job = doc.jobs['ios-package'];
  assert.deepEqual(job['runs-on'], ['self-hosted', 'macOS', 'ARM64', '${{ vars.AEGIS_IOS_RUNNER_LABEL }}']);
  assert.equal(job.environment, 'aegis-ios-signing');
  assert.equal(job.env.DEVELOPER_DIR, '/Applications/Xcode.app/Contents/Developer');
  const ruby = job.steps.findIndex(s => s.uses === './.github/actions/ensure-ios-ruby');
  assert(ruby >= 0);
  assert(!job.steps.some(s => s.uses?.startsWith('ruby/setup-ruby@')),
    'ios-package must not call ruby/setup-ruby directly; it hard-codes /Users/runner on macOS');
  const setup = job.steps.findIndex(s => s.run === 'python3 scripts/release/hosted-signing.py setup');
  const source = job.steps.findIndex(s => s.run?.includes('ios-release-preflight.mjs'));
  const pack = job.steps.findIndex(s => s.run === 'python3 scripts/release/ios-action.py package');
  const cleanup = job.steps.findIndex(s => s.run === 'python3 scripts/release/hosted-signing.py cleanup');
  const upload = job.steps.findIndex(s => s.uses?.startsWith('actions/upload-artifact@'));
  assert(ruby < source && source >= 0 && source < setup && setup < pack && pack < cleanup && cleanup < upload);
  assert.equal(job.steps[cleanup].if, "${{ always() && needs.admission.outputs.signing_mode == 'manual' }}");
  assert.equal(Object.keys(job.steps[setup].env).length, 5);
  assert(Object.values(job.steps[setup].env).every(v => v.startsWith('${{ secrets.AEGIS_IOS_')));
  assert(!JSON.stringify(doc.jobs.admission).includes('secrets.'));
});

test('public release workflow limits write permission to the serialized publisher', () => {
  const doc = parse(readFileSync('.github/workflows/ios-github-release.yml', 'utf8'));
  assert.deepEqual(Object.keys(doc.on), ['workflow_dispatch']);
  assert.deepEqual(doc.permissions, {actions: 'read', contents: 'read'});
  assert.deepEqual(doc.jobs.preview.permissions, {actions: 'read', contents: 'read'});
  assert.deepEqual(doc.jobs.publish.permissions, {actions: 'read', contents: 'write'});
  assert.deepEqual(doc.jobs.publish.needs, ['preview', 'stable-approval']);
  assert(doc.jobs.publish.if.includes("inputs.operation == 'Publish prerelease'"));
  assert(doc.jobs.publish.if.includes("inputs.operation == 'Promote stable'"));
  assert(doc.jobs['stable-approval'].if.includes("inputs.operation == 'Promote stable'"));
  assert(!doc.jobs.publish.if.includes('Publish Beta'));
  assert(!doc.jobs.publish.if.includes('Publish stable'));
  assert(doc.jobs.publish.if.includes("needs.stable-approval.result == 'skipped'"));
  assert(doc.jobs.publish.if.includes("needs.stable-approval.result == 'success'"));
  assert(doc.jobs.publish.if.includes("vars.AEGIS_IOS_GITHUB_RELEASE_ENABLED == 'true'"));
  assert.equal(doc.jobs.publish.environment, undefined);
  assert.equal(doc.jobs['stable-approval'].environment, 'aegis-ios-github-production');
  assert.deepEqual(doc.jobs['stable-approval'].permissions, {});
  assert.equal(doc.jobs['stable-approval'].concurrency, undefined);
  assert.equal(doc.concurrency, undefined);
  assert.equal(doc.jobs.preview.concurrency, undefined);
  assert.equal(doc.jobs.publish.concurrency.queue, 'max');
  assert.equal(doc.jobs.publish.concurrency['cancel-in-progress'], undefined);
  const controller = parse(readFileSync('.github/workflows/ios-delivery-bot.yml', 'utf8'));
  assert.match(controller.concurrency.group, /Preview GitHub release.*release-preview/u);
  assert(!JSON.stringify(doc).includes('administration:'));
  for (const job of Object.values(doc.jobs)) assert(!JSON.stringify(job).includes('secrets.'));
  assert.equal(doc.jobs.preview.env.AEGIS_IOS_GITHUB_RELEASE_ADMIN_IDS, '${{ vars.AEGIS_IOS_GITHUB_RELEASE_ADMIN_IDS }}');
  for (const job of [doc.jobs.preview, doc.jobs.publish]) {
    const artifactDownloads = job.steps.filter(step => step.uses?.startsWith('actions/download-artifact@'));
    assert.equal(artifactDownloads.length, 0, 'artifact bytes are checked before extracting their payload');
    const packageDownload = job.steps.find(step => step.run?.includes('ios-github-release.py download-package'));
    assert.equal(packageDownload.env.PACKAGE_ARTIFACT_ID, '${{ steps.locate.outputs.package_artifact_id }}');
    assert(packageDownload.run.includes('--package-artifact-id "$PACKAGE_ARTIFACT_ID"'));
    assert(!packageDownload.run.includes('${{'));
    const extract = job.steps.find(step => step.run?.includes('ios-github-release.py extract'));
    assert(extract?.run.includes('--status-run-id "$STATUS_RUN_ID"'));
    const planStep = job.steps.find(step => /ios-github-release\.py (?:preview|publish) /u.test(step.run));
    assert.equal(planStep.env.STATUS_ARTIFACT_ID, '${{ steps.locate.outputs.status_artifact_id }}');
    assert(planStep.run.includes('--status-artifact-id "$STATUS_ARTIFACT_ID"'));
    assert(!planStep.run.includes('${{'));
  }
});
