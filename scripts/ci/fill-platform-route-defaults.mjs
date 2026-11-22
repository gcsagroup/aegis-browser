#!/usr/bin/env node
import {appendFileSync, readFileSync, writeFileSync} from 'node:fs';

// Fill keys an older trusted-base router did not print. A value that is already
// printed stays, including an explicit false. New platforms default off so an
// old router cannot fan a change out onto Android, Windows or Linux.
const outputPath = process.env.GITHUB_OUTPUT;
const planPath = process.argv[2];
if (!outputPath || !planPath) throw new Error('GITHUB_OUTPUT and plan path required');
// eslint-disable-next-line security/detect-non-literal-fs-filename -- The runner supplies its own output file and the workflow names the plan artifact.
const output = readFileSync(outputPath, 'utf8');
// eslint-disable-next-line security/detect-non-literal-fs-filename -- The plan path is the artifact written by this same job.
const plan = JSON.parse(readFileSync(planPath, 'utf8'));
const has = key => new RegExp(`^${key}=`, 'm').test(output);
const get = key => (output.match(new RegExp(`^${key}=(.*)`, 'm')) ?? [])[1] ?? '';
const added = {};
const set = (key, value) => {
  if (has(key) || Object.hasOwn(added, key)) return;
  added[key] = value;
  plan[key] = value;
};
const current = key => {
  if (Object.hasOwn(added, key)) return added[key];
  if (has(key)) return get(key) === 'true';
  return plan[key] === true;
};
const typedDefault = {
  ios: process.env.ROUTE_DEFAULT_MISSING_IOS,
  macos: process.env.ROUTE_DEFAULT_MISSING_MACOS,
  docs: process.env.ROUTE_DEFAULT_MISSING_DOCS,
};
for (const [key, value] of Object.entries(typedDefault)) {
  if (value === 'true' || value === 'false') set(key, value === 'true');
}
for (const key of ['android', 'windows', 'linux']) set(key, false);
const opened = current('ios') || current('macos');
set('integrate', opened);
set('deep', opened);
if (Object.keys(added).length === 0) process.exit(0);
const lines = Object.entries(added).map(([key, value]) => `${key}=${value}`);
// eslint-disable-next-line security/detect-non-literal-fs-filename -- Same runner-owned files as the reads above.
appendFileSync(outputPath, `${output.endsWith('\n') || output.length === 0 ? '' : '\n'}${lines.join('\n')}\n`);
plan.platformReason = 'missing-platform-rule-default';
writeFileSync(planPath, `${JSON.stringify(plan, null, 2)}\n`);
