import assert from 'node:assert/strict';
import { test } from 'node:test';
import { inspectCurrentPage } from '../src/android-web-app-mcp.mjs';

test('同一网址重新加载时丢弃检查结果并关闭 CDP 连接', async () => {
  const url = 'https://aegis-test.example/web-app';
  const targetId = 'TEST_TAB';
  const documentReads = ['before-reload', 'after-reload'];
  let detached = false;
  let disconnected = false;
  const session = {
    async send(method) {
      switch (method) {
      case 'Target.getTargetInfo':
        return { targetInfo: { targetId, url } };
      case 'Page.getFrameTree':
        return { frameTree: { frame: { id: 'main-frame', loaderId: documentReads.shift(), url } } };
      case 'Page.getAppManifest':
        return { url: `${url}.webmanifest`, manifest: { name: '测试网页应用' }, errors: [] };
      case 'Page.getInstallabilityErrors':
        return { installabilityErrors: [] };
      default:
        assert.fail(`收到意外的 CDP 命令 ${method}`);
      }
    },
    async detach() { detached = true; },
  };
  const page = { url: () => url, createCDPSession: async () => session };
  const browser = { pages: async () => [page], disconnect() { disconnected = true; } };
  const puppeteer = { connect: async () => browser };

  await assert.rejects(inspectCurrentPage(puppeteer, 'ws://localhost', url, targetId), /检查期间网页已切换/);
  assert.deepEqual(documentReads, []);
  assert.ok(detached && disconnected);
});
