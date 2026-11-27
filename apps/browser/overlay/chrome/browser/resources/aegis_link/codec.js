// 同步协议 v1：PBKDF2-SHA256 与 AES-GCM，盐和随机 nonce 随密文发送。
// 附加认证数据绑定门户、用户和集合，跨账号复制密文不能还原为有效的本地资料。
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });
export const maxEnvelope = 2 * 1024 * 1024;

export function portalOrigin(raw) {
  const url = new URL(raw);
  const local = ["127.0.0.1", "localhost"].includes(url.hostname);
  if (
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    url.pathname !== "/" ||
    (url.protocol !== "https:" && !(url.protocol === "http:" && local))
  ) {
    throw new Error("origin");
  }
  return url.origin;
}

function toBase64(bytes) {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 8192) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
  }
  return btoa(binary);
}

async function keyFor(password, salt) {
  const input = await crypto.subtle.importKey(
    "raw",
    encoder.encode(password),
    "PBKDF2",
    false,
    ["deriveKey"],
  );
  return crypto.subtle.deriveKey(
    { name: "PBKDF2", salt, iterations: 600000, hash: "SHA-256" },
    input,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

/** 将已验证的同步资料封装为门户可保存的标准 Base64。 */
export async function seal(data, password, binding) {
  const plain = encoder.encode(JSON.stringify(data));
  if (plain.length + 45 > maxEnvelope) throw new Error("limit");
  const out = new Uint8Array(45 + plain.length);
  out[0] = 1;
  const salt = crypto.getRandomValues(out.subarray(1, 17));
  const iv = crypto.getRandomValues(out.subarray(17, 29));
  const key = await keyFor(password, salt);
  out.set(
    new Uint8Array(
      await crypto.subtle.encrypt(
        { name: "AES-GCM", iv, additionalData: encoder.encode(binding) },
        key,
        plain,
      ),
    ),
    29,
  );
  return toBase64(out);
}

/** 在任何本地写入前验证信封版本、大小与认证标签。 */
export async function unseal(encoded, password, binding) {
  if (typeof encoded !== "string" || encoded.length > 4 * Math.ceil(maxEnvelope / 3))
    throw new Error("limit");
  const bytes = Uint8Array.from(atob(encoded), (c) => c.charCodeAt(0));
  if (bytes.length < 46 || bytes.length > maxEnvelope || bytes[0] !== 1)
    throw new Error("invalid");
  const key = await keyFor(password, bytes.subarray(1, 17));
  let plaintext;
  try {
    plaintext = await crypto.subtle.decrypt(
      {
        name: "AES-GCM",
        iv: bytes.subarray(17, 29),
        additionalData: encoder.encode(binding),
      },
      key,
      bytes.subarray(29),
    );
  } catch {
    throw new Error("unlock");
  }
  return JSON.parse(decoder.decode(plaintext));
}

/** 比较本地内容，无变更时不重写密文，双方均有修改时由用户选择保留哪一份。 */
export async function fingerprint(data) {
  return toBase64(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", encoder.encode(JSON.stringify(data))),
    ),
  );
}
