import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { startFixtureServer } from './fixture-server.mjs';
import { McpStdioClient } from './mcp-stdio-client.mjs';
import { createRunContext } from './run-context.mjs';

const platform = process.argv[2];
assert.ok(['android', 'ios'].includes(platform), '请指定 android 或 ios');
const serial = process.env.AEGIS_ADB_SERIAL;
const simulator = process.env.AEGIS_IOS_SIMULATOR_ID;
assert.ok(platform === 'android' ? serial?.startsWith('emulator-') : simulator,
  '验收命令需要显式指定模拟器');
const { runRoot, workingDirectory, journal } = createRunContext({
  scenarioId: 'MOBILE-DEVTOOLS', candidate: platform,
});
const hits = new Map();
const fixture = await startFixtureServer({
  runRoot, secure: false,
  onRequest: ({ path: pathname }) => hits.set(pathname, (hits.get(pathname) ?? 0) + 1),
});
const url = fixture.origin + '/devtools';
const adb = (...args) => execFileSync('adb', ['-s', serial, ...args], {
  encoding: 'utf8', timeout: 8000, stdio: ['ignore', 'pipe', 'pipe'],
}).trim();
const android = platform === 'android';
const { port } = new URL(url);
const forwardedFixture = 'tcp:' + port;
let reverseActive = false;
let foreignFixture;
let client;
let stage = '启动 MCP';
let passed = false;
let failure;

const tools = ['navigate_page', 'take_snapshot', 'take_screenshot'];
if (!android) tools.push('inspect_web_app');
if (android) tools.push('list_pages', 'wait_for', 'fill', 'click',
  'list_console_messages', 'get_network_request', 'list_network_requests',
  'performance_start_trace', 'performance_stop_trace', 'mock_network', 'remove_network_mock');
const text = reply => reply.content.filter(item => item.type === 'text').map(item => item.text).join('\n');
async function call(name, params = {}) {
  stage = name;
  const reply = await client.callTool(name, params);
  assert.ok(!reply.isError, `${name} ${text(reply)}`);
  return reply;
}
function connect(args, allowedTools) {
  return new McpStdioClient({
    command: process.execPath,
    args: [fileURLToPath(new URL(`./chrome-devtools-${platform}.mjs`, import.meta.url)), ...args],
    cwd: workingDirectory,
    env: { ...process.env, AEGIS_IOS_DEVTOOLS_ORIGIN: fixture.origin },
    allowedTools,
    timeoutMs: 40_000,
  });
}

function browserForwards() {
  return new Set(adb('forward', '--list').split('\n').flatMap(line => {
    const [device, local, peer] = line.trim().split(/\s+/);
    return device === serial && /^tcp:\d+$/.test(local ?? '') &&
      peer === 'localabstract:chrome_devtools_remote' ? [local] : [];
  }));
}

async function recordIdentity() {
  let identity;
  if (android) {
    const packageInfo = adb('shell', 'dumpsys', 'package', 'app.gcsa.aegis');
    const apk = adb('shell', 'pm', 'path', 'app.gcsa.aegis').split('\n')
      .find(line => line.startsWith('package:') && line.endsWith('/base.apk'))?.slice('package:'.length);
    assert.ok(apk && /^[/A-Za-z0-9._=~-]+$/.test(apk), '测试 APK 路径无效');
    identity = {
      platform,
      kind: 'emulator',
      os: adb('shell', 'getprop', 'ro.build.version.release'),
      device: adb('shell', 'getprop', 'ro.product.model'),
      version: packageInfo.match(/versionName=(.+)/)?.[1]?.trim(),
      build: packageInfo.match(/versionCode=(\d+)/)?.[1],
      apkSha256: adb('shell', 'sha256sum', apk).split(/\s+/)[0],
    };
    assert.match(identity.apkSha256, /^[a-f0-9]{64}$/);
  } else {
    const simctl = (...args) => execFileSync('xcrun', ['simctl', ...args], { encoding: 'utf8', timeout: 8000 }).trim();
    const { devices } = JSON.parse(simctl('list', 'devices', 'booted', '-j'));
    const entry = Object.entries(devices).find(([, targets]) => targets.some(item => item.udid === simulator));
    assert.ok(entry, '指定的 iOS 验收模拟器尚未启动');
    const [runtime, targets] = entry;
    const target = targets.find(item => item.udid === simulator);
    const app = simctl('get_app_container', simulator, 'com.gcsa.aegis', 'app');
    const info = JSON.parse(execFileSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path.join(app, 'Info.plist')], {
      encoding: 'utf8', timeout: 8000,
    }));
    const executableName = info.CFBundleExecutable;
    assert.match(executableName, /^[A-Za-z0-9][A-Za-z0-9 ._-]*$/, '无效的验收 App 可执行文件名');
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- 通过文件名校验后，只读取验收 App 包内的可执行文件。
    const executable = await readFile(path.join(app, executableName));
    identity = { platform, kind: 'simulator', device: target.name, runtime,
      bundleId: info.CFBundleIdentifier, version: info.CFBundleShortVersionString, build: info.CFBundleVersion,
      executableSha256: createHash('sha256').update(executable).digest('hex') };
  }
  assert.ok(identity.version && identity.build, '无法确认实际安装版本');
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- 产物路径由本次隔离测试目录与固定文件名生成。
  await writeFile(path.join(runRoot, 'installed-identity.json'), JSON.stringify(identity, null, 2) + '\n', { mode: 0o600 });
}
const screenshotPath = path.join(workingDirectory, 'mobile-fixture.png');
const assertPNG = data => assert.equal(data.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
try {
  const config = path.join(workingDirectory, 'config.json');
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- 产物路径由本次隔离测试目录与固定文件名生成。
  await writeFile(config, '{}', { mode: 0o600 });
  if (android) {
    adb('reverse', '--no-rebind', forwardedFixture, forwardedFixture);
    reverseActive = true;
    adb('shell', 'am', 'start', '-W', '-a', 'android.intent.action.VIEW', '-d', url, '-p', 'app.gcsa.aegis');
    const deadline = Date.now() + 8000;
    while (!hits.has('/devtools/api') && Date.now() < deadline) await delay(100);
    assert.ok(hits.has('/devtools/api'), 'Android 验收页未收到真实网络响应');
  }
  await recordIdentity();
  client = connect(android ? [
    `--config=${config}`, '--category-network-mocks', '--no-file-navigations',
    `--filesystem-root=${workingDirectory}`, `--allowed-url-pattern=${fixture.origin}/*`,
  ] : [], tools);
  const hello = await client.initialize();
  assert.ok(hello.serverInfo.name, 'MCP 没有返回服务身份');
  const { tools: available } = await client.listTools();
  assert.ok(tools.every(name => available.some(tool => tool.name === name)));
  journal.assertion('MCP 工具注册', true, { name: hello.serverInfo.name });

  if (android) {
    let pageId;
    let pages;
    const deadline = Date.now() + 8000;
    do {
      pages = text(await call('list_pages'));
      pageId = Number(pages.split('\n').find(line => line.includes(`(${url})`))?.match(/^(\d+):/)?.[1]);
      if (Number.isSafeInteger(pageId)) break;
      await delay(250);
    } while (Date.now() < deadline);
    assert.ok(Number.isSafeInteger(pageId), pages || 'MCP 返回的页面列表为空');
    const target = { pageId };
    await call('navigate_page', { ...target, type: 'reload', ignoreCache: true, timeout: 10000 });
    await call('wait_for', { ...target, text: ['诊断状态 503'], timeout: 8000 });
    const snapshot = text(await call('take_snapshot', target));
    assert.match(snapshot, /Aegis 诊断测试页/);
    const input = snapshot.match(/uid=(\S+) textbox "诊断备注"/)?.[1];
    const button = snapshot.match(/uid=(\S+) button "显示备注"/)?.[1];
    assert.ok(input && button, snapshot);
    await call('fill', { ...target, uid: input, value: 'ANDROID_MCP' });
    await call('click', { ...target, uid: button });
    await call('wait_for', { ...target, text: ['备注已显示 ANDROID_MCP'], timeout: 8000 });
    assert.match(text(await call('take_snapshot', target)), /备注已显示 ANDROID_MCP/);
    journal.assertion('导航、DOM、点击及输入', true);

    await call('take_screenshot', { ...target, filePath: screenshotPath });
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- 产物路径由本次隔离测试目录与固定文件名生成。
    assertPNG(await readFile(screenshotPath));
    assert.match(text(await call('list_console_messages', { ...target, types: ['error'] })), /AEGIS_FIXTURE_CONSOLE_ERROR/);
    const network = text(await call('list_network_requests', { ...target, resourceTypes: ['fetch'] }));
    const reqid = Number(network.split('\n').find(line => line.includes('/devtools/api [503]'))?.match(/^reqid=(\d+)/)?.[1]);
    assert.ok(Number.isSafeInteger(reqid), network);
    assert.match(text(await call('get_network_request', { ...target, reqid })), /AEGIS_FIXTURE_BODY/);
    journal.assertion('截图、控制台和真实网络响应', true);

    const tracePath = path.join(workingDirectory, 'mobile-trace.json.gz');
    await call('performance_start_trace', { ...target, reload: false, autoStop: false });
    await call('navigate_page', { ...target, type: 'reload', ignoreCache: true });
    await call('wait_for', { ...target, text: ['诊断状态 503'], timeout: 8000 });
    await call('performance_stop_trace', { ...target, filePath: tracePath });
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- 产物路径由本次隔离测试目录与固定文件名生成。
    assert.equal((await readFile(tracePath)).subarray(0, 2).toString('hex'), '1f8b');
    journal.assertion('Android 浏览器性能 trace', true);

    const route = fixture.origin + '/devtools/api';
    const body = path.join(workingDirectory, 'mock.json');
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- 产物路径由本次隔离测试目录与固定文件名生成。
    await writeFile(body, '{"diagnostic":"mobile-mock"}', { mode: 0o600 });
    const rule = { ...target, route, resourceType: 'fetch' };
    const apiHits = hits.get('/devtools/api') ?? 0;
    const scriptHits = hits.get('/devtools.js') ?? 0;
    await call('mock_network', { ...rule, body });
    try {
      await call('navigate_page', { ...target, type: 'reload', ignoreCache: true });
      await call('wait_for', { ...target, text: ['诊断状态 200'], timeout: 8000 });
      assert.equal(hits.get('/devtools/api'), apiHits, '命中 Mock 的请求到达了源站');
      assert.ok(hits.get('/devtools.js') > scriptHits, '未命中 Mock 的脚本请求应放行');
    } finally {
      const mockStage = stage;
      await call('remove_network_mock', rule);
      stage = mockStage;
    }
    await call('navigate_page', { ...target, type: 'reload', ignoreCache: true });
    await call('wait_for', { ...target, text: ['诊断状态 503'], timeout: 8000 });
    assert.ok(hits.get('/devtools/api') > apiHits, '撤销 Mock 后真实请求未恢复');
    journal.assertion('Mock 命中、未命中与撤销恢复', true);

    await client.close();
    stage = 'Android 网页应用检查';
    const appUrl = fixture.origin + '/mobile-web-app';
    adb('shell', 'am', 'start', '-W', '-a', 'android.intent.action.VIEW', '-d', appUrl, '-p', 'app.gcsa.aegis');
    const appDeadline = Date.now() + 8000;
    while (!hits.has('/mobile-web-app.webmanifest') && Date.now() < appDeadline) await delay(100);
    assert.ok(hits.has('/mobile-web-app.webmanifest'), '网页应用测试页未完成加载');
    const joins = browserForwards();
    client = connect(['--web-app-inspection'], ['inspect_web_app']);
    await client.initialize();
    const [ownedPort, ...unexpectedPorts] = [...browserForwards()].filter(port => !joins.has(port));
    assert.ok(ownedPort && unexpectedPorts.length === 0, '无法唯一识别本次验收创建的 CDP 转发');
    const { tools: webAppTools } = await client.listTools();
    assert.deepEqual(webAppTools.map(tool => tool.name), ['inspect_web_app']);
    const report = JSON.parse(text(await call('inspect_web_app', { url: appUrl })));
    assert.equal(report.manifestUrl, fixture.origin + '/mobile-web-app.webmanifest');
    assert.equal(report.manifest.id, appUrl);
    assert.equal(report.manifest.startUrl, appUrl);
    assert.equal(report.manifest.display, 'kStandalone');
    assert.deepEqual(report.manifestErrors, []);
    assert.deepEqual(report.installabilityErrors, []);
    assert.ok((await client.callTool('inspect_web_app', { url: fixture.origin + '/never-opened' })).isError);
    assert.ok((await client.callTool('inspect_web_app', { url: 'file:///tmp/not-a-web-app' })).isError);
    const missingTarget = await client.callTool('inspect_web_app', { url: appUrl, targetId: 'MISSING_TARGET' });
    assert.ok(missingTarget.isError && /指定标签已关闭/.test(text(missingTarget)));
    journal.assertion('读取 Android Manifest 和安装条件，并拒绝未打开网页', true);

    stage = 'Android 同网址双标签';
    adb('shell', 'am', 'start', '-W', '-a', 'android.intent.action.VIEW', '-d', appUrl, '-p', 'app.gcsa.aegis');
    let ambiguous;
    const targetDeadline = Date.now() + 8000;
    do {
      ambiguous = await client.callTool('inspect_web_app', { url: appUrl });
      if (ambiguous.isError && /同一网址有多个标签/.test(text(ambiguous))) break;
      await delay(200);
    } while (Date.now() < targetDeadline);
    assert.ok(ambiguous?.isError, '同一网址的两个标签应要求选择');
    const targetIDs = text(ambiguous).match(/可选目标 ([A-F0-9、]+)$/)?.[1]?.split('、');
    assert.equal(targetIDs?.length, 2, text(ambiguous));
    assert.ok(targetIDs.includes(report.targetId));
    const secondID = targetIDs.find(id => id !== report.targetId);
    const peer = connect(['--web-app-inspection'], ['inspect_web_app']);
    try {
      await peer.initialize();
      const [first, second] = await Promise.all([
        client.callTool('inspect_web_app', { url: appUrl, targetId: report.targetId }),
        peer.callTool('inspect_web_app', { url: appUrl, targetId: secondID }),
      ]);
      assert.ok(!first.isError && !second.isError, text(first) + text(second));
      assert.equal(JSON.parse(text(first)).targetId, report.targetId);
      assert.equal(JSON.parse(text(second)).targetId, secondID);
      journal.assertion('Android 双客户端按标签目标 ID 选中同网址页面', true);

      stage = 'Android ADB 断开重连';
      adb('forward', '--remove', ownedPort);
      assert.ok((await client.callTool('inspect_web_app', { url: appUrl, targetId: report.targetId })).isError);
      const peerResult = await peer.callTool('inspect_web_app', { url: appUrl, targetId: secondID });
      assert.equal(JSON.parse(text(peerResult)).targetId, secondID);
      await client.close();
      client = connect(['--web-app-inspection'], ['inspect_web_app']);
      await client.initialize();
      const reconnected = await call('inspect_web_app', { url: appUrl, targetId: report.targetId });
      assert.equal(JSON.parse(text(reconnected)).targetId, report.targetId);
      journal.assertion('Android 转发断开后可重连且第二个客户端继续工作', true);
    } finally {
      await peer.close();
    }
  } else {
    const denied = await client.callTool('navigate_page', { url: 'http://127.0.0.1:1/' });
    assert.ok(denied.isError, '诊断工具接受了其它端口');
    journal.assertion('拒绝非本次测试源站', true);
    assert.equal(JSON.parse(text(await call('navigate_page', { url }))).url, url);
    const snapshot = JSON.parse(text(await call('take_snapshot')));
    assert.equal(snapshot.url, url);
    assert.match(snapshot.title, /Aegis 诊断测试页/);
    assert.match(snapshot.text, /Aegis 诊断测试页/);
    journal.assertion('iOS 导航与真实 WebKit DOM', true);
    const shot = (await call('take_screenshot')).content.find(item => item.type === 'image');
    assert.equal(shot?.mimeType, 'image/png');
    const png = Buffer.from(shot.data, 'base64');
    assertPNG(png);
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- 产物路径由本次隔离测试目录与固定文件名生成。
    await writeFile(screenshotPath, png, { mode: 0o600 });
    journal.assertion('真实 WebKit PNG 截图', true);
    await call('navigate_page', { url: fixture.origin + '/login' });
    assert.ok((await client.callTool('take_snapshot')).isError);
    assert.ok((await client.callTool('take_screenshot')).isError);
    journal.assertion('敏感表单拒绝读取和截图', true);
    let outsideHits = 0;
    foreignFixture = await startFixtureServer({ runRoot, secure: false, onRequest: () => { outsideHits += 1; } });
    const outside = new URL('/redirect-out', fixture.origin);
    outside.searchParams.set('to', foreignFixture.origin + '/research');
    assert.ok((await client.callTool('navigate_page', { url: outside.href })).isError);
    assert.ok(hits.has('/redirect-out'));
    assert.equal(outsideHits, 0, 'WebKit 跨源重定向抵达了第二个服务器');
    journal.assertion('WebKit 拦截跨源重定向', true);

    stage = 'iOS 同源 Manifest 检查';
    const appUrl = fixture.origin + '/mobile-web-app';
    await call('navigate_page', { url: appUrl });
    const actualManifest = JSON.parse(text(await call('inspect_web_app')));
    assert.equal(actualManifest.manifest.manifestURL, fixture.origin + '/mobile-web-app.webmanifest');
    assert.equal(actualManifest.manifest.id, appUrl);
    assert.equal(actualManifest.manifest.startURL, appUrl);
    assert.equal(actualManifest.manifest.display, 'standalone');
    journal.assertion('iOS Manifest 同源读取', true);

    stage = 'iOS 异常退出后重连';
    const peer = connect([], tools);
    try {
      await assert.rejects(peer.initialize());
      assert.match(peer.stderrLines.join('\n'), /已有诊断会话/);
      assert.match(text(await call('take_snapshot')), /移动网页应用测试标记/);
    } finally {
      await peer.close();
    }
    client.child.kill('SIGKILL');
    await client.exitPromise;
    client = connect([], tools);
    await client.initialize();
    await call('navigate_page', { url });
    assert.match(text(await call('take_snapshot')), /Aegis 诊断测试页/);
    journal.assertion('iOS 并发锁拒绝和强制退出后恢复', true);
    const noManifest = JSON.parse(text(await call('inspect_web_app')));
    assert.equal(noManifest.url, url);
    assert.deepEqual(noManifest.manifest, {});
    journal.assertion('iOS 页面没有 Manifest 时返回空结果', true);
  }
  passed = true;
} catch (error) {
  failure = error.message || String(error);
  journal.assertion(stage, false, { error: failure, requests: Object.fromEntries(hits) });
  process.exitCode = 1;
} finally {
  await client?.close();
  if (reverseActive) adb('reverse', '--remove', forwardedFixture);
  await Promise.all([fixture.close(), foreignFixture?.close()]);
  journal.append('run.finished', { platform, passed });
}
if (failure) process.stderr.write(failure + '\n' + (client?.stderrLines ?? []).slice(-8).join('\n') + '\n');
process.stdout.write(`${passed ? '验证通过' : '验证失败'}，证据目录 ${runRoot}\n`);
