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

async function runShell(source, env) {
  return await new Promise((resolve, reject) => {
    const child = spawn('/bin/bash', ['-c', source], {env});
    let output = '';
    child.stdout.on('data', data => { output += data; });
    child.stderr.on('data', data => { output += data; });
    child.on('error', reject);
    child.on('close', code => resolve({code, output}));
  });
}

async function exercise(proxies) {
  const root = mkdtempSync(join(tmpdir(), 'aegis-ruby-action-'));
  try {
    const tooling = join(root, 'tooling');
    const rubyBin = join(root, '.local/share/mise/installs/ruby/3.3.6/bin');
    for (const directory of [tooling, rubyBin]) mkdirSync(directory, {recursive: true});
    const executable = (path, source) => writeFileSync(path, `#!/bin/bash\n${source}\n`, {mode: 0o755});
    executable(join(tooling, 'mise'), 'echo mise-fixture');
    executable(join(rubyBin, 'ruby'), 'echo "ruby 3.3.6"');
    executable(join(rubyBin, 'bundle'), 'printf "%s\\n%s\\n%s\\n" "${http_proxy-unset}" "${HTTP_PROXY-unset}" "${HTTPS_PROXY-unset}" > "$PROXY_RECEIPT"');
    const pathFile = join(root, 'github-path');
    const receipt = join(root, 'proxies');
    writeFileSync(pathFile, '');
    const env = {...process.env, PATH: '/usr/bin:/bin', RUNNER_TOOLING_BIN: tooling,
      RUNNER_HOME: root, FIXTURE_HOME: root, GITHUB_PATH: pathFile, PROXY_RECEIPT: receipt};
    for (const key of ['http_proxy', 'HTTP_PROXY', 'https_proxy', 'HTTPS_PROXY', 'ALL_PROXY', 'all_proxy']) delete env[key];
    Object.assign(env, proxies);
    // 将主目录读取限定到测试资料，实际运行 Action 的 Bash 内容和系统 nc。
    const result = await runShell(script.replaceAll('$HOME', '$FIXTURE_HOME'), env);
    assert.equal(result.code, 0, result.output);
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
}

test('Ruby 路径跨步骤保留，可用的小写 HTTP 代理优先于失效的其他代理', macOS, async () => {
  const server = createServer(socket => socket.end());
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    const proxy = `http://127.0.0.1:${server.address().port}`;
    assert.deepEqual(await exercise({http_proxy: proxy, HTTP_PROXY: 'http://127.0.0.1:0', HTTPS_PROXY: 'http://127.0.0.1:0'}),
      [proxy, 'http://127.0.0.1:0', 'http://127.0.0.1:0']);
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
});

test('未设置小写 HTTP 代理时检测大写配置，并清除实际失效的本地代理', macOS, async () => {
  assert.deepEqual(await exercise({HTTP_PROXY: 'http://127.0.0.1:0', HTTPS_PROXY: 'https://example.invalid'}),
    ['unset', 'unset', 'unset']);
});

test('空的小写 HTTP 代理不回退到大写或 HTTPS 配置', macOS, async () => {
  assert.deepEqual(await exercise({http_proxy: '', HTTP_PROXY: 'http://127.0.0.1:0', HTTPS_PROXY: 'https://example.invalid'}),
    ['', 'http://127.0.0.1:0', 'https://example.invalid']);
});
