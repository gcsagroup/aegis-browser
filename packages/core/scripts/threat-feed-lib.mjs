import { createHash } from "node:crypto";
import { domainToASCII } from "node:url";

export const SOURCE_BITS = Object.freeze({
  phishtank: 1,
  urlhaus: 2,
  "cert-pl": 4,
});

const MAX_ENTRIES_PER_SOURCE = 1_000_000;

function canonicalHost(input) {
  const value = input.trim().replace(/\.+$/, "").toLowerCase();
  const ascii = domainToASCII(value);
  if (!ascii || !ascii.includes(".") || ascii.length > 253 ||
      ascii.split(".").some((label) => !label || label.length > 63)) {
    throw new Error(`invalid domain: ${input}`);
  }
  const parsed = new URL(`https://${ascii}/`);
  if (parsed.hostname !== ascii) throw new Error(`non-canonical domain: ${input}`);
  return ascii;
}

function canonicalUrl(input) {
  const parsed = new URL(input.trim());
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new Error(`unsupported URL scheme: ${input}`);
  }
  parsed.hash = "";
  return parsed.href;
}

function boundedPush(entries, entry) {
  if (entries.length >= MAX_ENTRIES_PER_SOURCE) {
    throw new Error("feed exceeds entry limit");
  }
  entries.push(entry);
}

export function parseCertPl(text) {
  const entries = [];
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    boundedPush(entries, { kind: 1, value: canonicalHost(line) });
  }
  if (entries.length === 0) throw new Error("CERT.PL feed has no domains");
  return entries;
}

function parseCsvLine(line) {
  const fields = [];
  let value = "";
  let quoted = false;
  for (let index = 0; index < line.length; index += 1) {
    const char = line[index];
    if (char === '"') {
      if (quoted && line[index + 1] === '"') {
        value += '"';
        index += 1;
      } else {
        quoted = !quoted;
      }
    } else if (char === "," && !quoted) {
      fields.push(value);
      value = "";
    } else {
      value += char;
    }
  }
  if (quoted) throw new Error("unterminated CSV quote");
  fields.push(value);
  return fields;
}

export function parseUrlhaus(text) {
  const entries = [];
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    let candidate = line;
    if (!/^https?:\/\//i.test(candidate)) {
      const fields = parseCsvLine(candidate);
      candidate = fields.find((field) => /^https?:\/\//i.test(field.trim())) ?? "";
    }
    if (!candidate) throw new Error(`URLhaus row has no URL: ${line.slice(0, 120)}`);
    boundedPush(entries, { kind: 2, value: canonicalUrl(candidate) });
  }
  if (entries.length === 0) throw new Error("URLhaus feed has no URLs");
  return entries;
}

export function parsePhishTank(text) {
  const parsed = JSON.parse(text);
  if (!Array.isArray(parsed)) throw new Error("PhishTank feed must be an array");
  const entries = [];
  for (const row of parsed) {
    if (!row || typeof row !== "object" || typeof row.url !== "string") {
      throw new Error("PhishTank row is missing url");
    }
    const verified = row.verified === true || row.verified === "yes";
    const online = row.online === true || row.online === "yes";
    if (!verified || !online) continue;
    boundedPush(entries, { kind: 2, value: canonicalUrl(row.url) });
  }
  if (entries.length === 0) throw new Error("PhishTank feed has no verified online URLs");
  return entries;
}

function digest(kind, value) {
  return createHash("sha256").update(kind === 1 ? "h:" : "u:").update(value).digest();
}

export function compileThreatIndex(feeds, { generatedAt, expiresAt }) {
  if (!Number.isSafeInteger(generatedAt) || generatedAt <= 0 ||
      !Number.isSafeInteger(expiresAt) || expiresAt < generatedAt) {
    throw new Error("invalid generation or expiry time");
  }
  const merged = new Map();
  for (const feed of feeds) {
    const sourceBit = SOURCE_BITS[feed.source];
    if (!sourceBit || !Array.isArray(feed.entries)) throw new Error(`invalid source: ${feed.source}`);
    for (const entry of feed.entries) {
      if (entry.kind !== 1 && entry.kind !== 2) throw new Error("invalid entry kind");
      const hash = digest(entry.kind, entry.value);
      const key = `${entry.kind}:${hash.toString("hex")}`;
      const existing = merged.get(key);
      if (existing) existing.sources |= sourceBit;
      else merged.set(key, { kind: entry.kind, sources: sourceBit, hash });
    }
  }
  const records = [...merged.values()].sort((left, right) =>
    left.kind - right.kind || Buffer.compare(left.hash, right.hash)
  );
  if (records.length === 0 || records.length > 1_000_000) {
    throw new Error("compiled index has invalid entry count");
  }

  const output = Buffer.alloc(36 + records.length * 36);
  output.write("AEGISTI1", 0, "ascii");
  output.writeUInt32LE(1, 8);
  output.writeBigUInt64LE(BigInt(generatedAt), 12);
  output.writeBigUInt64LE(BigInt(expiresAt), 20);
  output.writeUInt32LE(records.length, 28);
  output.writeUInt32LE(0, 32);
  records.forEach((record, index) => {
    const offset = 36 + index * 36;
    output.writeUInt8(record.kind, offset);
    output.writeUInt8(record.sources, offset + 1);
    output.writeUInt16LE(0, offset + 2);
    record.hash.copy(output, offset + 4);
  });
  return { bytes: output, count: records.length };
}

export function parseFeed(source, text) {
  if (source === "cert-pl") return parseCertPl(text);
  if (source === "phishtank") return parsePhishTank(text);
  if (source === "urlhaus") return parseUrlhaus(text);
  throw new Error(`unsupported source: ${source}`);
}
