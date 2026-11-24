#!/usr/bin/env node
import {readFileSync} from 'node:fs';

const platforms = ['android', 'ios', 'linux', 'macos', 'windows'];

export function selectPlatformChecks(plan, tested, rules) {
  const sha = /^[a-f0-9]{40}$/u;
  if (!sha.test(tested) || !sha.test(rules) || plan.tested !== tested || plan.rulesSha !== rules) {
    throw new Error('Platform plan source identity mismatch');
  }
  const {android, ios, linux, macos, windows, docs, integrate, deep} = plan;
  const decisions = Object.entries({android, ios, linux, macos, windows});
  if (plan.schemaVersion !== 3 || plan.gate !== true ||
      [docs, integrate, deep, ...decisions.map(([, selected]) => selected)].some(value => typeof value !== 'boolean')) {
    throw new Error('Platform plan schema or decisions are invalid');
  }
  const selected = decisions.filter(([, enabled]) => enabled).map(([name]) => name);
  if (docs && (integrate || deep || selected.length > 0)) {
    throw new Error('An admitted documentation route cannot require platform jobs');
  }
  if (!integrate && (deep || selected.length > 0)) {
    throw new Error('Platform selection requires the integration stage');
  }
  return selected;
}

export function checkPlatformResults(required, needs) {
  if (!Array.isArray(required) || required.some(name => !platforms.includes(name))
      || new Set(required).size !== required.length) throw new Error('Invalid platform job selection');
  if (needs.plan?.result !== 'success') throw new Error('Platform plan did not succeed');
  const jobs = new Map(Object.entries(needs));
  const failures = platforms.flatMap(name => {
    const result = jobs.get(name)?.result;
    const expected = required.includes(name) ? 'success' : 'skipped';
    return result === expected ? [] : [name + '=' + (result || 'missing') + ' (expected ' + expected + ')'];
  });
  if (failures.length) throw new Error(failures.join(', '));
  return {result: 'PASS', required, notApplicable: platforms.filter(name => !required.includes(name))};
}

if (import.meta.main) {
  const [command, tested, rules] = process.argv.slice(2);
  try {
    if (command === 'plan') {
      const plan = JSON.parse(readFileSync(0, 'utf8'));
      console.log(JSON.stringify(selectPlatformChecks(plan, tested, rules)));
    } else if (command === 'results') {
      const summary = checkPlatformResults(JSON.parse(process.env.PLATFORM_REQUIRED), JSON.parse(process.env.PLATFORM_NEEDS));
      console.log(JSON.stringify(summary, null, 2));
    } else {
      throw new Error('Expected plan or results command');
    }
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
