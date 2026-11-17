export async function serveAndroidWebAppInspection(endpoint, signal) {
  const { McpServer, StdioServerTransport, puppeteer, zod } =
    await import('chrome-devtools-mcp/out/Default/gen/src/third_party/index.js');
  const server = new McpServer({ name: 'aegis-android-web-app', version: '1.0.0' });
  server.registerTool('inspect_web_app', {
    description: '读取 Aegis Android 已打开页面的 Web App Manifest 与 Chromium 安装条件。',
    annotations: { readOnlyHint: true },
    inputSchema: {
      url: zod.url({ protocol: /^https?$/ }).max(2048)
        .describe('设备上当前已经打开的完整 HTTP 或 HTTPS 网页地址'),
      targetId: zod.string().max(128).optional().describe('同一网址打开多次时，从提示中的标签目标 ID 选择'),
    },
  }, async ({ url, targetId }) => {
    const address = new URL(url);
    if (address.username || address.password) {
      return { isError: true, content: [{ type: 'text', text: '网页地址不能含有凭据。' }] };
    }
    try {
      const data = await inspectCurrentPage(puppeteer, endpoint, address.href, targetId);
      return { content: [{ type: 'text', text: JSON.stringify(data) }] };
    } catch (error) {
      return { isError: true, content: [{ type: 'text', text: error.message }] };
    }
  });

  signal.throwIfAborted();
  await (async () => {
    await server.connect(new StdioServerTransport());
    if (!signal.aborted && !process.stdin.readableEnded) {
      await new Promise(resolve => {
        signal.addEventListener('abort', resolve, { once: true });
        process.stdin.once('end', resolve);
      });
    }
  })().finally(() => server.close());
}

export async function inspectCurrentPage(puppeteer, endpoint, url, requestedTargetId) {
  const browser = await puppeteer.connect({
    browserWSEndpoint: endpoint,
    defaultViewport: null,
    protocolTimeout: 5000,
    targetFilter: target => target.type() === 'browser' || target.url() === url,
  });
  const sessions = [];
  return await (async () => {
    const pages = (await browser.pages()).filter(candidate => candidate.url() === url);
    if (!pages.length) throw new Error('Aegis Android 没有打开这个网页。');
    const candidates = [];
    for (const page of pages) {
      const session = await page.createCDPSession();
      sessions.push(session);
      const { targetInfo } = await session.send('Target.getTargetInfo');
      if (targetInfo.url === url) candidates.push({ page, session, id: targetInfo.targetId });
    }
    if (!requestedTargetId && candidates.length > 1) {
      const ids = candidates.map(candidate => candidate.id).sort();
      throw new Error(`同一网址有多个标签，请指定 targetId。可选目标 ${ids.join('、')}`);
    }
    const selected = requestedTargetId
      ? candidates.find(candidate => candidate.id === requestedTargetId) : candidates[0];
    if (!selected) throw new Error('指定标签已关闭或不再显示该网址。');
    const { page, session, id } = selected;
    const document = async () => (await session.send('Page.getFrameTree')).frameTree.frame;
    const before = await document();
    if (before.url.split('#')[0] !== url.split('#')[0] || page.url() !== url) {
      throw new Error('检查期间网页已切换，请重新发起检查。');
    }
    const [details, status] = await Promise.all([
      session.send('Page.getAppManifest'),
      session.send('Page.getInstallabilityErrors'),
    ]);
    const after = await document();
    if (before.id !== after.id || before.loaderId !== after.loaderId || before.url !== after.url || page.url() !== url) {
      throw new Error('检查期间网页已切换，请重新发起检查。');
    }
    const manifest = details.manifest;
    return {
      targetId: id,
      url,
      manifestUrl: details.url || null,
      manifest: manifest ? {
        id: manifest.id,
        name: manifest.name,
        startUrl: manifest.startUrl,
        scope: manifest.scope,
        display: manifest.display,
        icons: manifest.icons,
      } : null,
      manifestErrors: details.errors,
      installabilityErrors: status.installabilityErrors,
    };
  })()
    .finally(() => Promise.allSettled(sessions.map(session => session.detach())))
    .finally(() => browser.disconnect());
}
