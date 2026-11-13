import {readFileSync} from 'node:fs';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';

const RELEASE_LINE_NAME = /^(?:main|releases\/ios\/[0-9]{1,10}\.[0-9]{1,10})$/u;

export function releaseLines(read = () => readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'ios-release-lines.json'), 'utf8')) {
  const lines = JSON.parse(read())?.lines;
  if (!Array.isArray(lines) || lines.length < 1 || lines.length > 20) throw new Error('iOS release lines are invalid');
  const names = new Set();
  for (const line of lines) {
    if (!line || typeof line.name !== 'string' || line.ref !== `refs/heads/${line.name}` || !RELEASE_LINE_NAME.test(line.name) || names.has(line.name)) {
      throw new Error('iOS release lines are invalid');
    }
    names.add(line.name);
  }
  if (!names.has('main')) throw new Error('iOS release lines are invalid');
  return lines;
}

export function qualityBranchNames() {
  return ['develop', ...releaseLines().map(line => line.name)];
}
