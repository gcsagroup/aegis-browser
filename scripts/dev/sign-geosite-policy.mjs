import { createPrivateKey, sign } from 'node:crypto';
import { readFileSync } from 'node:fs';

const [keyPath, payloadPath] = process.argv.slice(2);
if (!keyPath || !payloadPath || process.argv.length !== 4) {
  console.error('Usage: node scripts/dev/sign-geosite-policy.mjs private-key.pem payload.json');
  process.exit(2);
}

const privateKey = createPrivateKey(readFileSync(keyPath));
if (privateKey.asymmetricKeyType !== 'ed25519') {
  throw new Error('The GeoSite policy signing key must use Ed25519');
}
const payload = readFileSync(payloadPath);
const envelope = JSON.stringify({
  payload: payload.toString('base64'),
  signature: sign(null, payload, privateKey).toString('base64'),
});
if (Buffer.byteLength(envelope) + 1 > 12 * 1024) {
  throw new Error('GeoSite policy envelope exceeds the client size limit');
}
process.stdout.write(envelope + '\n');
