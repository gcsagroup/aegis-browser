import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import test from 'node:test';
import {writeInputManifest} from './simulator-input-manifest.mjs';

const scripts = path.dirname(fileURLToPath(import.meta.url));
const vectorPath = 'packages/core/src/agent/contracts/v1/agent-contract-v1.vectors.json';
const resourcePath = 'apps/browser/overlay/chrome/browser/resources/aegis/enhancements_shared/fixture.js';

function write(root, relative, content) {
  const destination = path.join(root, relative);
  fs.mkdirSync(path.dirname(destination), {recursive: true});
  fs.writeFileSync(destination, content);
}

function git(root, args) {
  return execFileSync('git', ['-c', 'core.hooksPath=/dev/null', ...args], {cwd: root, encoding: 'utf8'}).trim();
}

function createFixture(t) {
  const sandbox = fs.mkdtempSync('/tmp/aegis-ios-evidence-');
  t.after(() => fs.rmSync(sandbox, {recursive: true, force: true}));
  const root = path.join(sandbox, 'repo');
  write(root, 'apps/ios/project.yml', 'settings:\n  base:\n    CURRENT_PROJECT_VERSION: 34\n');
  write(root, 'apps/ios/Aegis.xcodeproj/project.pbxproj', 'original project');
  write(root, 'apps/ios/AegisApp/Main.swift', 'struct Main {}\n');
  write(root, vectorPath, '{"vector_version":1}\n');
  write(root, resourcePath, '// Shared browser resource.\n');
  write(root, 'packages/core/src/tracker/builtin-rules.ts', 'export const hosts = [];\n');
  for (const name of ['run-simulator-tests.sh', 'simulator-input-manifest.mjs', 'summarize-xccov.mjs']) {
    fs.mkdirSync(path.join(root, 'apps/ios/scripts'), {recursive: true});
    fs.copyFileSync(path.join(scripts, name), path.join(root, 'apps/ios/scripts', name));
  }
  for (const name of ['verify-fixtures.mjs', 'generate-tracker-rules.mjs', 'test-summarize-xccov.mjs']) {
    write(root, `apps/ios/scripts/${name}`, '// Fixture preflight.\n');
  }
  write(root, 'apps/ios/Tests/SharedWebExtension/SafariNavigationIdentityTests.mjs', '// Fixture preflight.\n');
  write(root, 'apps/ios/scripts/simulator-fixture-server.py', '# Fixture self-test.\n');
  git(root, ['init', '-q']);
  git(root, ['add', '.']);
  git(root, ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
    '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture']);
  return {sandbox, root};
}

// Only the Apple tools and the HTTP readiness probe are synthetic. The runner,
// Git snapshots, project version update, plist check and coverage writer are real.
const toolFixture = `#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
const tool = path.basename(process.argv[1]);
const args = process.argv.slice(2);
const root = process.env.EVIDENCE_FIXTURE_ROOT;
const ios = path.join(root, 'apps/ios');
const option = name => args[args.indexOf(name) + 1];
const output = value => console.log(JSON.stringify(value));
if (tool === 'python3') {
  if (args.length === 1 && args[0] === '-') {
    fs.readFileSync(0); // Treat the fixture server as ready; open no sockets.
  } else {
    const result = spawnSync(process.env.EVIDENCE_REAL_PYTHON, args, {stdio: 'inherit'});
    process.exit(result.status ?? 1);
  }
} else if (tool === 'xcodegen') {
  fs.writeFileSync(path.join(ios, 'Aegis.xcodeproj/project.pbxproj'), 'generated project');
} else if (tool === 'xcodebuild') {
  if (args.includes('-version')) {
    console.log('Xcode fixture');
  } else if (args.includes('build-for-testing')) {
    const version = process.env.EVIDENCE_APP_VERSION ??
      fs.readFileSync(path.join(ios, 'project.yml'), 'utf8').match(/CURRENT_PROJECT_VERSION: (\\d+)/)[1];
    const app = path.join(option('-derivedDataPath'), 'Build/Products/Debug-iphonesimulator/Aegis.app');
    fs.mkdirSync(app, {recursive: true});
    fs.writeFileSync(path.join(app, 'Info.plist'),
      '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleVersion</key><string>' + version + '</string></dict></plist>');
  } else if (args.includes('test-without-building')) {
    fs.mkdirSync(option('-resultBundlePath'), {recursive: true});
    if (process.env.EVIDENCE_MUTATE_VECTOR === '1') {
      fs.appendFileSync(path.join(root, '${vectorPath}'), ' ');
    }
    if (process.env.EVIDENCE_MUTATE_RESOURCE === '1') {
      fs.appendFileSync(path.join(root, '${resourcePath}'), ' ');
    }
  } else {
    throw new Error('Unexpected xcodebuild call');
  }
} else if (tool === 'xcrun') {
  const runtime = 'com.apple.CoreSimulator.SimRuntime.iOS-26-5';
  const devices = [
    {name: 'Aegis QA iPhone 17', deviceTypeIdentifier: 'com.apple.CoreSimulator.SimDeviceType.iPhone-17', udid: 'phone'},
    {name: 'Aegis QA iPad Air 11-inch (M4)', deviceTypeIdentifier: 'com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M4', udid: 'tablet'},
  ];
  if (args[0] === 'simctl' && args[2] === 'runtimes') {
    output({runtimes: [{identifier: runtime, version: '26.5', isAvailable: true}]});
  } else if (args[0] === 'simctl' && args[2] === 'devicetypes') {
    output({devicetypes: devices.map(device => ({identifier: device.deviceTypeIdentifier}))});
  } else if (args[0] === 'simctl' && args[2] === 'devices') {
    output({devices: {[runtime]: devices}});
  } else if (args[0] === 'xcresulttool') {
    output({result: 'Passed', totalTestCount: 1});
  } else if (args[0] === 'xccov') {
    output({targets: [{name: 'Aegis', files: [{path: path.join(ios, 'AegisApp/Main.swift'),
      coveredLines: 1, executableLines: 1, lineCoverage: 1}]}]});
  } else {
    throw new Error('Unexpected xcrun call');
  }
} else {
  throw new Error('Unexpected fixture tool');
}
`;

function runFixture(fixture, overrides = {}, mode = '--execute') {
  const bin = path.join(fixture.sandbox, 'bin');
  fs.mkdirSync(bin);
  for (const tool of ['python3', 'xcodegen', 'xcodebuild', 'xcrun']) {
    const destination = path.join(bin, tool);
    fs.writeFileSync(destination, toolFixture, {mode: 0o755});
  }
  const report = path.join(fixture.sandbox, 'report');
  const result = spawnSync('bash', [path.join(fixture.root, 'apps/ios/scripts/run-simulator-tests.sh'),
    mode, '--output-dir', report], {
    cwd: fixture.root,
    encoding: 'utf8',
    timeout: 90_000,
    env: {...process.env, ...overrides,
      PATH: `${bin}:${process.env.PATH}`,
      EVIDENCE_FIXTURE_ROOT: fixture.root,
      EVIDENCE_REAL_PYTHON: execFileSync('which', ['python3'], {encoding: 'utf8'}).trim(),
      AEGIS_IOS_DERIVED_DATA: path.join(fixture.sandbox, 'DerivedData'),
    },
  });
  return {...result, report};
}

function digest(file) {
  return createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

test('manifest includes shared and new inputs, deduplicates staged additions and escapes filenames', t => {
  const {root, sandbox} = createFixture(t);
  const manifest = path.join(sandbox, 'inputs.txt');
  write(root, 'packages/core/new.txt', 'new input');
  git(root, ['add', 'packages/core/new.txt']);
  write(root, 'apps/ios/new\nfile.swift', 'new source');
  write(root, '.gitignore', '*.ignored\n');
  write(root, 'packages/core/cache.ignored', 'ignored');
  write(root, 'unrelated.txt', 'outside input scope');
  writeInputManifest(root, manifest);
  const text = fs.readFileSync(manifest, 'utf8');
  assert.match(text, new RegExp(digest(path.join(root, vectorPath))));
  assert.match(text, /packages\/core\/src\/tracker\/builtin-rules.ts/);
  assert.ok(text.includes(resourcePath));
  assert.equal(text.match(/packages\/core\/new.txt/g).length, 1);
  assert.ok(text.includes('apps/ios/new\\nfile.swift'));
  assert.ok(!text.includes('cache.ignored') && !text.includes('unrelated.txt'));
  const before = digest(manifest);
  fs.appendFileSync(path.join(root, vectorPath), ' ');
  writeInputManifest(root, manifest);
  assert.notEqual(digest(manifest), before);
});

test('runner distinguishes clean source from generated inputs and binds coverage to the built version', t => {
  const fixture = createFixture(t);
  const result = runFixture(fixture);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  const metadata = fs.readFileSync(path.join(result.report, 'run-metadata.txt'), 'utf8');
  assert.match(metadata, /^source_git_tree_state=clean$/m);
  assert.match(metadata, /^git_tree_state=dirty$/m);
  assert.match(metadata, /^build_number=35$/m);
  assert.match(metadata, /^built_app_build_number=35$/m);
  const source = path.join(result.report, 'ios-input-sha256-source.txt');
  const before = path.join(result.report, 'ios-input-sha256-before.txt');
  const after = path.join(result.report, 'ios-input-sha256-after.txt');
  assert.notEqual(digest(source), digest(before));
  assert.equal(digest(before), digest(after));
  assert.match(metadata, new RegExp(`^source_input_manifest_sha256=${digest(source)}$`, 'm'));
  assert.match(metadata, new RegExp(`^input_manifest_sha256=${digest(before)}$`, 'm'));
  const coverage = JSON.parse(fs.readFileSync(path.join(result.report, 'iPhone-swift-coverage.json'), 'utf8'));
  assert.equal(coverage.metadata.gitTreeState, 'dirty');
  assert.equal(coverage.metadata.buildNumber, '35');
  assert.equal(coverage.metadata.inputManifestSha256, digest(before));
});

test('runner rejects shared-vector drift during testing and retains both manifests', t => {
  const fixture = createFixture(t);
  fs.appendFileSync(path.join(fixture.root, vectorPath), '\n');
  const result = runFixture(fixture, {EVIDENCE_MUTATE_VECTOR: '1'});
  assert.equal(result.status, 1, result.stderr + result.stdout);
  assert.match(result.stderr, /iOS\/Core 输入发生变化/);
  const metadata = fs.readFileSync(path.join(result.report, 'run-metadata.txt'), 'utf8');
  assert.match(metadata, /^source_git_tree_state=dirty$/m);
  assert.match(metadata, /^input_stability_exit=1$/m);
  assert.notEqual(digest(path.join(result.report, 'ios-input-sha256-before.txt')),
    digest(path.join(result.report, 'ios-input-sha256-after.txt')));
});

test('runner rejects drift in browser resources referenced by the iOS project', t => {
  const result = runFixture(createFixture(t), {EVIDENCE_MUTATE_RESOURCE: '1'});
  assert.equal(result.status, 1, result.stderr + result.stdout);
  assert.match(fs.readFileSync(path.join(result.report, 'run-metadata.txt'), 'utf8'), /^input_stability_exit=1$/m);
  assert.notEqual(digest(path.join(result.report, 'ios-input-sha256-before.txt')),
    digest(path.join(result.report, 'ios-input-sha256-after.txt')));
});

test('runner rejects a stale app build number before running tests', t => {
  const result = runFixture(createFixture(t), {EVIDENCE_APP_VERSION: '34'});
  assert.equal(result.status, 1, result.stderr + result.stdout);
  assert.match(result.stderr, /CFBundleVersion mismatch/);
  assert.match(fs.readFileSync(path.join(result.report, 'run-metadata.txt'), 'utf8'), /^built_app_build_number=34$/m);
  assert.ok(!fs.existsSync(path.join(result.report, 'iPhone.xcresult')));
});

test('dry run keeps the source and report directory untouched', t => {
  const fixture = createFixture(t);
  const result = runFixture(fixture, {}, '--dry-run');
  assert.equal(result.status, 0, result.stderr + result.stdout);
  assert.match(result.stdout, /DRY_RUN=PASS/);
  assert.equal(git(fixture.root, ['status', '--porcelain']), '');
  assert.ok(!fs.existsSync(result.report));
});
