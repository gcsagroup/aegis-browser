#!/usr/bin/env node
import {writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {fail, parseArgs, repoRoot, sourceSnapshot} from './common.mjs';

try {
  const {values} = parseArgs(process.argv.slice(2), ['write', 'verify', 'repo']);
  const cwd = resolve(values.repo ?? repoRoot);
  const snapshot = sourceSnapshot(cwd);
  if (values.verify) {
    const expected = JSON.parse(await import('node:fs').then(({readFileSync}) => readFileSync(resolve(values.verify), 'utf8')));
    if (expected.digest !== snapshot.digest || expected.files !== snapshot.files) {
      fail(`Source changed: expected ${expected.digest}/${expected.files}, got ${snapshot.digest}/${snapshot.files}`);
    }
  }
  if (values.write) {
    writeFileSync(resolve(values.write), `${JSON.stringify(snapshot, null, 2)}\n`);
  }
  console.log(JSON.stringify(snapshot));
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
