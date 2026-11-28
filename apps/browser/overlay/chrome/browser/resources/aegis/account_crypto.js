// 浏览器端同步信封。版本 2 使用账号密钥；只在迁移版本 1 时读取旧口令。
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });
export const maxEnvelope = 2 * 1024 * 1024;

function toBase64(bytes) {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 8192) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
  }
  return btoa(binary);
}

async function legacyKey(password, salt) {
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

/** 账号密钥只在本轮内存中使用；派生的每份密钥同时绑定随机盐、站点、账号和集合。 */
export async function importAccountKey(encoded) {
  const raw = Uint8Array.from(atob(encoded), (c) => c.charCodeAt(0));
  if (raw.length !== 32) throw new Error("invalid");
  try {
    return await crypto.subtle.importKey("raw", raw, "HKDF", false, ["deriveKey"]);
  } finally {
    raw.fill(0);
  }
}

function collectionKey(master, salt, binding) {
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt, info: encoder.encode(binding) },
    master,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

/** 只有账号密钥可以创建新信封，旧协议仅用于读取。 */
export async function seal(data, master, binding) {
  const plain = encoder.encode(JSON.stringify(data));
  if (plain.length + 45 > maxEnvelope) throw new Error("limit");
  const bytes = new Uint8Array(45 + plain.length);
  bytes[0] = 2;
  const salt = crypto.getRandomValues(bytes.subarray(1, 17));
  const iv = crypto.getRandomValues(bytes.subarray(17, 29));
  const key = await collectionKey(master, salt, binding);
  const encrypted = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: encoder.encode(binding) },
    key,
    plain,
  );
  bytes.set(new Uint8Array(encrypted), 29);
  return toBase64(bytes);
}

/** 先验证信封格式，再向旧版数据的拥有者请求迁移。口令始终留在设备上。 */
export async function unseal(encoded, master, binding, requestLegacy) {
  if (typeof encoded !== "string" || encoded.length > 4 * Math.ceil(maxEnvelope / 3))
    throw new Error("limit");
  const bytes = Uint8Array.from(atob(encoded), (c) => c.charCodeAt(0));
  const legacy = bytes[0] === 1;
  if (bytes.length < 46 || bytes.length > maxEnvelope || (!legacy && bytes[0] !== 2))
    throw new Error("invalid");
  const salt = bytes.subarray(1, 17);
  const key = legacy
    ? await legacyKey(await requestLegacy(), salt)
    : await collectionKey(master, salt, binding);
  let plain;
  try {
    plain = await crypto.subtle.decrypt(
      {
        name: "AES-GCM",
        iv: bytes.subarray(17, 29),
        additionalData: encoder.encode(binding),
      },
      key,
      bytes.subarray(29),
    );
  } catch {
    throw new Error(legacy ? "unlock" : "invalid");
  }
  return { value: JSON.parse(decoder.decode(plain)), legacy };
}

/** 比较本地内容，无变更时不重写密文，双方均有修改时由用户选择保留哪一份。 */
export async function fingerprint(data) {
  return toBase64(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", encoder.encode(JSON.stringify(data))),
    ),
  );
}
