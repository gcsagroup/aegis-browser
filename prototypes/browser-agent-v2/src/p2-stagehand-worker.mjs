import fs from 'node:fs';
import { localBrowser, Stagehand } from '@browserbasehq/stagehand';

async function main() {
  const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  let browser;
  try {
    browser = await localBrowser.launch({
      executablePath: config.browserExecutable,
      userDataDir: config.profilePath,
      preserveUserDataDir: true,
      headless: true,
      chromiumSandbox: true,
      ignoreHTTPSErrors: false,
      downloadsPath: config.downloadsPath,
      acceptDownloads: false,
      keepAlive: false,
      locale: 'zh-CN',
      viewport: { width: 1280, height: 800 },
      args: [
        `--ignore-certificate-errors-spki-list=${config.fixtureSpkiSha256}`,
        '--disable-background-networking',
        '--disable-component-update',
        '--disable-sync',
        '--metrics-recording-only',
        '--no-first-run',
      ],
    });
    await Stagehand.create({
      browser,
      telemetry: { traces: { endpoint: config.telemetryEndpoint, headers: {} } },
      logging: { level: 'off', format: 'json' },
      cache: false,
      selfHeal: false,
    });
    const [page] = await browser.context.pages();
    await page.goto(config.targetUrl, { waitUntil: 'domcontentloaded', timeout: 15_000 });
    const before = await page.snapshot();
    await page.locator('#refresh').click();
    const after = await page.snapshot();
    const result = {
      provider: browser.provider,
      origin: browser.origin,
      url: await page.url(),
      title: await page.title(),
      before: before.formattedTree,
      after: after.formattedTree,
    };
    process.stdout.write(`${JSON.stringify(result)}\n`);
  } finally {
    if (browser && !browser.closed) await browser.close();
  }
}

main().catch((error) => {
  process.stderr.write(`${error.stack ?? error.message}\n`);
  process.exitCode = 1;
});
