import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { generateKeyPairSync, verify } from 'node:crypto';
import { once } from 'node:events';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

test('GeoSite signing preserves payload bytes read from stdin with an inherited key descriptor', async () => {
  const signer = fileURLToPath(new URL('../../dev/sign-geosite-policy.mjs', import.meta.url));
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  const payload = Buffer.from('{\n  "schema": 1\n}\n');
  const child = spawn(process.execPath, [signer], { stdio: ['pipe', 'pipe', 'pipe', 'pipe'] });
  const completion = once(child, 'close');
  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8').on('data', chunk => { stdout += chunk; });
  child.stderr.setEncoding('utf8').on('data', chunk => { stderr += chunk; });
  child.stdio[3].end(privateKey.export({ type: 'pkcs8', format: 'pem' }));
  child.stdin.end(payload);
  const [code] = await completion;
  assert.equal(code, 0, stderr);
  const envelope = JSON.parse(stdout);
  assert.deepEqual(Buffer.from(envelope.payload, 'base64'), payload);
  assert.equal(verify(null, payload, publicKey, Buffer.from(envelope.signature, 'base64')), true);
});
