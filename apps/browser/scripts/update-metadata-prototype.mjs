// U04 离线原型：不访问网络、不安装软件，尚未接入浏览器更新链路。
import {createHash, verify} from 'node:crypto';

const keys = ['schemaVersion', 'version', 'sequence', 'publishedAt', 'expiresAt',
  'platform', 'url', 'sha256', 'size'];
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const hashPattern = /^[a-f0-9]{64}$/u;

function requireValue(condition, reason) {
  if (!condition) throw new Error(reason);
}

function versionParts(version) {
  requireValue(typeof version === 'string' && /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/u.test(version),
      '版本格式不合法');
  const parts = version.split('.').map(Number);
  requireValue(parts.every(part => Number.isSafeInteger(part) && part <= 2147483647),
      '版本数值超界');
  return parts;
}

export function verifyUpdateMetadata(envelope, trusted) {
  requireValue(envelope && Object.keys(envelope).length === 2 &&
      typeof envelope.payload === 'string' && typeof envelope.signature === 'string',
  '元数据封装不合法');
  const bytes = Buffer.from(envelope.payload, 'utf8');
  requireValue(bytes.length <= 16384, '元数据超出大小限制');
  requireValue(trusted.publicKey?.type === 'public' &&
      trusted.publicKey.asymmetricKeyType === 'ed25519', '需要独立可信的 Ed25519 公钥');
  const signature = Buffer.from(envelope.signature, 'base64');
  requireValue(signature.length === 64 && signature.toString('base64') === envelope.signature &&
      verify(null, bytes, trusted.publicKey, signature), '签名无效');
  let data;
  try { data = JSON.parse(envelope.payload); } catch { throw new Error('元数据不是合法 JSON'); }
  requireValue(data && typeof data === 'object' && !Array.isArray(data) &&
      Object.keys(data).length === keys.length && keys.every(key => Object.hasOwn(data, key)),
  '元数据字段不合法');
  // 只接受 JSON.stringify 生成的紧凑格式，拒绝重复字段等解析歧义。
  requireValue(JSON.stringify(data) === envelope.payload, '元数据编码不规范');
  requireValue(data.schemaVersion === 1, '不支持的元数据版本');
  requireValue(Number.isSafeInteger(trusted.nowSeconds) && trusted.nowSeconds >= 0 &&
      Number.isSafeInteger(data.publishedAt) && data.publishedAt >= 0 &&
      Number.isSafeInteger(data.expiresAt) && data.publishedAt <= trusted.nowSeconds &&
      data.expiresAt > trusted.nowSeconds && data.expiresAt > data.publishedAt &&
      data.expiresAt - data.publishedAt <= 7 * 86400, '元数据过期或时间范围不合法');
  requireValue(Number.isSafeInteger(trusted.lastSequence) && trusted.lastSequence >= 0 &&
      Number.isSafeInteger(data.sequence) && data.sequence > 0 &&
      data.sequence >= trusted.lastSequence, '拒绝元数据回滚');
  const payloadSha256 = digest(bytes);
  if (trusted.lastSequence > 0) {
    requireValue(typeof trusted.lastPayloadSha256 === 'string' &&
        hashPattern.test(trusted.lastPayloadSha256), '缺少已接受元数据摘要');
    requireValue(data.sequence !== trusted.lastSequence ||
        payloadSha256 === trusted.lastPayloadSha256, '同序号元数据发生变化');
  }
  requireValue(['macos-arm64', 'macos-x64', 'windows-x64', 'android-arm64'].includes(data.platform) &&
      data.platform === trusted.platform, '安装包平台不匹配');
  const available = versionParts(data.version);
  const current = versionParts(trusted.currentVersion);
  const different = available.findIndex((value, index) => value !== current[index]);
  requireValue(different < 0 || available[different] > current[different], '拒绝产品版本降级');
  requireValue(typeof data.sha256 === 'string' && hashPattern.test(data.sha256) &&
      Number.isSafeInteger(data.size) && data.size > 0 && data.size <= 2 * 1024 ** 3,
  '安装包摘要或大小不合法');
  let url;
  try { url = new URL(data.url); } catch { throw new Error('下载地址不合法'); }
  const prefix = `/gcsagroup/aegis-browser/releases/download/v${data.version}/`;
  requireValue(typeof data.url === 'string' && url.protocol === 'https:' &&
      url.hostname === 'github.com' && !url.username && !url.password && !url.port &&
      !url.search && !url.hash && url.pathname.startsWith(prefix) &&
      /^[A-Za-z0-9][A-Za-z0-9._-]{0,200}$/u.test(url.pathname.slice(prefix.length)),
  '下载地址超出固定仓库与版本范围');
  return {metadata: data, payloadSha256, state: different < 0 ? 'current' : 'available',
    metadataSignatureVerified: true, packageIntegrityVerified: false,
    platformCodeSignature: 'not_checked', installed: false};
}

export function verifyUpdatePackage(bytes, envelope, trusted) {
  // 下载后重新校验签名、期限和版本，不接受调用方自报“已校验”的布尔值。
  const verifiedMetadata = verifyUpdateMetadata(envelope, trusted);
  requireValue(Buffer.isBuffer(bytes), '需要安装包字节');
  requireValue(bytes.length === verifiedMetadata.metadata.size &&
      digest(bytes) === verifiedMetadata.metadata.sha256, '安装包大小或摘要不匹配');
  return {...verifiedMetadata, packageIntegrityVerified: true,
    platformCodeSignature: 'not_checked', installed: false};
}
