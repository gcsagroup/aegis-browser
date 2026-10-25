import assert from 'node:assert/strict';
import {Buffer} from 'node:buffer';
import {spawn, spawnSync} from 'node:child_process';
import {once} from 'node:events';
import {mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync} from 'node:fs';
import {join, resolve} from 'node:path';
import {clearTimeout, setTimeout} from 'node:timers';
import {fileURLToPath} from 'node:url';
import test from 'node:test';

const root = fileURLToPath(new URL('../../../', import.meta.url));
const core = resolve(root, 'packages/core');
const preload = join(core, 'vitest-coverage-exit.mjs');

function runFork(body, {enabled = true, coverage = true, traceExit = false, vitestCoverage = false,
  rawDirectory = 'existing'} = {}) {
  mkdirSync(join(core, '.artifacts'), {recursive: true});
  const directory = mkdtempSync(join(core, '.artifacts', 'v8-exit-'));
  const raw = rawDirectory === 'existing' ? join(directory, 'raw') : join(directory, 'nested', 'raw');
  if (rawDirectory === 'existing') mkdirSync(raw);
  if (rawDirectory === 'blocked') writeFileSync(join(directory, 'nested'), 'not a directory');
  const receipt = join(directory, 'exit.json');
  const production = vitestCoverage || rawDirectory === 'missing';
  if (production) writeFileSync(join(directory, 'owned-production.mjs'),
    'export function exercisedProduction() { return 42; }');
  writeFileSync(join(directory, 'fixture.test.mjs'), [
    "import {test, expect} from 'vitest';",
    "import {existsSync, writeFileSync} from 'node:fs';",
    production ? "import {exercisedProduction} from './owned-production.mjs';" : '',
    'process.on("exit", code => writeFileSync(' + JSON.stringify(receipt) + ', JSON.stringify({code})));',
    'function executedBeforeStop() { return ' + (production ? 'exercisedProduction()' : '42') + '; }',
    "test('owned fork fixture', async () => { " + body + ' });',
  ].join('\n'));
  const config = join(directory, 'vitest.config.mjs');
  writeFileSync(config, 'export default ' + JSON.stringify({root: directory, test: {
    include: ['fixture.test.mjs'], pool: 'forks', maxWorkers: 1, testTimeout: 200,
    execArgv: enabled ? ['--import', preload] : [],
    ...(vitestCoverage ? {coverage: {enabled: true, provider: 'v8', reporter: ['json-summary'],
      reportsDirectory: join(directory, 'core-coverage'), include: ['owned-production.mjs']}} : {}),
  }}) + ';\n');
  // Observe the real Vitest-owned child without changing its arguments or lifecycle.
  const observer = join(directory, 'observe-exit.mjs');
  if (traceExit) writeFileSync(observer, [
    "import childProcess from 'node:child_process';",
    "import {writeFileSync} from 'node:fs';",
    "import {syncBuiltinESMExports} from 'node:module';",
    'const fork = childProcess.fork;',
    'childProcess.fork = function (...args) {',
    '  const child = Reflect.apply(fork, this, args);',
    '  child.once("exit", (code, signal) => writeFileSync(' +
      JSON.stringify(join(directory, 'worker-exit.json')) + ', JSON.stringify({pid: child.pid, code, signal})));',
    '  return child;',
    '};',
    'syncBuiltinESMExports();',
  ].join('\n'));
  const result = spawnSync(process.execPath, [...(traceExit ? ['--import', observer] : []),
    join(core, 'node_modules/vitest/vitest.mjs'),
    'run', '--config', config], {
    cwd: core, env: {...process.env, NODE_V8_COVERAGE: coverage ? raw : ''},
    encoding: 'utf8', timeout: 15_000,
  });
  // Keep actual subprocess output and raw reports, including failure fixtures.
  writeFileSync(join(directory, 'stdout.log'), result.stdout ?? '');
  writeFileSync(join(directory, 'stderr.log'), result.stderr ?? '');
  assert.equal(result.error, undefined, result.stderr);
  // The blocked-path fixture deliberately cannot contain reports; its test must
  // assert the real handoff error instead. Every normal raw file stays strict.
  const reports = (rawDirectory === 'blocked' ? [] : readdirSync(raw)).map(name => {
    const bytes = readFileSync(join(raw, name));
    assert.ok(bytes.length > 0, 'Empty raw report: ' + name);
    const report = JSON.parse(bytes.toString());
    assert.ok(Array.isArray(report.result));
    return {name, report};
  });
  return {result, entries: reports.flatMap(({report}) => report.result), reports, receipt, directory};
}

test('fork teardown without the preload loses executed worker coverage (baseline)', () => {
  const {result, entries} = runFork('expect(executedBeforeStop()).toBe(42);', {enabled: false});
  assert.equal(result.status, 0, result.stderr);
  assert.equal(entries.some(entry => entry.url.endsWith('/fixture.test.mjs')), false);
});

test('the actual Vitest fork finishes teardown with complete executed-source coverage', () => {
  const {result, entries, receipt} = runFork('expect(executedBeforeStop()).toBe(42);');
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(readFileSync(receipt)).code, 0);
  const source = entries.find(entry => entry.url.endsWith('/fixture.test.mjs'));
  assert.ok(source, 'Executed worker source must remain covered');
  assert.ok(source.functions.some(fn => fn.functionName === 'executedBeforeStop' &&
    fn.ranges.some(range => range.count > 0)));
});

for (const vitestCoverage of [false, true]) {
test('a fresh nested coverage directory preserves production coverage; Vitest V8=' + vitestCoverage, () => {
  const {result, reports, directory} = runFork(`
    expect(existsSync(process.env.NODE_V8_COVERAGE)).toBe(false);
    expect(executedBeforeStop()).toBe(42);
  `, {rawDirectory: 'missing', traceExit: true, vitestCoverage});
  assert.equal(result.status, 0, result.stderr);
  const termination = JSON.parse(readFileSync(join(directory, 'worker-exit.json')));
  assert.equal(termination.code, 0);
  const own = reports.find(({name}) => name.startsWith('coverage-' + termination.pid + '-') && name.endsWith('-0.json'));
  assert.ok(own, 'The fresh directory must contain this exact worker report');
  if (vitestCoverage) {
    const summary = JSON.parse(readFileSync(join(directory, 'core-coverage/coverage-summary.json')));
    const production = Object.entries(summary).find(([name]) => name.endsWith('/owned-production.mjs'))?.[1];
    assert.ok(production, 'Vitest must retain the executed production coverage');
    assert.equal(production.lines.pct, 100);
    assert.equal(production.functions.covered, 1);
  } else {
    const source = own.report.result.find(entry => entry.url.endsWith('/owned-production.mjs'));
    assert.ok(source, 'The exact worker report must contain the production module');
    assert.ok(source.functions.some(fn => fn.functionName === 'exercisedProduction' &&
      fn.ranges.some(range => range.count > 0)));
  }
});
}

test('a non-directory coverage ancestor remains an explicit failed Vitest run', () => {
  const {result} = runFork('expect(executedBeforeStop()).toBe(42);', {rawDirectory: 'blocked'});
  assert.notEqual(result.status, 0, 'A non-directory coverage path was silently accepted');
  assert.match(result.stderr, /V8 worker coverage handoff failed: ENOTDIR/);
});

for (const vitestCoverage of [false, true]) {
test('a real fork killed at the 500 ms exit boundary already handed off coverage; Vitest V8=' + vitestCoverage, () => {
  const {result, reports, directory} = runFork(`
    process.on('exit', () => {
      const marker = new URL('./slow-exit.txt', import.meta.url);
      writeFileSync(marker, 'entered');
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1500);
      writeFileSync(marker, 'completed');
    });
    expect(executedBeforeStop()).toBe(42);
  `, {traceExit: true, vitestCoverage});
  assert.equal(result.status, 0, result.stderr);
  assert.equal(readFileSync(join(directory, 'slow-exit.txt'), 'utf8'), 'entered');
  const termination = JSON.parse(readFileSync(join(directory, 'worker-exit.json')));
  assert.equal(termination.code, null);
  assert.equal(termination.signal, 'SIGKILL');
  const own = reports.find(({name}) => name.startsWith('coverage-' + termination.pid + '-') && name.endsWith('-0.json'));
  assert.ok(own, 'A successful stop ACK must already own this exact worker report');
  if (vitestCoverage) {
    const summary = JSON.parse(readFileSync(join(directory, 'core-coverage/coverage-summary.json')));
    const production = Object.entries(summary).find(([name]) => name.endsWith('/owned-production.mjs'))?.[1];
    assert.ok(production, 'Vitest must retain the production coverage it collected before stop');
    assert.equal(production.lines.pct, 100);
    assert.equal(production.functions.covered, 1);
  } else {
    const source = own.report.result.find(entry => entry.url.endsWith('/fixture.test.mjs'));
    assert.ok(source, 'The exact worker dump must contain the executed fixture');
    assert.ok(source.functions.some(fn => fn.functionName === 'executedBeforeStop' &&
      fn.ranges.some(range => range.count > 0)));
  }
});
}

test('a worker that cannot hand off coverage is an explicit failed Vitest run', () => {
  const {result} = runFork(`
    const {stopCoverage} = await import('node:v8');
    stopCoverage();
    expect(executedBeforeStop()).toBe(42);
  `);
  assert.notEqual(result.status, 0, 'Missing whole-worker coverage was silently accepted');
  assert.match(result.stderr, /V8 worker coverage handoff failed:/);
});

for (const [name, body, workerCode] of [
  ['nonzero exit', 'process.exitCode = 7; expect(executedBeforeStop()).toBe(42);', 7],
  ['assertion failure', 'expect(executedBeforeStop()).toBe(0);', null],
  ['exception', 'throw new Error("intentional owned-fixture failure");', null],
  ['unfinished test', 'await new Promise(() => {});', null],
  ['unexpected SIGTERM', 'process.kill(process.pid, "SIGTERM"); await new Promise(() => {});', 143],
]) {
  test(name + ' remains a failed Vitest run', () => {
    const {result, receipt} = runFork(body);
    assert.notEqual(result.status, 0, name + ' was silently accepted');
    if (workerCode !== null) assert.equal(JSON.parse(readFileSync(receipt)).code, workerCode);
    if (workerCode === 7) assert.match(result.stderr, /Vitest worker requested nonzero exit code 7/);
  });
}

test('without V8 coverage the actual fork keeps its ordinary test result', () => {
  const {result, entries} = runFork('expect(executedBeforeStop()).toBe(42);', {coverage: false});
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(entries, []);
});

test('the preload leaves a non-Vitest owned Node process on ordinary SIGTERM semantics', async () => {
  mkdirSync(join(root, '.artifacts'), {recursive: true});
  const directory = mkdtempSync(join(root, '.artifacts', 'non-vitest-'));
  const fixture = join(directory, 'owned.cjs');
  writeFileSync(fixture, 'process.send({ready:true});setInterval(()=>{},1000);');
  const child = spawn(process.execPath, ['--import', preload, fixture], {
    env: {...process.env, NODE_V8_COVERAGE: join(directory, 'coverage')},
    stdio: ['ignore', 'pipe', 'pipe', 'ipc'],
  });
  child.stdout.resume();
  child.stderr.resume();
  const closed = once(child, 'close');
  const watchdog = setTimeout(() => child.kill('SIGKILL'), 5000);
  try {
    await Promise.race([once(child, 'message'), closed.then(() => { throw new Error('Early child close'); })]);
    child.kill('SIGTERM');
    const [code, signal] = await closed;
    assert.equal(code, null);
    assert.equal(signal, 'SIGTERM');
  } finally {
    if (child.exitCode === null && child.signalCode === null) {
      child.kill('SIGKILL');
      await closed;
    }
    clearTimeout(watchdog);
  }
});

for (const argument of ['non-file-tag', join(core, 'node_modules/vitest/dist/workers/forks.js')]) {
  test('the preload leaves IPC eval with argument ' + argument + ' untouched', async () => {
    mkdirSync(join(root, '.artifacts'), {recursive: true});
    const directory = mkdtempSync(join(root, '.artifacts', 'non-vitest-eval-'));
    const child = spawn(process.execPath, ['--import', preload, '-e',
      'process.send({ready:true,arg:process.argv[1]});setInterval(()=>{},1000);', argument], {
      env: {...process.env, NODE_V8_COVERAGE: join(directory, 'coverage')},
      stdio: ['ignore', 'pipe', 'pipe', 'ipc'],
    });
    const stdout = [];
    const stderr = [];
    child.stdout.on('data', chunk => stdout.push(chunk));
    child.stderr.on('data', chunk => stderr.push(chunk));
    const closed = once(child, 'close');
    const watchdog = setTimeout(() => child.kill('SIGKILL'), 5000);
    try {
      const [message] = await Promise.race([once(child, 'message'),
        closed.then(() => { throw new Error('Early eval close: ' + Buffer.concat(stderr)); })]);
      assert.deepEqual(message, {ready: true, arg: argument});
      child.kill('SIGTERM');
      const [code, signal] = await closed;
      assert.equal(code, null);
      assert.equal(signal, 'SIGTERM');
    } finally {
      if (child.exitCode === null && child.signalCode === null) {
        child.kill('SIGKILL');
        await closed;
      }
      clearTimeout(watchdog);
      writeFileSync(join(directory, 'stdout.log'), Buffer.concat(stdout));
      writeFileSync(join(directory, 'stderr.log'), Buffer.concat(stderr));
      writeFileSync(join(directory, 'exit.json'), JSON.stringify({code: child.exitCode, signal: child.signalCode}));
    }
  });
}
