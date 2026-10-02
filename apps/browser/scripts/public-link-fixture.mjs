// 可独立部署的合成链接服务。只提供状态码，不读取文件或暴露本机控制接口。
import {createServer} from 'node:http';
import {pathToFileURL} from 'node:url';

export function createLinkFixture() {
  const server = createServer((request, response) => {
    response.setHeader('cache-control', 'no-store');
    response.setHeader('content-type', 'text/plain; charset=utf-8');
    response.setHeader('x-content-type-options', 'nosniff');
    const finish = (status, body = '') => {
      response.writeHead(status, {'content-length': Buffer.byteLength(body)});
      response.end(request.method === 'HEAD' ? undefined : body);
    };
    if (!['GET', 'HEAD'].includes(request.method)) {
      response.setHeader('allow', 'GET, HEAD');
      finish(405);
      return;
    }
    // 按原始路径白名单匹配，拒绝编码绕行、绝对地址和目录遍历。
    const route = request.url.split('?')[0];
    if (route === '/healthz') {
      finish(200, 'aegis-link-fixture-v2\n');
      return;
    }
    const kind = /^\/status\/(live|head-unsupported|redirect|auth|rate|gone|missing|temporary|timeout)$/.exec(route)?.[1];
    if (!kind) { finish(404); return; }
    if (kind === 'redirect') {
      response.setHeader('location', '/status/live');
      finish(302);
    } else if (kind === 'head-unsupported' && request.method === 'HEAD') {
      response.setHeader('allow', 'GET');
      finish(405);
    } else if (kind === 'timeout') {
      const timer = setTimeout(() => finish(200, 'live\n'), 12_000);
      // 客户端超时后释放计时器，不保留等待任务。
      response.once('close', () => clearTimeout(timer));
    } else if (['auth', 'rate', 'gone', 'missing', 'temporary'].includes(kind)) {
      if (kind === 'rate' || kind === 'temporary') response.setHeader('retry-after', '1');
      finish({auth: 403, rate: 429, gone: 410, missing: 404, temporary: 503}[kind]);
    } else {
      finish(200, 'live\n');
    }
  });
  server.requestTimeout = 15_000;
  server.headersTimeout = 10_000;
  server.maxConnections = 128;
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const args = process.argv.slice(2);
    if (args.includes('--help')) {
      console.log('node public-link-fixture.mjs [--host 127.0.0.1] [--port 49211]\n公开部署时只将此服务接到受控 HTTPS 反向代理；不要代理完整开发夹具。');
    } else {
      let host = '127.0.0.1';
      let port = 49211;
      const seen = new Set();
      for (let i = 0; i < args.length; i += 2) {
        const key = args[i];
        const value = args[i + 1];
        if (!['--host', '--port'].includes(key) || seen.has(key) || !value) throw new Error('参数缺失、重复或未知');
        seen.add(key);
        if (key === '--host') {
          if (!['127.0.0.1', '0.0.0.0', '::1'].includes(value)) throw new Error('监听地址仅支持明确的回环或所有IPv4接口');
          host = value;
        } else {
          if (!/^\d+$/.test(value) || Number(value) > 65535) throw new Error('端口无效');
          port = Number(value);
        }
      }
      const server = createLinkFixture();
      server.on('error', error => { console.error(error.message); process.exitCode = 1; });
      server.listen(port, host, () => console.log(JSON.stringify({
        service: 'aegis-link-fixture-v2', host, port: server.address().port,
        publicDeploymentVerified: false, browserExecuted: false,
      })));
      for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => {
        server.close();
        server.closeAllConnections();
      });
    }
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
