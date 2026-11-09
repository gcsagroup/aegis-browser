import assert from 'node:assert/strict';
import test from 'node:test';
import {readFileSync} from 'node:fs';
import {parse} from 'yaml';

const sha = 'a'.repeat(40);
const repository = 'gcsagroup/aegis-browser';
const environment = {GH_TOKEN: 'fixture', GITHUB_ACTIONS: 'true', GITHUB_REPOSITORY: repository,
  GITHUB_REPOSITORY_ID: '1348409663', GITHUB_SHA: sha, GITHUB_REF: 'refs/heads/main',
  GITHUB_EVENT_NAME: 'workflow_dispatch', AEGIS_IOS_RELEASE_ENABLED: 'true', RELEASE_DESTINATION: 'artifacts'};
const load = async () => {
  const {iosReleasePreflight: preflight} = await import('../ios-release-preflight.mjs');
  return {iosReleasePreflight: (source, options) => preflight(source, {authorize: async () => true, ...options})};
};
function apiFixture({moved = false, parent = repository, pending = false} = {}) {
  let reads = 0;
  return async (repo, path) => {
    if (path === '') return repo === repository ? {id: 1348409663, default_branch: 'main'} : {id: 1363949860, fork: true, parent: {full_name: parent}};
    if (path === '/git/ref/heads/main') return {object: {sha: moved && ++reads > 1 ? 'b'.repeat(40) : sha}};
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
  await assert.rejects(iosReleasePreflight(sha, {environment, api: apiFixture({moved: true}), quality: async () => true}), /main|changed/u);
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
  for (const id of ['contracts', 'ios-archive']) assert(!JSON.stringify(validation.jobs[id]).includes('secrets.'));
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
      const expensive = job.steps.findIndex(s => s.run?.includes('bundle exec') || s.run?.includes('xcodebuild ') || s.run?.includes('run-simulator-tests.sh'));
      assert(guard < expensive, name+' must authorize before expensive work');
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

test('Simple and Full expose bounded English forms and share the same exact-source engine', () => {
  const workflow = name => parse(readFileSync(`.github/workflows/${name}.yml`, 'utf8'));
  const simple = workflow('ios-delivery');
  const full = workflow('ios-delivery-full');
  const inputs = simple.on.workflow_dispatch.inputs;
  assert.deepEqual(Object.keys(inputs), ['operation', 'version', 'build', 'product', 'signing_mode']);
  assert.equal(inputs.signing_mode.default, 'cloud');
  assert.deepEqual(inputs.signing_mode.options, ['cloud', 'manual']);
  assert.equal(simple.name, 'iOS Delivery · Simple');
  assert.equal(full.name, 'iOS Delivery · Full');
  assert.deepEqual(inputs.operation.options, ['Package', 'Package and upload', 'Status', 'Wait']);
  assert.deepEqual(inputs.product.options, ['Alpha', 'Beta', 'Release']);
  assert.equal(inputs.product.default, 'Alpha');
  const fullInputs = full.on.workflow_dispatch.inputs;
  assert.equal(fullInputs.signing_mode.default, 'cloud');
  assert.deepEqual(fullInputs.signing_mode.options, ['cloud', 'manual']);
  assert.deepEqual(fullInputs.operation.options, [
    'Package', 'Package and upload', 'Draft', 'Upload', 'Wait', 'Status',
    'Metadata', 'Compliance', 'Distribute internal', 'Distribute external',
  ]);
  assert.deepEqual(fullInputs.product.options, ['Auto', ...inputs.product.options]);
  assert.equal(fullInputs.product.default, 'Auto');
  assert.equal(inputs.version.required, true);
  assert.equal(inputs.build.required, true);
  assert(!inputs.source && !inputs.advanced);
  assert.deepEqual(Object.keys(full.on.workflow_dispatch.inputs), ['operation', 'version', 'build', 'product', 'source', 'signing_mode', 'package_entrypoint', 'groups', 'stage_input']);
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
    assert(emit > 0 && !steps[emit].if);
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

test('new-package upload is bound to the successful same-run producer and never loads ASC secrets while signing', () => {
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
  assert.deepEqual(upload.needs, ['admission', 'ios-package']);
  assert.equal(upload.if, "${{ needs.admission.outputs.operation == 'package-upload' }}");
  assert.equal(upload.env.RELEASE_MANIFEST_SHA256, '${{ needs.ios-package.outputs.manifest_sha256 }}');
  assert.equal(upload.env.PACKAGE_RUN_ID, '${{ github.run_id }}');
  assert.equal(upload.env.IMPORT_KIND, 'new-upload');
  assert.equal(upload.env.RELEASE_STAGE, 'upload');
  assert(upload.steps.find(s => s.run?.includes('ios-restore.py')));
  assert(upload.steps.find(s => s.run === 'python3 scripts/release/ios-action.py export').if.includes('always()'));
  assert.equal(upload.steps.find(s => s.run === 'python3 scripts/release/ios-action.py receipt').if, undefined);
});

test('Full explicitly forwards named secrets while protected jobs resolve environment values', () => {
  const simple = parse(readFileSync('.github/workflows/ios-delivery.yml', 'utf8'));
  const full = parse(readFileSync('.github/workflows/ios-delivery-full.yml', 'utf8'));
  const expected = ['AEGIS_ASC_KEY_ID', 'AEGIS_ASC_ISSUER_ID', 'AEGIS_ASC_KEY_BASE64'];
  const signing = ['AEGIS_IOS_DISTRIBUTION_P12_BASE64', 'AEGIS_IOS_DISTRIBUTION_P12_PASSWORD',
    'AEGIS_IOS_APP_PROFILE_BASE64', 'AEGIS_IOS_SAFARI_PROFILE_BASE64', 'AEGIS_IOS_SHARE_PROFILE_BASE64'];
  assert.deepEqual(Object.keys(simple.on.workflow_call.secrets), [...expected, ...signing]);
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
  assert.equal(job['runs-on'], "${{ fromJSON(format('[\"self-hosted\",\"macOS\",\"ARM64\",\"{0}\"]', vars.AEGIS_IOS_RUNNER_LABEL)) }}");
  assert.equal(job.environment, 'aegis-ios-signing');
  assert.equal(job.env.DEVELOPER_DIR, '/Applications/Xcode_26.6.app/Contents/Developer');
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
