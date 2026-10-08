import assert from 'node:assert/strict';
import {createHash, generateKeyPairSync, sign} from 'node:crypto';
import test from 'node:test';
import {verifyUpdateMetadata, verifyUpdatePackage} from './update-metadata-prototype.mjs';

// 仅在测试进程内生成临时密钥，不写入文件，也不作为产品信任根。
const {publicKey, privateKey} = generateKeyPairSync('ed25519');
const packageBytes = Buffer.from('合成更新包，不可执行');
const trusted = {publicKey, nowSeconds: 2000000000, lastSequence: 0,
  platform: 'macos-arm64', currentVersion: '1.1.0.34'};
const base = {schemaVersion: 1, version: '1.1.0.35', sequence: 2,
  publishedAt: trusted.nowSeconds - 60, expiresAt: trusted.nowSeconds + 3600,
  platform: 'macos-arm64', url: 'https://github.com/gcsagroup/aegis-browser/releases/download/v1.1.0.35/aegis-macos-arm64.zip',
  sha256: createHash('sha256').update(packageBytes).digest('hex'), size: packageBytes.length};
function signed(changes = {}) {
  const payload = JSON.stringify({...base, ...changes});
  return {payload, signature: sign(null, Buffer.from(payload), privateKey).toString('base64')};
}

test('合法签名及完整包仍不能代表平台签名通过或已安装', () => {
  const result = verifyUpdateMetadata(signed(), trusted);
  assert.equal(result.state, 'available');
  assert.equal(result.packageIntegrityVerified, false);
  const complete = verifyUpdatePackage(packageBytes, signed(), trusted);
  assert.equal(complete.packageIntegrityVerified, true);
  assert.equal(complete.platformCodeSignature, 'not_checked');
  assert.equal(complete.installed, false);
  assert.equal(verifyUpdateMetadata(signed(), {...trusted, currentVersion: base.version}).state, 'current');
});

for (const [name, changes, expected] of [
  ['过期', {expiresAt: trusted.nowSeconds}, /过期/u],
  ['未来发布', {publishedAt: trusted.nowSeconds + 1}, /时间/u],
  ['过长有效期', {expiresAt: trusted.nowSeconds + 8 * 86400}, /时间/u],
  ['错误平台', {platform: 'windows-x64'}, /平台/u],
  ['降级', {version: '1.1.0.33'}, /降级/u],
  ['版本格式歧义', {version: '1.1.0.035'}, /格式/u],
  ['伪造摘要格式', {sha256: 'x'.repeat(64)}, /摘要/u],
  ['越界大小', {size: 2 ** 32}, /大小/u],
  ['其他仓库', {url: base.url.replace('/gcsagroup/', '/other/')}, /范围/u],
  ['旧版本链接', {url: base.url.replace('/v1.1.0.35/', '/v1.1.0.33/')}, /范围/u],
  ['额外字段', {installNow: true}, /字段/u],
]) test(`拒绝${name}`, () => assert.throws(() => verifyUpdateMetadata(signed(changes), trusted), expected));

test('拒绝篡改签名、未知密钥和元数据回滚', () => {
  const valid = signed();
  assert.throws(() => verifyUpdateMetadata({...valid, payload: valid.payload.replace('1.1.0.35', '1.1.0.36')}, trusted), /签名/u);
  assert.throws(() => verifyUpdateMetadata(valid, {...trusted,
    publicKey: generateKeyPairSync('ed25519').publicKey}), /签名/u);
  const result = verifyUpdateMetadata(valid, trusted);
  const prior = {...trusted, lastSequence: 2, lastPayloadSha256: result.payloadSha256};
  assert.equal(verifyUpdateMetadata(valid, prior).state, 'available');
  assert.throws(() => verifyUpdateMetadata(signed({sequence: 1}), prior), /回滚/u);
  assert.throws(() => verifyUpdateMetadata(signed({size: base.size + 1}), prior), /同序号/u);
  assert.throws(() => verifyUpdatePackage(packageBytes.subarray(1), valid, trusted), /摘要不匹配/u);
  const corrupt = Buffer.from(packageBytes); corrupt[0] ^= 1;
  assert.throws(() => verifyUpdatePackage(corrupt, valid, trusted), /摘要不匹配/u);
  assert.throws(() => verifyUpdatePackage(packageBytes,
      {metadataSignatureVerified: true, metadata: base}, trusted), /封装/u);
});

test('元数据拒绝重复字段和缺失可信时钟', () => {
  const payload = signed().payload.replace('"sequence":2', '"sequence":1,"sequence":2');
  assert.throws(() => verifyUpdateMetadata({payload,
    signature: sign(null, Buffer.from(payload), privateKey).toString('base64')}, trusted), /编码/u);
  assert.throws(() => verifyUpdateMetadata(signed(), {...trusted, nowSeconds: undefined}), /时间/u);
});
