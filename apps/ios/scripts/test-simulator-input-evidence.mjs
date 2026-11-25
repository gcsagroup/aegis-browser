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

test('真实本机就绪探测绕过失效代理，并拒绝错误服务身份', () => {
  const result = spawnSync('python3', ['-c', `
import importlib.util, json, os, pathlib, subprocess, sys, threading
from http.server import BaseHTTPRequestHandler
spec = importlib.util.spec_from_file_location('fixture_server', sys.argv[2])
fixture_server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture_server)
source = pathlib.Path(sys.argv[1]).read_text()
probe = source.split("fixture_ready() {\\n  python3 - <<'PYTHON'\\n", 1)[1].split('\\nPYTHON', 1)[0]
class Handler(BaseHTTPRequestHandler):
    model = 'aegis-simulator-fixture'
    def log_message(self, *_): pass
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(json.dumps({'data': [{'id': self.model}]}).encode())
server = fixture_server.FixtureHTTPServer(('127.0.0.1', 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
probe = probe.replace('127.0.0.1:8768', '127.0.0.1:' + str(server.server_port))
environment = {**os.environ, 'http_proxy': 'http://127.0.0.1:1', 'HTTP_PROXY': 'http://127.0.0.1:1', 'no_proxy': '', 'NO_PROXY': ''}
try:
    good = subprocess.run([sys.executable, '-c', probe], env=environment, capture_output=True, text=True, timeout=10)
    assert good.returncode == 0, good.stderr
    Handler.model = 'unrelated-service'
    bad = subprocess.run([sys.executable, '-c', probe], env=environment, capture_output=True, text=True, timeout=10)
    assert bad.returncode != 0, '错误服务身份被接受'
finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=5)
`, path.join(scripts, 'run-simulator-tests.sh'), path.join(scripts, 'simulator-fixture-server.py')], {encoding: 'utf8', timeout: 30000});
  assert.equal(result.status, 0, result.stderr);
});

function write(root, relative, content) {
  const destination = path.join(root, relative);
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- Paths belong to this test’s temporary fixtures and fixed repository resources.
  fs.mkdirSync(path.dirname(destination), {recursive: true});  // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- Paths belong to this test’s temporary fixtures and fixed repository resources.
  fs.writeFileSync(destination, content);  // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
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
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- Paths belong to this test’s temporary fixtures and fixed repository resources.
    fs.mkdirSync(path.join(root, 'apps/ios/scripts'), {recursive: true});  // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
    fs.copyFileSync(path.join(scripts, name), path.join(root, 'apps/ios/scripts', name));
  }
  for (const name of ['verify-fixtures.mjs', 'generate-tracker-rules.mjs', 'test-summarize-xccov.mjs']) {
    write(root, `apps/ios/scripts/${name}`, '// Fixture preflight.\n');
  }
  write(root, 'apps/ios/Tests/SharedWebExtension/SafariNavigationIdentityTests.mjs', '// Fixture preflight.\n');
  write(root, 'apps/ios/scripts/simulator-fixture-server.py', '# Fixture self-test.\n');
  write(root, 'apps/ios/scripts/geosite-https-fixture.py',
    'import subprocess, sys\nsys.exit(subprocess.call(sys.argv[sys.argv.index("--") + 1:]))\n');
  // Upstream Access packaging calls this before xcodegen; keep the fixture self-contained.
  write(root, 'scripts/release/prepare-ios-package-core.sh',
    '#!/usr/bin/env bash\nset -euo pipefail\nmkdir -p "${2:?missing EmbeddedCore products}/AegisEmbeddedCore.xcframework"\n' +
    'for file in build-manifest.json embedded-core-lock.json build-inputs.xcfilelist; do printf fixture > "$2/$file"; done\n' +
    'printf binary > "$2/AegisEmbeddedCore.xcframework/AegisEmbeddedCore"\n');
  write(root, 'scripts/release/ios_embedded_core.py', '# Fixture verifier.\n');
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
    if (process.env.EVIDENCE_MUTATE_EMBEDDED === '1') {
      fs.appendFileSync(path.join(option('-derivedDataPath'), 'EmbeddedCore/AegisEmbeddedCore.xcframework/AegisEmbeddedCore'), 'drift');
    }
    if (process.env.EVIDENCE_MUTATE_CORE_VERIFIER === '1') {
      fs.appendFileSync(path.join(root, 'scripts/release/ios_embedded_core.py'), '# drift');
    }
  } else {
    throw new Error('Unexpected xcodebuild call');
  }
} else if (tool === 'xcrun') {
  const runtime = 'com.apple.CoreSimulator.SimRuntime.iOS-26-5';
  const devices = [
    {name: 'Aegis CI com.gcsa.aegis iPhone 17', deviceTypeIdentifier: 'com.apple.CoreSimulator.SimDeviceType.iPhone-17', udid: 'phone'},
    {name: 'Aegis CI com.gcsa.aegis iPad Air 11-inch (M4)', deviceTypeIdentifier: 'com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M4', udid: 'tablet'},
  ];
  const duoType = 'com.apple.CoreSimulator.SimDeviceType.iPhone-Duo';
  const supported = process.env.EVIDENCE_SUPPORTED_TYPES;
  const runtimeEntry = {identifier: runtime, version: '26.5', isAvailable: true};
  if (supported !== undefined) {
    runtimeEntry.supportedDeviceTypes = supported.split(',').filter(Boolean).map(identifier => ({identifier}));
  }
  if (args[0] === 'simctl' && args[2] === 'runtimes') {
    output({runtimes: [runtimeEntry]});
  } else if (args[0] === 'simctl' && args[2] === 'devicetypes') {
    output({devicetypes: [...devices.map(device => ({identifier: device.deviceTypeIdentifier})),
      {identifier: duoType, name: 'iPhone Duo'}]});
  } else if (args[0] === 'simctl' && args[2] === 'devices') {
    output({devices: {[runtime]: process.env.EVIDENCE_NO_DEVICES === '1' ? [] : devices}});
  } else if (args[0] === 'simctl' && args[1] === 'create') {
    if (process.env.EVIDENCE_CREATE_FAIL === 'fail') {
      console.error('An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=403)');
      console.log('Unable to create a device for device type');
      process.exit(1);
    }
    if (process.env.EVIDENCE_CREATE_FAIL === 'text') {
      console.log('Unable to create a device for device type');
    } else {
      console.log('11111111-2222-3333-4444-555555555555');
    }
  } else if (args[0] === 'xcresulttool') {
    const seed = (option('--path') ?? '').endsWith('-overseas-seed.xcresult');
    const passed = seed && process.env.EVIDENCE_FAIL_OVERSEAS_SEED === '1' ? 0 : 1;
    output({result: passed ? 'Passed' : 'Failed', totalTestCount: 1, passedTests: passed,
      failedTests: 1 - passed, skippedTests: 0});
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

function runFixture(fixture, overrides = {}, mode = '--execute', extraArgs = []) {
  const bin = path.join(fixture.sandbox, 'bin');
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- Paths belong to this test’s temporary fixtures and fixed repository resources.
  fs.mkdirSync(bin);  // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
  for (const tool of ['python3', 'xcodegen', 'xcodebuild', 'xcrun']) {
    const destination = path.join(bin, tool);
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- Paths belong to this test’s temporary fixtures and fixed repository resources.
    fs.writeFileSync(destination, toolFixture, {mode: 0o755});  // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
  }
  const report = path.join(fixture.sandbox, 'report');
  const result = spawnSync('bash', [path.join(fixture.root, 'apps/ios/scripts/run-simulator-tests.sh'),
    mode, '--output-dir', report, ...extraArgs], {
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
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- Paths belong to this test’s temporary fixtures and fixed repository resources.
  return createHash('sha256').update(fs.readFileSync(file)).digest('hex');  // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
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
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- Paths belong to this test’s temporary fixtures and fixed repository resources.
  const text = fs.readFileSync(manifest, 'utf8');  // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
  assert.ok(text.includes(digest(path.join(root, vectorPath))));
  assert.match(text, /packages\/core\/src\/tracker\/builtin-rules.ts/);
  assert.ok(text.includes(resourcePath));
  assert.equal(text.match(/packages\/core\/new.txt/g).length, 1);
  assert.ok(text.includes('apps/ios/new\\nfile.swift'));
  assert.ok(!text.includes('cache.ignored') && !text.includes('unrelated.txt'));
  const before = digest(manifest);
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- Paths belong to this test’s temporary fixtures and fixed repository resources.
  fs.appendFileSync(path.join(root, vectorPath), ' ');  // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
  writeInputManifest(root, manifest);
  assert.notEqual(digest(manifest), before);
});

test('runner distinguishes clean source from generated inputs and binds coverage to the built version', t => {
  const fixture = createFixture(t);
  const result = runFixture(fixture);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- Paths belong to this test’s temporary fixtures and fixed repository resources.
  const metadata = fs.readFileSync(path.join(result.report, 'run-metadata.txt'), 'utf8');  // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
  assert.match(metadata, /^source_git_tree_state=clean$/m);
  assert.match(metadata, /^git_tree_state=dirty$/m);
  assert.match(metadata, /^build_number=35$/m);
  assert.match(metadata, /^built_app_build_number=35$/m);
  const source = path.join(result.report, 'ios-input-sha256-source.txt');
  const before = path.join(result.report, 'ios-input-sha256-before.txt');
  const after = path.join(result.report, 'ios-input-sha256-after.txt');
  assert.notEqual(digest(source), digest(before));
  assert.equal(digest(before), digest(after));
  assert.ok(metadata.split('\n').includes(`source_input_manifest_sha256=${digest(source)}`));
  assert.ok(metadata.split('\n').includes(`input_manifest_sha256=${digest(before)}`));
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- Paths belong to this test’s temporary fixtures and fixed repository resources.
  const coverage = JSON.parse(fs.readFileSync(path.join(result.report, 'iPhone-swift-coverage.json'), 'utf8'));  // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
  assert.equal(coverage.metadata.gitTreeState, 'dirty');
  assert.equal(coverage.metadata.buildNumber, '35');
  assert.equal(coverage.metadata.inputManifestSha256, digest(before));
  for (const device of ['iPhone', 'iPad']) {
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- The report path belongs to this temporary test fixture.
    const seed = JSON.parse(fs.readFileSync(path.join(result.report, `${device}-overseas-seed-summary.json`), 'utf8'));  // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
    assert.equal(seed.passedTests, 1);
  }
});

test('runner refuses the full suite when the overseas settings seed does not pass', t => {
  const fixture = createFixture(t);
  const result = runFixture(fixture, {EVIDENCE_FAIL_OVERSEAS_SEED: '1'});
  assert.notEqual(result.status, 0, result.stderr + result.stdout);
  assert.match(result.stdout + result.stderr, /SIMULATOR_TESTS=FAIL/);
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- The report path belongs to this temporary test fixture.
  assert.ok(!fs.existsSync(path.join(result.report, 'iPhone.xcresult')));  // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- The report path belongs to this temporary test fixture.
  assert.ok(!fs.existsSync(path.join(result.report, 'iPad.xcresult')));  // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
});

test('runner rejects shared-vector drift during testing and retains both manifests', t => {
  const fixture = createFixture(t);
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- Paths belong to this test’s temporary fixtures and fixed repository resources.
  fs.appendFileSync(path.join(fixture.root, vectorPath), '\n');  // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
  const result = runFixture(fixture, {EVIDENCE_MUTATE_VECTOR: '1'});
  assert.equal(result.status, 1, result.stderr + result.stdout);
  assert.match(result.stderr, /iOS\/Core 输入发生变化/);
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- The report path belongs to this temporary test fixture.
  const metadata = fs.readFileSync(path.join(result.report, 'run-metadata.txt'), 'utf8');  // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
  assert.match(metadata, /^source_git_tree_state=dirty$/m);
  assert.match(metadata, /^input_stability_exit=1$/m);
  assert.notEqual(digest(path.join(result.report, 'ios-input-sha256-before.txt')),
    digest(path.join(result.report, 'ios-input-sha256-after.txt')));
});

test('runner rejects drift in browser resources referenced by the iOS project', t => {
  const result = runFixture(createFixture(t), {EVIDENCE_MUTATE_RESOURCE: '1'});
  assert.equal(result.status, 1, result.stderr + result.stdout);
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- Paths belong to this test’s temporary fixtures and fixed repository resources.
  assert.match(fs.readFileSync(path.join(result.report, 'run-metadata.txt'), 'utf8'), /^input_stability_exit=1$/m);  // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
  assert.notEqual(digest(path.join(result.report, 'ios-input-sha256-before.txt')),
    digest(path.join(result.report, 'ios-input-sha256-after.txt')));
});

test('runner rejects drift in the linked EmbeddedCore and its verifier', t => {
  for (const flag of ['EVIDENCE_MUTATE_EMBEDDED', 'EVIDENCE_MUTATE_CORE_VERIFIER']) {
    const result = runFixture(createFixture(t), {[flag]: '1'});
    assert.equal(result.status, 1, result.stderr + result.stdout);
    assert.match(result.stderr, /iOS\/Core 输入发生变化/);
    assert.notEqual(digest(path.join(result.report, 'ios-input-sha256-before.txt')),
      digest(path.join(result.report, 'ios-input-sha256-after.txt')));
  }
});

test('runner rejects a stale app build number before running tests', t => {
  const result = runFixture(createFixture(t), {EVIDENCE_APP_VERSION: '34'});
  assert.equal(result.status, 1, result.stderr + result.stdout);
  assert.match(result.stderr, /CFBundleVersion mismatch/);
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- Paths belong to this test’s temporary fixtures and fixed repository resources.
  assert.match(fs.readFileSync(path.join(result.report, 'run-metadata.txt'), 'utf8'), /^built_app_build_number=34$/m);  // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- Paths belong to this test’s temporary fixtures and fixed repository resources.
  assert.ok(!fs.existsSync(path.join(result.report, 'iPhone.xcresult')));  // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
});

test('dry run keeps the source and report directory untouched', t => {
  const fixture = createFixture(t);
  const result = runFixture(fixture, {}, '--dry-run');
  assert.equal(result.status, 0, result.stderr + result.stdout);
  assert.match(result.stdout, /DRY_RUN=PASS/);
  assert.equal(git(fixture.root, ['status', '--porcelain']), '');
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- Paths belong to this test’s temporary fixtures and fixed repository resources.
  assert.ok(!fs.existsSync(result.report));  // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
});

function exists(file) {
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- Paths belong to this test’s temporary fixtures and fixed repository resources.
  return fs.existsSync(file);  // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
}

function readText(file) {
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- Paths belong to this test’s temporary fixtures and fixed repository resources.
  return fs.readFileSync(file, 'utf8');  // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
}

const duoType = 'com.apple.CoreSimulator.SimDeviceType.iPhone-Duo';
const createdUdid = '11111111-2222-3333-4444-555555555555';

test('runner refuses a runtime that lacks the requested device type before creating devices', t => {
  const result = runFixture(createFixture(t), {EVIDENCE_SUPPORTED_TYPES: duoType, EVIDENCE_NO_DEVICES: '1'});
  assert.equal(result.status, 1, result.stderr + result.stdout);
  assert.match(result.stderr, /runtime 不支持设备类型/);
  assert.ok(!exists(result.report));
});

test('runner stops when simulator creation fails or returns something that is not a UDID', t => {
  for (const [mode, message] of [['fail', /创建 Simulator 失败/], ['text', /返回的不是 UDID/]]) {
    const result = runFixture(createFixture(t), {EVIDENCE_NO_DEVICES: '1', EVIDENCE_CREATE_FAIL: mode});
    assert.equal(result.status, 1, result.stderr + result.stdout);
    assert.match(result.stderr, message);
    assert.doesNotMatch(result.stdout, /已创建专用 Simulator/);
    assert.ok(!exists(result.report));
  }
});

test('runner can run iPhone only with another phone type when the runtime has no iPad', t => {
  const result = runFixture(createFixture(t), {EVIDENCE_SUPPORTED_TYPES: duoType, EVIDENCE_NO_DEVICES: '1'},
    '--execute', ['--phone-device-type', duoType, '--tablet-device-type', 'none']);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  const lines = readText(path.join(result.report, 'run-metadata.txt')).split('\n');
  assert.ok(lines.includes('iphone=Aegis CI com.gcsa.aegis iPhone Duo|' + createdUdid));
  assert.ok(lines.includes('ipad=<skipped>'));
  assert.ok(lines.includes('ipad_exit=skipped'));
  assert.ok(!lines.includes('ipad_exit=0'));
  assert.ok(exists(path.join(result.report, 'iPhone.xcresult')));
  assert.ok(!exists(path.join(result.report, 'iPad.xcresult')));
});

test('runner rejects a malformed device type identifier', t => {
  const result = runFixture(createFixture(t), {}, '--dry-run', ['--phone-device-type', 'iPhone-17']);
  assert.equal(result.status, 1, result.stderr + result.stdout);
  assert.match(result.stderr, /设备类型格式无效/);
});
