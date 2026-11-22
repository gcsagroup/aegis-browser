import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {createServer} from 'node:net';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {parse} from 'yaml';

const action = parse(readFileSync('.github/actions/ensure-ios-ruby/action.yml', 'utf8'));
const script = action.runs.steps[0].run;
const macOS = {skip: process.platform !== 'darwin'};
const proxiesToObserve = ['http_proxy', 'HTTP_PROXY', 'HTTPS_PROXY', 'https_proxy'];
const proxyCredentials = [
  'http_proxy_user', 'http_proxy_pass', 'HTTP_PROXY_USER', 'HTTP_PROXY_PASS',
  'https_proxy_user', 'https_proxy_pass', 'HTTPS_PROXY_USER', 'HTTPS_PROXY_PASS',
];

function runShell(source, env) {
  return new Promise((resolve, reject) => {
    const child = spawn('/bin/bash', ['-c', source], {env});
    let output = '';
    child.stdout.on('data', data => { output += data; });
    child.stderr.on('data', data => { output += data; });
    child.on('error', error => { reject(error); });
    child.on('close', code => { resolve({code, output}); });
  });
}

const exercise = async (proxies, {expectProbe, checkCredentials = false} = {}) => {
  const root = mkdtempSync(join(tmpdir(), 'aegis-ruby-action-'));
  try {
    const tooling = join(root, 'tooling');
    const rubyBin = join(root, '.local/share/mise/installs/ruby/3.3.6/bin');
    for (const directory of [tooling, rubyBin]) mkdirSync(directory, {recursive: true});
    const executable = (path, source) => writeFileSync(path, `#!/bin/bash\n${source}\n`, {mode: 0o755});
    executable(join(tooling, 'mise'), 'echo mise-fixture');
    executable(join(rubyBin, 'ruby'), 'if [ "$1" = -v ]; then echo "ruby 3.3.6"; else exec /usr/bin/ruby "$@"; fi');
    const observed = checkCredentials ? [...proxiesToObserve, ...proxyCredentials] : proxiesToObserve.slice(0, 3);
    executable(join(rubyBin, 'bundle'),
      `printf "%s\\n" ${observed.map(name => '"${' + name + '-unset}"').join(' ')} > "$PROXY_RECEIPT"`);
    const pathFile = join(root, 'github-path');
    const receipt = join(root, 'proxies');
    writeFileSync(pathFile, '');
    const env = {...process.env, PATH: '/usr/bin:/bin', RUNNER_TOOLING_BIN: tooling,
      RUNNER_HOME: root, FIXTURE_HOME: root, GITHUB_PATH: pathFile, PROXY_RECEIPT: receipt};
    for (const key of [...proxiesToObserve, ...proxyCredentials, 'ALL_PROXY', 'all_proxy']) delete env[key];
    Object.assign(env, proxies);
    // 将主目录读取限定到测试资料，实际运行 Action 的 Bash 内容和系统 nc。
    let source = script.replaceAll('$HOME', '$FIXTURE_HOME');
    if (expectProbe) {
      const nc = join(tooling, 'nc-fixture');
      executable(nc, 'printf "%s %s" "$4" "$5" > "$PROBE_RECEIPT"');
      env.PROBE_RECEIPT = join(root, 'probe');
      env.NC_FIXTURE = nc;
      source = source.replace('"/usr/bin/nc"', 'ENV.fetch("NC_FIXTURE")');
    }
    const result = await runShell(source, env);
    if (expectProbe) assert.equal(readFileSync(env.PROBE_RECEIPT, 'utf8'), expectProbe);
    assert.equal(result.code, 0, result.output);
    for (const name of proxyCredentials) {
      if (proxies[name]) assert(!result.output.includes(proxies[name]));
    }
    const paths = readFileSync(pathFile, 'utf8').trim().split('\n');
    // GitHub Runner 将后写入的路径置前；下一步骤必须仍能找到同一 Ruby 和 mise。
    const next = await runShell('ruby -v; command -v mise', {...env, PATH: [...paths].reverse().concat(env.PATH).join(':')});
    assert.equal(next.code, 0, next.output);
    assert(next.output.includes('ruby 3.3.6'));
    assert(next.output.includes(join(tooling, 'mise')));
    return readFileSync(receipt, 'utf8').trimEnd().split('\n');
  } finally {
    rmSync(root, {recursive: true, force: true});
  }
};

test('Ruby 路径跨步骤保留，可用的小写 HTTP 代理优先于失效的其他代理', macOS, async () => {
  const server = createServer(socket => socket.end());
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    const proxy = `http://127.0.0.1:${server.address().port}`;
    assert.deepEqual(await exercise({http_proxy: proxy, HTTP_PROXY: 'http://127.0.0.1:0', HTTPS_PROXY: 'http://127.0.0.1:0'}),
      [proxy, 'http://127.0.0.1:0', 'unset']);
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
});

test('未设置小写 HTTP 代理时检测大写配置，并清除实际失效的本地代理', macOS, async () => {
  assert.deepEqual(await exercise({HTTP_PROXY: 'http://127.0.0.1:0', HTTPS_PROXY: 'https://example.invalid'}),
    ['unset', 'unset', 'https://example.invalid']);
});

test('空的小写 HTTP 代理不回退到大写或 HTTPS 配置', macOS, async () => {
  assert.deepEqual(await exercise({http_proxy: '', HTTP_PROXY: 'http://127.0.0.1:0', HTTPS_PROXY: 'https://example.invalid'}),
    ['', 'http://127.0.0.1:0', 'https://example.invalid']);
});


test('同名前缀的外部代理不会按本地代理处理', macOS, async () => {
  const proxy = 'http://localhost-proxy.example:0';
  assert.deepEqual(await exercise({HTTP_PROXY: proxy, HTTPS_PROXY: 'https://example.invalid'}),
    ['unset', proxy, 'https://example.invalid']);
});

test('HTTPS 本地代理按有效端口探测，IPv6 保留实际主机', macOS, async () => {
  const defaultPort = 'https://localhost';
  assert.deepEqual(await exercise({HTTP_PROXY: defaultPort}, {expectProbe: 'localhost 443'}),
    ['unset', defaultPort, 'unset']);
  const ipv6 = '[::1]:3128';
  assert.deepEqual(await exercise({http_proxy: ipv6}, {expectProbe: '::1 3128'}),
    [ipv6, 'unset', 'unset']);
});


test('失效的小写索引代理保留健康的备用路由及归档代理', macOS, async () => {
  const archive = 'https://downloads.example.invalid';
  const fallback = 'http://proxy.example.invalid';
  assert.deepEqual(await exercise({http_proxy: '127.0.0.1:0', HTTP_PROXY: fallback, HTTPS_PROXY: archive}),
    ['unset', fallback, archive]);
});

test('代理回退移除两种大小写的外置凭据，保留备用 URL 自带的认证', macOS, async () => {
  const index = 'http://index-fixture:local-fixture@proxy.example.invalid';
  const archive = 'https://downloads.example.invalid';
  const fixture = {
    http_proxy: '127.0.0.1:0', HTTP_PROXY: index,
    https_proxy: 'http://[::1]:0', HTTPS_PROXY: archive,
    ...Object.fromEntries(proxyCredentials.map(name => [name, 'fixture-' + name])),
  };
  assert.deepEqual(await exercise(fixture, {checkCredentials: true}),
    ['unset', index, archive, 'unset', ...proxyCredentials.map(() => 'unset')]);
});

test('没有发生回退的归档代理保留该路由的外置凭据', macOS, async () => {
  const archive = 'https://downloads.example.invalid';
  const fixture = {
    http_proxy: '127.0.0.1:0', HTTP_PROXY: 'http://proxy.example.invalid',
    HTTPS_PROXY: archive, HTTPS_PROXY_USER: 'archive-fixture-user', HTTPS_PROXY_PASS: 'archive-fixture-pass',
  };
  const result = await exercise(fixture, {checkCredentials: true});
  assert.deepEqual(result.slice(-2), ['archive-fixture-user', 'archive-fixture-pass']);
});
