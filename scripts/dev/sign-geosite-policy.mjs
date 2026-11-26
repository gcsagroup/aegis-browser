import { createPrivateKey, sign } from 'node:crypto';
import { readFileSync } from 'node:fs';

if (process.argv.length !== 2) {
  console.error('Run node scripts/dev/sign-geosite-policy.mjs with the Ed25519 private key on file descriptor 3 and the JSON payload on standard input.');
  process.exit(2);
}

const privateKey = createPrivateKey(readFileSync(3));
if (privateKey.asymmetricKeyType !== 'ed25519') {
  throw new Error('The GeoSite policy signing key must use Ed25519');
}
const payload = readFileSync(0);
const envelope = JSON.stringify({
  payload: payload.toString('base64'),
  signature: sign(null, payload, privateKey).toString('base64'),
});
if (Buffer.byteLength(envelope) + 1 > 12 * 1024) {
  throw new Error('GeoSite policy envelope exceeds the client size limit');
}
process.stdout.write(envelope + '\n');
