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
const printed = new Map();
for (const line of output.split('\n')) {
  const eq = line.indexOf('=');
  if (eq > 0) printed.set(line.slice(0, eq), line.slice(eq + 1));
}
const additions = [];
const remember = (key, value) => {
  additions.push(`${key}=${value}`);
  if (key === 'docs') plan.docs = value;
  else if (key === 'ios') plan.ios = value;
  else if (key === 'android') plan.android = value;
  else if (key === 'macos') plan.macos = value;
  else if (key === 'windows') plan.windows = value;
  else if (key === 'linux') plan.linux = value;
  else if (key === 'integrate') plan.integrate = value;
  else if (key === 'deep') plan.deep = value;
};
const current = key => {
  if (printed.has(key)) return printed.get(key) === 'true';
  if (key === 'docs') return plan.docs === true;
  if (key === 'ios') return plan.ios === true;
  if (key === 'android') return plan.android === true;
  if (key === 'macos') return plan.macos === true;
  if (key === 'windows') return plan.windows === true;
  if (key === 'linux') return plan.linux === true;
  if (key === 'integrate') return plan.integrate === true;
  return plan.deep === true;
};
const apply = (key, value) => {
  if (printed.has(key)) return;
  printed.set(key, String(value));
  remember(key, value);
};
const iosDefault = process.env.ROUTE_DEFAULT_MISSING_IOS;
const macosDefault = process.env.ROUTE_DEFAULT_MISSING_MACOS;
const docsDefault = process.env.ROUTE_DEFAULT_MISSING_DOCS;
if (iosDefault === 'true' || iosDefault === 'false') apply('ios', iosDefault === 'true');
if (macosDefault === 'true' || macosDefault === 'false') apply('macos', macosDefault === 'true');
if (docsDefault === 'true' || docsDefault === 'false') apply('docs', docsDefault === 'true');
apply('android', false);
apply('windows', false);
apply('linux', false);
const opened = current('ios') || current('macos');
apply('integrate', opened);
apply('deep', opened);
if (additions.length === 0) process.exit(0);
// eslint-disable-next-line security/detect-non-literal-fs-filename -- Same runner-owned output file as the read above.
appendFileSync(outputPath, `${output.endsWith('\n') || output.length === 0 ? '' : '\n'}${additions.join('\n')}\n`);
plan.platformReason = 'missing-platform-rule-default';
// eslint-disable-next-line security/detect-non-literal-fs-filename -- Same workflow-owned plan artifact as the read above.
writeFileSync(planPath, `${JSON.stringify(plan, null, 2)}\n`);
