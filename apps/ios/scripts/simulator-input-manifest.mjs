import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

export function writeInputManifest(repoRoot, destination, embeddedProducts) {
  // Include shared test resources and policy-generation inputs outside apps/ios.
  const output = execFileSync('git', [
    'ls-files', '-z', '--cached', '--others', '--exclude-standard', '--',
    'apps/ios', 'packages/core',
    'apps/browser/overlay/chrome/browser/resources/aegis/enhancements_shared',
    'scripts/release/prepare-ios-package-core.sh', 'scripts/release/prepare-ios-access-core.sh',
    'scripts/release/build-ios-access-core.sh', 'scripts/release/record-ios-access-core-digests.sh',
    'scripts/release/ios_embedded_core.py',
  ], {cwd: repoRoot, maxBuffer: 16 * 1024 * 1024}).toString('utf8');
  const files = [...new Set(output.split('\0').filter(Boolean))].map(file => [file, path.join(repoRoot, file)]);
  if (embeddedProducts) {
    const include = relative => {
      const input = path.join(embeddedProducts, relative);
      // eslint-disable-next-line security/detect-non-literal-fs-filename -- Read the selected native build products; never follow a product symlink.
      const stat = fs.lstatSync(input);  // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
      if (stat.isDirectory()) {
        // eslint-disable-next-line security/detect-non-literal-fs-filename -- Enumerate only the selected native framework's files.
        for (const name of fs.readdirSync(input)) include(path.join(relative, name));  // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
      } else if (stat.isFile()) {
        files.push([`@EmbeddedCore/${relative.split(path.sep).join('/')}`, input]);
      } else {
        throw new Error('EmbeddedCore input must be a regular file or directory');
      }
    };
    for (const relative of ['build-manifest.json', 'embedded-core-lock.json', 'build-inputs.xcfilelist',
      'AegisEmbeddedCore.xcframework']) include(relative);
  }
  files.sort(([left], [right]) => Buffer.from(left).compare(Buffer.from(right)));
  const lines = files.map(([file, input]) => {
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- Local operator selects the repository and output; input names come from git ls-files.
    const digest = createHash('sha256').update(fs.readFileSync(input)).digest('hex');  // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
    // Match shasum's escaped filename convention, keeping each record on one line.
    const escaped = file.replaceAll('\\', '\\\\').replaceAll('\n', '\\n').replaceAll('\r', '\\r');
    return `${escaped === file ? '' : '\\'}${digest}  ${escaped}\n`;
  });
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- Local operator selects the repository and output; input names come from git ls-files.
  fs.writeFileSync(destination, lines.join(''));  // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  if (![4, 5].includes(process.argv.length)) throw new Error('usage: simulator-input-manifest.mjs REPO_ROOT OUTPUT [EMBEDDED_PRODUCTS]');
  writeInputManifest(process.argv[2], process.argv[3], process.argv[4]);
}
