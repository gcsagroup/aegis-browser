import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

const requireValue = (value, message) => { if (!value) throw new Error(message); };
const positiveId = value => Number.isSafeInteger(value) && value > 0;
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const ARCHIVE_LIMIT = 1024 * 1024;
const MANIFEST = 'macos-delivery-manifest.json';
const RECEIPT = 'macos-delivery-receipt.json';

export function downloadEvidenceArchive(path, token) {
  requireValue(/^\/repos\/(?:quinn521|gcsagroup)\/aegis-browser\/actions\/artifacts\/[1-9][0-9]*\/zip$/u.test(path),
    'Unexpected evidence archive endpoint');
  try {
    return execFileSync('gh', ['api', '--hostname', 'github.com', path], {
      env: {...process.env, GH_HOST: 'github.com', GH_TOKEN: token},
      timeout: 30000, maxBuffer: ARCHIVE_LIMIT, stdio: ['ignore', 'pipe', 'pipe'],
    });
  } catch { throw new Error('Unable to download the sealed DMG evidence archive'); }
}

function readEvidence(bytes, artifact) {
  requireValue(Buffer.isBuffer(bytes) && bytes.length <= ARCHIVE_LIMIT &&
    bytes.length === artifact.size_in_bytes && 'sha256:'+digest(bytes) === artifact.digest,
  'DMG evidence archive digest or size differs');
  /* eslint-disable security/detect-non-literal-fs-filename -- Private, generated temporary directory; only a bounded archive is written. */
  const directory = mkdtempSync(join(tmpdir(), 'aegis-dmg-evidence-')); // nosemgrep: javascript.lang.security.audit.detect-non-literal-fs-filename.detect-non-literal-fs-filename
  const path = join(directory, 'evidence.zip');
  try {
    writeFileSync(path, bytes, {mode: 0o600, flag: 'wx'}); // nosemgrep: javascript.lang.security.audit.detect-non-literal-fs-filename.detect-non-literal-fs-filename
    const options = {timeout: 5000, maxBuffer: 256 * 1024, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']};
    const names = execFileSync('unzip', ['-Z1', path], options).trim().split('\n').sort();
    requireValue(JSON.stringify(names) === JSON.stringify([MANIFEST, RECEIPT]), 'DMG evidence archive entries differ');
    const manifestBytes = execFileSync('unzip', ['-p', path, MANIFEST], options);
    return {manifest: JSON.parse(manifestBytes), manifestSha256: digest(manifestBytes),
      receipt: JSON.parse(execFileSync('unzip', ['-p', path, RECEIPT], options))};
  } catch (error) {
    throw new Error('Invalid sealed DMG evidence archive', {cause: error});
  } finally {
    rmSync(directory, {recursive: true, force: true}); // nosemgrep: javascript.lang.security.audit.detect-non-literal-fs-filename.detect-non-literal-fs-filename
  }
  /* eslint-enable security/detect-non-literal-fs-filename */
}

function completeInventory(rows, totalCount, key) {
  requireValue(Array.isArray(rows) && totalCount === rows.length && rows.length <= 100,
    'Incomplete DMG '+key+' inventory');
  requireValue(rows.every(row => positiveId(row?.id)) && new Set(rows.map(row => row.id)).size === rows.length,
    'Invalid DMG '+key+' inventory');
  return rows;
}

function verifyManifest(evidence, repository, sha, inputs) {
  const {manifest, receipt} = evidence;
  const notarized = inputs.packageKind === 'notarized';
  const filename = `GCSA-aegis-${inputs.version}-mac-arm64.dmg`;
  const item = manifest?.artifacts?.[0];
  requireValue(manifest?.schema === 'aegis-macos-delivery-v1' && manifest.repository === repository &&
    manifest.sourceSha === sha && manifest.version === inputs.version && manifest.build === inputs.build &&
    manifest.packageKind === inputs.packageKind && manifest.notarized === notarized &&
    JSON.stringify(manifest.architectures) === '["arm64"]' && manifest.artifacts.length === 1 &&
    item?.filename === filename && item.architecture === 'arm64' && item.role === 'package' &&
    item.uploadable === false && /^[0-9a-f]{64}$/u.test(item.sha256 || '') && positiveId(item.sizeBytes),
  'Sealed DMG manifest differs');
  requireValue(receipt?.sourceSha === sha && receipt.packagingSourceSha === sha && receipt.version === inputs.version &&
    receipt.arch === 'arm64' && receipt.notarized === false && receipt.dmg?.name === filename &&
    receipt.signingMode === (inputs.packageKind === 'ad-hoc' ? 'ad-hoc' : 'developer-id') &&
    (notarized ? receipt.notarizationSigning === true : receipt.dmg.sha256 === item.sha256),
  'Sealed DMG package receipt differs');
}

export async function requireDmgEvidence({api, repository, sha, id, inputs}) {
  const prefix = '/repos/'+repository;
  const jobInventory = await api(`${prefix}/actions/runs/${id}/attempts/1/jobs?per_page=100`);
  const jobs = completeInventory(jobInventory?.jobs, jobInventory?.total_count, 'jobs');
  const selected = 'package-'+inputs.packageKind;
  const required = ['admission', selected, ...(inputs.operation === 'Tag release' ? ['candidate'] : [])];
  for (const name of required) {
    const matches = jobs.filter(job => job.name === name);
    requireValue(matches.length === 1 && matches[0].run_id === id && matches[0].run_attempt === 1 &&
      matches[0].head_sha === sha && matches[0].status === 'completed' && matches[0].conclusion === 'success',
    'Required DMG job did not succeed: '+name);
  }
  requireValue(jobs.filter(job => job.name?.startsWith('package-') && job.name !== selected)
    .every(job => job.status === 'completed' && job.conclusion === 'skipped'), 'Unexpected DMG package job ran');
  const artifactInventory = await api(`${prefix}/actions/runs/${id}/artifacts?per_page=100`);
  const artifacts = completeInventory(artifactInventory?.artifacts, artifactInventory?.total_count, 'artifacts');
  const admitted = name => {
    const matches = artifacts.filter(artifact => artifact.name === name);
    requireValue(matches.length === 1, 'Missing or duplicate sealed DMG artifact: '+name);
    const artifact = matches[0];
    requireValue(artifact.expired === false && positiveId(artifact.size_in_bytes) &&
      /^sha256:[0-9a-f]{64}$/u.test(artifact.digest || '') && artifact.workflow_run?.id === id &&
      artifact.workflow_run.head_sha === sha && artifact.workflow_run.head_branch === 'main',
    'Sealed DMG artifact identity differs');
    return artifact;
  };
  const packageArtifact = admitted(`macos-dmg-${id}-1`);
  const artifact = admitted(`macos-dmg-evidence-${id}-1`);
  requireValue(artifact.size_in_bytes <= ARCHIVE_LIMIT, 'DMG evidence archive exceeds limit');
  const evidence = readEvidence(await api(`${prefix}/actions/artifacts/${artifact.id}/zip`, {archive: true}), artifact);
  verifyManifest(evidence, repository, sha, inputs);
  if (inputs.operation === 'Tag release') {
    const tag = `candidate/macos/${inputs.version}-${inputs.packageKind}.${inputs.build}`;
    const release = await api(prefix+'/releases/tags/'+encodeURIComponent(tag));
    const expected = evidence.manifest.artifacts[0];
    const assets = release?.assets?.filter(asset => asset.name === expected.filename);
    requireValue(release?.tag_name === tag && release.prerelease === true && release.draft === false &&
      assets?.length === 1 && positiveId(assets[0].id) && assets[0].state === 'uploaded' &&
      assets[0].size === expected.sizeBytes && assets[0].digest === 'sha256:'+expected.sha256,
    'Published DMG candidate asset differs');
  }
  return {notarized: evidence.manifest.notarized, manifestSha256: evidence.manifestSha256,
    packageArtifactId: packageArtifact.id, evidenceArtifactId: artifact.id};
}
