import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { constants } from 'node:fs';
import { access, mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { startFixtureServer } from './fixture-server.mjs';
import { McpStdioClient } from './mcp-stdio-client.mjs';
import { createRunContext } from './run-context.mjs';
import { buildAdapterEnvironment, validateNavigationUrl } from './security.mjs';

const require = createRequire(import.meta.url);
const advanced = process.argv.includes('--advanced');
const networkMock = process.argv.includes('--network-mock');
const toolNames = [
  'list_pages', 'new_page', 'select_page', 'close_page', 'navigate_page', 'wait_for',
  'take_snapshot', 'take_screenshot',
  'list_console_messages', 'get_console_message', 'list_network_requests', 'get_network_request',
  'performance_start_trace', 'performance_stop_trace', 'get_css_styles', 'lighthouse_audit',
  'take_heapsnapshot', 'get_heapsnapshot_summary', 'close_heapsnapshot', 'fill', 'click', 'emulate',
  ...(advanced ? [
    'set_logpoints', 'screencast_start', 'screencast_stop',
    'install_extension', 'list_extensions', 'reload_extension', 'uninstall_extension',
  ] : []),
  ...(networkMock ? ['mock_network', 'remove_network_mock'] : []),
];
const defaultChrome = '/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const executable = process.env.AEGIS_DEVTOOLS_CHROME || defaultChrome;
if (!path.isAbsolute(executable)) throw new Error('AEGIS_DEVTOOLS_CHROME 必须是浏览器可执行文件的绝对路径');
await access(executable, constants.X_OK).catch(() => {
  throw new Error('找不到可执行的 Chrome for Testing，请用 AEGIS_DEVTOOLS_CHROME 指定路径');
});

const { version: mcpVersion } = require('chrome-devtools-mcp/package.json');
const launcher = fileURLToPath(new URL('./devtools-mcp.mjs', import.meta.url));
const context = createRunContext({ scenarioId: 'DEVTOOLS', candidate: 'chrome-devtools-mcp' });
const { runRoot, workingDirectory, journal } = context;
const tmp = path.join(workingDirectory, 'tmp');
// eslint-disable-next-line security/detect-non-literal-fs-filename -- 产物路径由本次隔离测试目录与固定文件名生成。
await mkdir(tmp, { mode: 0o700 });
const config = path.join(workingDirectory, 'devtools-config.json');
// eslint-disable-next-line security/detect-non-literal-fs-filename -- 产物路径由本次隔离测试目录与固定文件名生成。
await writeFile(config, '{}', { mode: 0o600 });

const requests = new Map();
let forbiddenRequests = 0;
let fixture;
let forbiddenTarget;
let client;
let stage = '初始化';
let passed = false;
try {
  fixture = await startFixtureServer({
    runRoot,
    onRequest: ({ path: requestPath }) => requests.set(requestPath, (requests.get(requestPath) ?? 0) + 1),
  });
  forbiddenTarget = await startFixtureServer({
    runRoot, secure: false, onRequest: () => { forbiddenRequests += 1; },
  });
  const url = validateNavigationUrl(`${fixture.origin}/devtools`, {
    allowedOrigins: [fixture.origin], fixtureOrigins: [fixture.origin],
  }).href;
  const secondUrl = `${fixture.origin}/research?from=devtools`;
  const env = buildAdapterEnvironment({ sourceEnvironment: process.env, runRoot, workingDirectory });
  client = new McpStdioClient({
    command: process.execPath,
    args: [
      launcher, `--config=${config}`, `--executable-path=${executable}`, '--headless',
      '--lighthouse-skip-about-blank',
      advanced ? '--category-extensions' : '--no-javascript-evaluation',
      ...(networkMock ? ['--category-network-mocks'] : []),
      '--no-file-navigations', '--no-source-maps',
      '--max-navigation-saved=1', `--allowed-url-pattern=${fixture.origin}/*`,
      `--filesystem-root=${workingDirectory}`,
      `--chrome-arg=--ignore-certificate-errors-spki-list=${fixture.spkiSha256}`,
      '--chrome-arg=--disable-component-update',
      '--chrome-arg=--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1',
      `--chrome-arg=${url}`,
    ],
    cwd: workingDirectory,
    env: { ...env, HOME: workingDirectory, USERPROFILE: workingDirectory, TMPDIR: tmp,
      TMP: tmp, TEMP: tmp },
    allowedTools: toolNames,
    timeoutMs: 40_000,
  });
  const call = async (name, args) => {
    stage = name;
    const result = await client.callTool(name, args);
    assert.ok(!result.isError);
    return result.content.filter(item => item.type === 'text').map(item => item.text).join('\n');
  };

  assert.equal((await client.initialize()).serverInfo.version, mcpVersion);
  const { tools } = await client.listTools();
  assert.ok(toolNames.every(name => tools.some(tool => tool.name === name)));
  if (!advanced) {
    assert.ok(!tools.some(tool => ['evaluate_script', 'set_logpoints'].includes(tool.name)));
  }
  await assert.rejects(client.callTool('upload_file', {}), /allowlist/);
  journal.assertion('工具清单与调用权限', true, { advertised: tools.length, exercised: toolNames.length });

  const pages = await call('list_pages');
  const pageIdForUrl = (pageList, href) => {
    const pageLine = pageList.split('\n').find(line => line.includes(`(${href})`));
    return Number(pageLine?.match(/^(\d+):/)?.[1]);
  };
  const pageId = pageIdForUrl(pages, url);
  assert.ok(Number.isSafeInteger(pageId));
  const target = { pageId };
  await call('navigate_page', { ...target, type: 'reload', ignoreCache: true, timeout: 8_000 });
  await call('wait_for', { ...target, text: ['诊断状态 503'], timeout: 8_000 });
  const snapshot = await call('take_snapshot', target);
  assert.ok(snapshot.includes('诊断状态 503'));
  journal.assertion('快照显示合成故障', true);

  const heading = snapshot.match(/uid=(\S+) heading "Aegis 诊断测试页"/)?.[1];
  assert.ok(heading);
  const styles = await call('get_css_styles', { ...target, uid: heading });
  assert.match(styles, /rgb\(12,\s*34,\s*56\)/);
  journal.assertion('读取实际匹配的 CSS 规则', true);

  const showNote = async (value, current) => {
    const pageSnapshot = current ?? await call('take_snapshot', target);
    const input = pageSnapshot.match(/uid=(\S+) textbox "诊断备注"/)?.[1];
    assert.ok(input);
    await call('fill', { ...target, uid: input, value });
    const afterFill = await call('take_snapshot', target);
    const button = afterFill.match(/uid=(\S+) button "显示备注"/)?.[1];
    assert.ok(button);
    await call('click', { ...target, uid: button });
    await call('wait_for', { ...target, text: [`备注已显示 ${value}`], timeout: 8_000 });
  };
  await showNote('AEGIS_NOTE', snapshot);
  journal.assertion('输入与点击后读回真实页面结果', true);

  try {
    await call('emulate', { ...target, colorScheme: 'light' });
    assert.doesNotMatch(await call('take_snapshot', target), /深色模式已生效/);
    await call('emulate', { ...target, colorScheme: 'dark' });
    assert.match(await call('take_snapshot', target), /深色模式已生效/);
  } finally {
    await call('emulate', target);
  }
  journal.assertion('浏览器媒体查询响应深色仿真', true);

  const messages = await call('list_console_messages', { ...target, types: ['error'], pageSize: 10 });
  const msgid = Number(messages.match(/^msgid=(\d+).*AEGIS_FIXTURE_CONSOLE_ERROR/m)?.[1]);
  assert.ok(Number.isSafeInteger(msgid));
  assert.match(await call('get_console_message', { ...target, msgid }), /AEGIS_FIXTURE_CONSOLE_ERROR/);
  const network = await call('list_network_requests', { ...target, resourceTypes: ['fetch'], pageSize: 10 });
  const requestLine = network.split('\n').find(line => line.includes(`${fixture.origin}/devtools/api [503]`));
  const reqid = Number(requestLine?.match(/^reqid=(\d+)/)?.[1]);
  assert.ok(Number.isSafeInteger(reqid));
  assert.match(await call('get_network_request', { ...target, reqid }), /AEGIS_FIXTURE_BODY/);
  journal.assertion('控制台详情、网络状态和响应正文', true, { status: 503 });

  if (advanced) {
    const logpoint = `${fixture.origin}/devtools.js:4 'AEGIS_LOGPOINT:' + note`;
    await call('set_logpoints', { ...target, logpoints: [logpoint] });
    const video = path.join(workingDirectory, 'fixture.mp4');
    try {
      await call('screencast_start', { ...target, filePath: video });
      try {
        await showNote('录屏一');
        await showNote('录屏二');
      } finally {
        await call('screencast_stop', target);
      }
      const consoleLog = await call('list_console_messages', { ...target, types: ['log'], pageSize: 10 });
      assert.match(consoleLog, /AEGIS_LOGPOINT:录屏一/);
      assert.match(consoleLog, /AEGIS_LOGPOINT:录屏二/);
      journal.assertion('日志点读取局部变量并继续执行', true);
    } finally {
      await call('set_logpoints', { ...target, logpoints: [] });
    }
    stage = '解码录屏产物';
    const { streams, format } = JSON.parse(execFileSync('ffprobe', [
      '-v', 'error', '-count_frames', '-select_streams', 'v:0',
      '-show_entries', 'stream=nb_read_frames:format=duration', '-of', 'json', video,
    ], { encoding: 'utf8', timeout: 10_000, stdio: ['ignore', 'pipe', 'pipe'] }));
    assert.ok(Number(streams[0]?.nb_read_frames) > 1 && Number(format.duration) > 0);
    journal.assertion('录屏生成可解码的多帧视频', true);

    const extensionPath = path.join(workingDirectory, 'extension');
    const manifestPath = path.join(extensionPath, 'manifest.json');
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- 产物路径由本次隔离测试目录与固定文件名生成。
    await mkdir(extensionPath, { mode: 0o700 });
    const manifest = { manifest_version: 3, name: 'Aegis 合成调试扩展', version: '1.0.0' };
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- 产物路径由本次隔离测试目录与固定文件名生成。
    await writeFile(manifestPath, JSON.stringify(manifest), { mode: 0o600 });
    const installed = await call('install_extension', { path: extensionPath });
    const id = installed.match(/Id: ([a-p]{32})/)?.[1];
    assert.ok(id);
    try {
      const listed = await call('list_extensions');
      assert.ok(listed.includes(id) && listed.includes(manifest.version));
      // eslint-disable-next-line security/detect-non-literal-fs-filename -- 产物路径由本次隔离测试目录与固定文件名生成。
      await writeFile(manifestPath, JSON.stringify({ ...manifest, version: '1.0.1' }));
      await call('reload_extension', { id });
      const reloaded = await call('list_extensions');
      assert.ok(reloaded.includes(id) && reloaded.includes('1.0.1'));
    } finally {
      await call('uninstall_extension', { id });
    }
    assert.ok(!(await call('list_extensions')).includes(id));
    journal.assertion('解包扩展安装、重载改版和卸载', true);
  }

  const screenshot = path.join(workingDirectory, 'fixture.png');
  await call('take_screenshot', { ...target, filePath: screenshot });
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- 产物路径由本次隔离测试目录与固定文件名生成。
  assert.equal((await readFile(screenshot)).subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
  const trace = path.join(workingDirectory, 'performance.json.gz');
  await call('performance_start_trace', { ...target, reload: false, autoStop: false });
  await call('navigate_page', { ...target, type: 'reload', ignoreCache: true, timeout: 8_000 });
  await call('wait_for', { ...target, text: ['诊断状态 503'], timeout: 8_000 });
  assert.ok((await call('performance_stop_trace', { ...target, filePath: trace })).includes('Summary of Performance trace findings'));
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- 产物路径由本次隔离测试目录与固定文件名生成。
  assert.equal((await readFile(trace)).subarray(0, 2).toString('hex'), '1f8b');
  journal.assertion('截图与性能 trace', true);

  const heap = path.join(workingDirectory, 'fixture.heapsnapshot');
  await call('take_heapsnapshot', { ...target, filePath: heap });
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- 产物路径由本次隔离测试目录与固定文件名生成。
  assert.ok((await stat(heap)).size > 1_024);
  try {
    const summary = await call('get_heapsnapshot_summary', { filePath: heap });
    assert.match(summary, /"nodeCount":\s*[1-9]\d*/);
  } finally {
    await call('close_heapsnapshot', { filePath: heap });
  }
  journal.assertion('生成、读取和关闭堆快照', true);

  for (const mode of ['snapshot', 'navigation']) {
    const outputDirPath = path.join(workingDirectory, `lighthouse-${mode}`);
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- 产物路径由本次隔离测试目录与固定文件名生成。
    await mkdir(outputDirPath, { mode: 0o700 });
    const beforeAudit = requests.get('/devtools');
    await call('lighthouse_audit', { ...target, mode, outputDirPath });
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- 产物路径由本次隔离测试目录与固定文件名生成。
    const report = JSON.parse(await readFile(path.join(outputDirPath, 'report.json'), 'utf8'));
    assert.equal(report.gatherMode, mode);
    assert.ok(Number.isFinite(report.categories.accessibility.score));
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- 产物路径由本次隔离测试目录与固定文件名生成。
    assert.ok((await stat(path.join(outputDirPath, 'report.html'))).size > 1_024);
    if (mode === 'navigation') {
      assert.equal(report.configSettings.skipAboutBlank, true);
      assert.equal(report.mainDocumentUrl, url);
      assert.ok(requests.get('/devtools') > beforeAudit);
    }
    journal.assertion(`Lighthouse ${mode} 生成 JSON 和 HTML`, true);
  }

  await call('navigate_page', { ...target, url: `${fixture.origin}/research`, timeout: 8_000 });
  await call('wait_for', { ...target, text: ['候选 A', '候选 B'], timeout: 8_000 });
  assert.match(await call('take_snapshot', target), /电池续航 18 小时/);
  await call('navigate_page', { ...target, type: 'back', timeout: 8_000 });
  await call('wait_for', { ...target, text: ['诊断状态 503'], timeout: 8_000 });
  journal.assertion('标签内导航并返回原页面', true);

  const opened = await call('new_page', { url: secondUrl, timeout: 8_000 });
  assert.ok(opened.includes(`(${secondUrl}) [selected]`));
  const secondPageId = pageIdForUrl(opened, secondUrl);
  assert.ok(Number.isSafeInteger(secondPageId));
  assert.notEqual(pageId, secondPageId);
  await call('select_page', { ...target, bringToFront: true });
  const selected = await call('select_page', { pageId: secondPageId, bringToFront: true });
  assert.ok(selected.includes(`(${secondUrl}) [selected]`));
  assert.match(await call('take_snapshot', { pageId: secondPageId }), /电池续航 18 小时/);
  await call('select_page', { ...target, bringToFront: true });
  await call('close_page', { pageId: secondPageId });
  const remaining = await call('list_pages');
  assert.ok(remaining.includes(`(${url}) [selected]`));
  assert.ok(!remaining.includes(secondUrl));
  journal.assertion('MCP 新建、切换并关闭第二个标签', true);

  if (networkMock) {
    const route = `${fixture.origin}/devtools/api`;
    const body = path.join(workingDirectory, 'mock-response.json');
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- 产物路径由本次隔离测试目录与固定文件名生成。
    await writeFile(body, '{"diagnostic":"AEGIS_FIXTURE_MOCK"}', { mode: 0o600 });
    const rule = { ...target, route, resourceType: 'fetch' };
    const requestsBefore = requests.get('/devtools/api');
    const scriptsBefore = requests.get('/devtools.js');
    await call('mock_network', { ...rule, body });
    try {
      await call('navigate_page', { ...target, type: 'reload', timeout: 8_000 });
      await call('wait_for', { ...target, text: ['诊断状态 200'], timeout: 5_000 });
      const requestsText = await call('list_network_requests', { ...target, resourceTypes: ['fetch'] });
      const mockedLine = requestsText.split('\n').find(line => line.includes(`${route} [200]`));
      const mockedId = Number(mockedLine?.match(/^reqid=(\d+)/)?.[1]);
      assert.ok(Number.isSafeInteger(mockedId));
      assert.match(await call('get_network_request', { ...target, reqid: mockedId }), /AEGIS_FIXTURE_MOCK/);
      assert.equal(requests.get('/devtools/api'), requestsBefore);
      assert.ok(requests.get('/devtools.js') > scriptsBefore);
    } finally {
      const mockStage = stage;
      await call('remove_network_mock', rule);
      stage = mockStage;
    }
    await call('navigate_page', { ...target, type: 'reload', timeout: 8_000 });
    await call('wait_for', { ...target, text: ['诊断状态 503'], timeout: 8_000 });
    assert.ok(requests.get('/devtools/api') > requestsBefore);
    journal.assertion('网络 Mock 命中、未命中请求续传及撤销恢复', true);
  }

  // 可达的第二个 loopback 服务用来区分策略拦截和网络连接失败。
  const redirectUrl = new URL('/redirect-out', fixture.origin);
  redirectUrl.searchParams.set('to', `${forbiddenTarget.origin}/research`);
  stage = '跨 origin 重定向';
  await client.callTool('navigate_page', { ...target, url: redirectUrl.href, timeout: 8_000 });
  assert.ok(requests.has('/redirect-out'));
  assert.equal(forbiddenRequests, 0);
  journal.assertion('重定向未访问第二服务', true);
  passed = true;
} catch {
  // 工具错误、控制台原文和页面内容都不写进摘要。
  journal.assertion(stage, false);
  process.exitCode = 1;
} finally {
  try {
    await client?.close();
  } finally {
    await Promise.all([fixture?.close(), forbiddenTarget?.close()]);
    journal.append('run.finished', { passed, mcpVersion });
  }
}
process.stdout.write(`${passed ? '验证通过' : `验证失败（${stage}）`}，证据目录 ${runRoot}\n`);
