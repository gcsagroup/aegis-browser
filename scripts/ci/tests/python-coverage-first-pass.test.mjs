import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import test from 'node:test';

const groups = [
  './scripts/check-chromium-upstream_test.py',
  './scripts/release-assets_test.py',
  './scripts/release-github_test.py',
  '-m unittest discover -s ./scripts/ci',
  './scripts/native_validation/terminal_receipt_test.py',
];

test('quality script runs each covered Python group once and propagates failure', () => {
  const directory = mkdtempSync(join(tmpdir(), 'python-coverage-first-pass-'));
  try {
    const trace = join(directory, 'trace');
    const stub = [
      '#!/bin/bash',
      'printf "%s|%s\\n" "${0##*/}" "$*" >> "$TEST_TRACE"',
      'if [[ -n "$TEST_FAIL_GROUP" && "$*" == *"$TEST_FAIL_GROUP"* ]]; then exit 23; fi',
      '',
    ].join('\n');
    for (const tool of ['bash', 'coverage', 'node', 'python3']) {
      writeFileSync(join(directory, tool), stub, {mode: 0o700});
    }
    const script = resolve('apps/browser/scripts/run-script-quality-checks.sh');
    function invoke(coverage, failingGroup = '') {
      writeFileSync(trace, '');
      const result = spawnSync('/bin/bash', [script], {
        encoding: 'utf8',
        env: {...process.env, PATH: `${directory}:${process.env.PATH}`, TEST_TRACE: trace,
          TEST_FAIL_GROUP: failingGroup, AEGIS_PYTHON_COVERAGE_SOURCE: '/fixture',
          AEGIS_PYTHON_COVERAGE_BIN: coverage ? join(directory, 'coverage') : ''},
      });
      return {result, calls: readFileSync(trace, 'utf8').trim().split('\n')};
    }
    for (const coverage of [false, true]) {
      const {result, calls} = invoke(coverage);
      assert.equal(result.status, 0, result.stderr);
      for (const group of groups) {
        const callsForGroup = calls.filter(call => call.includes(group));
        assert.equal(callsForGroup.length, 1, group);
        assert.match(callsForGroup[0], coverage ? /^coverage\|run .*--parallel-mode/u : /^python3\|-B /u);
      }
    }
    const {result, calls} = invoke(true, groups[1]);
    assert.equal(result.status, 23);
    assert(!calls.some(call => call.includes(groups[2])));
  } finally {
    rmSync(directory, {recursive: true, force: true});
  }
});
