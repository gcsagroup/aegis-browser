import { createServer } from 'node:http';
import { isB1App } from './app.mjs';
import { reject } from './proof.mjs';

const started = new WeakSet();
export async function start({ app, host, port }) {
  if (!isB1App(app) || started.has(app) || host !== '127.0.0.1' ||
      !Number.isSafeInteger(port) || port < 0 || port > 65535) reject('BINDING_REQUIRED');
  started.add(app);
  const server = createServer({ maxHeaderSize: 49_152, requestTimeout: 5000,
    headersTimeout: 5000, connectionsCheckingInterval: 100 }, app.handler);
  server.keepAliveTimeout = 1;
  server.maxConnections = 8;
  let bound = false, closed = false;
  try {
    await new Promise((resolve, fail) => {
      server.once('error', fail);
      server.listen(port, host, () => { server.removeListener('error', fail); resolve(); });
    });
    bound = true;
    const address = server.address();
    const origin = 'http://127.0.0.1:' + address.port;
    app.bindOrigin(origin);
    return Object.freeze({
      origin,
      close: async () => {
        if (closed) return;
        closed = true;
        const drained = new Promise((resolve, fail) => server.close(error => error ? fail(error) : resolve()));
        server.closeAllConnections();
        await app.close();
        await drained;
      },
    });
  } catch (error) {
    if (bound) await new Promise(resolve => { server.close(resolve); server.closeAllConnections(); });
    await app.close();
    throw error;
  }
}
// No main entry, environment parsing, automatic listen, DB connection or DDL.
