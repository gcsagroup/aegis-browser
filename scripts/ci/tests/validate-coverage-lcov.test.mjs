// SPDX-License-Identifier: Apache-2.0
import assert from 'node:assert/strict';
import test from 'node:test';

import {repoRoot} from '../common.mjs';
import {parseLcov} from '../validate-coverage.mjs';

const sourcePath = 'scripts/ci/validate-coverage.mjs';

function lcovRecord({lf, lh, da}) {
  return [
    `SF:${sourcePath}`,
    'FNF:1',
    'FNH:1',
    ...da.map(([line, count]) => `DA:${line},${count}`),
    'BRF:0',
    'BRH:0',
    `LF:${lf}`,
    `LH:${lh}`,
    'end_of_record',
    '',
  ].join('\n');
}

test('strict LCOV validation still rejects line-summary mismatches', () => {
  const source = lcovRecord({lf: 2, lh: 2, da: [[1, 1]]});
  assert.throws(
    () => parseLcov(source, repoRoot),
    /line totals do not match DA data/u,
  );
});

test('LLVM LCOV mode accepts a line-summary superset', () => {
  const source = lcovRecord({lf: 2, lh: 2, da: [[1, 1]]});
  const parsed = parseLcov(source, repoRoot, {
    allowLineSummarySuperset: true,
  });
  assert.equal(parsed.totals.lines.total, 2);
  assert.equal(parsed.totals.lines.covered, 2);
});

test('LLVM LCOV mode rejects DA data that exceeds the summary', () => {
  const source = lcovRecord({lf: 0, lh: 0, da: [[1, 1]]});
  assert.throws(
    () =>
      parseLcov(source, repoRoot, {
        allowLineSummarySuperset: true,
      }),
    /DA data exceeds line summary totals/u,
  );
});

test('LLVM LCOV mode rejects more uncovered DA lines than the summary', () => {
  const source = lcovRecord({lf: 2, lh: 2, da: [[1, 0]]});
  assert.throws(
    () =>
      parseLcov(source, repoRoot, {
        allowLineSummarySuperset: true,
      }),
    /DA data exceeds line summary totals/u,
  );
});
