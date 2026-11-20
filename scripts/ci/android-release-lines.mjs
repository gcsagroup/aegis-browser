import {readFileSync} from 'node:fs';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';

const RELEASE_LINE_NAME = /^main$/u;

export function releaseLines(read = () => readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'android-release-lines.json'), 'utf8')) {
  const lines = JSON.parse(read())?.lines;
  if (!Array.isArray(lines) || lines.length !== 1) throw new Error('Android release lines are invalid');
  const line = lines[0];
  if (!line || line.name !== 'main' || line.ref !== 'refs/heads/main' || !RELEASE_LINE_NAME.test(line.name)) {
    throw new Error('Android release lines are invalid');
  }
  return lines;
}
