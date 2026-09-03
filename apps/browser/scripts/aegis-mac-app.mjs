import {readFileSync} from 'node:fs';
import {readFile} from 'node:fs/promises';
import {join} from 'node:path';

export const AEGIS_MAC_PRODUCT_NAME = 'GCSA Aegis';
export const AEGIS_MAC_APP_BUNDLE_NAME = `${AEGIS_MAC_PRODUCT_NAME}.app`;

function decodeXmlText(value) {
  return value
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'");
}

export function bundleExecutableNameFromPlist(plist) {
  const match = plist.match(
    /<key>\s*CFBundleExecutable\s*<\/key>\s*<string>([^<]+)<\/string>/u,
  );
  if (!match) {
    throw new Error('Info.plist 缺少 CFBundleExecutable');
  }
  const name = decodeXmlText(match[1].trim());
  if (
    !name ||
    name === '.' ||
    name === '..' ||
    name.includes('/') ||
    name.includes('\0')
  ) {
    throw new Error('Info.plist 的 CFBundleExecutable 不是安全文件名');
  }
  return name;
}

export function macAppExecutableNameSync(appPath) {
  const plist = readFileSync(join(appPath, 'Contents', 'Info.plist'), 'utf8');
  return bundleExecutableNameFromPlist(plist);
}

export async function macAppExecutableName(appPath) {
  const plist = await readFile(join(appPath, 'Contents', 'Info.plist'), 'utf8');
  return bundleExecutableNameFromPlist(plist);
}

export function macAppExecutablePath(appPath, executableName) {
  return join(appPath, 'Contents', 'MacOS', executableName);
}

export function macAppFrameworkExecutablePath(appPath, executableName) {
  const frameworkName = `${executableName} Framework`;
  return join(
    appPath,
    'Contents',
    'Frameworks',
    `${frameworkName}.framework`,
    'Versions',
    'Current',
    frameworkName,
  );
}
