import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import {parse} from 'yaml';

test('iOS Access delivery keeps its self-hosted, internal-only workflow contract', () => {
  const delivery = readFileSync('.github/workflows/ios-delivery.yml', 'utf8');
  const fork = readFileSync('.github/workflows/ios-fork-access.yml', 'utf8');
  assert(delivery.includes('AEGIS_IOS_RUNNER_LABEL'));
  assert(fork.includes('AEGIS_IOS_RUNNER_LABEL'));
  assert(!delivery.includes('macos-26'));
  assert(!fork.includes('macos-26'));
  assert(!fork.includes('DISTRIBUTION_P12'));
  assert(!fork.includes('altool'));
  const commands = Object.values(parse(fork).jobs).flatMap(job => job.steps ?? [])
    .map(step => step.run ?? '').join('\n');
  assert(commands.includes('ios-access-tests.sh'));
  assert(commands.includes('ios-internal-archive.sh'));
});
