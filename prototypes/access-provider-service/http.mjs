import { performance } from 'node:perf_hooks';
import { ProviderError, reject, parseRequest, identifier, publicFailure } from './proof.mjs';

function oneHeader(request, name, required = false) {
  const matches = [];
  for (let i = 0; i < request.rawHeaders.length; i += 2) {
    if (request.rawHeaders[i].toLowerCase() === name) matches.push(request.rawHeaders[i + 1]);
  }
  if (matches.length > 1 || (required && matches.length !== 1)) reject('INVALID_INPUT');
  const value = matches[0];
  if (value !== undefined && (typeof value !== 'string' || Buffer.byteLength(value) > 16_384)) reject('INPUT_TOO_LARGE');
  return value;
}
function token(request, required = false) {
  const value = oneHeader(request, 'authorization', required);
  if (value === undefined) return undefined;
  if (!/^Bearer [A-Za-z0-9_.-]+$/.test(value)) reject('UNAUTHORIZED');
  return value.slice(7);
}
async function body(request, signal) {
  if (request.headers['content-type'] !== 'application/json') reject('INVALID_INPUT');
  if (request.headers['content-encoding'] || request.headers['transfer-encoding']) reject('INVALID_INPUT');
  oneHeader(request, 'content-length', true);
  const length = request.headers['content-length'];
  if (!/^(?:0|[1-9][0-9]*)$/.test(length) || Number(length) > 65_536) reject('INPUT_TOO_LARGE');
  const chunks = []; let bytes = 0;
  for await (const chunk of request) {
    if (signal.aborted) reject('DEADLINE_EXCEEDED');
    bytes += chunk.length;
    if (bytes > 65_536) reject('INPUT_TOO_LARGE');
    chunks.push(chunk);
  }
  if (bytes !== Number(length)) reject('INVALID_INPUT');
  return Buffer.concat(chunks);
}
function respond(response, result) {
  if (response.destroyed) return;
  response.sendDate = false;
  response.writeHead(result.status, { ...result.headers, 'content-length': String(result.body.length),
    'x-content-type-options': 'nosniff', connection: 'close' });
  response.end(result.body);
}
export function createHandler(authority, limits) {
  let active = 0, closed = false;
  const controllers = new Set();
  const handler = async (request, response) => {
    if (closed || active >= limits.concurrentRequests) {
      const error = publicFailure(new ProviderError(closed ? 'SERVER_CLOSED' : 'STATE_CAPACITY'));
      respond(response, { status: error.status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
        body: Buffer.from(JSON.stringify(error.body)) });
      return;
    }
    active++;
    const controller = new AbortController(); controllers.add(controller);
    Object.defineProperty(controller.signal, 'b1Deadline', { value: performance.now() + limits.requestMilliseconds });
    const abort = () => controller.abort();
    const timer = setTimeout(() => {
      controller.abort();
      request.destroy();
      response.destroy();
    }, limits.requestMilliseconds);
    request.once('aborted', abort);
    response.once('close', abort);
    try {
      if (request.socket.remoteAddress !== '127.0.0.1' || request.method !== 'POST' ||
          !['/bootstrap/challenge', '/bootstrap/register', '/profile-credentials'].includes(request.url)) reject('NOT_AVAILABLE');
      const key = oneHeader(request, 'idempotency-key', true); identifier(key);
      const requestBody = parseRequest(await body(request, controller.signal), request.url === '/bootstrap/challenge');
      if (key !== requestBody.idempotencyKey) reject('BINDING_MISMATCH');
      let result;
      if (request.url === '/bootstrap/challenge') {
        // Auth/proof header duplicates are rejected on all routes, even when unused.
        oneHeader(request, 'x-aegis-pop'); oneHeader(request, 'x-aegis-recipient-pop');
        result = await authority.challenge(requestBody, token(request, requestBody.operation === 'profile-issue'), controller.signal);
      } else {
        const operation = request.url === '/bootstrap/register' ? 'register' : 'profile-issue';
        result = await authority.issue(operation, requestBody, {
          installationToken: token(request, operation === 'profile-issue'),
          proof: oneHeader(request, 'x-aegis-pop', true),
          recipientProof: oneHeader(request, 'x-aegis-recipient-pop', operation === 'profile-issue'),
        }, controller.signal);
      }
      if (controller.signal.aborted) reject('DEADLINE_EXCEEDED');
      respond(response, result);
    } catch (error) {
      const failure = publicFailure(error);
      respond(response, { status: failure.status,
        headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
        body: Buffer.from(JSON.stringify(failure.body)) });
    } finally {
      clearTimeout(timer); active--; controllers.delete(controller);
      request.removeListener('aborted', abort); response.removeListener('close', abort);
    }
  };
  return { handler, close: () => { closed = true; for (const c of controllers) c.abort(); } };
}
