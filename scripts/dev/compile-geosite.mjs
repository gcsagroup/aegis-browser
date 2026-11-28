#!/usr/bin/env node

import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {
  closeSync, constants, fstatSync, fsyncSync, linkSync, lstatSync, mkdtempSync, openSync, readSync, realpathSync,
  rmSync, rmdirSync, statSync, writeFileSync,
} from 'node:fs';
import {isIP} from 'node:net';
import {basename, dirname, join} from 'node:path';
import {domainToASCII, fileURLToPath, URL} from 'node:url';
import {parseArgs} from 'node:util';

const MAX_DAT_BYTES = 16 * 1024 * 1024;
const MAX_PSL_BYTES = 512 * 1024;
const MAX_PSL_RULES = 20_000;
const MAX_GROUPS = 4_096;
const MAX_GROUP_BYTES = 512 * 1024;
const MAX_GROUP_CODE_BYTES = 64;
// The pinned XTLS catalogue has opaque groups with up to 75,744 domain records.
const MAX_SCANNED_GROUP_ROWS = 100_000;
const MAX_GROUP_ROWS = 4_096;
const MAX_ROW_BYTES = 1_024;

const DLC = {
  project: 'v2fly/domain-list-community',
  version: '20261121064510',
  commit: 'ffb513217b9cb22835eb74a39a907d77742ce68f',
  file: 'dlc.dat',
  bytes: 2_408_868,
  sha256: 'b1e803c6b8d02def0865b1b4953ee391c562478d8ff7ee3e8b621a2d15fb7ed2',
  url: 'https://github.com/v2fly/domain-list-community/releases/download/20261121064510/dlc.dat',
  license: 'MIT',
  copyright: 'Copyright (c) 2018-2019 V2Ray',
  licenseUrl: 'https://github.com/v2fly/domain-list-community/blob/ffb513217b9cb22835eb74a39a907d77742ce68f/LICENSE',
};
const XTLS = {
  project: 'XTLS/Xray-rules-dat',
  version: '20261127013728',
  commit: '71449413dd268821143695c5bf3720545f392e63',
  tagCommit: '0f8082e3b11bbe8ee65f26de86cbd2e0d510c983',
  file: 'geosite.dat',
  bytes: 7_735_216,
  sha256: '919a4b32cc9e6619e5bc17831cd388f89df77d9bf9817dab98b489d479162047',
  url: 'https://github.com/XTLS/Xray-rules-dat/releases/download/20261127013728/geosite.dat',
  sourceUrl: 'https://github.com/XTLS/Xray-rules-dat/blob/71449413dd268821143695c5bf3720545f392e63/README.md',
  license: 'MIT',
  licenseScope: 'Inherited V2Fly data',
  copyright: 'Copyright (c) 2018-2019 V2Ray',
  licenseUrl: 'https://github.com/XTLS/Xray-rules-dat/blob/71449413dd268821143695c5bf3720545f392e63/LICENSE-inherited',
};
const PSL = {
  project: 'Chromium',
  version: '155.0.8059.80',
  commit: '43a195105613ac83c21d3f14de279f4a045c7da0',
  file: 'effective_tld_names.dat',
  bytes: 331_000,
  sha256: '4155611645690529d1bbea0cfe653b0c45f63b028e0ba039de29a97edc3204ca',
  url: 'https://chromium.googlesource.com/chromium/src/+/43a195105613ac83c21d3f14de279f4a045c7da0/net/base/registry_controlled_domains/effective_tld_names.dat',
  license: 'MPL-2.0',
  licenseUrl: 'https://mozilla.org/MPL/2.0/',
  privateDomains: true,
};
// Each allowlist certifies the complete typed payload for its raw source and the PSL above.
const DEBIAN_SHA256 = 'd865d67c829d0f13bf508e152ef402d5d9634227ed12a8b49434d231baf5a643';
const DLC_GROUPS = new Map([['DEBIAN', DEBIAN_SHA256]]);
const XTLS_GROUPS = new Map([
  ['DEBIAN', '06c514bb68567fdf422969927719a7e6c19442509cb2c69eb43cb02efbc83aeb'],
  ['DOUBAN', '62cfcbf5e006744783206139a2cbb6a3dffb05dbc366f1784a193e887e038619'],
  ['MEITUAN', '7f23061fb1a46f4150077aa56c369188cfda5bb49bd99649264c5bfb7bf8efa9'],
]);
const GROUP_CODE = /^[A-Z0-9][A-Z0-9_!-]*$/;
const LOCAL_SUFFIXES = ['local', 'localhost', 'localdomain', 'home.arpa', 'internal'];
const utf8 = new TextDecoder('utf-8', {fatal: true, ignoreBOM: true});

// Tags and lengths in this schema, and its supported enum values, fit uint32.
class Reader {
  constructor(data) {
    this.data = data;
    this.offset = 0;
  }

  get done() {
    return this.offset === this.data.length;
  }

  varint() {
    let value = 0;
    for (let shift = 0; shift <= 28; shift += 7) {
      if (this.done) throw new Error('Truncated protobuf varint');
      const byte = this.data[this.offset++];
      if (shift === 28 && byte > 15) throw new Error('Protobuf varint exceeds uint32');
      value += (byte & 127) * 2 ** shift;
      if (byte < 128) {
        if (shift && byte === 0) throw new Error('Non-canonical protobuf varint');
        return value;
      }
    }
    throw new Error('Protobuf varint exceeds uint32');
  }

  length(limit) {
    const length = this.varint();
    if (length > this.data.length - this.offset) throw new Error('Truncated protobuf field');
    if (length > limit) throw new Error('Protobuf field exceeds size limit');
    return length;
  }

  bytes(limit) {
    const size = this.length(limit);
    const start = this.offset;
    this.offset += size;
    return this.data.subarray(start, this.offset);
  }

  skipBytes(limit) {
    const size = this.length(limit);
    this.offset += size;
  }
}

function findGroup(data, requested) {
  const catalogue = new Reader(data);
  const codes = new Set();
  let selected;
  while (!catalogue.done) {
    if (codes.size >= MAX_GROUPS) throw new Error('DAT exceeds group count limit');
    if (catalogue.varint() !== 10) throw new Error('Invalid GeoSiteList entry field');
    const group = catalogue.bytes(MAX_DAT_BYTES);
    const fields = new Reader(group);
    let code;
    let rowCount = 0;
    while (!fields.done) {
      switch (fields.varint()) {
        case 10: // GeoSite.country_code
          if (code !== undefined) throw new Error('Duplicate GeoSite group code field');
          code = utf8.decode(fields.bytes(MAX_GROUP_CODE_BYTES));
          break;
        case 18: // GeoSite.domain
          if (++rowCount > MAX_SCANNED_GROUP_ROWS) throw new Error('GeoSite group exceeds record count limit');
          fields.skipBytes(MAX_ROW_BYTES);
          break;
        default:
          throw new Error('Unsupported GeoSite group field');
      }
    }
    if (!code || !GROUP_CODE.test(code)) throw new Error('Invalid GeoSite group code');
    if (codes.has(code)) throw new Error('Duplicate GeoSite group: ' + code);
    codes.add(code);
    if (code === requested) {
      if (group.length > MAX_GROUP_BYTES) throw new Error('Selected group exceeds size limit');
      selected = group;
    }
  }
  if (!selected) throw new Error('GeoSite group not found: ' + requested);
  return selected;
}

function dnsName(input) {
  // Guard the raw DNS path against authority, URL delimiters, and escaped input.
  if (!input || /[\s\p{Cc}%:/\\@[\]?#]/u.test(input)) return '';
  const ascii = domainToASCII(input).replace(/\.$/, '');
  if (!ascii || ascii.length > 253 || isIP(ascii)) return '';
  const validLabels = ascii.split('.').every((label) => label.length > 0 && label.length <= 63 &&
    !label.startsWith('-') && !label.endsWith('-') && !/[^a-z0-9-]/u.test(label));
  return validLabels ? ascii : '';
}

function isLocal(name) {
  return LOCAL_SUFFIXES.some(
    (suffix) => name === suffix || name.endsWith('.' + suffix)
  );
}

function parentName(name) {
  const dot = name.indexOf('.');
  return dot < 0 ? '' : name.slice(dot + 1);
}

function readRegistry(text) {
  if (typeof text !== 'string' || Buffer.byteLength(text) > MAX_PSL_BYTES) {
    throw new Error('PSL exceeds input size limit or is not text');
  }
  const exact = new Set();
  const wildcards = new Set();
  const exceptions = new Set();
  const registryAncestors = new Set();
  let count = 0;

  // The ICANN and PRIVATE sections use the same PSL matching algorithm.
  for (const [line] of text.matchAll(/[^\n]+/g)) {
    const entry = line.trim().split(/\s/u, 1)[0];
    if (!entry || entry.startsWith('//')) continue;
    if (++count > MAX_PSL_RULES) throw new Error('PSL exceeds rule count limit');
    const wildcard = entry.startsWith('*.');
    const exception = entry.startsWith('!');
    const name = dnsName(entry.replace(/^(?:\*\.|!)/, ''));
    if (!name) throw new Error('Invalid PSL rule: ' + entry);
    if (exception) {
      exceptions.add(name);
      continue;
    }
    (wildcard ? wildcards : exact).add(name);
    // A domain rule on an ancestor would also match every registrant under this boundary.
    for (let ancestor = wildcard ? name : parentName(name); ancestor; ancestor = parentName(ancestor)) {
      registryAncestors.add(ancestor);
    }
  }
  if (!count) throw new Error('Empty PSL');
  for (const exception of exceptions) {
    if (!wildcards.has(parentName(exception))) throw new Error('Invalid PSL exception: ' + exception);
  }
  return {exact, wildcards, exceptions, registryAncestors};
}

function isPublicSuffix(name, {exact, wildcards, exceptions}) {
  // Only a rule matching the entire name can make it a public suffix. A matching
  // exception, even on an ancestor, takes priority and shortens the suffix.
  for (let suffix = name; suffix; suffix = parentName(suffix)) {
    if (exceptions.has(suffix)) return false;
  }
  const parent = parentName(name);
  return !parent || exact.has(name) || wildcards.has(parent);
}

function readRule(bytes, registry, requireCanonical) {
  const domain = new Reader(bytes);
  let type;
  let value;
  while (!domain.done) {
    switch (domain.varint()) {
      case 8: // Domain.type
        if (type !== undefined) throw new Error('Duplicate GeoSite domain type field');
        type = domain.varint();
        break;
      case 18: // Domain.value
        if (value !== undefined) throw new Error('Duplicate GeoSite domain value field');
        value = utf8.decode(domain.bytes(MAX_ROW_BYTES));
        break;
      case 26: // Domain.attribute
        throw new Error('GeoSite domain attributes are unsupported');
      default:
        throw new Error('Unsupported GeoSite domain field');
    }
  }
  // Omitted type is the protobuf default, Plain (keyword).
  if (type !== 2 && type !== 3) throw new Error('Unsupported GeoSite domain type: ' + (type ?? 0));
  const name = dnsName(value);
  if (!name || isLocal(name)) throw new Error('Invalid GeoSite DNS rule: ' + value);
  if (requireCanonical && name !== value) throw new Error('Noncanonical GeoSite DNS rule: ' + value);
  if (isPublicSuffix(name, registry)) throw new Error('GeoSite rule is a public suffix: ' + name);
  if (type === 2 && registry.registryAncestors.has(name)) {
    throw new Error('GeoSite domain rule covers a registry boundary: ' + name);
  }
  return Object.freeze({type: type === 2 ? 'domain' : 'full', value: name});
}

// The decoder can inspect synthetic and rejected groups. Only the CLI admits a
// group for the macOS DEV build, after verifying both immutable inputs.
export function compileGroup(buffer, pslText, group, {requireCanonical = false} = {}) {
  if (!Buffer.isBuffer(buffer) || buffer.length > MAX_DAT_BYTES) throw new Error('Invalid DAT input or size limit exceeded');
  if (typeof group !== 'string' || group.length > MAX_GROUP_CODE_BYTES || !GROUP_CODE.test(group)) {
    throw new Error('Invalid requested GeoSite group code');
  }
  const selected = new Reader(findGroup(buffer, group));
  const registry = readRegistry(pslText);
  const rules = [];
  while (!selected.done) {
    // findGroup verified that the only other field here is the group code.
    if (selected.varint() === 10) {
      selected.skipBytes(MAX_GROUP_CODE_BYTES);
      continue;
    }
    if (rules.length >= MAX_GROUP_ROWS) throw new Error('Selected group exceeds row count limit');
    rules.push(readRule(selected.bytes(MAX_ROW_BYTES), registry, requireCanonical));
  }
  if (!rules.length) throw new Error('Selected GeoSite group is empty');
  rules.sort((left, right) => {
    if (left.type !== right.type) return left.type < right.type ? -1 : 1;
    if (left.value === right.value) return 0;
    return left.value < right.value ? -1 : 1;
  });
  if (requireCanonical && rules.some((rule, index) =>
    index > 0 && rule.type === rules[index - 1].type && rule.value === rules[index - 1].value
  )) {
    throw new Error('Duplicate GeoSite rule');
  }
  return {rules: Object.freeze(rules)};
}

export function matchesHost(rules, host) {
  if (typeof host !== 'string') return false;
  let hostname = host;
  const authority = /^(?:https?|wss?):\/\/([^/?#]+)/i.exec(host);
  if (authority) {
    if (/[\s\p{Cc}\\]/u.test(authority[1])) return false;
    try {
      hostname = new URL(host).hostname;
    } catch {
      return false;
    }
  }
  const name = dnsName(hostname);
  if (!name.includes('.') || isLocal(name)) return false;

  return rules.some(({type, value}) =>
    (type === 'full' && name === value) ||
    (type === 'domain' && (name === value || name.endsWith('.' + value))));
}

function sha256(data) {
  return createHash('sha256').update(data).digest('hex');
}

function readExactFile(path, size, label, flags = 0) {
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- Read the selected regular file through a size-checked descriptor.
  const fd = openSync(path, constants.O_RDONLY | constants.O_NONBLOCK | flags);
  try {
    const info = fstatSync(fd, {bigint: true});
    if (!info.isFile() || info.size !== BigInt(size)) throw new Error(label + ' must be a regular file of ' + size + ' bytes');
    // Bound the read even if a file changes after fstat. The extra byte detects growth.
    const data = Buffer.allocUnsafe(size + 1);
    let offset = 0;
    while (offset < data.length) {
      const length = readSync(fd, data, offset, data.length - offset, null);
      if (length === 0) break;
      offset += length;
    }
    if (offset !== size) throw new Error(label + ' changed size while reading');
    return {data: data.subarray(0, size), info};
  } finally {
    closeSync(fd);
  }
}

function readPinned(path, pin, label) {
  const canonicalPath = realpathSync.native(path);
  const input = readExactFile(canonicalPath, pin.bytes, label);
  if (sha256(input.data) !== pin.sha256) throw new Error(label + ' SHA-256 does not match the pin');
  return {...input, namedPath: path, canonicalPath};
}

function checkOutput(path, namedPath, inputs) {
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- Inspect the resolved destination without following a final symlink.
  const destination = lstatSync(path, {bigint: true, throwIfNoEntry: false});
  if (destination && !destination.isFile()) {
    throw new Error('Output destination must be a regular file. Use a fresh --output path.');
  }
  const canonicalPath = destination ? realpathSync.native(path) : path;
  const sameFile = ({dev, ino}) => destination?.dev === dev && destination.ino === ino;
  if (inputs.some((input) => {
    if (namedPath === input.namedPath || canonicalPath === input.canonicalPath || sameFile(input.info)) return true;
    // A parent symlink can retarget the raw input name after the pinned read.
    if (canonicalPath === realpathSync.native(input.namedPath)) return true;
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- Compare inode identity against the original input name after resolution.
    return sameFile(statSync(input.namedPath, {bigint: true}));
  })) {
    throw new Error('Output must be separate from the pinned input files');
  }
  return destination;
}

function checkExistingCatalogue(path, expected, existing) {
  const conflict = 'Existing output changed or differs from the pinned build: ' + path + '. Use a fresh --output path.';
  for (let attempt = 0; attempt < 2; attempt++) {
    if (existing?.size !== BigInt(expected.length)) throw new Error(conflict);
    let opened;
    try {
      opened = readExactFile(path, expected.length, 'Existing output', constants.O_NOFOLLOW);
    } catch (error) {
      throw new Error(conflict, {cause: error});
    }
    const {data, info} = opened;
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- Recheck the opened catalogue's identity without following links.
    const current = lstatSync(path, {bigint: true, throwIfNoEntry: false});
    const sameContentVersion = (other) => other?.dev === info.dev && other.ino === info.ino &&
      other.size === info.size && other.mtimeNs === info.mtimeNs;
    if (!sameContentVersion(existing) || !sameContentVersion(current) || !data.equals(expected)) {
      throw new Error(conflict);
    }
    if (existing.ctimeNs === info.ctimeNs && current.ctimeNs === info.ctimeNs) return;
    // Unlinking the winning publisher's staging name changes ctime on the shared inode.
    existing = current;
  }
  throw new Error(conflict);
}

const READ_ONLY_ACL_RIGHTS = new Set([
  'execute', 'list', 'read', 'readattr', 'readextattr', 'readsecurity', 'search', 'synchronize',
]);

function readMacOutputDirectory(path) {
  const helper = join(dirname(realpathSync.native(fileURLToPath(import.meta.url))), 'read-macos-acl.rb');
  let info;
  try {
    const output = execFileSync('/usr/bin/ruby', ['--disable-gems', helper, path], {
      encoding: 'utf8', env: {...process.env, RUBYOPT: '', RUBYLIB: ''},
    });
    info = JSON.parse(output);
    if (!Number.isInteger(info.uid) || !Number.isInteger(info.mode) || typeof info.acl !== 'string' ||
        typeof info.ignoresOwnership !== 'boolean') {
      throw new Error('Invalid macOS directory metadata');
    }
  } catch (error) {
    throw new Error('Could not read macOS ACL for output directory: ' + path, {cause: error});
  }
  if (info.ignoresOwnership) throw new Error('Output volume ignores ownership: ' + path);
  if (!info.acl) return info;
  const [header, ...records] = info.acl.trimEnd().split('\n');
  const diagnostic = 'Choose a trusted output directory with a read-only macOS ACL: ' + path;
  if (header !== '!#acl 1') throw new Error(diagnostic);
  for (const record of records) {
    const fields = record.split(':');
    if (fields.length < 3) throw new Error(diagnostic);
    const [disposition, ...flags] = fields.at(-2).split(',');
    const rights = fields.at(-1);
    if ((disposition !== 'allow' && disposition !== 'deny') ||
        flags.some((flag) => !/^[a-z_]+$/u.test(flag)) || /[^a-z_,]/u.test(rights) ||
        (disposition === 'allow' && rights && rights.split(',').some((right) => !READ_ONLY_ACL_RIGHTS.has(right)))) {
      throw new Error(diagnostic);
    }
  }
  return info;
}

function requireTrustedOutputDirectory(path, uid) {
  if (uid === undefined) throw new Error('Publishing requires POSIX directory permissions');
  const parent = dirname(path);
  if (parent !== path) requireTrustedOutputDirectory(parent, uid);
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- Inspect each resolved parent for ownership and permissions.
  const info = process.platform === 'darwin' ? readMacOutputDirectory(path) : lstatSync(path);
  const directory = (info.mode & constants.S_IFMT) === constants.S_IFDIR;
  const trustedOwner = info.uid === uid || info.uid === 0;
  const sharedWithoutStickyBit = (info.mode & 0o022) !== 0 && (info.mode & 0o1000) === 0;
  if (!directory || !trustedOwner || sharedWithoutStickyBit) {
    throw new Error('Choose a trusted output directory: ' + path);
  }
}

function writeAtomically(path, data, inputs) {
  const name = basename(path);
  if (!name || name === '.' || name === '..' || !path.endsWith(name)) {
    throw new Error('Output must name a regular file');
  }
  // Resolve symlinks before processing any subsequent parent-directory segments.
  const directory = realpathSync.native(dirname(path));
  const destination = join(directory, name);
  const existing = checkOutput(destination, path, inputs);
  if (existing) {
    checkExistingCatalogue(destination, data, existing);
    return;
  }
  requireTrustedOutputDirectory(directory, process.geteuid?.());
  // mkdtemp creates an owner-only directory on the destination filesystem.
  const staging = mkdtempSync(join(directory, '.geosite-'));
  const temporary = join(staging, 'catalogue');
  try {
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- Open a fixed filename exclusively inside the owner-only staging directory.
    const fd = openSync(temporary, 'wx', 0o644);
    try {
      // eslint-disable-next-line security/detect-non-literal-fs-filename -- Write through the exclusive staging descriptor.
      writeFileSync(fd, data);
      fsyncSync(fd);
    } finally {
      closeSync(fd);
    }
    checkOutput(destination, path, inputs);
    // The filesystem creates the destination only if its name is still free.
    try {
      // eslint-disable-next-line security/detect-non-literal-fs-filename -- Publish the staged file without replacing an existing destination.
      linkSync(temporary, destination);
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      checkExistingCatalogue(destination, data, checkOutput(destination, path, inputs));
    }
  } finally {
    rmSync(temporary, {force: true});
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- Remove only the empty directory created for this invocation.
    rmdirSync(staging);
  }
}

function main() {
  const {values} = parseArgs({
    options: {
      dat: {type: 'string'},
      dlc: {type: 'string'},
      psl: {type: 'string'},
      group: {type: 'string'},
      output: {type: 'string'},
      verify: {type: 'boolean'},
      help: {type: 'boolean'},
    },
  });
  const {dat, dlc, psl, group, output, verify, help} = values;
  if (help) {
    console.log('Usage: node scripts/dev/compile-geosite.mjs --dat geosite.dat --psl effective_tld_names.dat');
    console.log('       --group DEBIAN|DOUBAN|MEITUAN --output catalogue.json [--verify]');
    console.log('Use raw XTLS/Xray-rules-dat standard geosite.dat ' + XTLS.version + ' and the Chromium 155.0.8059.80 ICANN+PRIVATE PSL.');
    console.log('Historical DEBIAN reproduction uses --dlc dlc.dat (V2Fly 20261121064510) in place of --dat.');
    console.log('Inputs are verified offline. --verify compares the complete catalogue byte for byte.');
    return;
  }
  const official = dat !== undefined;
  if (official === (dlc !== undefined)) throw new Error('Specify exactly one of --dat or --dlc (see --help)');
  const sourcePath = official ? dat : dlc;
  if (!sourcePath || !psl || !group || !output) throw new Error('A source path, --psl, --group and --output are required (see --help)');
  const approvedDigest = (official ? XTLS_GROUPS : DLC_GROUPS).get(group);
  if (!approvedDigest) {
    throw new Error(official ? 'GeoSite group must be approved for the pinned XTLS DAT' : 'Only the DEBIAN group is approved');
  }
  const source = official ? XTLS : DLC;
  const datInput = readPinned(sourcePath, source, official ? 'DAT' : 'DLC');
  const pslInput = readPinned(psl, PSL, 'PSL');
  const {rules} = compileGroup(datInput.data, utf8.decode(pslInput.data), group, {requireCanonical: official});
  const payload = rules.map(({type, value}) => type + ':' + value + '\n').join('');
  const payloadSha256 = sha256(payload);
  if (payloadSha256 !== approvedDigest) throw new Error('Compiled rule payload SHA-256 does not match the pin');
  const catalogue = {
    schemaVersion: 1,
    compiler: {name: 'compile-geosite', version: 1},
    group,
    inputs: {[official ? 'dat' : 'dlc']: source, psl: PSL},
    ruleCount: rules.length,
    payloadSha256,
    rules,
  };
  const expected = Buffer.from(JSON.stringify(catalogue, null, 2) + '\n');
  if (verify) {
    const {data} = readExactFile(output, expected.length, 'Catalogue to verify');
    if (!data.equals(expected)) throw new Error('Catalogue does not match the pinned build');
  } else {
    writeAtomically(output, expected, [datInput, pslInput]);
  }
}

function isDirectEntry() {
  if (typeof import.meta.main === 'boolean') return import.meta.main;

  // Node 20 exposes the entry path in argv when it runs a file directly.
  const entry = process.argv[1];
  const evaluation = /^(?:--(?:eval|print)|-[ep]|-pe)(?:=|$)/u;
  if (!entry || process.execArgv.some((arg) => evaluation.test(arg))) return false;
  try {
    return realpathSync.native(entry) === realpathSync.native(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

if (isDirectEntry()) {
  try {
    main();
  } catch (error) {
    console.error('compile-geosite: ' + error.message);
    process.exitCode = 1;
  }
}
