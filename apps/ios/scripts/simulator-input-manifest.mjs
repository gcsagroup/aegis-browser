import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

export function writeInputManifest(repoRoot, destination) {
  // Include shared test resources and policy-generation inputs outside apps/ios.
  const output = execFileSync('git', [
    'ls-files', '-z', '--cached', '--others', '--exclude-standard', '--',
    'apps/ios', 'packages/core',
    'apps/browser/overlay/chrome/browser/resources/aegis/enhancements_shared',
  ], {cwd: repoRoot, maxBuffer: 16 * 1024 * 1024}).toString('utf8');
  const files = [...new Set(output.split('\0').filter(Boolean))]
    .sort((left, right) => Buffer.from(left).compare(Buffer.from(right)));
  const lines = files.map(file => {
    const digest = createHash('sha256').update(fs.readFileSync(path.join(repoRoot, file))).digest('hex');
    // Match shasum's escaped filename convention, keeping each record on one line.
    const escaped = file.replaceAll('\\', '\\\\').replaceAll('\n', '\\n').replaceAll('\r', '\\r');
    return `${escaped === file ? '' : '\\'}${digest}  ${escaped}\n`;
  });
  fs.writeFileSync(destination, lines.join(''));
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  if (process.argv.length !== 4) throw new Error('usage: simulator-input-manifest.mjs REPO_ROOT OUTPUT');
  writeInputManifest(process.argv[2], process.argv[3]);
}
